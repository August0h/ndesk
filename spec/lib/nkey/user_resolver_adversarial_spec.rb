# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# Adversarial QA (2026-07-12): hostile / edge inputs to the nkey login resolver.
RSpec.describe Nkey::UserResolver, :aggregate_failures do
  let(:organization) { create(:organization) }
  let(:raw_info) do
    { 'email_verified' => true, 'ndesk_organization_id' => organization.id, 'nkey_groups' => ['account-113'] }
  end
  let(:auth_hash) do
    { 'uid' => 'zsub-adv', 'info' => { 'email' => 'ana@cliente.com', 'first_name' => 'Ana', 'last_name' => 'Silva' },
      'extra' => { 'raw_info' => raw_info } }
  end

  def resolve = described_class.new(auth_hash).resolve

  describe 'org-id claim shapes (L17/L18)' do
    it 'accepts a stringified org id' do
      raw_info['ndesk_organization_id'] = organization.id.to_s
      expect(resolve.organization).to eq(organization)
    end

    it 'denies org id 0 cleanly' do
      raw_info['ndesk_organization_id'] = 0
      expect { resolve }.to raise_error(Nkey::LoginDenied)
    end

    it 'denies a negative org id cleanly' do
      raw_info['ndesk_organization_id'] = -5
      expect { resolve }.to raise_error(Nkey::LoginDenied)
    end

    it 'denies an out-of-range huge org id WITHOUT a 500 (StatementInvalid must not escape as a crash)' do
      raw_info['ndesk_organization_id'] = '999999999999999999999999999'
      expect { resolve }.to raise_error(Nkey::LoginDenied)
    end

    it 'denies a non-numeric org id claim' do
      raw_info['ndesk_organization_id'] = 'not-a-number'
      expect { resolve }.to raise_error(Nkey::LoginDenied)
    end
  end

  describe 'nkey_groups coercion (L19/L20)' do
    it 'denies when nkey_groups is the bare string "staff"' do
      raw_info['nkey_groups'] = 'staff'
      expect { resolve }.to raise_error(Nkey::LoginDenied, %r{usuários de clientes})
    end

    it 'denies staff even when an account group is also present' do
      raw_info['nkey_groups'] = %w[account-113 staff]
      expect { resolve }.to raise_error(Nkey::LoginDenied, %r{usuários de clientes})
    end

    it 'does not treat a missing nkey_groups as staff (falls through to org/email checks)' do
      raw_info.delete('nkey_groups')
      expect(resolve).to be_persisted # not denied as staff; org+email are valid → JIT
    end
  end

  describe 'email shapes (L8/L9/L21)' do
    it 'adopts a case-different existing user (no duplicate)' do
      existing = create(:customer, email: 'ana@cliente.com', organization: organization)
      auth_hash['info']['email'] = 'ANA@Cliente.COM'
      expect(resolve).to eq(existing)
    end

    it 'trims surrounding whitespace in the claim email' do
      auth_hash['info']['email'] = '  ana@cliente.com  '
      expect(resolve.email).to eq('ana@cliente.com')
    end

    it 'denies when email is blank despite email_verified true' do
      auth_hash['info']['email'] = ''
      expect { resolve }.to raise_error(Nkey::LoginDenied, %r{não foi verificado})
    end
  end

  describe 'privilege probe (L16) — email collides with an AGENT account in the same org' do
    it 'documents that adoption attaches to the existing user with roles UNTOUCHED' do
      agent = create(:agent, email: 'ana@cliente.com', organization: organization)
      result = resolve
      expect(result).to eq(agent)
      # roles are deliberately not rewritten by nkey — this pins the behavior so any
      # change is a conscious decision (whole-branch review flagged the interaction).
      expect(result.roles.pluck(:name)).to include('Agent')
    end
  end

  describe 'tombstone re-login (L22)' do
    it 'does NOT adopt a tombstoned user (email differs) — JITs a fresh customer' do
      create(:customer, email: 'removed-zsub-adv@nkey.invalid', organization: organization, active: false)
      result = resolve
      expect(result.email).to eq('ana@cliente.com')
      expect(result.roles.pluck(:name)).to eq(['Customer'])
    end
  end

  describe 'JIT with blank names (L23)' do
    it 'creates the customer even when the claim carries no names' do
      auth_hash['info']['first_name'] = ''
      auth_hash['info']['last_name'] = ''
      expect(resolve).to be_persisted
    end
  end
end
