# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

module Nkey
  # A deny-path error carrying its own (translatable) message. Subclasses
  # Authorization::Provider::AccountError so SessionsController#create_omniauth's
  # existing rescue renders it as 403 — but AccountError hardcodes its message,
  # so bind StandardError#initialize directly.
  class LoginDenied < Authorization::Provider::AccountError
    def initialize(message) # rubocop:disable Lint/MissingSuper
      StandardError.instance_method(:initialize).bind_call(self, message)
    end
  end
end
