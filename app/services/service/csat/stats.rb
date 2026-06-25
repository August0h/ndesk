# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class Service::Csat::Stats
  def initialize(params)
    @params = params
  end

  def execute
    rel = filtered_scope
    {
      overall:  aggregate(rel),
      by_agent: by_agent(rel),
    }
  end

  private

  def filtered_scope
    rel = Ticket::SatisfactionRating.all
    rel = rel.where(agent_id: @params[:agent_id]) if @params[:agent_id].present?
    rel = rel.where(group_id: @params[:group_id]) if @params[:group_id].present?
    rel = rel.where(created_at: Time.zone.parse(@params[:date_from])..) if @params[:date_from].present?
    rel = rel.where(created_at: ..Time.zone.parse(@params[:date_to]))   if @params[:date_to].present?
    rel
  end

  def aggregate(rel)
    scores = rel.pluck(:score)
    {
      count:         scores.size,
      average:       scores.empty? ? nil : (scores.sum.to_f / scores.size).round(2),
      distribution:  (1..5).index_with { |s| scores.count(s) },
      response_rate: response_rate,
    }
  end

  def by_agent(rel)
    rel.group(:agent_id).pluck(:agent_id, Arel.sql('COUNT(*)'), Arel.sql('AVG(score)')).map do |agent_id, count, avg|
      {
        agent_id:,
        agent:    User.find_by(id: agent_id)&.fullname,
        count:    count,
        average:  avg&.to_f&.round(2),
      }
    end
  end

  # Taxa de Resposta (overall): of tickets finalized in the window (close_at), how many have a rating.
  def response_rate
    cohort = finalized_cohort
    total  = cohort.count
    return nil if total.zero?

    rated = cohort.where(id: Ticket::SatisfactionRating.select(:ticket_id)).count
    (rated.to_f / total).round(2)
  end

  def finalized_cohort
    rel = Ticket.where.not(close_at: nil)
    rel = rel.where(close_at: Time.zone.parse(@params[:date_from])..) if @params[:date_from].present?
    rel = rel.where(close_at: ..Time.zone.parse(@params[:date_to]))   if @params[:date_to].present?
    rel = rel.where(group_id: @params[:group_id]) if @params[:group_id].present?
    rel = rel.where(owner_id: @params[:agent_id]) if @params[:agent_id].present?
    rel
  end
end
