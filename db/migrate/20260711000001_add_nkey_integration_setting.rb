# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class AddNkeyIntegrationSetting < ActiveRecord::Migration[8.0]
  def change
    # return if it's a new setup (fresh installs get these via db/seeds)
    return if !Setting.exists?(name: 'system_init_done')

    add_setting
  end

  def add_setting
    Setting.create_if_not_exists(
      title:       'nkey integration',
      name:        'nkey_integration',
      area:        'Integration::Nkey',
      description: 'Enables the nkey (New Byte unified identity) rules on the OpenID Connect login: staff deny, tenant resolution from the token, tenant-scoped email link, JIT customer provisioning and lazy reactivation. The lifecycle webhook is only active when this is on.',
      options:     { form: [{ display: '', null: true, name: 'nkey_integration', tag: 'boolean',
                              options: { true => 'yes', false => 'no' } }] },
      state:       false,
      preferences: { permission: ['admin.security'] },
      frontend:    false
    )
  end
end
