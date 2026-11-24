require "test_helper"

# The Counterparty column of a statement import's review (FR-004 slice 1).
class Import::CounterpartyReviewTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @checking = accounts(:depository)
    @family = @checking.family
    @savings = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new, owner: @user)
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @checking,
      file: uploaded_file(
        filename: "statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )
    @import = PdfImport.create_from_statement!(statement: statement)
    @import.update!(document_type: "bank_statement", ai_summary: "A bank statement.", extracted_data: { "transactions" => [
      { "date" => Date.current.to_s, "amount" => "-45.10", "name" => "FUNDS TRANSFER FT1234" }
    ] })
    enable_preview(@user)
    @import.generate_rows_from_extracted_data
    @row = @import.reload.rows.sole
    sign_in @user
  end

  test "the review shows the Counterparty column to a member who opted into preview features" do
    get import_clean_path(@import)

    assert_response :success
    assert_select "select[name='import_row[counterparty_choice]']" do
      assert_select "option[value='account:#{@savings.id}']", text: "Savings"
      assert_select "option[value='account:#{@checking.id}']", count: 0
      assert_select "option[value='external'][selected]"
    end
  end

  test "the review hides the column from a member who did not opt in" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get import_clean_path(@import)

    assert_response :success
    assert_select "select[name='import_row[counterparty_choice]']", count: 0
  end

  test "a reviewer can name one of their accounts as the other side" do
    patch import_row_path(@import, @row), params: { import_row: { counterparty_choice: "account:#{@savings.id}" } }

    assert_redirected_to import_row_path(@import, @row)
    @row.reload
    assert_equal "internal_tracked", @row.counterparty_class
    assert_equal @savings.id, @row.counterparty_account_id
    assert @row.counterparty_user_set
  end

  test "an account the reviewer cannot write to, or the import's own, is refused" do
    other_family_account = accounts(:depository).dup.tap { |account| account.family = families(:empty) }
    other_family_account.update!(name: "Elsewhere", accountable: Depository.new, owner: nil)

    [ other_family_account.id, @checking.id ].each do |account_id|
      patch import_row_path(@import, @row), params: { import_row: { counterparty_choice: "account:#{account_id}" } }
      assert_equal "external", @row.reload.counterparty_class
    end
  end

  test "a member without preview access cannot change the classification" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    patch import_row_path(@import, @row), params: { import_row: { counterparty_choice: "internal_untracked" } }

    assert_equal "external", @row.reload.counterparty_class
  end

  test "publishing by a member without preview access drops the classification" do
    @row.update!(counterparty_choice: "account:#{@savings.id}")
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    PdfImport.any_instance.expects(:publish_later).once

    post publish_import_url(@import)

    assert_nil @row.reload.counterparty_class
  end

  test "publishing keeps the classification for a member with preview access" do
    @row.update!(counterparty_choice: "account:#{@savings.id}")
    PdfImport.any_instance.expects(:publish_later).once

    post publish_import_url(@import)

    assert_equal "internal_tracked", @row.reload.counterparty_class
  end

  test "rows cannot be changed once the import is publishing" do
    @import.update!(status: :importing)

    patch import_row_path(@import, @row), params: { import_row: { counterparty_choice: "internal_untracked" } }

    assert_redirected_to import_path(@import)
    assert_equal "external", @row.reload.counterparty_class
  end

  test "a publish refused for lack of access leaves the review untouched" do
    @row.update!(counterparty_choice: "account:#{@savings.id}")
    PdfImport.any_instance.expects(:publish_later).never
    @checking.update!(owner: users(:family_member))
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    post publish_import_url(@import)

    assert_equal "internal_tracked", @row.reload.counterparty_class
  end

  test "a line linked to an account the reviewer cannot change shows as undecided, without naming it" do
    hidden = @family.accounts.create!(name: "Private savings", balance: 0, currency: "USD", accountable: Depository.new, owner: users(:family_member))
    @row.update_columns(counterparty_class: "internal_tracked", counterparty_account_id: hidden.id,
      counterparty_reasons: [ { "code" => "mirror_entry", "date" => Date.current.iso8601, "account_id" => hidden.id } ])

    get import_clean_path(@import)

    assert_response :success
    assert_select "option[value='unknown'][selected]"
    assert_no_match "Private savings", response.body
    assert_select "select[title=?]", I18n.t("imports.counterparty.reasons.not_linkable")
  end

  test "the picker offers the family's accounts not in Sure, and a way to add one" do
    wallet = @family.own_untracked_accounts.create!(name: "PayLah wallet")

    get import_clean_path(@import)

    assert_select "option[value='untracked:#{wallet.id}']", text: "PayLah wallet"
    assert_select "option[value='new_untracked']"
    assert_select "form[data-controller~='counterparty-select']"
  end

  test "a reviewer can name an account not in Sure, but not another family's" do
    wallet = @family.own_untracked_accounts.create!(name: "Wallet")
    theirs = families(:empty).own_untracked_accounts.create!(name: "Theirs")

    patch import_row_path(@import, @row), params: { import_row: { counterparty_choice: "untracked:#{theirs.id}" } }
    assert_equal "external", @row.reload.counterparty_class

    patch import_row_path(@import, @row), params: { import_row: { counterparty_choice: "untracked:#{wallet.id}" } }
    assert_equal [ "internal_untracked", wallet.id ], [ @row.reload.counterparty_class, @row.counterparty_untracked_account_id ]
  end

  test "the tooltip says what publishing will do with a line to a tracked account" do
    @row.update!(counterparty_choice: "account:#{@savings.id}")

    get import_clean_path(@import)
    assert_select "select[title*=?]", I18n.t("imports.counterparty.plan.leg", account: "Savings")

    create_valuation_for(@savings)
    get import_clean_path(@import)
    assert_select "select[title*=?]", I18n.t("imports.counterparty.plan.unlinked_hand_set_balance", account: "Savings")
  end

  test "the statement review card summarises the transfers it found" do
    PdfImport.any_instance.stubs(:pdf_uploaded?).returns(true)
    @row.update!(counterparty_choice: "internal_untracked")

    get import_url(@import)

    assert_response :success
    assert_match I18n.t("imports.pdf_import.counterparty_internal", count: 1, total: 1), response.body
  end

  private
    def create_valuation_for(account)
      account.entries.create!(date: Date.current - 10, amount: 100, currency: account.currency, name: "Balance", entryable: Valuation.new(kind: "reconciliation"))
    end

    def enable_preview(user)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end
end
