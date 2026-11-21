class Provider::Openai::BankStatementExtractor
  include Provider::Openai::Concerns::JsonMode

  MAX_CHARS_PER_CHUNK = 3000
  # Balance checks needed before trusting the balance column over the model's signs.
  MIN_BALANCE_CHECKS = 3
  attr_reader :client, :pdf_content, :model, :json_mode

  # liability: true for a credit card statement, false for a bank account,
  # nil when the caller does not know. It sets which way a running balance
  # moves with money in.
  def initialize(client:, pdf_content:, model:, json_mode: nil, liability: nil)
    @client = client
    @pdf_content = pdf_content
    @model = model
    @json_mode = json_mode || default_json_mode
    @liability = liability
  end

  def extract
    pages = extract_pages_from_pdf
    raise Provider::Openai::Error, "Could not extract text from PDF" if pages.empty?

    chunks = build_chunks(pages)
    Rails.logger.info("BankStatementExtractor: Processing #{chunks.size} chunk(s) from #{pages.size} page(s)")

    all_transactions = []
    metadata = {}

    chunks.each_with_index do |chunk, index|
      Rails.logger.info("BankStatementExtractor: Processing chunk #{index + 1}/#{chunks.size}")
      result = process_chunk(chunk, index == 0)

      # Tag transactions with chunk index for deduplication
      tagged_transactions = (result[:transactions] || []).map { |t| t.merge(chunk_index: index) }
      all_transactions.concat(tagged_transactions)

      if index == 0
        metadata = {
          account_holder: result[:account_holder],
          account_number: result[:account_number],
          bank_name: result[:bank_name],
          opening_balance: result[:opening_balance],
          closing_balance: result[:closing_balance],
          period: result[:period]
        }
      end

      if result[:closing_balance].present?
        metadata[:closing_balance] = result[:closing_balance]
      end
      if result.dig(:period, :end_date).present?
        metadata[:period] ||= {}
        metadata[:period][:end_date] = result.dig(:period, :end_date)
      end
    end

    transactions = correct_signs_from_balances(deduplicate_transactions(all_transactions), metadata[:opening_balance])

    {
      transactions: transactions,
      period: metadata[:period] || {},
      account_holder: metadata[:account_holder],
      account_number: metadata[:account_number],
      bank_name: metadata[:bank_name],
      opening_balance: metadata[:opening_balance],
      closing_balance: metadata[:closing_balance]
    }
  end

  private

    def extract_pages_from_pdf
      return [] if pdf_content.blank?

      Pdf::TextExtractor.pages(pdf_content).reject(&:blank?)
    rescue => e
      Rails.logger.error("Failed to extract text from PDF: #{e.message}")
      []
    end

    def build_chunks(pages)
      chunks = []
      current_chunk = []
      current_size = 0

      pages.each do |page_text|
        if page_text.length > MAX_CHARS_PER_CHUNK
          chunks << current_chunk.join("\n\n") if current_chunk.any?
          current_chunk = []
          current_size = 0
          chunks << page_text
          next
        end

        if current_size + page_text.length > MAX_CHARS_PER_CHUNK && current_chunk.any?
          chunks << current_chunk.join("\n\n")
          current_chunk = []
          current_size = 0
        end

        current_chunk << page_text
        current_size += page_text.length
      end

      chunks << current_chunk.join("\n\n") if current_chunk.any?
      chunks
    end

    def process_chunk(text, is_first_chunk)
      params = {
        model: model,
        messages: [
          { role: "system", content: is_first_chunk ? instructions_with_metadata : instructions_transactions_only },
          { role: "user", content: "Extract transactions:\n\n#{text}" }
        ]
      }

      apply_json_mode(params, mode: json_mode)

      response = client.chat(parameters: params)
      content = response.dig("choices", 0, "message", "content")

      raise Provider::Openai::Error, "No response from AI" if content.blank?

      parsed = parse_json_response(content)

      {
        transactions: normalize_transactions(parsed["transactions"] || []),
        period: {
          start_date: parsed.dig("statement_period", "start_date"),
          end_date: parsed.dig("statement_period", "end_date")
        },
        account_holder: parsed["account_holder"],
        account_number: parsed["account_number"],
        bank_name: parsed["bank_name"],
        opening_balance: parsed["opening_balance"],
        closing_balance: parsed["closing_balance"]
      }
    end

    def parse_json_response(content)
      cleaned = content.gsub(%r{^```json\s*}i, "").gsub(/```\s*$/, "").strip
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      Rails.logger.error("BankStatementExtractor JSON parse error: #{e.message} (content_length=#{content.to_s.bytesize})")
      { "transactions" => [] }
    end

    def deduplicate_transactions(transactions)
      # Deduplicates transactions repeated in the next chunk (chunking artifacts).
      #
      # KNOWN LIMITATION: Legitimate duplicate transactions (same date, amount, merchant)
      # split across adjacent chunks will be incorrectly deduplicated. Repeats within
      # one chunk, such as two identical top-ups on the same day, are always kept.
      seen = Set.new
      transactions.select do |t|
        key = [ t[:date], t[:amount], t[:name], t[:chunk_index] ]

        duplicate = seen.any? do |prev_key|
          prev_key[0..2] == key[0..2] && key[3] - prev_key[3] == 1
        end

        seen << key
        !duplicate
      end.map { |t| t.except(:chunk_index) }
    end

    # The running balance settles each row's direction more reliably than the
    # model, which can be misled by wording ("FAST Collection" is money out).
    # Rows whose balance change equals their amount are balance-checked. A
    # bank balance rises with money in and a card balance with charges, so
    # when the caller says which this is and most checked rows already agree,
    # the few that disagree are flipped. When most disagree, the statement
    # prints its balance some other way (an owed balance as a negative number)
    # or the model returned unsigned amounts, and the signs are left alone, as
    # they are when the caller does not know the account type. Rows without a
    # usable balance keep the model's sign.
    def correct_signs_from_balances(transactions, opening_balance)
      # Balances run forward in time; a newest-first list is checked oldest
      # first, from the opening balance.
      newest_first = transactions.first&.dig(:date).to_s > transactions.last&.dig(:date).to_s
      return correct_signs_from_balances(transactions.reverse, opening_balance).reverse if newest_first

      previous = parse_balance(opening_balance)
      deltas = transactions.map do |t|
        balance = t[:balance]
        delta = balance && previous && (balance - previous).round(2)
        previous = balance if balance
        next nil unless delta && t[:amount] && t[:amount].nonzero? && (delta.abs - t[:amount].abs).abs < 0.005

        delta
      end

      checked = transactions.zip(deltas).select { |_, delta| delta }
      unless @liability.nil? || checked.size < MIN_BALANCE_CHECKS
        rises_with_inflow = !@liability
        disagreeing = checked.reject { |t, delta| t[:amount].positive? == (rises_with_inflow ? delta.positive? : delta.negative?) }
        disagreeing.each { |t, _| t[:amount] = -t[:amount] } if disagreeing.size * 2 < checked.size
      end

      transactions.map { |t| t.except(:balance) }
    end

    def normalize_transactions(transactions)
      transactions.map do |txn|
        {
          date: parse_date(txn["date"]),
          amount: parse_amount(txn["amount"]),
          balance: parse_balance(txn["balance"]),
          name: txn["description"] || txn["name"] || txn["merchant"],
          category: infer_category(txn),
          notes: txn["reference"] || txn["notes"]
        }
      end.compact
    end

    def parse_date(date_str)
      return nil if date_str.blank?

      Date.parse(date_str).strftime("%Y-%m-%d")
    rescue ArgumentError
      nil
    end

    def parse_amount(amount)
      return nil if amount.nil?

      if amount.is_a?(Numeric)
        amount.to_f
      else
        amount.to_s.gsub(/[^0-9.\-]/, "").to_f
      end
    end

    # A balance as printed: "1,050.00 DR", "35.00Dr." or OD is overdrawn on a
    # bank account and "50.00 CR" is in credit on a card; "35.00-" and
    # "(35.00)" are below zero.
    def parse_balance(balance)
      return nil if balance.nil? || balance.to_s.strip.empty?

      value = parse_amount(balance)
      return value if value.nil? || balance.is_a?(Numeric)

      text = balance.to_s.strip
      if (marker = text[/(DR|OD|CR)\.?\z/i, 1]&.upcase)
        below_zero = @liability ? marker == "CR" : marker.in?(%w[DR OD])
        return below_zero ? -value.abs : value.abs
      end
      return -value.abs if text.end_with?("-") || (text.start_with?("(") && text.end_with?(")"))

      value
    end

    def infer_category(txn)
      txn["category"] || txn["type"]
    end

    def instructions_with_metadata
      <<~INSTRUCTIONS.strip
        Extract bank statement data as JSON. Return:
        {"bank_name":"...","account_holder":"...","account_number":"last 4 digits","statement_period":{"start_date":"YYYY-MM-DD","end_date":"YYYY-MM-DD"},"opening_balance":0.00,"closing_balance":0.00,"transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00,"balance":0.00}]}

        Rules: Negative amounts for debits/expenses/withdrawals, positive for credits/deposits. balance is the running balance printed on the row, or null if none. Dates as YYYY-MM-DD. Extract ALL transactions. JSON only, no markdown.
      INSTRUCTIONS
    end

    def instructions_transactions_only
      <<~INSTRUCTIONS.strip
        Extract transactions from bank statement text as JSON. Return:
        {"transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00,"balance":0.00}]}

        Rules: Negative amounts for debits/expenses/withdrawals, positive for credits/deposits. balance is the running balance printed on the row, or null if none. Dates as YYYY-MM-DD. Extract ALL transactions. JSON only, no markdown.
      INSTRUCTIONS
    end
end
