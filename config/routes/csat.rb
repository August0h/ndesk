# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

Zammad::Application.routes.draw do
  api_path = Rails.configuration.api_path

  match api_path + '/csat/surveys', to: 'csat_surveys#index', via: :get
  match api_path + '/csat/stats',   to: 'csat_stats#index',   via: :get
  match api_path + '/csat/ratings', to: 'csat_ratings#create', via: :post
end
