# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# Adversarial QA (2026-07-12): hostile signed bodies to the lifecycle webhook.
# The contract: bad sig → 401 · non-object → 400 · unknown → 200 · NEVER 500.
RSpec.describe 'nkey lifecycle webhook — adversarial', :aggregate_failures, type: :request do
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

  def signed_post(raw_string)
    ts  = Time.zone.now.to_i
    hex = OpenSSL::HMAC.hexdigest('SHA256', key, "#{ts}.#{raw_string}")
    post '/nkey/lifecycle', params: raw_string, headers: {
      'CONTENT_TYPE' => 'application/json', 'ZITADEL-Signature' => "t=#{ts},v1=#{hex}"
    }
  end

  describe 'non-object bodies → 400, never 500 (W9/W10)' do
    ['42', '"a string"', 'null', 'true', '3.14', '[1,2,3]', 'not json at all', ''].each do |body|
      it "rejects #{body.inspect} with 4xx and not 500" do
        signed_post(body)
        expect(response.status).to be_between(400, 499)
        expect(response).not_to have_http_status(:internal_server_error)
      end
    end
  end

  describe 'type-confused fields must not 500 (W21/W23)' do
    it 'event_payload as a non-Hash string → no-op, no 500' do
      signed_post({ event_type: 'user.grant.removed', event_payload: 'hi' }.to_json)
      expect(response).not_to have_http_status(:internal_server_error)
      expect(user.reload.active).to be(true)
    end

    it 'event_payload as an array → no-op, no 500' do
      signed_post({ event_type: 'user.grant.removed', event_payload: [1, 2] }.to_json)
      expect(response).not_to have_http_status(:internal_server_error)
    end

    it 'aggregateID as an object (type confusion) → no crash, user untouched' do
      signed_post({ event_type: 'user.deactivated', aggregateID: { nested: 'x' } }.to_json)
      expect(response).not_to have_http_status(:internal_server_error)
      expect(user.reload.active).to be(true)
    end

    it 'aggregateID as an array → no crash' do
      signed_post({ event_type: 'user.removed', aggregateID: %w[a b] }.to_json)
      expect(response).not_to have_http_status(:internal_server_error)
    end

    it 'event_payload.userId as an object → no crash, target untouched' do
      signed_post({ event_type:    'user.grant.removed',
                    event_payload: { userId: { x: 1 }, projectId: project_id } }.to_json)
      expect(response).not_to have_http_status(:internal_server_error)
      expect(user.reload.active).to be(true)
    end
  end

  describe 'replay (W5) and future timestamp (W6)' do
    it 'a replayed valid body is idempotent (second delivery no-ops the same effect)' do
      body = { event_type: 'user.deactivated', aggregateID: 'sub-1' }.to_json
      signed_post(body)
      expect(user.reload.active).to be(false)
      signed_post(body) # replay
      expect(response).to have_http_status(:ok)
      expect(user.reload.active).to be(false)
    end

    it 'a far-future timestamp is rejected (|now - t| via abs)' do
      future = Time.zone.now.to_i + 10_000
      body   = '{"event_type":"user.deactivated","aggregateID":"sub-1"}'
      hex    = OpenSSL::HMAC.hexdigest('SHA256', key, "#{future}.#{body}")
      post '/nkey/lifecycle', params: body, headers: {
        'CONTENT_TYPE' => 'application/json', 'ZITADEL-Signature' => "t=#{future},v1=#{hex}"
      }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'double-remove idempotency (W27)' do
    it 'a second user.removed for the same sub no-ops (auth already gone)' do
      create(:ticket, customer: user, group: Group.first || create(:group))
      body = { event_type: 'user.removed', aggregateID: 'sub-1' }.to_json
      signed_post(body)
      expect(User.find(user.id).email).to eq('removed-sub-1@nkey.invalid')
      signed_post(body) # second delivery — auth already unlinked
      expect(response).to have_http_status(:ok)
    end
  end
end
