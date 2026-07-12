# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe 'nkey lifecycle webhook', :aggregate_failures, type: :request do
  let(:key)          { 'test-signing-key' }
  let(:project_id)   { 'ndesk-project-1' }
  let(:organization) { create(:organization) }
  let(:user)         { create(:customer, organization: organization) }

  before do
    Authorization.create!(user: user, uid: 'sub-1', provider: 'openid_connect')
    Setting.set('nkey_integration', true)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('ZITADEL_OFFBOARD_SIGNING_KEY', nil).and_return(key)
    allow(ENV).to receive(:fetch).with('NKEY_NDESK_PROJECT_ID', nil).and_return(project_id)
  end

  def signed_post(body_hash, sign_key: key)
    raw = body_hash.is_a?(String) ? body_hash : body_hash.to_json
    ts  = Time.zone.now.to_i
    hex = OpenSSL::HMAC.hexdigest('SHA256', sign_key, "#{ts}.#{raw}")
    post '/nkey/lifecycle', params: raw, headers: {
      'CONTENT_TYPE'      => 'application/json',
      'ZITADEL-Signature' => "t=#{ts},v1=#{hex}",
    }
  end

  # A rack session row keyed on a user id, matching how destroy_sessions_of reads
  # them (`session.data['user_id']`). String key on purpose — that is the stored shape.
  def make_session(user_id)
    ActiveRecord::SessionStore::Session.create!(
      session_id: SecureRandom.hex(16),
      data:       { 'user_id' => user_id }
    )
  end

  def session_exists?(session)
    ActiveRecord::SessionStore::Session.exists?(id: session.id)
  end

  describe 'authentication contract' do
    it 'rejects a missing signature with 401' do
      post '/nkey/lifecycle', params: '{}', headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a bad signature with 401' do
      signed_post({ event_type: 'user.deactivated', aggregateID: 'sub-1' }, sign_key: 'wrong')
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a signed non-object body with 400, never 500' do
      signed_post('[1,2,3]')
      expect(response).to have_http_status(:bad_request)
    end

    it 'answers 404 when nkey_integration is off (dark)' do
      Setting.set('nkey_integration', false)
      signed_post({ event_type: 'user.deactivated', aggregateID: 'sub-1' })
      expect(response).to have_http_status(:not_found)
    end

    it 'checks the dark-mode gate BEFORE the signature (off + no signature → 404, not 401)' do
      Setting.set('nkey_integration', false)
      post '/nkey/lifecycle', params: '{}', headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'user.deactivated (Bloquear) → soft-disable' do
    it 'deactivates the user and destroys ONLY their sessions' do
      target_session = make_session(user.id)
      other_user     = create(:customer)
      other_session  = make_session(other_user.id)

      signed_post({ event_type: 'user.deactivated', aggregateID: 'sub-1' })

      expect(response).to have_http_status(:ok)
      expect(user.reload.active).to be(false)
      expect(session_exists?(target_session)).to be(false)
      expect(session_exists?(other_session)).to be(true)
    end

    it 'no-ops an unknown sub with 200' do
      signed_post({ event_type: 'user.deactivated', aggregateID: 'ghost' })
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'user.grant.removed (produto revoke) → soft-disable, own project only' do
    it 'soft-disables when the projectId is ours (target = event_payload.userId)' do
      signed_post({ event_type:    'user.grant.removed',
                    aggregateID:   'grant-agg-1',
                    event_payload: { userId: 'sub-1', projectId: project_id } })
      expect(response).to have_http_status(:ok)
      expect(user.reload.active).to be(false)
    end

    it 'ignores a foreign projectId' do
      signed_post({ event_type:    'user.grant.removed',
                    event_payload: { userId: 'sub-1', projectId: 'someone-else' } })
      expect(response).to have_http_status(:ok)
      expect(user.reload.active).to be(true)
    end

    it 'no-ops (fail-closed) when NKEY_NDESK_PROJECT_ID is unset — blank must not match blank' do
      allow(ENV).to receive(:fetch).with('NKEY_NDESK_PROJECT_ID', nil).and_return(nil)
      signed_post({ event_type:    'user.grant.removed',
                    event_payload: { userId: 'sub-1', projectId: '' } })
      expect(response).to have_http_status(:ok)
      expect(user.reload.active).to be(true)
    end
  end

  describe 'user.removed (Remover) → delete or tombstone' do
    it 'deletes a user without references and drops their sessions' do
      target_session = make_session(user.id)
      signed_post({ event_type: 'user.removed', aggregateID: 'sub-1' })
      expect(response).to have_http_status(:ok)
      expect(User.find_by(id: user.id)).to be_nil
      expect(session_exists?(target_session)).to be(false)
    end

    it 'tombstones a ticket-holding user: frees the email, keeps the name, unlinks' do
      create(:ticket, customer: user, group: Group.first || create(:group))
      original_firstname = user.firstname
      signed_post({ event_type: 'user.removed', aggregateID: 'sub-1' })
      expect(response).to have_http_status(:ok)
      reloaded = User.find(user.id)
      expect(reloaded.email).to eq('removed-sub-1@nkey.invalid')
      expect(reloaded.active).to be(false)
      expect(reloaded.firstname).to eq(original_firstname)
      expect(Authorization.find_by(uid: 'sub-1', provider: 'openid_connect')).to be_nil
    end

    it 'is atomic: a failure mid-removal rolls back the auth severing so the event is re-processable' do
      create(:ticket, customer: user, group: Group.first || create(:group)) # forces the tombstone path
      allow_any_instance_of(User).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)

      signed_post({ event_type: 'user.removed', aggregateID: 'sub-1' })

      expect(response).not_to have_http_status(:ok)
      # The openid_connect Authorization must survive the rollback — otherwise a
      # Zitadel retry would find no auth and silently 200-no-op, stranding the
      # user active and un-offboarded.
      expect(Authorization.find_by(uid: 'sub-1', provider: 'openid_connect')).to be_present
      expect(user.reload.active).to be(true)
    end
  end

  it 'no-ops unknown event types with 200' do
    signed_post({ event_type: 'user.locked', aggregateID: 'sub-1' })
    expect(response).to have_http_status(:ok)
  end
end
