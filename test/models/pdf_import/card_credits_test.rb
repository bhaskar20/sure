require "test_helper"

class PdfImport::CardCreditsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:credit_card)
    @family = @account.family
    @import = PdfImport.create_from_statement!(statement: create_statement)
    @import.update!(document_type: "credit_card_statement")
    @date = Date.current
    @shopping = @family.categories.create!(name: "Card Shopping #{SecureRandom.hex(3)}")
  end

  # Extractor convention: negative for charges, positive for credits.
  def extracted(date:, amount:, name:, category: nil)
    { "date" => date.to_s, "amount" => amount.to_s, "name" => name, "category" => category.to_s }
  end

  def publish(*transactions)
    @import.update!(extracted_data: { "transactions" => transactions })
    @import.generate_rows_from_extracted_data
    @import.sync_mappings
    @import.import!
    @import.entries.reload.index_by(&:name)
  end

  test "a credit that refunds nothing is a card payment, not income" do
    entries = publish(
      extracted(date: @date - 5, amount: -40, name: "GROCER"),
      extracted(date: @date, amount: 500, name: "PAYMENT RECEIVED - THANK YOU")
    )

    payment = entries["PAYMENT RECEIVED - THANK YOU"].entryable
    assert_equal "cc_payment", payment.kind
    assert_nil payment.category
    assert_equal "standard", entries["GROCER"].entryable.kind
  end

  test "an unlabelled credit with no matching purchase is a payment" do
    entries = publish(extracted(date: @date, amount: 812.40, name: "NEFT HDFC0001 SMITH"))

    assert_equal "cc_payment", entries["NEFT HDFC0001 SMITH"].entryable.kind
  end

  test "a full refund settles a purchase on the same statement" do
    entries = publish(
      extracted(date: @date - 4, amount: -59.99, name: "AMAZON MKTPLACE"),
      extracted(date: @date, amount: 59.99, name: "AMAZON MKTPLACE REFUND")
    )

    purchase = entries["AMAZON MKTPLACE"]
    refund = entries["AMAZON MKTPLACE REFUND"]
    assert purchase.excluded?, "a purchase refunded in full drops out of spending"
    assert refund.excluded?, "and its refund out of income"
    assert_equal "standard", refund.entryable.kind
    assert_equal({ "entry_id" => purchase.id, "settled" => true }, refund.entryable.extra["card_refund"])
  end

  test "a full refund settles a purchase already recorded on the card" do
    purchase = create_transaction(account: @account, date: @date - 30, amount: 120, name: "Nike Store", category: @shopping)

    entries = publish(extracted(date: @date, amount: 120, name: "REFUND NIKE STORE"))

    refund = entries["REFUND NIKE STORE"]
    assert purchase.reload.excluded?
    assert refund.excluded?
    assert_equal @shopping, refund.entryable.category
  end

  test "a partial refund takes the purchase's category and nets against it" do
    purchase = create_transaction(account: @account, date: @date - 10, amount: 200, name: "IKEA Singapore", category: @shopping)

    entries = publish(extracted(date: @date, amount: 45, name: "IKEA SINGAPORE"))

    refund = entries["IKEA SINGAPORE"]
    assert_equal "standard", refund.entryable.kind
    assert_equal @shopping, refund.entryable.category
    assert_not refund.excluded?
    assert_not purchase.reload.excluded?, "only part of it came back"
  end

  test "a refund word with no purchase to match stays a standard credit" do
    entries = publish(extracted(date: @date, amount: 15, name: "CASHBACK REWARD"))

    refund = entries["CASHBACK REWARD"]
    assert_equal "standard", refund.entryable.kind
    assert_not refund.excluded?
  end

  test "a payment equal to some charge is not mistaken for its refund" do
    entries = publish(
      extracted(date: @date - 3, amount: -300, name: "APPLE STORE"),
      extracted(date: @date, amount: 300, name: "AUTOPAY PAYMENT")
    )

    assert_equal "cc_payment", entries["AUTOPAY PAYMENT"].entryable.kind
    assert_not entries["APPLE STORE"].excluded?
  end

  test "one purchase is settled by one refund only" do
    entries = publish(
      extracted(date: @date - 3, amount: -25, name: "UBER TRIP"),
      extracted(date: @date - 1, amount: 25, name: "UBER TRIP REFUND"),
      extracted(date: @date, amount: 25, name: "UBER REFUND")
    )

    settled = [ entries["UBER TRIP REFUND"], entries["UBER REFUND"] ].select(&:excluded?)
    assert_equal 1, settled.size
  end

  test "bank account credits are left as they are" do
    import = PdfImport.create_from_statement!(statement: create_statement(account: accounts(:depository)))
    import.update!(document_type: "bank_statement", extracted_data: { "transactions" => [
      extracted(date: @date, amount: 500, name: "PAYMENT FROM EMPLOYER")
    ] })
    import.generate_rows_from_extracted_data
    import.import!

    assert_equal "standard", import.entries.sole.entryable.kind
  end

  test "reverting restores a recorded purchase the import settled" do
    purchase = create_transaction(account: @account, date: @date - 30, amount: 120, name: "Nike Store")
    publish(extracted(date: @date, amount: 120, name: "REFUND NIKE STORE"))
    @import.update!(status: :complete)
    assert purchase.reload.excluded?

    @import.revert

    assert_nil @import.reload.error
    assert_not purchase.reload.excluded?
  end

  test "reverting leaves a purchase the user excluded themselves alone" do
    purchase = create_transaction(account: @account, date: @date - 30, amount: 120, name: "Nike Store")
    publish(extracted(date: @date, amount: 30, name: "NIKE STORE REFUND"))
    purchase.update!(excluded: true)
    @import.update!(status: :complete)

    @import.revert

    assert purchase.reload.excluded?, "a partial refund never settled it"
  end

  private
    def create_statement(account: @account)
      AccountStatement.create_from_upload!(
        family: account.family,
        account: account,
        file: uploaded_file(
          filename: "statement-#{SecureRandom.hex(3)}.pdf",
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread + "\n% #{SecureRandom.hex(4)}"
        )
      )
    end
end
