class CreateMiniApps < ActiveRecord::Migration[8.1]
  def change
    create_table :mini_apps, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :installed_by, type: :uuid, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :app_key, null: false
      t.string :name, null: false
      t.string :version, null: false
      t.text :description
      t.jsonb :manifest, null: false, default: {}
      t.string :icon
      t.string :source, null: false, default: "bundle"
      t.string :dev_url
      t.string :bundle_sha256
      t.string :status, null: false, default: "enabled"
      t.string :granted_permissions, array: true, null: false, default: []
      t.string :write_policy, null: false, default: "confirm"
      t.datetime :last_opened_at

      t.timestamps
    end

    add_index :mini_apps, %i[family_id app_key], unique: true

    create_table :mini_app_assets, id: :uuid do |t|
      t.references :mini_app, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :path, null: false
      t.string :content_type, null: false
      t.binary :content, null: false
      t.integer :byte_size, null: false, default: 0

      t.timestamps
    end

    add_index :mini_app_assets, %i[mini_app_id path], unique: true

    create_table :mini_app_records, id: :uuid do |t|
      t.references :mini_app, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :collection, null: false
      t.string :key, null: false
      t.jsonb :data, null: false, default: {}

      t.timestamps
    end

    add_index :mini_app_records, %i[mini_app_id collection key], unique: true

    create_table :mini_app_activities, id: :uuid do |t|
      t.references :mini_app, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, type: :uuid, null: true, foreign_key: { on_delete: :nullify }
      t.string :rpc_method, null: false
      t.string :tool
      t.string :permission
      t.string :outcome, null: false
      t.boolean :write, null: false, default: false
      t.jsonb :summary, null: false, default: {}
      t.text :error_message
      t.datetime :created_at, null: false
    end

    add_index :mini_app_activities, %i[mini_app_id created_at]
  end
end
