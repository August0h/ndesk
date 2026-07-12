# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe 'Nkey lazy reactivation' do # rubocop:disable RSpec/DescribeClass
  let(:user)  { create(:customer, active: false) }
  let!(:auth) { Authorization.create!(user: user, uid: 'sub-1', provider: 'openid_connect') } # rubocop:disable RSpec/LetSetup
  let(:hash) do
    { 'provider' => 'openid_connect', 'uid' => 'sub-1',
      'info' => {}, 'credentials' => { 'token' => 't', 'secret' => 's' } }
  end

  context 'with nkey_integration on' do
    before { Setting.set('nkey_integration', true) }

    it 'reactivates the user on a returning SSO login' do
      Authorization.find_from_hash(hash)
      expect(user.reload.active).to be(true)
    end
  end

  context 'with nkey_integration off' do
    before { Setting.set('nkey_integration', false) }

    it 'does not touch the user' do
      Authorization.find_from_hash(hash)
      expect(user.reload.active).to be(false)
    end
  end

  it 'ignores other providers' do
    Setting.set('nkey_integration', true)
    other = create(:customer, active: false)
    Authorization.create!(user: other, uid: 'gh-1', provider: 'github')
    Authorization.find_from_hash(hash.merge('provider' => 'github', 'uid' => 'gh-1'))
    expect(other.reload.active).to be(false)
  end
end
