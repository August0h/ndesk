# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class AddCsatPermissionsAndSettings < ActiveRecord::Migration[8.0]
  def change
    # return if it's a new setup (fresh installs get these via db/seeds)
    return if !Setting.exists?(name: 'system_init_done')

    Permission.create_if_not_exists(
      name:        'csat.read',
      label:       'CSAT - Read',
      description: 'View CSAT surveys and statistics.',
      preferences: { prio: 1465 }
    )
    Permission.create_if_not_exists(
      name:        'admin.csat',
      label:       'CSAT',
      description: 'Manage Customer Satisfaction settings.',
      preferences: { prio: 1335 }
    )

    Role.find_by(name: 'Admin')&.tap do |admin|
      admin.permission_grant('csat.read')
      admin.permission_grant('admin.csat')
    end

    Setting.create_if_not_exists(
      title:       'Enable CSAT',
      name:        'csat_integration',
      area:        'Ticket::CSAT',
      description: 'Defines if customers are asked to rate resolved tickets.',
      options:     { form: [{ display: '', null: true, name: 'csat_integration', tag: 'boolean',
                              options: { true => 'yes', false => 'no' } }] },
      state:       true,
      preferences: { permission: ['admin.csat'] },
      frontend:    true
    )
    Setting.create_if_not_exists(
      title:       'CSAT comment',
      name:        'csat_comment',
      area:        'Ticket::CSAT',
      description: 'Whether the optional comment field is shown/required in the rating popup.',
      options:     { form: [{ display: '', null: false, name: 'csat_comment', tag: 'select',
                              options: { 'off' => 'Off', 'optional' => 'Optional', 'required' => 'Required' } }] },
      state:       'optional',
      preferences: { permission: ['admin.csat'] },
      frontend:    true
    )
    Setting.create_if_not_exists(
      title:       'CSAT trigger states',
      name:        'csat_closed_state_types',
      area:        'Ticket::CSAT',
      description: 'Which ticket state categories trigger the rating popup.',
      options:     { form: [{ display: '', null: false, multiple: true, name: 'csat_closed_state_types', tag: 'select',
                              options: { 'closed' => 'closed' } }] },
      state:       %w[closed],
      preferences: { permission: ['admin.csat'] },
      frontend:    false
    )
  end
end
