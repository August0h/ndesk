# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe 'Ticket payload: embedded satisfaction', :aggregate_failures, type: :request do
  let(:group)    { create(:group) }
  let(:agent)    { create(:agent, groups: [group]) }
  let(:admin)    { create(:admin, groups: [group]) }
  let(:customer) { create(:customer) }
  let(:state)    { Ticket::State.find_by(name: 'closed') }
  let(:ticket)   { create(:ticket, group:, customer:, owner: agent, state:) }

  before { Setting.set('csat_integration', true) }

  context 'when the ticket has a rating' do
    before { create(:ticket_satisfaction_rating, ticket:, customer:, score_service: 4, score_resolution: 5, comment: 'Ótimo') }

    it 'embeds the satisfaction object on the expanded GET show' do
      authenticated_as(admin)
      get "/api/v1/tickets/#{ticket.id}?expand=true", as: :json
      expect(response).to have_http_status(:ok)
      sat = json_response['satisfaction']
      expect(sat).to include(
        'score_service'    => 4,
        'score_resolution' => 5,
        'comment'          => 'Ótimo',
        'agent_id'         => agent.id,
        'agent_name'       => agent.fullname,
        'group_id'         => group.id,
      )
      expect(sat['created_at']).to be_present
    end

    it 'embeds the satisfaction object on the plain GET show' do
      authenticated_as(admin)
      get "/api/v1/tickets/#{ticket.id}", as: :json
      expect(response).to have_http_status(:ok)
      expect(json_response.dig('satisfaction', 'score_service')).to eq(4)
      expect(json_response.dig('satisfaction', 'score_resolution')).to eq(5)
      expect(json_response.dig('satisfaction', 'agent_name')).to eq(agent.fullname)
    end

    it 'embeds the satisfaction object per ticket on the plain list' do
      authenticated_as(admin)
      get '/api/v1/tickets', as: :json
      row = json_response.find { |t| t['id'] == ticket.id }
      expect(row).to be_present
      expect(row.dig('satisfaction', 'score_service')).to eq(4)
    end
  end

  context 'when the ticket has a legacy rating (no resolution score)' do
    before { create(:ticket_satisfaction_rating, :legacy, ticket:, customer:, score_service: 3) }

    it 'returns score_resolution as null' do
      authenticated_as(admin)
      get "/api/v1/tickets/#{ticket.id}", as: :json
      expect(json_response.dig('satisfaction', 'score_service')).to eq(3)
      expect(json_response['satisfaction']).to have_key('score_resolution')
      expect(json_response['satisfaction']['score_resolution']).to be_nil
    end
  end

  context 'when the ticket has no rating' do
    it 'returns satisfaction as null on the expanded GET show' do
      authenticated_as(admin)
      get "/api/v1/tickets/#{ticket.id}?expand=true", as: :json
      expect(json_response).to have_key('satisfaction')
      expect(json_response['satisfaction']).to be_nil
    end

    it 'returns satisfaction as null on the plain GET show' do
      authenticated_as(admin)
      get "/api/v1/tickets/#{ticket.id}", as: :json
      expect(json_response).to have_key('satisfaction')
      expect(json_response['satisfaction']).to be_nil
    end
  end
end
