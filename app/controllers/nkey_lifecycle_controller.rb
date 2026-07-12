# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# nkey lifecycle webhook (ADR-0007 / ADR-0010): Zitadel Actions pushes user
# lifecycle events; the HMAC signature is the ONLY authentication. Contract:
# bad signature → 401 · non-object body → 400 · unknown event/user → 200 no-op ·
# idempotent · never 500 on hostile input.
class NkeyLifecycleController < ApplicationController
  skip_before_action :verify_csrf_token
  skip_before_action :user_device_log

  OWN_PROJECT_EVENTS = %w[user.grant.removed].freeze

  def handle
    raise ActiveRecord::RecordNotFound if !Setting.get('nkey_integration')

    raw = request.raw_post
    if !Nkey::WebhookSignature.valid?(
      header:      request.headers['ZITADEL-Signature'],
      raw_body:    raw,
      signing_key: ENV.fetch('ZITADEL_OFFBOARD_SIGNING_KEY', nil)
    )
      render json: { error: 'invalid signature' }, status: :unauthorized
      return
    end

    payload = parse_object(raw)
    if payload.nil?
      render json: { error: 'body must be a JSON object' }, status: :bad_request
      return
    end

    dispatch_event(payload)
    render json: { ok: true }
  end

  private

  def parse_object(raw)
    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  # NB: named `dispatch_event`, not `dispatch` — `ActionController::Metal#dispatch`
  # is the framework's own action dispatcher; overriding it breaks request handling.
  def dispatch_event(payload)
    case payload['event_type']
    when 'user.deactivated'
      with_user(payload['aggregateID']) { |user| soft_disable(user) }
    when 'user.removed'
      with_user(payload['aggregateID']) { |user| remove(user) }
    when *OWN_PROJECT_EVENTS
      # Fail-closed (nchat reference, live-verified): a blank env must NOT
      # disable scoping — blank == blank would soft-disable on EVERY app's
      # produto revoke.
      return if ENV.fetch('NKEY_NDESK_PROJECT_ID', nil).blank?

      grant = payload['event_payload'].is_a?(Hash) ? payload['event_payload'] : {}
      return if grant['projectId'].to_s != ENV.fetch('NKEY_NDESK_PROJECT_ID', nil)

      with_user(grant['userId']) { |user| soft_disable(user) }
    end
    # unknown events fall through → 200 no-op
  end

  def with_user(sub)
    return if sub.blank?

    authorization = Authorization.find_by(provider: 'openid_connect', uid: sub)
    return if !authorization

    yield(authorization.user)
  end

  # Soft-disable (spec §4.3): active=false blocks EVERY auth path per-request
  # in core; destroying the rack sessions kills the live UI instantly. Email
  # ticket threading is unaffected (sender matching ignores `active`).
  def soft_disable(user)
    user.update!(active: false) if user.active
    destroy_sessions_of(user)
  end

  # Removal propagation (spec §4.3): true DELETE when unreferenced; ticket-holding
  # users get the TOMBSTONE — email freed (glossary: Remover frees the email),
  # name kept for ticket attribution, Authorization unlinked, all auth blocked.
  def remove(user)
    sub = Authorization.find_by(user: user, provider: 'openid_connect')&.uid
    # Atomic: the OIDC link is severed BEFORE the delete/tombstone so the user's
    # own auth can't count as a reference. But that severing must commit only if
    # the whole removal succeeds — otherwise a mid-way failure strands the user
    # (auth gone, still active) and Zitadel's retry, finding no auth, silently
    # 200-no-ops. The transaction keeps the event re-processable on any failure.
    ActiveRecord::Base.transaction do
      Authorization.where(user: user, provider: 'openid_connect').destroy_all

      if removable?(user)
        destroy_sessions_of(user) # sessions aren't FK-linked; drop them explicitly
        user.destroy!
      else
        user.update!(email: "removed-#{sub}@nkey.invalid", active: false)
        destroy_sessions_of(user)
      end
    end
  end

  def removable?(user)
    Models.references('User', user.id).blank?
  rescue
    false
  end

  def destroy_sessions_of(user)
    ActiveRecord::SessionStore::Session.find_each do |session|
      session.destroy if session.data['user_id'] == user.id
    end
  end
end
