# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

Rails.application.config.to_prepare do
  Authorization.singleton_class.prepend Nkey::AuthorizationReactivation
end
