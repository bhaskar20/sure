# frozen_string_literal: true

# Creates a manual account owned by the user, the same way the new-account
# forms do.
class Assistant::Function::CreateAccount < Assistant::Function
  class << self
    def name
      "create_account"
    end

    def description
      <<~INSTRUCTIONS
        Create a manual account (one not synced from a bank) owned by the user.

        `accountable_type` is the kind of account: #{Accountable::TYPES.join(", ")}.
        Liabilities (CreditCard, Loan, OtherLiability) use a positive balance for
        the amount owed. `currency` defaults to the family currency.
        `opening_balance_date` (YYYY-MM-DD) is the day the balance history
        starts; it defaults to two years ago. Record later values with
        record_valuation.

        Example:

        ```
        create_account({ name: "Brokerage", accountable_type: "Investment", currency: "USD", balance: 0, opening_balance_date: "2023-01-01" })
        ```
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[name accountable_type],
      properties: {
        name: { type: "string", description: "Account name." },
        accountable_type: { type: "string", enum: Accountable::TYPES, description: "Kind of account." },
        currency: { type: "string", description: "ISO 4217 currency code. Defaults to the family currency." },
        balance: { type: "number", description: "Current balance. Defaults to 0." },
        opening_balance_date: { type: "string", description: "Date the balance history starts (YYYY-MM-DD). Defaults to two years ago." }
      }
    )
  end

  def call(params = {})
    name = params["name"].to_s.strip
    return error("invalid_name", "name is required.") if name.empty?

    type = params["accountable_type"].to_s
    return error("invalid_type", "accountable_type must be one of #{Accountable::TYPES.join(", ")}.") unless Accountable::TYPES.include?(type)

    currency = (params["currency"].presence || family.currency).to_s.upcase
    return error("invalid_currency", "currency must be an ISO 4217 code.") unless known_currency?(currency)

    balance = params["balance"].nil? ? BigDecimal("0") : parse_decimal(params["balance"])
    return error("invalid_balance", "balance must be a number.") if balance.nil?

    opening_date = Time.zone.today - 2.years
    if params["opening_balance_date"].present?
      opening_date = parse_date(params["opening_balance_date"])
      return error("invalid_date", "opening_balance_date must be YYYY-MM-DD.") unless opening_date
    end

    account = family.accounts.create_and_sync(
      { name: name, balance: balance, currency: currency, accountable_type: type, owner: user },
      opening_balance_date: opening_date
    )

    {
      success: true,
      account: { id: account.id, name: account.name, accountable_type: account.accountable_type, currency: account.currency, balance: account.balance.to_s }
    }
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def known_currency?(code)
      Money::Currency.new(code)
      true
    rescue Money::Currency::UnknownCurrencyError
      false
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    def parse_decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
