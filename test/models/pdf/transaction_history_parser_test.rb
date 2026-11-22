require "test_helper"

class Pdf::TransactionHistoryParserTest < ActiveSupport::TestCase
  # Laid out the way sure-ocr prints a banking app's history export.
  PAGE_ONE = <<~TEXT
    Transaction History                                               Page 1 of 2
    Available Balance          Ledger Balance                         As at:
    SGD 1,234.56               SGD 1,234.56                           16 Nov 2026
    Yesterday, 15 Nov 2026
    TRF TOP-UP TO WALLET : alice01 REF000111                          SGD - 12.30
    Advice • ADV
    COFFEE PLACE                                                      SGD - 4.50
    Card • VISA
    Thursday, 13 Nov 2026
    SALARY EXAMPLE CO                                                 SGD 2,500.00
    Credit • GIRO
  TEXT

  PAGE_TWO = <<~TEXT
    Transaction History                                               Page 2 of 2
    ICT PayNow Transfer To: BOB                                       SGD - 1,000.00
    Advice • ADV
    8 0ct 2026
    Interest Earned                                                   SGD 0.12
  TEXT

  test "reads rows under their date headings, across pages" do
    result = Pdf::TransactionHistoryParser.parse([ PAGE_ONE, PAGE_TWO ])

    assert_equal [ -12.3, -4.5, 2500.0, -1000.0, 0.12 ], result.transactions.map { |t| t[:amount] }
    assert_equal %w[2026-11-15 2026-11-15 2026-11-13 2026-11-13 2026-10-08], result.transactions.map { |t| t[:date] }
    assert_equal "TRF TOP-UP TO WALLET : alice01 REF000111", result.transactions.first[:name]
    assert_equal({ start_date: "2026-10-08", end_date: "2026-11-15" }, result.period)
  end

  test "reads the header balance as the closing balance and works back to the opening" do
    result = Pdf::TransactionHistoryParser.parse([ PAGE_ONE, PAGE_TWO ])

    assert_equal BigDecimal("1234.56"), result.closing_balance
    assert_equal BigDecimal("-248.76"), result.opening_balance
  end

  test "reads header amounts printed below a caption" do
    page = PAGE_ONE.sub("Ledger Balance                         As at:\n", "Ledger Balance\n                                                      As at:\n")

    assert_equal BigDecimal("1234.56"), Pdf::TransactionHistoryParser.parse([ page, PAGE_TWO ]).closing_balance
  end

  test "prefers the ledger balance to the available balance" do
    page = PAGE_ONE.sub("SGD 1,234.56               SGD 1,234.56", "SGD 1,200.00               SGD 1,234.56")

    assert_equal BigDecimal("1234.56"), Pdf::TransactionHistoryParser.parse([ page, PAGE_TWO ]).closing_balance
  end

  test "reads an overdrawn header balance" do
    page = PAGE_ONE.sub("SGD 1,234.56               SGD 1,234.56", "SGD - 20.00                SGD - 20.00")

    assert_equal BigDecimal("-20"), Pdf::TransactionHistoryParser.parse([ page, PAGE_TWO ]).closing_balance
  end

  test "leaves the balances out when the header prints none" do
    page = PAGE_ONE.lines.reject { |line| line.include?("Balance") || line.start_with?("SGD 1,234.56") }.join
    result = Pdf::TransactionHistoryParser.parse([ page, PAGE_TWO ])

    assert_equal 5, result.transactions.size
    assert_nil result.closing_balance
    assert_nil result.opening_balance
  end

  test "gives up when a date heading cannot be read" do
    page = PAGE_TWO.sub("8 0ct 2026", "8 Xyz 2026")

    assert_nil Pdf::TransactionHistoryParser.parse([ PAGE_ONE, page ])
  end

  test "gives up when an amount does not fit the row layout" do
    page = PAGE_TWO.sub("SGD 0.12", "0.12 SGD")

    assert_nil Pdf::TransactionHistoryParser.parse([ PAGE_ONE, page ])
  end

  test "gives up when money in is shown both with and without a plus sign" do
    page = PAGE_TWO.sub("SGD 0.12", "SGD + 0.12")

    assert_nil Pdf::TransactionHistoryParser.parse([ PAGE_ONE, page ])
  end

  test "gives up on statements and text without dated rows" do
    assert_nil Pdf::TransactionHistoryParser.parse([ Pdf::StatementParserTest::BANK_PAGE ])
    assert_nil Pdf::TransactionHistoryParser.parse([ "Page 1 of 17" ])
  end

  test "skips totals and balances printed among the rows" do
    [ "Total", "Totals", "Net total", "Sub-total:", "Balance", "Ledger balance", "Ending balance" ].each do |label|
      page = PAGE_TWO + "#{label.ljust(66)}SGD - 1,000.00\n"

      result = Pdf::TransactionHistoryParser.parse([ PAGE_ONE, page ])

      assert_equal [ -12.3, -4.5, 2500.0, -1000.0, 0.12 ], result.transactions.map { |t| t[:amount] }, label
    end
  end

  test "gives up on a row that may be a total or may be a merchant" do
    [ "Total spent", "Total (3 items)", "Balance due", "TOTAL ENERGIES STATION", "Monthly total", "Account balance", "Totals for Nov" ].each do |name|
      page = PAGE_TWO + "#{name.ljust(66)}SGD - 60.00\n"

      assert_nil Pdf::TransactionHistoryParser.parse([ PAGE_ONE, page ]), name
    end
  end

  test "repairs OCR misreads in a heading's day, month and year" do
    [ "l3 Nov 2026", "13 Nov 2O26", "13 N0v 2026", "Thursday. 13 Nov 2026" ].each do |heading|
      page = PAGE_ONE.sub("Thursday, 13 Nov 2026", heading)

      result = Pdf::TransactionHistoryParser.parse([ page, PAGE_TWO ])

      assert_equal "2026-11-13", result.transactions.third[:date], heading
    end
  end

  test "gives up on a heading it cannot read, rows before any heading, or an amount without cents" do
    unreadable = PAGE_ONE.sub("Thursday, 13 Nov 2026", "13Nov 2026")
    today = PAGE_ONE.sub("Yesterday, 15 Nov 2026", "Today")
    no_cents = PAGE_TWO + "Parking#{" " * 59}SGD - 2\n"

    assert_nil Pdf::TransactionHistoryParser.parse([ unreadable, PAGE_TWO ])
    assert_nil Pdf::TransactionHistoryParser.parse([ today, PAGE_TWO ])
    assert_nil Pdf::TransactionHistoryParser.parse([ PAGE_ONE, no_cents ])
  end

  test "reads month separators between rows as page furniture" do
    page = PAGE_TWO.sub("8 0ct 2026", "October 2026\n8 0ct 2026")

    assert_equal 5, Pdf::TransactionHistoryParser.parse([ PAGE_ONE, page ]).transactions.size
  end
end
