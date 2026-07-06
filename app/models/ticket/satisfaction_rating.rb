# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class Ticket::SatisfactionRating < ApplicationModel
  include HasDefaultModelUserRelations

  belongs_to :ticket
  belongs_to :customer, class_name: 'User'
  belongs_to :agent,    class_name: 'User', optional: true
  belongs_to :group,    optional: true

  validates :score_service, presence: true, inclusion: { in: 1..5 }
  # on: :create — linhas legadas (pré-dimensão, score_resolution NULL) continuam
  # válidas se algum fluxo futuro as regravar (ex.: comment, que não é readonly)
  validates :score_resolution, presence: true, inclusion: { in: 1..5 }, on: :create
  validates :ticket_id, uniqueness: { scope: :customer_id }

  # write-once: never mutate after registration
  attr_readonly :ticket_id, :customer_id, :agent_id, :score_service, :score_resolution

  before_create :snapshot_agent_and_group

  # True if `user` may rate `ticket` right now (CSAT on, user is the ticket
  # customer, ticket finalized, no prior rating). Single source of truth: wraps
  # the policy so this boolean and the create authorization never drift.
  def self.ratable?(ticket:, user:)
    return false if user.blank?

    Ticket::SatisfactionRatingPolicy.new(user, new(ticket:, customer: user)).create? == true
  end

  private

  def snapshot_agent_and_group
    self.group_id ||= ticket.group_id
    self.agent_id ||= resolve_last_agent
  end

  # last assigned agent at registration time; fall back to the last human owner in history
  def resolve_last_agent
    return ticket.owner_id if ticket.owner_id.present? && ticket.owner_id != 1

    ticket.history_get
          .select { |h| h['attribute'] == 'owner' }
          .filter_map { |h| h['id_to'] }
          .reverse
          .find { |id| id != 1 && User.exists?(id:) }
  end
end
