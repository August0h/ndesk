# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe 'CSAT ratings API', :aggregate_failures, type: :request do
  let(:group)    { create(:group) }
  let(:agent)    { create(:agent, groups: [group]) }
  let(:customer) { create(:customer) }
  let(:state)    { Ticket::State.find_by(name: 'closed') }
  let(:ticket)   { create(:ticket, group:, customer:, owner: agent, state:) }

  before { Setting.set('csat_integration', true) }

  it 'lets the ticket customer create a rating (credited to the owner)' do
    authenticated_as(customer)
    expect do
      post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_service: 4, score_resolution: 5, comment: 'Ótimo' }, as: :json
    end.to change(Ticket::SatisfactionRating, :count).by(1)
    expect(response).to have_http_status(:created)
    rating = Ticket::SatisfactionRating.last
    expect(rating.score_service).to eq(4)
    expect(rating.score_resolution).to eq(5)
    expect(rating.agent_id).to eq(agent.id)
    expect(json_response).to include('score_service' => 4, 'score_resolution' => 5)
  end

  it 'rejects a submission missing the resolution score' do
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_service: 4 }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'rejects a submission missing the service score' do
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_resolution: 4 }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'rejects a legacy-form submission that only sends score (deploy window)' do
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score: 4 }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'forbids a non-customer (agent)' do
    authenticated_as(agent)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_service: 4, score_resolution: 4 }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'forbids rating an open ticket' do
    ticket.update!(state: Ticket::State.find_by(name: 'open'))
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_service: 4, score_resolution: 4 }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'forbids a second rating' do
    create(:ticket_satisfaction_rating, ticket:, customer:)
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_service: 4, score_resolution: 4 }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'drops the comment when csat_comment is off' do
    Setting.set('csat_comment', 'off')
    authenticated_as(customer)
    post '/api/v1/csat/ratings', params: { ticket_id: ticket.id, score_service: 5, score_resolution: 5, comment: 'x' }, as: :json
    expect(response).to have_http_status(:created)
    expect(Ticket::SatisfactionRating.last.comment).to be_nil
  end
end
