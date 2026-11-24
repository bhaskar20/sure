require "test_helper"

# FR-004 slice 1: statement lines classified as internal or external, and
# lines between the family's own accounts linked as transfers on publish.
class PdfImportCounterpartyTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @admin = users(:family_admin)
    @admin.update!(preferences: (@admin.preferences || {}).merge("preview_features_enabled" => true))
    @checking = accounts(:depository)
    @family = @checking.family
    @savings = @family.accounts.create!(
      name: "Savings", balance: 0, currency: "USD", accountable: Depository.new, owner: @admin
    )
    @statement = create_statement
    @import = PdfImport.create_from_statement!(statement: @statement)
    @import.update!(document_type: "bank_statement")
    @date = Date.current
  end

  # Extractor convention: negative is money leaving the statement's account.
  def extracted(amount:, name:, date: @date)
    { "date" => date.to_s, "amount" => amount.to_s, "name" => name }
  end

  def generate(*lines, **extra)
    @import.update!(extracted_data: { "transactions" => lines }.merge(extra.stringify_keys))
    @import.generate_rows_from_extracted_data
    @import.reload.rows.ordered.to_a
  end

  def identify(account, value, kind: "account_last4")
    AccountIdentifier.create!(account: account, family: @family, kind: kind, value: value, source: "user")
  end

  test "a line naming another account's number and mirrored there is a transfer to that account" do
    identify(@savings, "4821")
    mirror = create_transaction(account: @savings, date: @date - 1, amount: -4321.5, name: "From checking")

    row = generate(extracted(amount: -4321.5, name: "ONLINE TRANSFER TO A/C XXXX4821")).sole

    assert_equal "internal_tracked", row.counterparty_class
    assert_equal @savings.id, row.counterparty_account_id
    assert_equal mirror.id, row.counterparty_entry_id
    assert_includes row.counterparty_reasons.map { |reason| reason["code"] }, "mirror_entry"
  end

  test "publishing links the line to its mirror as a confirmed transfer" do
    identify(@savings, "4821")
    mirror = create_transaction(account: @savings, date: @date - 1, amount: -4321.5, name: "From checking")
    generate(extracted(amount: -4321.5, name: "ONLINE TRANSFER TO A/C XXXX4821"))

    assert_difference -> { Transfer.count } => 1 do
      @import.import!
    end

    transfer = mirror.entryable.reload.transfer
    assert transfer.confirmed?
    outflow = transfer.outflow_transaction
    assert_equal @checking, outflow.entry.account
    assert_equal "funds_movement", outflow.kind
    assert_nil outflow.category
    assert_equal "funds_movement", mirror.entryable.reload.kind
  end

  test "an account number plus a self marker classifies without a mirror, and publishes as a transfer kind" do
    identify(@savings, "4821")
    # A balance set by hand keeps the other side from being written (slice 2).
    create_valuation(account: @savings, amount: 500, date: @date - 30, kind: "reconciliation")

    row = generate(extracted(amount: -880.25, name: "NEFT/SELF/XXXX4821")).sole
    assert_equal "internal_tracked", row.counterparty_class
    assert_nil row.counterparty_entry_id

    assert_no_difference -> { Transfer.count } do
      @import.import!
    end
    transaction = @import.entries.sole.entryable
    assert_equal "funds_movement", transaction.kind
    assert_nil transaction.category
  end

  test "a card bill naming the card's number publishes as a card payment" do
    card = @family.accounts.create!(name: "Rewards card ••2222", balance: 0, currency: "USD", accountable: CreditCard.new, owner: @admin)

    row = generate(extracted(amount: -611.4, name: "BILL PAYMENT DBSC-5520380011112222 : I-BANK")).sole
    assert_equal "internal_tracked", row.counterparty_class
    assert_equal card.id, row.counterparty_account_id

    @import.import!
    assert_equal "cc_payment", @import.entries.where(account: @checking).sole.entryable.kind
  end

  test "a mirror alone is only a suggestion" do
    create_transaction(account: @savings, date: @date, amount: -777.77, name: "Deposit")

    row = generate(extracted(amount: -777.77, name: "FUNDS TRANSFER FT1234")).sole

    assert_equal "unknown", row.counterparty_class
    assert_equal @savings.id, row.counterparty_account_id

    assert_no_difference -> { Transfer.count } do
      @import.import!
    end
    assert_equal "standard", @import.entries.sole.entryable.kind
  end

  test "evidence pointing at two different accounts is never applied" do
    identify(@savings, "4821")
    identify(accounts(:credit_card), "4821", kind: "card_last4")

    row = generate(extracted(amount: -654.32, name: "TRANSFER TO A/C XXXX4821")).sole

    assert_equal "unknown", row.counterparty_class
    assert_nil row.counterparty_account_id
    assert_equal "conflict", row.counterparty_reasons.first["code"]
  end

  test "money to or from a household member's own name is internal to an untracked account" do
    rows = generate(
      extracted(amount: 2500, name: "INCOMING PAYNOW REF 0812345 FROM: DYLAN BOB"),
      extracted(amount: -45.1, name: "PAYNOW TRANSFER 8001111 TO: CORNER BAKERY PTE LTD")
    )

    assert_equal "internal_untracked", rows.first.counterparty_class
    assert_equal [ "own_name" ], rows.first.counterparty_reasons.map { |reason| reason["code"] }
    assert_equal "external", rows.second.counterparty_class

    @import.import!
    kinds = @import.entries.joins("INNER JOIN transactions ON transactions.id = entries.entryable_id").order(:amount).pluck("transactions.kind")
    assert_equal %w[funds_movement standard], kinds
  end

  test "a household member's name with a mirror is a transfer to the mirrored account" do
    create_transaction(account: @savings, date: @date, amount: 3100, name: "To checking")

    row = generate(extracted(amount: 3100, name: "INCOMING PAYNOW FROM: BOB DYLAN")).sole

    assert_equal "internal_tracked", row.counterparty_class
    assert_equal @savings.id, row.counterparty_account_id
  end

  test "a wallet top-up goes to the wallet account when the family tracks it" do
    wallet = @family.accounts.create!(name: "PayLah wallet", balance: 0, currency: "USD", accountable: Depository.new, owner: @admin)

    rows = generate(extracted(amount: -20, name: "Advice Funds Transfer TOP-UP TO PAYLAH! : 91234567"))

    assert_equal "internal_tracked", rows.sole.counterparty_class
    assert_equal wallet.id, rows.sole.counterparty_account_id
  end

  test "the statement's own card number on a purchase is not a counterparty" do
    identify(@checking, "2222", kind: "card_last4")
    identify(@savings, "2222", kind: "card_last4")

    row = generate(extracted(amount: -18.4, name: "Debit Card Transaction GROCER SGP 07OCT 4628-4500-1111-2222")).sole

    assert_equal "external", row.counterparty_class
  end

  test "two lines never claim the same mirror" do
    mirror = create_transaction(account: @savings, date: @date, amount: -999.99, name: "Deposit")
    identify(@savings, "4821")

    rows = generate(
      extracted(amount: -999.99, name: "TRANSFER TO A/C XXXX4821"),
      extracted(amount: -999.99, name: "TRANSFER TO A/C XXXX4821")
    )

    assert_equal [ mirror.id, nil ], rows.map(&:counterparty_entry_id)
  end

  test "a mirror already in a transfer, pending, or excluded is not offered" do
    excluded = create_transaction(account: @savings, date: @date, amount: -432.1, name: "Deposit")
    excluded.update!(excluded: true)

    row = generate(extracted(amount: -432.1, name: "FUNDS TRANSFER")).sole

    assert_equal "external", row.counterparty_class
  end

  test "a counterpart claimed after review leaves the line a plain transaction" do
    identify(@savings, "4821")
    # A balance set by hand keeps a provisional leg out of it (slice 2).
    create_valuation(account: @savings, amount: 500, date: @date - 30, kind: "reconciliation")
    mirror = create_transaction(account: @savings, date: @date, amount: -1234.56, name: "Deposit")
    generate(extracted(amount: -1234.56, name: "TRANSFER TO A/C XXXX4821"))

    other = create_transaction(account: accounts(:credit_card), date: @date, amount: 1234.56, name: "Card")
    Transfer.create!(inflow_transaction: mirror.entryable, outflow_transaction: other.entryable, status: "confirmed")

    assert_no_difference -> { Transfer.count } do
      @import.import!
    end
    assert_equal 1, @import.entries.count
  end

  test "reverting the import removes the transfer and frees the counterpart" do
    identify(@savings, "4821")
    mirror = create_transaction(account: @savings, date: @date, amount: -2468.0, name: "Deposit")
    generate(extracted(amount: -2468.0, name: "TRANSFER TO A/C XXXX4821"))
    @import.import!
    assert mirror.entryable.reload.transfer.present?

    @import.revert

    counterpart = mirror.entryable.reload
    assert_nil counterpart.transfer
    assert_equal "standard", counterpart.kind
  end

  test "lines are not classified when no household member opted into preview features" do
    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => false))
    identify(@savings, "4821")

    row = generate(extracted(amount: -50.5, name: "NEFT/SELF/XXXX4821")).sole

    assert_nil row.counterparty_class
    @import.import!
    assert_equal "standard", @import.entries.sole.entryable.kind
  end

  test "clearing the classification publishes every line as a plain transaction" do
    identify(@savings, "4821")
    generate(extracted(amount: -50.5, name: "NEFT/SELF/XXXX4821"))

    @import.clear_counterparty_classification!

    assert_empty @import.preexisting_target_account_ids
    @import.import!
    assert_equal "standard", @import.entries.sole.entryable.kind
  end

  test "only accounts a published transfer reaches are revert targets" do
    identify(@savings, "4821")
    create_transaction(account: @savings, date: @date, amount: -50.5, name: "Deposit")
    generate(
      extracted(amount: -50.5, name: "NEFT/SELF/XXXX4821"),
      extracted(amount: -60.25, name: "TRANSFER TO RAVI SHARMA") # nothing written elsewhere
    )
    assert_empty @import.preexisting_target_account_ids

    @import.import!

    assert_equal [ @savings.id ], @import.preexisting_target_account_ids
  end

  test "preparing to publish keeps only links the publisher may make" do
    identify(@savings, "4821")
    generate(extracted(amount: -50.5, name: "NEFT/SELF/XXXX4821"))
    row = @import.rows.sole

    @import.prepare_counterparty_for_publish!(@admin)
    assert_equal "internal_tracked", row.reload.counterparty_class

    @savings.update!(owner: users(:family_member))
    @import.prepare_counterparty_for_publish!(@admin)
    assert_equal "unknown", row.reload.counterparty_class
  end

  test "reverting gives a linked counterpart back the kind it had" do
    counterpart = create_transaction(account: @savings, date: @date, amount: -1357.9, name: "From checking")
    counterpart.entryable.update!(kind: "funds_movement", category: nil)
    identify(@savings, "4821")
    generate(extracted(amount: -1357.9, name: "TRANSFER TO A/C XXXX4821"))
    @import.import!
    assert counterpart.entryable.reload.transfer.present?

    @import.revert

    restored = counterpart.entryable.reload
    assert_nil restored.transfer
    assert_equal "funds_movement", restored.kind
    assert_nil restored.category
  end

  test "a mirror only counts in an account the line already points at" do
    identify(@savings, "4821")
    create_transaction(account: accounts(:credit_card), date: @date, amount: -500.5, name: "Refund")
    real = create_transaction(account: @savings, date: @date + 3, amount: -500.5, name: "From checking")

    row = generate(extracted(amount: -500.5, name: "TRANSFER TO A/C XXXX4821")).sole

    assert_equal [ "internal_tracked", @savings.id, real.id ], [ row.counterparty_class, row.counterparty_account_id, row.counterparty_entry_id ]
  end

  test "two accounts with the same evidence are not guessed between" do
    joint = @family.accounts.create!(name: "Joint", balance: 0, currency: "USD", accountable: Depository.new, owner: @admin)
    identify(@savings, "BOB DYLAN", kind: "holder_name")
    identify(joint, "BOB DYLAN", kind: "holder_name")

    row = generate(extracted(amount: -70.25, name: "TRANSFER TO BOB DYLAN")).sole

    assert_equal "internal_untracked", row.counterparty_class
    assert_nil row.counterparty_account_id
  end

  test "a household member named next to another party is just the holder" do
    row = generate(extracted(amount: 4000, name: "INCOMING PAYNOW FROM: ACME PTE LTD TO: BOB DYLAN")).sole

    assert_equal "external", row.counterparty_class
  end

  test "a household member written with an initial is recognised" do
    row = generate(extracted(amount: -90.5, name: "TRANSFER TO B DYLAN")).sole

    assert_equal "internal_untracked", row.counterparty_class
  end

  test "a card bill paid from a bank account is own money even before the card is known" do
    accounts(:credit_card).update!(status: "disabled")

    row = generate(extracted(amount: -1200.4, name: "CREDIT CARD PAYMENT")).sole

    assert_equal "internal_untracked", row.counterparty_class
  end

  test "a top-up of something that is not a known wallet or account is spending" do
    row = generate(extracted(amount: -30, name: "SINGTEL PREPAID TOP UP STARHUB")).sole

    assert_equal "external", row.counterparty_class
  end

  test "the summary counts a line linked to a removed account as needing a decision" do
    identify(@savings, "4821")
    generate(extracted(amount: -50.5, name: "NEFT/SELF/XXXX4821"), extracted(amount: -9.5, name: "BOOKSTORE"))

    @savings.update!(status: "disabled")

    assert_equal({ internal: 0, needs_decision: 1, total: 2, classified: 2 }, @import.counterparty_summary(@admin))
  end

  test "unlinking or deleting the statement takes its identifiers with it" do
    @statement.update!(account_last4_hint: "6789")
    generate(extracted(amount: -10.5, name: "BOOKSTORE"))
    assert_equal 1, @checking.account_identifiers.count

    @statement.unlink!
    assert_empty @checking.account_identifiers.reload

    @statement.link_to_account!(@checking)
    @import.generate_rows_from_extracted_data
    assert_equal 1, @checking.account_identifiers.reload.count

    @import.destroy!
    @statement.destroy!
    assert_empty @checking.account_identifiers.reload
  end

  test "an identifier another statement still shows survives its first statement leaving" do
    @statement.update!(account_last4_hint: "6789")
    generate(extracted(amount: -10.5, name: "BOOKSTORE"))
    other = AccountStatement.create_from_upload!(
      family: @family, account: @checking,
      file: uploaded_file(filename: "second.pdf", content_type: "application/pdf", content: file_fixture("imports/sample_bank_statement.pdf").binread + " ")
    )
    other.update!(account_last4_hint: "6789")

    @statement.unlink!

    assert_equal [ other.id ], @checking.account_identifiers.pluck(:account_statement_id)
  end

  test "the statement's last four and holder are remembered for the account it is imported into" do
    @statement.update!(account_last4_hint: "6789")

    generate(extracted(amount: -10.5, name: "BOOKSTORE"), account_holder: "MR BOB DYLAN")

    identifiers = @checking.account_identifiers.order(:kind).pluck(:kind, :value, :source)
    assert_equal [ [ "account_last4", "6789", "statement" ], [ "holder_name", "MR BOB DYLAN", "statement" ] ], identifiers
  end

  test "moving the statement to another account moves its identifiers" do
    @statement.update!(account_last4_hint: "6789")
    generate(extracted(amount: -10.5, name: "BOOKSTORE"))

    @import.assign_account!(@savings)

    assert_empty @checking.account_identifiers
    assert_equal [ "6789" ], @savings.account_identifiers.pluck(:value)
  end

  test "a line naming the statement's own account number is not a counterparty" do
    @statement.update!(account_last4_hint: "4821")
    identify(@savings, "4821")

    row = generate(extracted(amount: -15.75, name: "CHARGES FOR A/C XXXX4821")).sole

    assert_equal "external", row.counterparty_class
  end

  test "a reviewer's pick replaces the classification" do
    row = generate(extracted(amount: -45.1, name: "FUNDS TRANSFER FT1234")).sole

    row.update!(counterparty_choice: "account:#{@savings.id}")
    assert_equal [ "internal_tracked", @savings.id, true ], [ row.counterparty_class, row.counterparty_account_id, row.counterparty_user_set ]
    assert_equal "account:#{@savings.id}", row.counterparty_choice

    row.update!(counterparty_choice: "external")
    assert_equal [ "external", nil ], [ row.counterparty_class, row.counterparty_account_id ]

    row.update!(counterparty_choice: "nonsense")
    assert_equal "external", row.counterparty_class
  end

  test "a household member with an added middle initial is recognised" do
    row = generate(extracted(amount: -90.5, name: "TRANSFER TO BOB K DYLAN")).sole

    assert_equal "internal_untracked", row.counterparty_class
  end

  test "a card bill naming a card number nobody tracks does not suggest the only card" do
    row = generate(extracted(amount: -88.8, name: "CREDIT CARD PAYMENT 4111-2222-3333-9999")).sole

    assert_equal "internal_untracked", row.counterparty_class
    assert_nil row.counterparty_account_id
  end

  test "weak evidence for one account does not hide a mirror in another" do
    joint = @family.accounts.create!(name: "Joint", balance: 0, currency: "USD", accountable: Depository.new, owner: @admin)
    identify(joint, "BOB DYLAN", kind: "holder_name")
    mirror = create_transaction(account: @savings, date: @date, amount: -640.0, name: "Deposit")

    row = generate(extracted(amount: -640.0, name: "TRANSFER TO BOB DYLAN")).sole

    assert_equal [ @savings.id, mirror.id ], [ row.counterparty_account_id, row.counterparty_entry_id ]
  end

  test "deleting a published import gives a linked counterpart back the kind it had" do
    counterpart = create_transaction(account: @savings, date: @date, amount: -2222.2, name: "From checking")
    counterpart.entryable.update!(kind: "funds_movement", category: nil)
    identify(@savings, "4821")
    generate(extracted(amount: -2222.2, name: "TRANSFER TO A/C XXXX4821"))
    @import.import!

    @import.destroy!

    restored = counterpart.entryable.reload
    assert_nil restored.transfer
    assert_equal "funds_movement", restored.kind
  end

  test "reverting leaves alone a counterpart whose link was undone since" do
    counterpart = create_transaction(account: @savings, date: @date, amount: -3333.3, name: "From checking")
    identify(@savings, "4821")
    generate(extracted(amount: -3333.3, name: "TRANSFER TO A/C XXXX4821"))
    @import.import!
    counterpart.entryable.reload.transfer.destroy!
    groceries = @family.categories.create!(name: "Groceries FR004", color: "#111111")
    counterpart.entryable.reload.update!(category: groceries)

    @import.revert

    assert_equal groceries, counterpart.entryable.reload.category
  end

  test "editing a statement's account or last four releases what it said before" do
    @statement.update!(account_last4_hint: "6789")
    generate(extracted(amount: -10.5, name: "BOOKSTORE"))

    @statement.update!(account_last4_hint: "6788")
    assert_empty @checking.account_identifiers.reload

    @import.generate_rows_from_extracted_data
    @statement.update!(account: @savings)
    assert_empty @checking.account_identifiers.reload
  end

  test "deleting a statement hands its identifiers to another statement that shows them" do
    @statement.update!(account_last4_hint: "6789")
    generate(extracted(amount: -10.5, name: "BOOKSTORE"))
    other = AccountStatement.create_from_upload!(
      family: @family, account: @checking,
      file: uploaded_file(filename: "third.pdf", content_type: "application/pdf", content: file_fixture("imports/sample_bank_statement.pdf").binread + "  ")
    )
    other.update!(account_last4_hint: "6789")

    @import.destroy!
    @statement.destroy!

    assert_equal [ other.id ], @checking.account_identifiers.pluck(:account_statement_id)
  end

  test "a line given a readable name is classified from the statement's own words" do
    wallet = @family.accounts.create!(name: "PayLah wallet", balance: 0, currency: "USD", accountable: Depository.new, owner: @admin)
    identify(@savings, "4821")
    renamed = ->(amount, name, original, notes = original) { extracted(amount: amount, name: name).merge("original_name" => original, "notes" => notes) }

    rows = generate(
      renamed.call(-20, "PayLah! top-up", "TOP-UP TO PAYLAH! : 91234567"),
      renamed.call(2500, "Transfer from Bob Dylan", "INCOMING PAYNOW FROM: BOB DYLAN"),
      renamed.call(-4321.5, "Transfer to savings", "ONLINE TRANSFER TO A/C XXXX4821 SELF", "ONLINE TRANSFER TO A/C XXXX4821 SELF TF58123")
    )

    assert_equal [ [ "internal_tracked", wallet.id ], [ "internal_untracked", nil ], [ "internal_tracked", @savings.id ] ],
      rows.map { |row| [ row.counterparty_class, row.counterparty_account_id ] }
    assert_equal "TOP-UP TO PAYLAH! : 91234567", rows.first.original_name
    assert_equal "ONLINE TRANSFER TO A/C XXXX4821 SELF TF58123", rows.last.counterparty_text
  end

  test "a last four only the model read is not taken as the statement's own account" do
    @statement.update!(account_last4_hint: "4821")
    identify(@savings, "4821")

    row = generate(extracted(amount: -4321.5, name: "ONLINE TRANSFER TO A/C XXXX4821 SELF"), ai_filled: [ "account_last4" ], account_number: "4821").sole

    assert_equal [ "internal_tracked", @savings.id ], [ row.counterparty_class, row.counterparty_account_id ]
    assert_empty @checking.account_identifiers.where(value: "4821")
    assert_not_includes @import.new_account_name.to_s, "4821"
  end

  test "a last four the family corrected after the model read one is the statement's own" do
    @statement.update!(account_last4_hint: "6789")

    generate(extracted(amount: -10.5, name: "BOOKSTORE"), ai_filled: [ "account_last4" ], account_number: "4821")

    assert_equal [ "6789" ], @checking.account_identifiers.where(kind: "account_last4").pluck(:value)
  end

  test "a line renamed before the original was kept apart is read from its notes" do
    wallet = @family.accounts.create!(name: "PayLah wallet", balance: 0, currency: "USD", accountable: Depository.new, owner: @admin)

    row = generate(
      extracted(amount: -20, name: "PayLah! top-up").merge("notes" => "TOP-UP TO PAYLAH! : 91234567"),
      ai_filled: [ "transaction_names" ]
    ).sole

    assert_equal [ "internal_tracked", wallet.id ], [ row.counterparty_class, row.counterparty_account_id ]
  end

  private
    def create_statement
      AccountStatement.create_from_upload!(
        family: @family,
        account: @checking,
        file: uploaded_file(
          filename: "statement.pdf",
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread
        )
      )
    end
end
