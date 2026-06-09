# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class CsatStatsController < ApplicationController
  prepend_before_action :authenticate_and_authorize!

  # GET /api/v1/csat/stats
  def index
    render json: Service::Csat::Stats.new(stats_params).execute, status: :ok
  end

  private

  def stats_params
    params.permit(:agent_id, :group_id, :date_from, :date_to).to_h.symbolize_keys
  end
end
