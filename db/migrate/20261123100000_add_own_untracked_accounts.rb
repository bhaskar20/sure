class AddOwnUntrackedAccounts < ActiveRecord::Migration[8.1]
  def change
    # The family's own accounts that Sure does not track (a wallet, a bank not
    # added), named so statement lines can be traced to them. No balance.
    create_table :own_untracked_accounts, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.timestamps
    end
    add_index :own_untracked_accounts, "family_id, lower(name)", unique: true, name: "index_own_untracked_accounts_on_family_and_name"

    # An identifier belongs to exactly one tracked or untracked account.
    # Untracked ones are learned from the review, never read from a statement.
    change_column_null :account_identifiers, :account_id, true
    add_reference :account_identifiers, :own_untracked_account, type: :uuid, foreign_key: { on_delete: :cascade }, index: false
    add_index :account_identifiers, %i[own_untracked_account_id kind value], unique: true,
      where: "own_untracked_account_id IS NOT NULL", name: "index_account_identifiers_on_untracked_owner_kind_value"
    add_check_constraint :account_identifiers, "num_nonnulls(account_id, own_untracked_account_id) = 1",
      name: "account_identifiers_one_owner"
    add_check_constraint :account_identifiers, "own_untracked_account_id IS NULL OR account_statement_id IS NULL",
      name: "account_identifiers_untracked_not_from_statement"
    # The import whose review taught it, so reverting that import forgets it.
    add_reference :account_identifiers, :learned_by_import, type: :uuid, foreign_key: { to_table: :imports, on_delete: :nullify }

    add_reference :import_rows, :counterparty_untracked_account, type: :uuid,
      foreign_key: { to_table: :own_untracked_accounts, on_delete: :nullify }
    add_check_constraint :import_rows,
      "counterparty_untracked_account_id IS NULL OR counterparty_class = 'internal_untracked'",
      name: "import_rows_untracked_account_class"

    add_reference :transactions, :own_untracked_account, type: :uuid,
      foreign_key: { on_delete: :nullify }
  end
end
