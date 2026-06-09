# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class Ticket::SatisfactionRatingPolicy < ApplicationPolicy
  def create?
    return not_authorized(__('CSAT is not enabled')) if !Setting.get('csat_integration')
    return not_authorized(__('Only the ticket customer can rate')) if user.id != record.ticket.customer_id
    return not_authorized(__('Ticket is not finalized')) if !closed_state?
    return not_authorized(__('This ticket was already rated')) if already_rated?

    true
  end

  def show?
    return false if !Setting.get('csat_integration')
    return true if user.id == record.customer_id

    user.permissions?('csat.read')
  end

  private

  def closed_state?
    Setting.get('csat_closed_state_types').include?(record.ticket.state.state_type.name)
  end

  def already_rated?
    Ticket::SatisfactionRating
      .where(ticket_id: record.ticket_id, customer_id: record.ticket.customer_id)
      .where.not(id: record.id)
      .exists?
  end
end
