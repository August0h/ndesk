# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class Controllers::CsatRatingsControllerPolicy < Controllers::ApplicationControllerPolicy
  # No-op placeholder: CsatRatingsController uses `authentication_check` (not
  # `authenticate_and_authorize!`), so this controller policy is never invoked.
  # Authorization happens at the record level via `authorize!(rating, :create?)`
  # (Ticket::SatisfactionRatingPolicy), which lets the ticket *customer* — who has
  # no csat.read/admin permission — create their own rating. Same convention as
  # Controllers::TicketArticlesControllerPolicy.
  default_permit!('admin')
end
