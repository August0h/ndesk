# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe 'CSAT seeds', :aggregate_failures do # rubocop:disable RSpec/DescribeClass
  it 'defines the csat.read and admin.csat permissions' do
    expect(Permission.exists?(name: 'csat.read')).to be(true)
    expect(Permission.exists?(name: 'admin.csat')).to be(true)
  end

  it 'grants both permissions to the Admin role' do
    admin = Role.find_by(name: 'Admin')
    expect(admin.with_permission?('csat.read')).to be(true)
    expect(admin.with_permission?('admin.csat')).to be(true)
  end

  it 'seeds CSAT settings with the expected defaults' do
    expect(Setting.get('csat_integration')).to be(true)
    expect(Setting.get('csat_comment')).to eq('optional')
    expect(Setting.get('csat_closed_state_types')).to eq(['closed'])
  end
end
