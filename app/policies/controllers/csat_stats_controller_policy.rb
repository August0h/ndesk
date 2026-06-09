# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class Controllers::CsatStatsControllerPolicy < Controllers::ApplicationControllerPolicy
  default_permit!('csat.read')
end
