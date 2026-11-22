# Reads a banking app's transaction history export: rows grouped under date
# headings ("Saturday, 15 Nov 2026"), each row ending in a currency amount
# whose sign gives the direction ("SGD - 12.30" out, "SGD 500.00" in).
#
# Such exports print no running balance or totals, so nothing reconciles.
# Instead it only accepts a document where every row sits under a heading it
# could read, every amount is in a row, and the signs follow one convention:
# "-" for money out, and either "+" or no sign (not both) for money in.
# Anything else returns nil and the caller falls back to LLM extraction.
#
# The header above the first heading may print the account's balance as of
# the export ("Ledger Balance" over "SGD 1,234.56"). That is the closing
# balance, and the opening balance is what it was before the listed rows.
class Pdf::TransactionHistoryParser
  MONTH = "(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\\.?"
  HEADING = /\A(?:[a-z]+[,.]\s+)?(\d{1,2})\s+#{MONTH}\s+(\d{4})[\s|.]*\z/i
  # A heading OCR misread ("8 0ct 2026", "l3 Nov 2026", "13 Nov 2O26"). Its
  # rows would land on the previous date, so it is repaired or nothing is read.
  # A day must keep at least one real digit, so "October 2026" is no "O ctober".
  DAY = "(?:\\d[\\dlio]?|[lio]\\d)"
  HEADING_SHAPE = /\A(?:[a-z]+[,.]\s+)?(#{DAY})\s+([a-z0-9]{3,9}\.?)\s+([\dlio]{4})[\s|.]*\z/i
  # Anything else that starts like a dated heading ("13Nov 2026") but does
  # not read as one. Month separators ("June 2026") do not start with a day.
  HEADING_LIKE = /\A(?:[a-z]+[,.]?\s+)?#{DAY}[\s.]*[a-z0-9]{3,9}\.?[\s,]+[\dlio]{4}\b/i
  OCR_LETTERS = { "0" => "o", "1" => "l", "5" => "s", "8" => "b" }.freeze
  OCR_DIGITS = { "l" => "1", "L" => "1", "i" => "1", "I" => "1", "o" => "0", "O" => "0" }.freeze
  ROW = /\A(.*?)\s{2,}(?:[A-Z]{3}|S\$|\$)\s?([-+])?\s?(\d{1,3}(?:,\d{3})*\.\d{2})\s*\z/
  # Amounts this layout cannot read as a row: no cents, a decimal comma, a
  # symbol it does not know.
  ANY_AMOUNT = /\d\.\d{2}\b|(?:\b[A-Z]{3}|[$€£¥₹])\s?[-+]?\s?\d/
  # A total or balance printed among the rows is not a transaction. Any other
  # description with those words ("Ending balance", "Monthly total", or the
  # merchant "TOTAL ENERGIES") cannot be told apart from one, so the parser
  # gives up and the model reads the export instead.
  SUMMARY_LABEL = /\A(?:(?:grand|net|sub-?)\s*)?totals?[\s:]*\z|\A(?:(?:available|ledger|current|closing|opening|ending)\s+)?balance[\s:]*\z/i
  SUMMARY_LIKE = /\b(?:totals?|balance)\b/i
  # Header labels, most trusted first: the ledger balance counts only posted
  # transactions, as the rows do, while the available balance can be reduced
  # by holds the export does not list.
  BALANCE_LABELS = [ /\bledger\s+balance\b/i, /\bavailable\s+balance\b/i, /\b(?:current\s+)?balance\b/i ].freeze
  BALANCE_AMOUNT = /(?:\b[A-Z]{3}|S\$|\$)\s?([-+])?\s?(\d{1,3}(?:,\d{3})*\.\d{2})\b/
  MIN_HEADINGS = 2
  MIN_ROWS = 3

  def self.parse(pages)
    new(pages).parse
  end

  def initialize(pages)
    @lines = Array(pages).flat_map { |page| page.to_s.split("\n") }.map(&:strip)
  end

  def parse
    rows = []
    headings = 0
    date = nil
    balance_labels = nil
    balance = nil

    @lines.each do |text|
      next if text.empty?

      unless date || balance
        # The amounts can sit a line or two below their labels, under an
        # "As at:" caption printed beside them.
        if balance_labels && text.match?(BALANCE_AMOUNT)
          balance = header_balance(balance_labels, text)
          balance_labels = nil
        elsif !text.match?(ANY_AMOUNT) && text.match?(BALANCE_LABELS.last)
          balance_labels = text
          next
        end
      end

      if (shape = HEADING_SHAPE.match(text))
        m = HEADING.match(repaired_heading(text, shape))
        return nil unless m
        date = safe_date(m[3].to_i, Pdf::StatementParser::MONTHS.index(m[2].downcase[0, 3]) + 1, m[1].to_i)
        return nil unless date
        headings += 1
      elsif (m = ROW.match(text))
        # A row before any heading ("Today", or a date printed below its row)
        # is a layout this parser does not read.
        return nil unless date

        name = m[1].squeeze(" ").strip
        next if name.match?(SUMMARY_LABEL)
        return nil if name.match?(SUMMARY_LIKE)

        rows << { date: date, name: name, sign: m[2], amount: m[3].delete(",").to_d }
      elsif date && text.match?(ANY_AMOUNT)
        # An amount this layout cannot place: not safe to read without it.
        return nil
      elsif text.match?(HEADING_LIKE)
        return nil
      end
    end

    return nil if headings < MIN_HEADINGS || rows.size < MIN_ROWS
    signs = rows.map { |row| row[:sign] }.uniq
    return nil unless signs.include?("-") && !(signs.include?("+") && signs.include?(nil))

    dates = rows.map { |row| row[:date] }.sort
    transactions = rows.map { |row| to_transaction(row) }
    Pdf::StatementParser::Result.new(
      transactions: transactions,
      opening_balance: balance && balance - rows.sum { |row| row[:sign] == "-" ? -row[:amount] : row[:amount] },
      closing_balance: balance,
      period: { start_date: dates.first.iso8601, end_date: dates.last.iso8601 }
    )
  end

  private
    # The amount printed under the most trusted balance label. Labels and
    # amounts are paired in order; when their counts differ, only a lone
    # amount is safe to read.
    def header_balance(labels, text)
      amounts = text.scan(BALANCE_AMOUNT)
      columns = labels.to_enum(:scan, /\bbalance\b/i).map { Regexp.last_match.begin(0) }
      return if amounts.empty?
      return unless amounts.size == 1 || amounts.size == columns.size

      BALANCE_LABELS.each do |label|
        found = labels.match(label) or next
        sign, digits = amounts.size == 1 ? amounts.first : amounts[columns.index { |at| at >= found.begin(0) }]
        value = digits.delete(",").to_d
        return sign == "-" ? -value : value
      end
      nil
    end

    def repaired_heading(text, shape)
      day = shape[1].gsub(/[lio]/i, OCR_DIGITS)
      month = shape[2].gsub(/\d/, OCR_LETTERS)
      year = shape[3].gsub(/[lio]/i, OCR_DIGITS)
      "#{text[0...shape.begin(1)]}#{day} #{month} #{year}"
    end

    def to_transaction(row)
      {
        date: row[:date].iso8601,
        amount: (row[:sign] == "-" ? -row[:amount] : row[:amount]).to_f,
        name: row[:name].presence&.truncate(255) || "Statement entry",
        category: nil,
        notes: nil
      }
    end

    def safe_date(year, month, day)
      Date.new(year, month, day)
    rescue Date::Error
      nil
    end
end
