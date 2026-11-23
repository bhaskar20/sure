require "test_helper"

class OwnUntrackedAccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    sign_in @user
  end

  test "lists the family's accounts not in Sure" do
    @family.own_untracked_accounts.create!(name: "PayLah wallet")

    get own_untracked_accounts_path

    assert_response :success
    assert_match "PayLah wallet", response.body
  end

  test "is a preview feature" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get own_untracked_accounts_path

    assert_redirected_to root_path
  end

  test "creates, renames and deletes an account" do
    assert_difference -> { @family.own_untracked_accounts.count }, 1 do
      post own_untracked_accounts_path, params: { own_untracked_account: { name: "HDFC savings" } }
    end
    account = @family.own_untracked_accounts.last
    assert_redirected_to own_untracked_accounts_path

    patch own_untracked_account_path(account), params: { own_untracked_account: { name: "HDFC NRO" } }
    assert_equal "HDFC NRO", account.reload.name

    assert_difference -> { @family.own_untracked_accounts.count }, -1 do
      delete own_untracked_account_path(account)
    end
  end

  test "a duplicate name is refused" do
    @family.own_untracked_accounts.create!(name: "Wallet")

    assert_no_difference -> { @family.own_untracked_accounts.count } do
      post own_untracked_accounts_path, params: { own_untracked_account: { name: "wallet" } }
    end
  end

  test "creating from a statement review row assigns the new account to it" do
    row = review_row

    post own_untracked_accounts_path, params: { own_untracked_account: { name: "Revolut" }, import_row_id: row.id }

    account = @family.own_untracked_accounts.find_by!(name: "Revolut")
    assert_redirected_to import_clean_path(row.import)
    assert_equal [ "internal_untracked", account.id ], [ row.reload.counterparty_class, row.counterparty_untracked_account_id ]
  end

  test "a review already being imported creates nothing from its dialog" do
    row = review_row
    row.import.update!(status: :importing)

    assert_no_difference -> { @family.own_untracked_accounts.count } do
      post own_untracked_accounts_path, params: { own_untracked_account: { name: "Late" }, import_row_id: row.id }
    end
    assert_redirected_to import_path(row.import)
    assert_equal "external", row.reload.counterparty_class
  end

  test "another family's accounts and rows are out of reach" do
    other = families(:empty).own_untracked_accounts.create!(name: "Theirs")

    get edit_own_untracked_account_path(other)
    assert_response :not_found
  end

  private
    def review_row
      statement = AccountStatement.create_from_upload!(
        family: @family, account: accounts(:depository),
        file: uploaded_file(filename: "statement.pdf", content_type: "application/pdf", content: file_fixture("imports/sample_bank_statement.pdf").binread)
      )
      import = PdfImport.create_from_statement!(statement: statement)
      import.update!(document_type: "bank_statement", ai_summary: "A bank statement.", extracted_data: { "transactions" => [
        { "date" => Date.current.to_s, "amount" => "-45.10", "name" => "FUNDS TRANSFER FT1234" }
      ] })
      import.generate_rows_from_extracted_data
      import.reload.rows.sole
    end
end
