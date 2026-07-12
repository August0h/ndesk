# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

module Nkey
  # First-login resolution for the nkey OIDC door (ADR-0010; spec §4.2).
  # The door is CLIENTS-ONLY: staff tokens are denied outright.
  class UserResolver
    def initialize(auth_hash)
      @auth_hash = auth_hash
    end

    def resolve
      deny_staff!
      require_verified_email!
      organization = resolve_organization!
      adopt(organization) || jit_create(organization)
    end

    private

    attr_reader :auth_hash

    def raw_info
      auth_hash.dig('extra', 'raw_info') || {}
    end

    def email
      auth_hash.dig('info', 'email').to_s.strip.downcase
    end

    def deny_staff!
      groups = Array(raw_info['nkey_groups'])
      return if groups.exclude?('staff')

      raise Nkey::LoginDenied, __('O login nkey no NDesk está disponível apenas para usuários de clientes.')
    end

    def require_verified_email!
      return if raw_info['email_verified'] == true && email.present?

      raise Nkey::LoginDenied, __('Seu email nkey ainda não foi verificado.')
    end

    def resolve_organization!
      claim = raw_info['ndesk_organization_id']
      organization = claim.present? ? Organization.find_by(id: claim.to_i) : nil
      return organization if organization&.active

      raise Nkey::LoginDenied, __('Sua organização ainda não está liberada para o acesso ao suporte. Entre em contato com seu Gestor.')
    end

    # The SHARED ADOPTION RULE (spec §4.2 — identical semantics to the
    # accounts-manager eager-create receiver):
    #   one match, same org  -> adopt
    #   one match, org-less  -> adopt + assign
    #   different org        -> fail loud
    #   multiple matches     -> fail loud
    def adopt(organization)
      matches = User.where(email: email).to_a
      return nil if matches.empty?

      if matches.size > 1
        raise Nkey::LoginDenied, __('Não foi possível vincular seu email com segurança. Entre em contato com o suporte da New Byte.')
      end

      user = matches.first
      if user.organization_id.present? && user.organization_id != organization.id
        raise Nkey::LoginDenied, __('Não foi possível vincular seu email com segurança. Entre em contato com o suporte da New Byte.')
      end

      user.organization = organization if user.organization_id.blank?
      user.active = true if !user.active # Zitadel just vouched for them
      user.save! if user.changed?
      user
    end

    def jit_create(organization)
      User.create!(
        firstname:     auth_hash.dig('info', 'first_name').to_s,
        lastname:      auth_hash.dig('info', 'last_name').to_s,
        email:         email,
        login:         email,
        organization:  organization,
        role_ids:      [Role.find_by(name: 'Customer').id],
        active:        true,
        source:        'openid_connect',
        updated_by_id: 1,
        created_by_id: 1
      )
    end
  end
end
