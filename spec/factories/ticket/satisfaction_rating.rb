# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

FactoryBot.define do
  factory :'ticket/satisfaction_rating', aliases: %i[ticket_satisfaction_rating] do
    ticket
    customer         { association(:customer) }
    score_service    { Faker::Number.between(from: 1, to: 5) } # rubocop:disable Zammad/FakerUnique -- scores intentionally repeat across the 1..5 range
    score_resolution { Faker::Number.between(from: 1, to: 5) } # rubocop:disable Zammad/FakerUnique -- scores intentionally repeat across the 1..5 range
    comment          { nil }
    created_by_id    { 1 }
    updated_by_id    { 1 }

    trait :with_comment do
      comment { 'Excellent service!' }
    end

    # Avaliação gravada antes da dimensão de resolução existir (produção pré-rename).
    # Bypass do save via validate: false porque a presença é exigida on: :create.
    trait :legacy do
      score_resolution { nil }
      to_create { |instance| instance.save!(validate: false) }
    end
  end
end
