# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class CsatRatingsController < ApplicationController
  prepend_before_action :authentication_check

  # POST /api/v1/csat/ratings
  def create
    rating = ::Ticket::SatisfactionRating.new(
      ticket:   Ticket.find(params[:ticket_id]),
      customer: current_user,
      score:    params[:score],
      comment:  comment_value(params[:comment]),
    )

    authorize!(rating, :create?)
    rating.save!

    render json: serialize(rating), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def comment_value(comment)
    return if Setting.get('csat_comment') == 'off'

    comment
  end

  def serialize(rating)
    {
      id:         rating.id,
      ticket_id:  rating.ticket_id,
      score:      rating.score,
      comment:    rating.comment,
      created_at: rating.created_at,
    }
  end
end
