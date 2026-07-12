# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Nkey::UserResolver, :aggregate_failures do
  let(:organization) { create(:organization) }
  let(:raw_info) do
    {
      'email_verified'        => true,
      'ndesk_organization_id' => organization.id,
      'nkey_groups'           => ['account-113'],
    }
  end
  let(:auth_hash) do
    {
      'uid'   => 'zitadel-sub-1',
      'info'  => { 'email' => 'ana@cliente.com', 'first_name' => 'Ana', 'last_name' => 'Silva' },
      'extra' => { 'raw_info' => raw_info },
    }
  end

  def resolve
    described_class.new(auth_hash).resolve
  end

  describe 'deny paths' do
    it 'denies staff tokens outright' do
      raw_info['nkey_groups'] = ['staff']
      expect { resolve }.to raise_error(Nkey::LoginDenied, %r{usuários de clientes})
    end

    it 'denies unverified emails' do
      raw_info['email_verified'] = false
      expect { resolve }.to raise_error(Nkey::LoginDenied, %r{não foi verificado})
    end

    it 'denies a missing ndesk_organization_id claim (account-not-provisioned)' do
      raw_info.delete('ndesk_organization_id')
      expect { resolve }.to raise_error(Nkey::LoginDenied, %r{não está liberada})
    end

    it 'denies an unknown Organization' do
      raw_info['ndesk_organization_id'] = Organization.maximum(:id).to_i + 999
      expect { resolve }.to raise_error(Nkey::LoginDenied, %r{não está liberada})
    end

    it 'denies an inactive Organization' do
      organization.update!(active: false)
      expect { resolve }.to raise_error(Nkey::LoginDenied, %r{não está liberada})
    end
  end

  describe 'shared adoption rule' do
    it 'adopts an existing same-organization user, untouched roles/org' do
      existing = create(:customer, email: 'ana@cliente.com', organization: organization)
      expect(resolve).to eq(existing)
      expect(existing.reload.organization).to eq(organization)
    end

    it 'adopts an org-less user AND assigns the Organization' do
      existing = create(:customer, email: 'ana@cliente.com', organization: nil)
      expect(resolve).to eq(existing)
      expect(existing.reload.organization).to eq(organization)
    end

    it 'fails loud on a different Organization' do
      create(:customer, email: 'ana@cliente.com', organization: create(:organization))
      expect { resolve }.to raise_error(Nkey::LoginDenied, %r{vincular seu email})
    end

    it 'fails loud on multiple users with the email' do
      create(:customer, email: 'ana@cliente.com', organization: organization)
      second = build(:customer, email: 'ana@cliente.com', organization: organization)
      second.skip_ensure_uniq_email = true
      second.save!(validate: false)
      expect { resolve }.to raise_error(Nkey::LoginDenied, %r{vincular seu email})
    end

    it 'reactivates an inactive adoptee (Zitadel just vouched)' do
      existing = create(:customer, email: 'ana@cliente.com', organization: organization, active: false)
      expect(resolve).to eq(existing)
      expect(existing.reload.active).to be(true)
    end
  end

  describe 'JIT create' do
    it 'creates a Customer in the resolved Organization, no password' do
      user = resolve
      expect(user).to be_persisted
      expect(user.email).to eq('ana@cliente.com')
      expect(user.firstname).to eq('Ana')
      expect(user.organization).to eq(organization)
      expect(user.roles).to eq([Role.find_by(name: 'Customer')])
      expect(user.password).to be_blank
    end
  end
end
