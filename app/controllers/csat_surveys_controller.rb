# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class CsatSurveysController < ApplicationController
  include CanPaginate

  prepend_before_action :authenticate_and_authorize!

  # GET /api/v1/csat/surveys
  def index
    paginate_with(max: 100, default: 50)

    records = scope.reorder(created_at: :desc)
                   .offset(pagination.offset)
                   .limit(pagination.limit)

    render json: records.map { |r| serialize(r) }, status: :ok
  end

  private

  def scope
    rel = Ticket::SatisfactionRating.all

    %i[agent_id group_id score_service score_resolution].each do |attribute|
      rel = rel.where(attribute => params[attribute]) if params[attribute].present?
    end

    rel = rel.where(created_at: Time.zone.parse(params[:date_from])..) if params[:date_from].present?
    rel = rel.where(created_at: ..Time.zone.parse(params[:date_to]))   if params[:date_to].present?
    rel
  end

  def serialize(rating)
    {
      id:               rating.id,
      ticket_id:        rating.ticket_id,
      customer_id:      rating.customer_id,
      agent_id:         rating.agent_id,
      agent_name:       rating.agent&.fullname,
      group_id:         rating.group_id,
      score_service:    rating.score_service,
      score_resolution: rating.score_resolution,
      comment:          rating.comment,
      created_at:       rating.created_at,
    }
  end
end
