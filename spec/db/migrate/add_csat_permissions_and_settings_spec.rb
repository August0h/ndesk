# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe AddCsatPermissionsAndSettings, :aggregate_failures, type: :db_migration do
  before do
    Setting.where(name: %w[csat_integration csat_comment csat_closed_state_types]).destroy_all
    Permission.where(name: %w[csat.read admin.csat]).destroy_all
  end

  it 'creates the CSAT permissions and grants them to the Admin role' do
    migrate

    expect(Permission.exists?(name: 'csat.read')).to be(true)
    expect(Permission.exists?(name: 'admin.csat')).to be(true)
    expect(Role.find_by(name: 'Admin').with_permission?('csat.read')).to be(true)
    expect(Role.find_by(name: 'Admin').with_permission?('admin.csat')).to be(true)
  end

  it 'creates the CSAT settings with the expected defaults' do
    migrate

    expect(Setting.get('csat_integration')).to be(true)
    expect(Setting.get('csat_comment')).to eq('optional')
    expect(Setting.get('csat_closed_state_types')).to eq(['closed'])
  end
end
