# frozen_string_literal: true

# Records many dated values for one account in a single call, each with the
# same citation. Each value goes through RecordValuation, so validation,
# replacement on an existing date and note merging behave exactly the same.
class Assistant::Function::RecordValuations < Assistant::Function
  MAX_VALUATIONS = 120

  class << self
    def name
      "record_valuations"
    end

    def description
      <<~INSTRUCTIONS
        Record several dated values for one account at once, such as a monthly
        balance history copied from a spreadsheet. Behaves like
        record_valuation for each item: a date that already has a valuation is
        replaced, and the shared `source` citation is stored on every entry.

        At most #{MAX_VALUATIONS} values per call. Items are processed in date
        order; a bad item is reported in `failed` and does not stop the rest.

        Example:

        ```
        record_valuations({
          account_id: "abc123-def456",
          source: "Net worth tracker spreadsheet (grade: B)",
          valuations: [
            { date: "2026-01-31", amount: 1200.00 },
            { date: "2026-02-28", amount: 1350.00 }
          ]
        })
        ```
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[account_id source valuations],
      properties: {
        account_id: {
          type: "string",
          description: "UUID of the account to value. The user must have write access to it."
        },
        source: {
          type: "string",
          description: "Citation shared by every value, in the grammar: [\"estimated: \"] citation [\" (grade: A|B|C)\"]."
        },
        valuations: {
          type: "array",
          description: "Up to #{MAX_VALUATIONS} values, each in the account's own currency.",
          items: {
            type: "object",
            properties: {
              date: { type: "string", description: "ISO 8601 date (YYYY-MM-DD)." },
              amount: { type: "number", description: "The account's value on that date." }
            },
            required: %w[date amount]
          }
        }
      }
    )
  end

  def call(params = {})
    items = params["valuations"]
    return error("invalid_valuations", "valuations must be a non-empty array.") unless items.is_a?(Array) && items.any?
    return error("too_many_valuations", "At most #{MAX_VALUATIONS} valuations per call.") if items.size > MAX_VALUATIONS

    single = Assistant::Function::RecordValuation.new(user)
    recorded = []
    failed = []

    items.map { |item| item.is_a?(Hash) ? item.stringify_keys : {} }
         .sort_by { |item| item["date"].to_s }
         .each do |item|
      result = single.call(
        "account_id" => params["account_id"],
        "source" => params["source"],
        "date" => item["date"],
        "amount" => item["amount"]
      )

      if result[:success]
        recorded << { date: result[:date], amount: result[:amount], replaced_existing: result[:replaced_existing] }
      else
        # The account and citation are shared, so their errors fail every item.
        return result if %w[account_not_found invalid_account_id invalid_source_citation].include?(result[:error])

        failed << { date: item["date"], amount: item["amount"], error: result[:error], message: result[:message] }
      end
    end

    {
      success: failed.empty?,
      recorded_count: recorded.size,
      failed_count: failed.size,
      recorded: recorded,
      failed: failed
    }
  end

  private
    def error(key, message)
      { success: false, error: key, message: message }
    end
end
