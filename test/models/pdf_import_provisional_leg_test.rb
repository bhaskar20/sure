require "test_helper"

# FR-004 slice 2: the other side of a transfer written into an account whose
# statement is not imported yet, claimed by that statement later in either
# order, and the family's own accounts outside Sure.
class PdfImportProvisionalLegTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @admin = users(:family_admin)
    @admin.update!(preferences: (@admin.preferences || {}).merge("preview_features_enabled" => true))
    @family = @admin.family
    @current = @family.accounts.create!(name: "Current", balance: 0, currency: "USD", accountable: Depository.new, owner: @admin)
    @savings = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new, owner: @admin)
    identify(@savings, "4821")
    identify(@current, "6789")
    @date = Date.current
    @uploads = 0
  end

  def extracted(amount:, name:, date: @date)
    { "date" => date.to_s, "amount" => amount.to_s, "name" => name }
  end

  def identify(owner, value, kind: "account_last4")
    attrs = owner.is_a?(OwnUntrackedAccount) ? { own_untracked_account: owner } : { account: owner }
    AccountIdentifier.create!(**attrs, family: @family, kind: kind, value: value, source: "user")
  end

  # period: the statement's own period, which bounds the legs it may claim.
  def statement_import(account, *lines, period: nil)
    @uploads += 1
    statement = AccountStatement.create_from_upload!(
      family: @family, account: account,
      file: uploaded_file(filename: "statement-#{@uploads}.pdf", content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread + (" " * @uploads))
    )
    statement.update!(period_start_on: period&.begin, period_end_on: period&.end)
    import = PdfImport.create_from_statement!(statement: statement)
    import.update!(document_type: "bank_statement", extracted_data: { "transactions" => lines })
    import.generate_rows_from_extracted_data
    import.reload
  end

  def leg_in(account)
    account.entries.where(entryable_type: "Transaction").where.not(import_id: nil).joins(:import).where.not(imports: { account_id: account.id }).sole
  end

  test "publishing writes the other side into a manual account without a statement yet" do
    a = statement_import(@current, extracted(amount: -4321.5, name: "NEFT/SELF/XXXX4821"))
    assert_equal "internal_tracked", a.rows.sole.counterparty_class

    assert_difference [ -> { Transfer.count }, -> { @savings.entries.count } ], 1 do
      a.import!
    end

    leg = leg_in(@savings)
    assert_equal(-4321.5, leg.amount.to_f)
    assert_equal a, leg.import
    assert_nil leg.reconciled_at
    assert leg.entryable.transfer.confirmed?
    assert_equal "funds_movement", leg.entryable.kind
    assert_equal 1, a.imported_count
  end

  test "the account's own statement claims the leg instead of duplicating it" do
    statement_import(@current, extracted(amount: -4321.5, name: "NEFT/SELF/XXXX4821")).import!
    leg = leg_in(@savings)

    b = statement_import(@savings, extracted(amount: 4321.5, name: "NEFT CR FROM XXXX6789", date: @date + 1))

    assert_equal 0, b.rows_count
    assert_equal [ leg ], b.reconciled_entries.to_a
    assert leg.reload.reconciled_at.present?
    assert_equal 1, @savings.entries.where(entryable_type: "Transaction").count
  end

  test "a leg is claimed over the wider window a transfer can take to post" do
    statement_import(@current, extracted(amount: -4321.5, name: "NEFT/SELF/XXXX4821")).import!

    b = statement_import(@savings, extracted(amount: 4321.5, name: "NEFT CR", date: @date + 6), period: (@date - 20)..(@date + 20))

    assert_equal 0, b.rows_count
    assert_equal 1, @savings.entries.where(entryable_type: "Transaction").count
  end

  test "importing in the opposite order ends the same way" do
    statement_import(@savings, extracted(amount: 4321.5, name: "NEFT/SELF/XXXX6789")).import!
    leg = leg_in(@current)
    assert_equal 4321.5, leg.amount.to_f

    a = statement_import(@current, extracted(amount: -4321.5, name: "NEFT/SELF/XXXX4821"))
    assert_equal 0, a.rows_count
    assert leg.reload.reconciled_at.present?
    assert_equal 1, Transfer.count - transfers_before_fixture_count
  end

  test "a line whose rows were reviewed before the other statement published still claims the leg" do
    b = statement_import(@savings, extracted(amount: 4321.5, name: "NEFT CR"))
    assert_equal 1, b.rows_count

    statement_import(@current, extracted(amount: -4321.5, name: "NEFT/SELF/XXXX4821")).import!

    assert_no_difference -> { @savings.entries.count } do
      b.import!
    end
    assert leg_in(@savings).reconciled_at.present?
  end

  test "no leg is written into a provider-linked account" do
    linked = accounts(:connected)
    identify(linked, "5555")
    a = statement_import(@current, extracted(amount: -880.25, name: "NEFT/SELF/XXXX5555"))

    assert_no_difference [ -> { Transfer.count }, -> { linked.entries.count } ] do
      a.import!
    end
    assert_equal "funds_movement", a.entries.sole.entryable.kind
  end

  test "no leg is written into an account with a balance set by hand" do
    create_valuation(account: @savings, amount: 1000, date: @date - 10, kind: "reconciliation")
    a = statement_import(@current, extracted(amount: -880.25, name: "NEFT/SELF/XXXX4821"))

    assert_no_difference -> { @savings.entries.where(entryable_type: "Transaction").count } do
      a.import!
    end
    txn = a.entries.sole.entryable
    assert_equal "funds_movement", txn.kind
    assert_nil txn.transfer
  end

  test "an opening balance entered by hand counts as set by hand" do
    @savings.set_opening_anchor_balance(balance: 250, date: @date - 60)
    a = statement_import(@current, extracted(amount: -880.25, name: "NEFT/SELF/XXXX4821"))

    assert_no_difference -> { @savings.entries.where(entryable_type: "Transaction").count } do
      a.import!
    end
  end

  test "no leg where that account already holds the other side or its statement covers the date" do
    deposit = create_transaction(account: @savings, date: @date - 5, amount: -880.25, name: "Deposit")
    a = statement_import(@current, extracted(amount: -880.25, name: "NEFT/SELF/XXXX4821"))
    assert_no_difference -> { @savings.entries.count } do
      a.import!
    end
    assert deposit.entryable.reload.transfer.present?

    covered = AccountStatement.create_from_upload!(
      family: @family, account: @savings,
      file: uploaded_file(filename: "covered.pdf", content_type: "application/pdf", content: file_fixture("imports/sample_bank_statement.pdf").binread + "covered")
    )
    covered.update!(period_start_on: @date - 30, period_end_on: @date + 1)
    a2 = statement_import(@current, extracted(amount: -321.75, name: "NEFT/SELF/XXXX4821"))
    assert_no_difference -> { @savings.entries.count } do
      a2.import!
    end
  end

  test "no leg into an account in another currency" do
    @savings.update!(currency: "EUR")
    a = statement_import(@current, extracted(amount: -880.25, name: "NEFT/SELF/XXXX4821"))

    assert_no_difference -> { @savings.entries.count } do
      a.import!
    end
  end

  test "reverting removes a leg nobody claimed" do
    a = statement_import(@current, extracted(amount: -2468.0, name: "NEFT/SELF/XXXX4821"))
    a.import!
    leg_id = leg_in(@savings).id

    a.revert

    assert_nil a.reload.error
    assert_not Entry.exists?(leg_id)
    assert_equal 0, Transfer.count - transfers_before_fixture_count
  end

  test "reverting keeps a leg another statement claimed, as that account's transfer-kind line" do
    a = statement_import(@current, extracted(amount: -2468.0, name: "NEFT/SELF/XXXX4821"))
    a.import!
    leg = leg_in(@savings)
    b = statement_import(@savings, extracted(amount: 2468.0, name: "NEFT CR"))
    assert leg.reload.reconciled_at.present?
    b.update!(status: :complete)

    a.revert

    leg.reload
    # Now the published claiming statement's own line: reverting that import offers it again.
    assert_equal b.id, leg.import_id
    assert_nil leg.entryable.transfer
    assert_equal "funds_movement", leg.entryable.kind
  end

  test "deleting the import keeps a claimed leg too" do
    a = statement_import(@current, extracted(amount: -1357.0, name: "NEFT/SELF/XXXX4821"))
    a.import!
    leg = leg_in(@savings)
    statement_import(@savings, extracted(amount: 1357.0, name: "NEFT CR"))

    a.destroy!

    # Kept, but not handed to a claiming import still waiting to be published.
    assert Entry.exists?(leg.id)
    assert_nil leg.reload.import_id
  end

  test "a series of equal transfers each gets its own leg" do
    a = statement_import(@current,
      extracted(amount: -500.0, name: "NEFT/SELF/XXXX4821", date: @date - 7),
      extracted(amount: -500.0, name: "NEFT/SELF/XXXX4821"))

    assert_difference -> { @savings.entries.count }, 2 do
      a.import!
    end
  end

  test "a line that is really the transfer claims the leg before an unrelated one of the same amount" do
    statement_import(@current, extracted(amount: -500.0, name: "NEFT/SELF/XXXX4821")).import!
    leg = leg_in(@savings)

    b = statement_import(@savings,
      extracted(amount: 500.0, name: "INTEREST", date: @date - 5),
      extracted(amount: 500.0, name: "NEFT CR"),
      period: (@date - 20)..(@date + 20))

    assert_equal [ "INTEREST" ], b.rows.map(&:name)
    assert_equal [ leg ], b.reconciled_entries.to_a
  end

  test "a transfer crossing the statement boundary is still claimed" do
    statement_import(@current, extracted(amount: -500.0, name: "NEFT/SELF/XXXX4821", date: @date - 5)).import!

    b = statement_import(@savings, extracted(amount: 500.0, name: "NEFT CR"), period: (@date - 1)..(@date + 27))

    assert_equal 0, b.rows_count
  end

  test "reverting forgets what that import's review taught" do
    hdfc = @family.accounts.create!(name: "HDFC", balance: 0, currency: "USD", accountable: Depository.new, owner: @admin)
    a = statement_import(@current, extracted(amount: -75.0, name: "IMPS/P2A/612345678901/XXXX7777/rent"))
    a.rows.sole.update!(counterparty_choice: "account:#{hdfc.id}")
    a.import!
    assert_equal 1, hdfc.account_identifiers.count

    a.revert

    assert_empty hdfc.account_identifiers.reload
  end

  test "a value another account already owns, or an incoming line's own handle, is not learned" do
    wallet = @family.own_untracked_accounts.create!(name: "Wallet")
    a = statement_import(@current,
      extracted(amount: -75.0, name: "TRANSFER TO A/C XXXX4821"),
      extracted(amount: 60.0, name: "INCOMING PAYNOW FROM: SOMEONE FUND TRANSFER TO +6598765432"))
    a.rows.each { |row| row.update!(counterparty_choice: "untracked:#{wallet.id}") }

    a.import!

    assert_empty wallet.account_identifiers
  end

  test "a reviewer's pick teaches the account the numbers the line prints" do
    hdfc = @family.accounts.create!(name: "HDFC", balance: 0, currency: "USD", accountable: Depository.new, owner: @admin)
    a = statement_import(@current, extracted(amount: -75.0, name: "IMPS/P2A/612345678901/XXXX7777/rent"))
    a.rows.sole.update!(counterparty_choice: "account:#{hdfc.id}")

    a.import!

    assert_equal [ [ "account_last4", "7777", "user" ] ], hdfc.account_identifiers.pluck(:kind, :value, :source)
  end

  test "a line naming an untracked account's handle is internal to that account" do
    wallet = @family.own_untracked_accounts.create!(name: "PayLah wallet")
    identify(wallet, "91234567", kind: "payment_handle")

    a = statement_import(@current, extracted(amount: -20.0, name: "PAYNOW TRANSFER TO +6591234567"))
    row = a.rows.sole
    assert_equal [ "internal_untracked", wallet.id ], [ row.counterparty_class, row.counterparty_untracked_account_id ]

    a.import!
    txn = a.entries.sole.entryable
    assert_equal [ "funds_movement", wallet.id ], [ txn.kind, txn.own_untracked_account_id ]
    assert_nil txn.transfer
  end

  test "a wallet top-up goes to an untracked wallet of that name" do
    wallet = @family.own_untracked_accounts.create!(name: "PayLah")

    row = statement_import(@current, extracted(amount: -20.0, name: "Advice Funds Transfer TOP-UP TO PAYLAH! : 91234567")).rows.sole

    assert_equal [ "internal_untracked", wallet.id ], [ row.counterparty_class, row.counterparty_untracked_account_id ]
  end

  test "assigning a line to an untracked account learns its handle for next time" do
    wallet = @family.own_untracked_accounts.create!(name: "Wallet")
    a = statement_import(@current, extracted(amount: -15.0, name: "PAYNOW TRANSFER TO +6598765432"))
    a.rows.sole.update!(counterparty_choice: "untracked:#{wallet.id}")
    a.import!

    next_month = statement_import(@current, extracted(amount: -30.0, name: "PAYNOW TRANSFER TO +6598765432", date: @date + 30))

    assert_equal wallet.id, next_month.rows.sole.counterparty_untracked_account_id
  end

  test "deleting an untracked account keeps its transactions as transfers" do
    wallet = @family.own_untracked_accounts.create!(name: "Wallet")
    identify(wallet, "91234567", kind: "payment_handle")
    a = statement_import(@current, extracted(amount: -20.0, name: "PAYNOW TRANSFER TO +6591234567"))
    a.import!

    wallet.destroy!

    txn = a.entries.sole.entryable.reload
    assert_nil txn.own_untracked_account_id
    assert_equal "funds_movement", txn.kind
    assert_empty AccountIdentifier.where(own_untracked_account_id: wallet.id)
  end

  test "an identifier belongs to exactly one tracked or untracked account" do
    wallet = @family.own_untracked_accounts.create!(name: "Wallet")

    assert_not AccountIdentifier.new(family: @family, kind: "account_last4", value: "1111", source: "user").valid?
    assert_not AccountIdentifier.new(account: @savings, own_untracked_account: wallet, family: @family, kind: "account_last4", value: "1111", source: "user").valid?
    assert AccountIdentifier.new(own_untracked_account: wallet, family: @family, kind: "account_last4", value: "1111", source: "user").valid?
  end

  test "untracked account names are unique in a family, ignoring case" do
    @family.own_untracked_accounts.create!(name: "PayLah")

    assert_not @family.own_untracked_accounts.new(name: "paylah").valid?
  end

  private
    def transfers_before_fixture_count
      @transfers_before_fixture_count ||= Transfer.joins(:inflow_transaction).where.not(inflow_transaction_id: Transaction.joins(:entry).where(entries: { account_id: [ @current.id, @savings.id ] }).select(:id)).count
    end
end
