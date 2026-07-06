# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class Service::Csat::Stats
  def initialize(params)
    @params = params
  end

  def execute
    rel = filtered_scope
    {
      overall:  overall(rel),
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

  def overall(rel)
    {
      count:         rel.count,
      response_rate: response_rate,
      service:       dimension(rel, :score_service),
      resolution:    dimension(rel, :score_resolution),
    }
  end

  # Agregados de uma dimensão. Avaliações legadas têm score_resolution NULL e
  # ficam fora do count/média/distribuição daquela dimensão.
  def dimension(rel, column)
    scores = rel.where.not(column => nil).pluck(column)
    {
      count:        scores.size,
      average:      scores.empty? ? nil : (scores.sum.to_f / scores.size).round(2),
      distribution: (1..5).index_with { |s| scores.count(s) },
    }
  end

  def by_agent(rel)
    rel.group(:agent_id)
       .pluck(:agent_id, Arel.sql('COUNT(*)'), Arel.sql('COUNT(score_resolution)'), Arel.sql('AVG(score_service)'), Arel.sql('AVG(score_resolution)'))
       .map do |agent_id, count, count_resolution, avg_service, avg_resolution|
         {
           agent_id:,
           agent:              User.find_by(id: agent_id)&.fullname,
           count:              count,
           count_resolution:   count_resolution,
           average_service:    avg_service&.to_f&.round(2),
           average_resolution: avg_resolution&.to_f&.round(2),
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
