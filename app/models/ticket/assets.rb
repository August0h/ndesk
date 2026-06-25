# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

module Ticket::Assets
  extend ActiveSupport::Concern

=begin

get all assets / related models for this ticket

  ticket = Ticket.find(123)
  result = ticket.assets(assets_if_exists)

returns

  result = {
    users: {
      123: user_model_123,
      1234: user_model_1234,
    },
    tickets: [ ticket_model1 ]
  }

=end

  def assets(data)
    app_model = self.class.to_app_model

    if !data[ app_model ]
      data[ app_model ] = {}
    end
    return data if data[ app_model ][ id ]

    data[ app_model ][ id ] = attributes_with_association_ids

    organization&.assets(data)
    assets_user(data)

    data
  end

  def assets_user(data)
    app_model_user = User.to_app_model
    %w[created_by_id updated_by_id owner_id customer_id].each do |local_user_id|
      next if !self[ local_user_id ]
      next if data[ app_model_user ] && data[ app_model_user ][ self[ local_user_id ] ]

      user = User.lookup(id: self[ local_user_id ])
      next if !user

      data = user.assets(data)
    end
  end

  def authorized_asset?
    return true if UserInfo.current_user.blank?
    return true if TicketPolicy.new(UserInfo.current_user, self).show?

    false
  end

  def filter_unauthorized_attributes(attributes)
    filtered_attributes = super

    user = UserInfo.current_user_id.present? ? User.lookup(id: UserInfo.current_user_id) : nil
    filtered_attributes.merge(satisfaction_api_attributes(user))
  end

  # Satisfaction attributes for REST ticket payloads. Reused by the assets
  # filter above (?expand/?full/?all) and by TicketsController (plain GET).
  # `satisfaction_ratable` stays per-user + behind csat_integration (popup logic);
  # `satisfaction` (the rating data) is always exposed when a rating exists, for
  # admin API consumers (see docs/csat/adr/0002).
  def satisfaction_api_attributes(user)
    attrs = {}
    if user.present? && Setting.get('csat_integration')
      attrs['satisfaction_ratable'] = Ticket::SatisfactionRating.ratable?(ticket: self, user:)
    end
    attrs['satisfaction'] = satisfaction_rating_payload
    attrs
  end

  def satisfaction_rating_payload
    # Read the persisted rating directly (one query): the satisfaction_ratable check
    # above builds Ticket::SatisfactionRating.new(ticket: self, ...), which Rails
    # caches on the has_one inverse association, so reading `satisfaction_rating`
    # here can return an unsaved blank record. find_by is reliable across all
    # serialization paths. On list endpoints this is one query per ticket
    # (admin-only, capped at 100/page — accepted, see docs/csat/adr/0002).
    rating = Ticket::SatisfactionRating.find_by(ticket_id: id)
    return if rating.nil?

    {
      'score'      => rating.score,
      'comment'    => rating.comment,
      'agent_id'   => rating.agent_id,
      'agent_name' => rating.agent&.fullname,
      'group_id'   => rating.group_id,
      'created_at' => rating.created_at,
    }
  end
end
