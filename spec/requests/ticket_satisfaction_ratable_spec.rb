# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe 'Ticket payload satisfaction_ratable', :aggregate_failures, type: :request do
  let(:group)    { create(:group) }
  let(:agent)    { create(:agent, groups: [group]) }
  let(:customer) { create(:customer) }
  let(:state)    { Ticket::State.find_by(name: 'closed') }
  let(:ticket)   { create(:ticket, group:, customer:, owner: agent, state:) }

  before { Setting.set('csat_integration', true) }

  def ticket_asset(response_body, ticket_id)
    JSON.parse(response_body).dig('assets', 'Ticket', ticket_id.to_s)
  end

  it 'exposes satisfaction_ratable=true to the ticket customer when ratable' do
    authenticated_as(customer)
    get "/api/v1/tickets/#{ticket.id}?all=true", as: :json
    expect(response).to have_http_status(:ok)
    expect(ticket_asset(response.body, ticket.id)['satisfaction_ratable']).to be(true)
  end

  it 'is not true for an agent viewing the same ticket' do
    authenticated_as(agent)
    get "/api/v1/tickets/#{ticket.id}?all=true", as: :json
    expect(ticket_asset(response.body, ticket.id)['satisfaction_ratable']).not_to be(true)
  end

  it 'is false for the customer when CSAT is disabled' do
    Setting.set('csat_integration', false)
    authenticated_as(customer)
    get "/api/v1/tickets/#{ticket.id}?all=true", as: :json
    expect(ticket_asset(response.body, ticket.id)['satisfaction_ratable']).to be_falsey
  end

  it 'is false for the customer once a rating exists' do
    create(:ticket_satisfaction_rating, ticket:, customer:)
    authenticated_as(customer)
    get "/api/v1/tickets/#{ticket.id}?all=true", as: :json
    expect(ticket_asset(response.body, ticket.id)['satisfaction_ratable']).to be(false)
  end
end
