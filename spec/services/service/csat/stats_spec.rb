# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Service::Csat::Stats, :aggregate_failures do
  let(:group)    { create(:group) }
  let(:agent_a)  { create(:agent, groups: [group]) }
  let(:agent_b)  { create(:agent, groups: [group]) }
  let(:customer) { create(:customer) }
  let(:state)    { Ticket::State.find_by(name: 'closed') }

  def rate(agent, score)
    ticket = create(:ticket, group:, customer:, owner: agent, state:)
    create(:ticket_satisfaction_rating, ticket:, customer:, score:)
  end

  before do
    rate(agent_a, 5)
    rate(agent_a, 3)
    rate(agent_b, 4)
  end

  it 'computes overall count, average and distribution' do
    result = described_class.new({}).execute
    expect(result[:overall][:count]).to eq(3)
    expect(result[:overall][:average]).to eq(4.0)
    expect(result[:overall][:distribution]).to include(3 => 1, 4 => 1, 5 => 1)
  end

  it 'breaks down by agent' do
    result = described_class.new({}).execute
    a = result[:by_agent].find { |row| row[:agent_id] == agent_a.id }
    expect(a[:count]).to eq(2)
    expect(a[:average]).to eq(4.0)
  end

  it 'computes the overall response rate from the finalized cohort' do
    create(:ticket, group:, customer:, owner: agent_a, state:) # finalized, unrated
    result = described_class.new({}).execute
    expect(result[:overall][:response_rate]).to eq(0.75) # 3 rated of 4 finalized
  end

  it 'filters by agent_id' do
    result = described_class.new({ agent_id: agent_b.id }).execute
    expect(result[:overall][:count]).to eq(1)
    expect(result[:by_agent].size).to eq(1)
  end
end
