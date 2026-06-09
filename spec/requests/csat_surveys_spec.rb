# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe 'CSAT surveys API', :aggregate_failures, type: :request do
  let(:group)    { create(:group) }
  let(:admin)    { create(:admin) }
  let(:agent)    { create(:agent, groups: [group]) }
  let(:customer) { create(:customer) }
  let(:state)    { Ticket::State.find_by(name: 'closed') }

  before do
    Setting.set('csat_integration', true)
    3.times do
      ticket = create(:ticket, group:, customer:, owner: agent, state:)
      create(:ticket_satisfaction_rating, ticket:, customer:, score: 5)
    end
  end

  it 'returns ratings to an admin' do
    authenticated_as(admin)
    get '/api/v1/csat/surveys', as: :json
    expect(response).to have_http_status(:ok)
    expect(json_response).to be_a(Array)
    expect(json_response.size).to eq(3)
    expect(json_response.first).to include('score' => 5, 'agent_id' => agent.id)
  end

  it 'paginates' do
    authenticated_as(admin)
    get '/api/v1/csat/surveys?per_page=2&page=1', as: :json
    expect(json_response.size).to eq(2)
  end

  it 'filters by agent_id' do
    authenticated_as(admin)
    get "/api/v1/csat/surveys?agent_id=#{agent.id}", as: :json
    expect(json_response.size).to eq(3)
    get '/api/v1/csat/surveys?agent_id=0', as: :json
    expect(json_response.size).to eq(0)
  end

  it 'forbids a non-admin' do
    authenticated_as(agent)
    get '/api/v1/csat/surveys', as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
