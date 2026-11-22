# Tells a credit card statement from a bank account statement by the
# wording only one of them prints: a card states a credit limit and a
# minimum payment due, a bank account an available balance, withdrawals and
# routing codes. A model reading the same document confuses the two often
# enough (both list dated debits and credits) that its answer is checked
# against this.
#
# Returns nil unless one side has at least two distinct phrases and the
# other side clearly fewer, so a statement mentioning both ("pay your card
# from your account") is left to the model.
module Pdf::StatementKind
  CREDIT_CARD_PHRASES = [
    "credit limit", "credit line", "available credit", "cash advance limit",
    "cash limit", "minimum payment", "minimum amount due", "min amount due", "minimum due",
    "payment due date", "total amount due", "total payment due", "statement balance",
    "previous statement balance", "card number", "card no", "cardholder", "card holder", "cardmember",
    "card member", "primary card", "reward points", "rewards summary", "finance charge", "purchase apr",
    "annual percentage rate", "late payment fee", "past due amount"
  ].freeze

  BANK_PHRASES = [
    "available balance", "ledger balance", "savings account", "current account", "checking account",
    "check number", "withdrawals", "deposits", "ifsc", "micr", "sort code", "routing number",
    "overdraft limit", "od limit", "interest earned", "branch code", "nomination", "passbook"
  ].freeze

  MIN_HITS = 2

  def self.detect(text)
    normalized = text.to_s.downcase.gsub(/[[:space:].:]+/, " ")
    card = hits(normalized, CREDIT_CARD_PHRASES)
    bank = hits(normalized, BANK_PHRASES)

    if card >= MIN_HITS && card > bank * 2
      "credit_card_statement"
    elsif bank >= MIN_HITS && bank > card * 2
      "bank_statement"
    end
  end

  def self.hits(text, phrases)
    phrases.count { |phrase| text.match?(/\b#{Regexp.escape(phrase)}\b/) }
  end
  private_class_method :hits
end
