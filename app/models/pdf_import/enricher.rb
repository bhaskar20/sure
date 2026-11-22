# Fills what a statement's extraction left out, with the model in extract_pdf's
# route: the statement's and account's own details (balances, period, currency,
# bank, account number, subtype, card terms), then a readable name for each
# transaction. Rules and the extraction model stay authoritative; the model
# here only answers for fields that are still empty.
#
# The model reads the document's text, and its answers are checked against it:
# a figure must be printed in the document, a currency must be a real one, a
# subtype one Sure knows. A balance that disagrees with the rows is replaced by
# one worked out from the other balance, as the rows are what gets imported.
class PdfImport::Enricher
  MAX_TEXT_CHARS = 60_000
  NAME_BATCH_SIZE = 50
  MAX_NAME_LENGTH = 80
  BALANCE_TOLERANCE = BigDecimal("0.01")
  CARD_FIELDS = %w[available_credit minimum_payment apr annual_fee].freeze

  def initialize(pdf_import, provider:)
    @pdf_import = pdf_import
    @provider = provider
  end

  # Returns the data with the gaps it could fill, and the names of the fields
  # it filled under "ai_filled". A failed request leaves the data as it was.
  def enrich(data)
    data = data.deep_dup
    filled = []
    @text = document_text

    filled.concat(fill_statement_gaps(data)) if @text.present?
    filled << "transaction_names" if clean_transaction_names(data)

    data["ai_filled"] = (Array(data["ai_filled"]) | filled) if filled.any?
    data
  end

  private
    attr_reader :pdf_import, :provider, :text

    def liability?
      pdf_import.credit_card_statement?
    end

    def document_text
      text = Pdf::TextExtractor.pages(pdf_import.pdf_file_content).join("\n\f\n")
      return text if text.length <= MAX_TEXT_CHARS

      # Balances and card terms sit in a statement's first and last pages.
      head = text[0, MAX_TEXT_CHARS * 3 / 4]
      tail = text[-(MAX_TEXT_CHARS / 4)..]
      "#{head}\n…\n#{tail}"
    rescue StandardError => e
      log_failure("read the document text", e)
      nil
    end

    # -- Statement and account details ---------------------------------------

    def fill_statement_gaps(data)
      missing = missing_fields(data)
      return [] if missing.empty?

      answer = ask(
        operation: "fill_statement_gaps",
        instructions: gap_instructions,
        input: gap_input(data, missing),
        schema: gap_schema(missing)
      )
      return [] unless answer

      apply_gaps(data, answer.slice(*missing))
    end

    def missing_fields(data)
      statement = pdf_import.account_statement
      parser_output = statement&.sanitized_parser_output || {}
      fields = []
      fields << "currency" if data["currency"].blank? && parser_output["extracted_currency"].blank?
      fields << "institution_name" if data["bank_name"].blank? && parser_output["extracted_institution"].blank?
      fields << "account_name"
      fields << "account_last4" if data["account_number"].blank? && statement&.account_last4_hint.blank?
      fields << "account_subtype" if pdf_import.bank_statement?
      fields << "period_start" if data.dig("period", "start_date").blank?
      fields << "period_end" if data.dig("period", "end_date").blank?
      fields << "opening_balance" if data["opening_balance"].nil?
      fields << "closing_balance" if data["closing_balance"].nil?
      fields.concat(CARD_FIELDS + %w[payment_due_date]) if liability?
      fields
    end

    def gap_instructions
      <<~TEXT.strip
        You read the text of a #{liability? ? "credit card" : "bank account"} statement or transaction history export and report details printed in it.
        Report only what the document states. Use null for anything it does not print; never estimate or compute a figure.
        - Amounts are plain numbers without currency symbols or thousands separators.#{" Balances are the amount owed on the card, positive when the cardholder owes money." if liability?}
        - closing_balance is the balance at the end of the statement, or the current, ledger or available balance a history export prints. opening_balance is the balance brought forward at its start.
        - Dates are YYYY-MM-DD. currency is the ISO 4217 code of the account (S$ is SGD).
        - account_name is the product as printed ("Multiplier Account", "Platinum Visa"), without the bank's name or the account number.
        - account_last4 is the last four digits of the account or card number.
        - account_subtype is checking for a current or everyday account, savings for a savings account (including bonus-interest accounts), money_market, cd for a fixed or time deposit, hsa, or cash.
      TEXT
    end

    def gap_input(data, missing)
      known = {
        "document_type" => pdf_import.document_type,
        "period" => data["period"],
        "opening_balance" => data["opening_balance"],
        "closing_balance" => data["closing_balance"],
        "transaction_count" => Array(data["transactions"]).size
      }.compact
      "Fields to report: #{missing.join(", ")}\nAlready known: #{known.to_json}\n\nDOCUMENT TEXT:\n#{text}"
    end

    def gap_schema(missing)
      number = { type: [ "number", "null" ] }
      string = { type: [ "string", "null" ] }
      types = {
        "currency" => string, "institution_name" => string, "account_name" => string, "account_last4" => string,
        "account_subtype" => { type: [ "string", "null" ], enum: Depository::SUBTYPES.keys + [ nil ] },
        "period_start" => string, "period_end" => string, "payment_due_date" => string,
        "opening_balance" => number, "closing_balance" => number
      }
      CARD_FIELDS.each { |field| types[field] = number }
      { type: "object", properties: types.slice(*missing), required: missing }
    end

    def apply_gaps(data, answer)
      filled = []
      details = (data["account_details"] || {}).dup

      if (code = PdfImport.iso_currency(answer["currency"]))
        data["currency"] = code
        filled << "currency"
      end
      if (name = bounded_string(answer["institution_name"]))
        data["bank_name"] = name
        filled << "institution_name"
      end
      if (name = bounded_string(answer["account_name"]))
        details["account_name"] = name
        filled << "account_name"
      end
      last4 = answer["account_last4"].to_s[/\A\d{4}\z/]
      # Account numbers are printed grouped ("271-142964-0", "**** 1234").
      if last4 && text.gsub(/(?<=\d)[\s-](?=\d)/, "").include?(last4)
        data["account_number"] = last4
        filled << "account_last4"
      end
      if Depository::SUBTYPES.key?(answer["account_subtype"])
        details["subtype"] = answer["account_subtype"]
        filled << "account_subtype"
      end

      filled.concat(apply_period(data, answer))
      filled.concat(apply_balances(data, answer))

      CARD_FIELDS.each do |field|
        value = printed_number(answer[field])
        next unless value && value >= 0

        details[field] = value.to_f
        filled << field
      end
      if (due = statement_date(answer["payment_due_date"], future: true))
        details["due_day"] = due.day
        filled << "payment_due_date"
      end

      data["account_details"] = details if details.any?
      filled
    end

    def apply_period(data, answer)
      period = (data["period"] || {}).dup
      read_start = period["start_date"].blank? ? statement_date(answer["period_start"]) : nil
      read_end = period["end_date"].blank? ? statement_date(answer["period_end"]) : nil
      start_on = read_start || safe_date(period["start_date"])
      end_on = read_end || safe_date(period["end_date"])
      return [] if start_on && end_on && start_on > end_on

      filled = []
      if read_start
        period["start_date"] = read_start.iso8601
        filled << "period_start"
      end
      if read_end
        period["end_date"] = read_end.iso8601
        filled << "period_end"
      end
      data["period"] = period if filled.any?
      filled
    end

    # A balance the model read is kept only when the rows agree with it. With
    # one balance known, the other follows from the rows: a bank balance rises
    # with money in, the amount owed on a card falls with it.
    def apply_balances(data, answer)
      known_opening = data["opening_balance"]&.to_d
      known_closing = data["closing_balance"]&.to_d
      return [] if known_opening && known_closing

      opening = known_opening || printed_number(answer["opening_balance"])
      closing = known_closing || printed_number(answer["closing_balance"])
      rows = Array(data["transactions"])

      if rows.any?
        delta = rows.sum { |row| row["amount"].to_d }
        delta = -delta if liability?

        if opening && closing && (opening + delta - closing).abs > BALANCE_TOLERANCE
          # Keep the balance that did not come from this answer; when both
          # did, keep the closing one, which a history export prints.
          if known_opening
            closing = opening + delta
          else
            opening = closing - delta
          end
        elsif closing && opening.nil?
          opening = closing - delta
        elsif opening && closing.nil?
          closing = opening + delta
        end
      end

      filled = []
      if known_opening.nil? && opening
        data["opening_balance"] = opening.to_f
        filled << "opening_balance"
      end
      if known_closing.nil? && closing
        data["closing_balance"] = closing.to_f
        filled << "closing_balance"
      end
      filled
    end

    # -- Transaction names ----------------------------------------------------

    # Turns bank text ("TRF TOP-UP TO PAYLAH! : 93415445 TF58...") into a name
    # a person would write. The original stays in the notes, so references and
    # account numbers are not lost.
    def clean_transaction_names(data)
      rows = Array(data["transactions"])
      return false if rows.empty?

      changed = false
      rows.each_slice(NAME_BATCH_SIZE).with_index do |batch, batch_index|
        offset = batch_index * NAME_BATCH_SIZE
        answer = ask(
          operation: "clean_transaction_names",
          instructions: name_instructions,
          input: batch.each_with_index.map { |row, i| "#{offset + i}\t#{row["name"]}" }.join("\n"),
          schema: name_schema
        )
        next unless answer

        Array(answer["names"]).each do |item|
          next unless item.is_a?(Hash)
          index = Integer(item["i"], exception: false)
          next unless index && index >= offset && index < offset + batch.size

          name = bounded_string(item["name"], MAX_NAME_LENGTH)
          row = rows[index]
          next if name.nil? || name == row["name"].to_s.strip

          row["notes"] = row["name"] if row["notes"].blank?
          row["name"] = name
          changed = true
        end
      end
      changed
    end

    def name_instructions
      <<~TEXT.strip
        Each input line is an index, a tab, and a transaction description copied from a bank statement.
        Rewrite each description as the short name a person would give the transaction: the merchant, payee or purpose ("PayLah! top-up", "Transfer to John Tan", "Salary from Acme", "Interest earned", "NTUC FairPrice").
        Drop reference numbers, card numbers, terminal codes and dates. Keep a person's or company's name when it is the payee. Do not invent details that are not in the description.
        Return every index once.
      TEXT
    end

    def name_schema
      {
        type: "object",
        properties: {
          names: {
            type: "array",
            items: {
              type: "object",
              properties: { i: { type: "integer" }, name: { type: "string" } },
              required: %w[i name]
            }
          }
        },
        required: %w[names]
      }
    end

    # -- Checks ---------------------------------------------------------------

    def ask(operation:, instructions:, input:, schema:)
      response = provider.structured_json(
        instructions: instructions, input: input, schema: schema,
        operation: operation, family: pdf_import.family
      )
      return response.data if response.success? && response.data.is_a?(Hash)

      log_failure(operation, response.error)
      nil
    rescue StandardError => e
      log_failure(operation, e)
      nil
    end

    # A number the model reported, when the document prints it ("23,974.01",
    # "23974.01", "S$ 23,974"). Anything not printed is a guess and dropped.
    def printed_number(value)
      return unless value.is_a?(Numeric) || value.to_s.strip.match?(/\A-?\d+(?:\.\d+)?\z/)

      number = value.to_d
      plain = number.abs.to_s("F").sub(/\.0\z/, "")
      forms = [ plain, format("%.2f", number.abs) ]
      forms << plain.sub(/\.\d+\z/, "") if plain.end_with?(".00")
      digits = text.gsub(/(?<=\d),(?=\d{3}\b)/, "")
      number if forms.uniq.any? { |form| digits.match?(/(?<![\d.])#{Regexp.escape(form)}(?![\d])/) }
    end

    def statement_date(value, future: false)
      date = safe_date(value)
      return unless date
      latest = future ? Date.current + 90 : Date.current + 1
      date if date.between?(Date.current - 15.years, latest)
    end

    def safe_date(value)
      value.present? ? Date.iso8601(value.to_s) : nil
    rescue Date::Error
      nil
    end

    def bounded_string(value, max = 120)
      string = value.to_s.squish
      string.presence && string.length <= max ? string : nil
    end

    # Enrichment is best effort: the import goes on with what extraction read.
    def log_failure(step, error)
      DebugLogEntry.capture(
        category: "import",
        level: "info",
        message: "PdfImport enrichment could not #{step}: #{error&.message.to_s.truncate(200)}",
        source: "pdf_import",
        family: pdf_import.family,
        account: pdf_import.account,
        metadata: { import_id: pdf_import.id, step: step, error_class: error&.class&.name }
      )
    end
end
