# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

module Nkey
  # nkey (ADR-0010): when nkey_integration is on, the OpenID Connect provider's
  # user resolution is replaced by the nkey rules (clients-only door, tenant
  # resolution from the token, shared adoption rule, JIT Customer creation).
  # Off ⇒ stock Zammad behavior, byte-identical.
  module ProviderExtension
    private

    def fetch_user
      return super if !Setting.get('nkey_integration')

      Nkey::UserResolver.new(auth_hash).resolve
    end
  end
end
