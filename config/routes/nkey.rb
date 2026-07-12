# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

Zammad::Application.routes.draw do
  match '/nkey/lifecycle', to: 'nkey_lifecycle#handle', via: :post
end
