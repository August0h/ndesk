# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class CreateTicketSatisfactionRatings < ActiveRecord::Migration[8.0]
  def change
    create_table :ticket_satisfaction_ratings, id: :integer do |t|
      t.references :ticket,   null: false, type: :integer, foreign_key: { to_table: :tickets }
      t.references :customer, null: false, type: :integer, foreign_key: { to_table: :users }
      t.references :agent,    null: true,  type: :integer, foreign_key: { to_table: :users }
      t.references :group,    null: true,  type: :integer, foreign_key: { to_table: :groups }
      t.integer :score, null: false
      t.text    :comment
      t.column  :created_by_id, :integer, null: false
      t.column  :updated_by_id, :integer, null: false

      t.timestamps limit: 3

      t.index %i[ticket_id customer_id], unique: true, name: 'index_csat_ticket_customer'
      t.index %i[agent_id created_at]
    end
  end
end
