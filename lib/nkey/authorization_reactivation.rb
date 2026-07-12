# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

module Nkey
  # nkey (ADR-0010): Liberar (reactivation in nkey) fires no lifecycle event, so
  # the block is lifted lazily on the next successful SSO — Zitadel just vouched
  # for the user (a Bloquear'd user cannot complete SSO at all).
  module AuthorizationReactivation
    def find_from_hash(hash)
      auth = super
      if auth &&
         Setting.get('nkey_integration') &&
         hash['provider'] == 'openid_connect' &&
         !auth.user.active
        auth.user.update!(active: true)
      end
      auth
    end
  end
end
