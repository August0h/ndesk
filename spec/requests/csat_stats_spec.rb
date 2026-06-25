# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe 'CSAT stats API', :aggregate_failures, type: :request do
  let(:group)    { create(:group) }
  let(:admin)    { create(:admin) }
  let(:agent)    { create(:agent, groups: [group]) }
  let(:customer) { create(:customer) }
  let(:state)    { Ticket::State.find_by(name: 'closed') }

  before do
    Setting.set('csat_integration', true)
    ticket = create(:ticket, group:, customer:, owner: agent, state:)
    create(:ticket_satisfaction_rating, ticket:, customer:, score: 5)
  end

  it 'returns overall + by_agent to an admin' do
    authenticated_as(admin)
    get '/api/v1/csat/stats', as: :json
    expect(response).to have_http_status(:ok)
    expect(json_response['overall']['count']).to eq(1)
    expect(json_response['by_agent'].first['agent_id']).to eq(agent.id)
  end

  it 'forbids a non-admin' do
    authenticated_as(agent)
    get '/api/v1/csat/stats', as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
