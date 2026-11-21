# Reads transactions from the text of a bank or credit card statement without
# an LLM. Statements print one transaction per line (date, description,
# amount, often a running balance), which rules read exactly and quickly where
# a small local model is slow and can loop on runs of identical rows.
#
# The result counts only when it reconciles: every running balance agrees with
# its row and the last one with the closing balance, or opening balance plus
# the rows equals the closing balance. Dates must also be unambiguous. Any
# other result returns nil and the caller falls back to LLM extraction.
#
# Amounts follow the extractor convention: negative for money out of a bank
# account or a charge on a card, positive for money in or a card credit.
class Pdf::StatementParser
  MONTHS = %w[jan feb mar apr may jun jul aug sep oct nov dec].freeze
  MONTH = "(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\\.?"
  NUMERIC_DATE = %r{\A(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{4}|\d{2})(?!\d)}
  ISO_DATE = %r{\A(\d{4})-(\d{2})-(\d{2})(?!\d)}
  NAMED_DATE = /\A(\d{1,2})[ \-]#{MONTH}(?:[ \-,]+(\d{4}))?(?![a-z\d])/i
  FULL_NAMED_DATE = /\b(\d{1,2}) #{MONTH},? (\d{4})\b/i
  MONEY = /\(?-?(?:[$€£₹]|S\$|RM)?\s?\d{1,3}(?:,\d{3})*\.\d{2}\)?(?:\s?(?:CR|DR)\b|-)?/i
  TRAILING_AMOUNTS = /(?:\s{2,}|\s(?=\S*\d\.\d{2}))(#{MONEY})(?:\s+(#{MONEY}))?\s*\z/i

  OPENING = /previous\s+balance|balance\s+brought\s+forward|opening\s+balance|balance\s+b\/?f\b|balance\s+from\s+previous/i
  CLOSING_PATTERNS = [
    /grand\s+total|total\s+outstanding|new\s+balance|statement\s+balance|closing\s+balance/i,
    /balance\s+carried\s+forward|balance\s+c\/?f\b/i,
    /\Atotal\b/i
  ].freeze
  SECTION_TOTAL = /\A(?:sub-?\s?total|total)\b/i
  DEBIT_HEADER = /withdrawals?|debits?|paid\s+out|money\s+out/i
  CREDIT_HEADER = /deposits?|credits?|paid\s+in|money\s+in/i
  CURRENCY_HEADER = /\Acurrency\s*:/i
  NOT_DESCRIPTION = /\Apage\s+\d|\d+\s+of\s+\d+\z|\Avalue\s+date|\APDS_|carried\s+forward|brought\s+forward|\Atotal|sub-?total|currency\s*:|new\s+transactions|card\s+no/i

  Result = Data.define(:transactions, :opening_balance, :closing_balance, :period)

  # A statement covers about a month; rows without a year must fall within
  # this many days before the header date they are anchored to.
  YEARLESS_WINDOW = 75

  # pages: the text of each page, as pdf-reader lays it out.
  # liability: true for a credit card statement (no running balance; a "CR"
  # suffix or a minus sign marks a payment or refund).
  def self.parse(pages, liability: false)
    new(pages, liability: liability).parse
  end

  def initialize(pages, liability: false)
    @lines = Array(pages).flat_map { |page| page.to_s.split("\n") }
    @liability = liability
  end

  # Tries every reading the text allows (day order when no date settles it,
  # each header date as the year anchor) and returns a result only when the
  # readings that pass all agree.
  def parse
    orders = detect_date_orders
    ambiguous_order = orders.size > 1
    anchors = detect_anchor_dates.presence || [ nil ]
    # Every reading that reconciles is kept, so two that disagree (day-first
    # and month-first with nothing to tell them apart) leave no answer.
    results = orders.product(anchors).filter_map do |order, anchor|
      attempt(order, anchor, ambiguous_order: ambiguous_order)
    end.uniq
    results.one? ? results.first : nil
  end

  private
    attr_reader :lines, :liability

    def attempt(order, anchor, ambiguous_order:)
      @order = order
      @anchor = anchor
      @yearless_dates = []
      rows = read_rows
      return nil if rows.empty? || rows.size < 2 && @opening.nil?
      return nil if @sections_with_rows > 1

      resolve_directions(rows)
      return nil unless rows.all? { |row| row[:direction] }
      return nil unless reconciled?(rows)
      return nil unless @yearless_dates.all? { |date| date.between?(anchor - YEARLESS_WINDOW, anchor) }
      # Day-first and month-first readings both parse. A statement's rows fall
      # shortly before the date in its header, so a reading that puts them
      # elsewhere is not the statement's.
      return nil if ambiguous_order && anchor && rows.any? { |row| !row[:date].between?(anchor - YEARLESS_WINDOW, anchor) }

      dates = rows.map { |row| row[:date] }.sort
      Result.new(
        transactions: rows.map { |row| to_transaction(row) },
        opening_balance: @opening,
        closing_balance: @closing || rows.last[:balance],
        period: { start_date: dates.first.iso8601, end_date: dates.last.iso8601 }
      )
    end

    def read_rows
      rows = []
      current = nil
      continuation = 0
      columns = nil
      closing_rank = nil
      @opening = nil
      @closing = nil
      @sections_with_rows = 0
      section_has_rows = false
      closing_frozen = false

      lines.each do |raw|
        line = strip_margin(raw)
        text = line.strip
        next current = nil if text.empty?

        if text.match?(CURRENCY_HEADER)
          # Balances of a later currency section must not replace this one's.
          closing_frozen ||= section_has_rows
          @sections_with_rows += 1 if section_has_rows
          section_has_rows = false
          current = nil
          next
        end

        if (header = header_columns(line))
          columns = header
          current = nil
          next
        end

        date, rest = leading_date(text)
        amounts = trailing_amounts(text)

        if date.nil? && amounts.any?
          value = signed_balance(amounts.last)
          if text.match?(OPENING)
            @opening ||= value
            # A page's brought-forward balance; a later currency section's
            # opening belongs to rows this parser does not read.
            rows << { reset: value } if rows.any? && !closing_frozen
          elsif !closing_frozen && (rank = CLOSING_PATTERNS.index { |pattern| text.match?(pattern) }) && (closing_rank.nil? || rank <= closing_rank)
            closing_rank = rank
            @closing = signed_balance(amounts.last)
          end
          current = nil
          next
        end

        if date && amounts.any? && !text.match?(SECTION_TOTAL) && !rest.match?(OPENING)
          description = description_from(rest, amounts)
          amount, balance = amounts.size >= 2 ? [ amounts[0], amounts[1] ] : [ amounts[0], nil ]
          current = {
            date: date,
            name: description,
            notes: [],
            amount: amount[:value],
            marker: amount[:marker],
            column: columns && nearest_column(columns, line, amount[:text]),
            balance: balance && signed_balance(balance)
          }
          rows << current
          section_has_rows = true
          continuation = 0
          next
        end

        if current && date.nil? && amounts.empty? && continuation < 3 && text.length.between?(3, 100) && !text.match?(NOT_DESCRIPTION)
          current[:notes] << text.squeeze(" ")
          continuation += 1
        else
          current = nil
        end
      end

      @sections_with_rows += 1 if section_has_rows
      rows
    end

    # DBS-style statements print rotated margin text, which pdf-reader places
    # as a stray character before the real line.
    def strip_margin(line)
      line.sub(/\A\s*\S\s{2,}(?=\S)/, "")
    end

    def leading_date(text)
      if (m = ISO_DATE.match(text))
        date = safe_date(m[1].to_i, m[2].to_i, m[3].to_i)
      elsif (m = NUMERIC_DATE.match(text))
        a, b = m[1].to_i, m[2].to_i
        day, month = @order == :mdy ? [ b, a ] : [ a, b ]
        date = safe_date(full_year(m[3]), month, day)
      elsif (m = NAMED_DATE.match(text))
        month = month_number(m[2])
        if m[3] && plausible_year?(m[3].to_i)
          date = safe_date(m[3].to_i, month, m[1].to_i)
        else
          # "07 OCT 7011 SHELL": four digits after a yearless date are the
          # description's (a store number), not a year.
          date = yearless_date(month, m[1].to_i)
          return [ date, text[m.begin(3)..].to_s ] if date && m[3]
        end
      end
      return [ nil, text ] unless date

      [ date, text[m[0].length..].to_s ]
    end

    # A year a statement row can carry: recent, and not after the header date
    # this reading is anchored to.
    def plausible_year?(year)
      return false unless year.between?(Date.current.year - 30, Date.current.year + 1)

      @anchor.nil? || year <= @anchor.year
    end

    def trailing_amounts(text)
      match = TRAILING_AMOUNTS.match(text)
      return [] unless match

      [ match[1], match[2] ].compact.map { |token| parse_money(token).merge(text: token) }
    end

    def parse_money(token)
      t = token.strip
      marker =
        if t.match?(/CR\z/i) then :cr
        elsif t.match?(/DR\z/i) then :dr
        elsif t.start_with?("-", "(") || t.end_with?("-") then :minus
        end
      { value: t.scan(/\d[\d,]*\.\d{2}/).first.delete(",").to_d, marker: marker }
    end

    def signed_balance(amount)
      negative = liability ? amount[:marker].in?([ :cr, :minus ]) : amount[:marker].in?([ :dr, :minus ])
      negative ? -amount[:value] : amount[:value]
    end

    def description_from(rest, amounts)
      text = rest.dup
      amounts.reverse_each do |amount|
        index = text.rindex(amount[:text])
        text = text[0...index] if index
      end
      # A value-date column straight after the transaction date.
      value_date, after = leading_date(text.strip)
      text = after if value_date
      text.strip.squeeze(" ")
    end

    def header_columns(line)
      return nil if leading_date(line.strip).first
      return nil unless line.match?(DEBIT_HEADER) && line.match?(CREDIT_HEADER)

      debit = line =~ DEBIT_HEADER
      debit_end = debit + Regexp.last_match[0].length
      credit = line =~ CREDIT_HEADER
      credit_end = credit + Regexp.last_match[0].length
      { debit: debit_end, credit: credit_end }
    end

    def nearest_column(columns, line, token)
      index = line.rindex(token.strip)
      return nil unless index

      right = index + token.strip.length
      columns.min_by { |_, column_end| (column_end - right).abs }.first
    end

    # Running balance first, then the column the amount sits in, then a
    # CR/DR or minus marker. A card statement without markers is a charge.
    def resolve_directions(rows)
      previous = @opening
      @resets_consistent = true
      rows.each do |row|
        if row.key?(:reset)
          # A brought-forward balance that differs from the last one printed
          # means rows between them were not read.
          @resets_consistent = false if previous && (row[:reset] - previous).abs >= 0.005
          previous = row[:reset]
          next
        end

        # The column the amount sits in, or a CR/DR or minus marker on it.
        printed = { credit: :in, debit: :out }[row[:column]] || (marker_direction(row[:marker]) if row[:marker])
        if row[:balance] && previous
          delta = row[:balance] - previous
          if (delta.abs - row[:amount]).abs < 0.005
            rises_with_inflow = !liability
            from_balance = (delta.positive? == rises_with_inflow) ? :in : :out
            # A balance change that only happens to equal the amount (a day's
            # balance after an unbalanced row) must not override what the
            # row itself prints.
            if printed.nil? || printed == from_balance
              row[:direction] = from_balance
              row[:checked] = true
            end
          end
        end
        row[:direction] ||= printed
        row[:direction] ||= marker_direction(row[:marker])
        previous = row[:balance] if row[:balance]
      end
      rows.reject! { |row| row.key?(:reset) }
    end

    def marker_direction(marker)
      if liability
        marker.in?([ :cr, :minus ]) ? :in : :out
      else
        { cr: :in, dr: :out, minus: :out }[marker]
      end
    end

    def reconciled?(rows)
      return false if @closing.nil?

      # Every row agrees with its running balance, nothing was skipped at a
      # page break, and nothing was skipped after the last row read.
      if rows.all? { |row| row[:checked] }
        return @resets_consistent && (rows.last[:balance] - @closing).abs < 0.005
      end
      return false if @opening.nil?

      net = rows.sum { |row| row[:direction] == :in ? row[:amount] : -row[:amount] }
      expected = liability ? @opening - net : @opening + net
      (expected - @closing).abs < 0.005
    end

    def to_transaction(row)
      # Wrapped lines usually carry the payee ("TOP-UP TO PAYLAH! : JACK123").
      name = [ row[:name], *row[:notes] ].compact_blank.join(" ").squeeze(" ").truncate(255)
      {
        date: row[:date].iso8601,
        amount: (row[:direction] == :in ? row[:amount] : -row[:amount]).to_f,
        name: name.presence || "Statement entry",
        category: nil,
        notes: nil
      }
    end

    # The day orders the numeric dates allow: one when a day above 12 settles
    # it, both when every date reads either way.
    def detect_date_orders
      numeric = dmy = mdy = 0
      lines.each do |line|
        m = NUMERIC_DATE.match(strip_margin(line).strip) or next
        numeric += 1
        dmy += 1 if m[1].to_i > 12
        mdy += 1 if m[2].to_i > 12
      end
      return %i[dmy mdy] if numeric.positive? && dmy.zero? && mdy.zero?

      mdy > dmy ? [ :mdy ] : [ :dmy ]
    end

    # Rows like "07 OCT" carry no year. A full date in the header (statement
    # date, payment due date) anchors them: a month after it belongs to the
    # previous year. Each one is tried, since the header can also print an
    # unrelated date.
    def detect_anchor_dates
      header = lines.first(60).join("\n")
      header.scan(FULL_NAMED_DATE).filter_map { |day, month, year| safe_date(year.to_i, month_number(month), day.to_i) }.uniq.sort
    end

    def yearless_date(month, day)
      return nil unless @anchor

      date = safe_date(@anchor.year, month, day)
      date = safe_date(@anchor.year - 1, month, day) if date && date > @anchor
      @yearless_dates << date if date
      date
    end

    def month_number(name)
      MONTHS.index(name.to_s.downcase[0, 3]) + 1
    end

    def full_year(year)
      year.to_s.length == 2 ? 2000 + year.to_i : year.to_i
    end

    def safe_date(year, month, day)
      Date.new(year, month, day)
    rescue Date::Error, TypeError
      nil
    end
end
