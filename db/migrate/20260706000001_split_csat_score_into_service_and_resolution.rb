# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class SplitCsatScoreIntoServiceAndResolution < ActiveRecord::Migration[8.0]
  def change
    # O score único de produção sempre teve semântica de atendimento — o popup
    # perguntava "Como foi o seu atendimento?" (ver docs/csat/adr/0003).
    rename_column :ticket_satisfaction_ratings, :score, :score_service
    # NULL = avaliação registrada antes da dimensão de resolução existir.
    add_column :ticket_satisfaction_ratings, :score_resolution, :integer, null: true

    Ticket::SatisfactionRating.reset_column_information
  end
end
