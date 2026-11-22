class AddStatementCounterpartyClassification < ActiveRecord::Migration[8.1]
  def change
    # How an account appears on other statements: partial numbers and holder
    # names only, never a full account or card number.
    create_table :account_identifiers, id: :uuid do |t|
      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      # Identifiers read from a statement go with it.
      t.references :account_statement, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.string :value, null: false
      t.string :source, null: false
      t.timestamps
    end

    add_index :account_identifiers, %i[account_id kind value], unique: true
    add_index :account_identifiers, %i[family_id kind]
    add_check_constraint :account_identifiers,
      "kind IN ('account_last4', 'card_last4', 'payment_handle', 'holder_name')",
      name: "account_identifiers_kind_known"
    add_check_constraint :account_identifiers,
      "source IN ('statement', 'provider', 'user')",
      name: "account_identifiers_source_known"

    change_table :import_rows, bulk: true do |t|
      t.string :counterparty_class
      t.uuid :counterparty_account_id
      t.uuid :counterparty_entry_id
      t.decimal :counterparty_confidence, precision: 5, scale: 4
      t.jsonb :counterparty_reasons, null: false, default: []
      t.boolean :counterparty_user_set, null: false, default: false
      # The counterpart's kind and category before publishing linked it, so a
      # revert can put them back.
      t.jsonb :counterparty_restore, null: false, default: {}
    end

    add_foreign_key :import_rows, :accounts, column: :counterparty_account_id, on_delete: :nullify
    add_foreign_key :import_rows, :entries, column: :counterparty_entry_id, on_delete: :nullify
    add_index :import_rows, :counterparty_account_id
    add_index :import_rows, :counterparty_entry_id
    add_check_constraint :import_rows,
      "counterparty_class IS NULL OR counterparty_class IN ('internal_tracked', 'internal_untracked', 'external', 'unknown')",
      name: "import_rows_counterparty_class_known"
  end
end
