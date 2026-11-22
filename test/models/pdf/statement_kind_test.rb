require "test_helper"

class Pdf::StatementKindTest < ActiveSupport::TestCase
  test "reads a credit card statement from its limit and minimum payment" do
    text = <<~TEXT
      Card No. XXXX XXXX XXXX 4821
      Credit Limit 5,000.00   Available Credit 3,210.55
      Minimum Amount Due 120.00   Payment Due Date 15 Dec 2026
    TEXT

    assert_equal "credit_card_statement", Pdf::StatementKind.detect(text)
  end

  test "reads a bank statement from its balance and routing codes" do
    text = <<~TEXT
      Savings Account 001234567890   IFSC: HDFC0000123
      Withdrawals   Deposits   Available Balance
    TEXT

    assert_equal "bank_statement", Pdf::StatementKind.detect(text)
  end

  test "leaves a document mixing both kinds of wording to the model" do
    text = "Credit Limit 5,000  Minimum Payment 50  Savings Account  Available Balance"

    assert_nil Pdf::StatementKind.detect(text)
  end

  test "a single phrase is not enough" do
    assert_nil Pdf::StatementKind.detect("Payment due date 1 Jan")
    assert_nil Pdf::StatementKind.detect("")
  end
end
