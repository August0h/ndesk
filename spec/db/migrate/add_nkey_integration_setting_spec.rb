# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe AddNkeyIntegrationSetting, type: :db_migration do
  before { Setting.find_by(name: 'nkey_integration')&.destroy }

  it 'creates the nkey_integration setting, default off' do
    migrate
    expect(Setting.get('nkey_integration')).to be(false)
  end
end
