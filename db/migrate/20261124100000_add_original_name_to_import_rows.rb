class AddOriginalNameToImportRows < ActiveRecord::Migration[8.1]
  def change
    # The description as the statement printed it, kept when the row's name is
    # rewritten into a readable one: account numbers, handles and SELF markers
    # in it are what tells an own-account transfer apart.
    add_column :import_rows, :original_name, :string
  end
end
