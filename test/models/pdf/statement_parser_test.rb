require "test_helper"

class Pdf::StatementParserTest < ActiveSupport::TestCase
  BANK_PAGE = <<~TEXT
                              Transaction Details as at 31 Oct 2026
    Date          Description                         Withdrawal (-)      Deposit (+)          Balance
    CURRENCY: SINGAPORE DOLLAR
                  Balance Brought Forward                                              SGD 1,000.00
    01/10/2026    Advice Funds Transfer                        17.70                            982.30
                  TOP-UP TO WALLET :
                  ALICE01
    8    02/10/2026    Advice FAST Collection                       500.00                           482.30
    o             VALUE DATE : 02/10/2026
    03/10/2026    Salary Credit                                                  2,000.00         2,482.30
    03/10/2026    Advice Funds Transfer                         3.50                          2,478.80
    03/10/2026    Advice Funds Transfer                         3.50                          2,475.30
                  Balance Carried Forward                                              SGD 2,475.30
    CURRENCY: US DOLLAR
                  Balance Brought Forward                                              USD 10.00
                  Balance Carried Forward                                              USD 10.00
  TEXT

  CARD_PAGE = <<~TEXT
    STATEMENT DATE        CREDIT LIMIT      MINIMUM PAYMENT     PAYMENT DUE DATE
    15 Jan 2027           $10,000.00        $50.00              10 Feb 2027
    DATE      DESCRIPTION                                         AMOUNT (S$)
    EVERYDAY CARD NO.: 1111 2222 3333 4444
              PREVIOUS BALANCE                                         100.00
    07 JAN   BILL PAYMENT - INTERNET                                   100.00 CR
             REF NO: 123456
    NEW TRANSACTIONS EXAMPLE HOLDER
    20 DEC   COFFEE PLACE                                                5.50
    22 DEC   WEB SERVICE SAN FRANCISCO CA                              23.77
             U. S. DOLLAR 18.00
    04 JAN   TOOL INC                                                   13.43
    04 JAN   TOOL INC                                                   13.43
    04 JAN   TOOL INC                                                   13.43 CR
             SUB-TOTAL:                                                 42.70
             TOTAL:                                                     42.70
    GRAND TOTAL FOR ALL CARD ACCOUNTS:                                  42.70
  TEXT

  test "reads a bank statement by its running balance, whatever the wording" do
    result = Pdf::StatementParser.parse([ BANK_PAGE ])

    assert_equal [ -17.7, -500.0, 2000.0, -3.5, -3.5 ], result.transactions.map { |t| t[:amount] }
    assert_equal %w[2026-10-01 2026-10-02 2026-10-03 2026-10-03 2026-10-03], result.transactions.map { |t| t[:date] }
    assert_equal "Advice Funds Transfer TOP-UP TO WALLET : ALICE01", result.transactions.first[:name]
    assert_equal "Advice FAST Collection", result.transactions.second[:name]
    assert_equal 1000, result.opening_balance
    assert_equal 2475.3, result.closing_balance.to_f
    assert_equal({ start_date: "2026-10-01", end_date: "2026-10-03" }, result.period)
  end

  test "keeps a row's detail lines across a blank line and stray margin characters" do
    page = <<~TEXT
                            Transaction Details as at 31 Oct 2026
      Date          Description                         Withdrawal (-)      Deposit (+)          Balance
                    Balance Brought Forward                                              1,000.00
      12/10/2026    Advice FAST Payment / Receipt                                  250.00         1,250.00

                    INCOMING PAYNOW REF 0812345
      B
                    FROM: EXAMPLE HOLDER
      13/10/2026    Advice FAST Payment / Receipt                  40.00                          1,210.00
                    PAYNOW TRANSFER 8001111


                    TERMS AND CONDITIONS APPLY
                    Balance Carried Forward                                              1,210.00
    TEXT

    result = Pdf::StatementParser.parse([ page ])

    assert_equal "Advice FAST Payment / Receipt INCOMING PAYNOW REF 0812345 FROM: EXAMPLE HOLDER", result.transactions.first[:name]
    # Two blank lines end a row, so trailing page text is not folded in.
    assert_equal "Advice FAST Payment / Receipt PAYNOW TRANSFER 8001111", result.transactions.second[:name]
  end

  test "a page footer after a blank line or a page number is not folded into the last row" do
    page_one = <<~TEXT
                            Transaction Details as at 31 Oct 2026
      Date          Description                         Withdrawal (-)      Deposit (+)          Balance
                    Balance Brought Forward                                              1,000.00
      05/10/2026    GRAB TRANSPORT                         10.00                               990.00

      EXAMPLE BANK LTD CO. REG. NO. 196800306E
      06/10/2026    GRAB TRANSPORT                         10.00                               980.00
      2
    TEXT
    page_two = <<~TEXT
      Statement of Account
      Account No. 027-123456-7
      Date          Description                         Withdrawal (-)      Deposit (+)          Balance
      07/10/2026    COFFEE PLACE                            4.50                               975.50
                    Balance Carried Forward                                                975.50
    TEXT

    result = Pdf::StatementParser.parse([ page_one, page_two ])

    assert_equal [ "GRAB TRANSPORT", "GRAB TRANSPORT", "COFFEE PLACE" ], result.transactions.map { |t| t[:name] }
  end

  test "a footer starting with a label word is not taken as a detail line, but a detail line on the next page is" do
    page_one = <<~TEXT
                            Transaction Details as at 31 Oct 2026
      Date          Description                         Withdrawal (-)      Deposit (+)          Balance
                    Balance Brought Forward                                              1,000.00
      05/10/2026    GRAB TRANSPORT                          10.00                               990.00

      To report a lost card, call 1800 111 1111
      06/10/2026    Advice FAST Payment                     12.00                               978.00
    TEXT
    page_two = <<~TEXT
                    TO: EXAMPLE PAYEE
      Date          Description                         Withdrawal (-)      Deposit (+)          Balance
                    Balance Carried Forward                                                978.00
    TEXT

    result = Pdf::StatementParser.parse([ page_one, page_two ])

    assert_equal [ "GRAB TRANSPORT", "Advice FAST Payment TO: EXAMPLE PAYEE" ], result.transactions.map { |t| t[:name] }
  end

  test "reads a credit card statement with CR credits and dates without a year" do
    result = Pdf::StatementParser.parse([ CARD_PAGE ], liability: true)

    assert_equal [ 100.0, -5.5, -23.77, -13.43, -13.43, 13.43 ], result.transactions.map { |t| t[:amount] }
    assert_equal %w[2027-01-07 2026-12-20 2026-12-22 2027-01-04 2027-01-04 2027-01-04], result.transactions.map { |t| t[:date] }
    assert_equal "BILL PAYMENT - INTERNET REF NO: 123456", result.transactions.first[:name]
    assert_equal 100, result.opening_balance
    assert_equal 42.7, result.closing_balance.to_f
  end

  test "gives up when the rows do not add up to the closing balance" do
    page = CARD_PAGE.sub("GRAND TOTAL FOR ALL CARD ACCOUNTS:                                  42.70",
                         "GRAND TOTAL FOR ALL CARD ACCOUNTS:                                  99.99")

    assert_nil Pdf::StatementParser.parse([ page ], liability: true)
  end

  test "gives up when a row contradicts the running balance and the totals" do
    page = BANK_PAGE.sub("500.00      ", "50.00       ")

    assert_nil Pdf::StatementParser.parse([ page ])
  end

  test "gives up on text that is not a statement" do
    assert_nil Pdf::StatementParser.parse([ "Page 1 of 17" ])
    assert_nil Pdf::StatementParser.parse([ "" ])
  end

  test "reads month-first dates when the statement uses them" do
    page = <<~TEXT
      Date         Description               Amount       Balance
                   Opening balance                         500.00
      10/13/2026   Grocery                  -20.00        480.00
      10/14/2026   Refund                    5.00         485.00
      10/15/2026   Fuel                     -40.00        445.00
                   Closing balance                         445.00
    TEXT

    result = Pdf::StatementParser.parse([ page ])

    assert_equal %w[2026-10-13 2026-10-14 2026-10-15], result.transactions.map { |t| t[:date] }
    assert_equal [ -20.0, 5.0, -40.0 ], result.transactions.map { |t| t[:amount] }
  end

  test "gives up when rows are missing before a brought-forward balance" do
    salary = "03/10/2026    Salary Credit                                                  2,000.00         2,482.30\n"
    assert_includes BANK_PAGE, salary
    page = BANK_PAGE.sub(salary, "              Balance Brought Forward                                              SGD 2,482.30\n")

    assert_nil Pdf::StatementParser.parse([ page ])
  end

  test "gives up when the last rows are missing before the closing balance" do
    last_row = "03/10/2026    Advice Funds Transfer                         3.50                          2,475.30\n"
    assert_includes BANK_PAGE, last_row

    assert_nil Pdf::StatementParser.parse([ BANK_PAGE.sub(last_row, "") ])
  end

  test "does not take a column total for the closing balance" do
    page = <<~TEXT
      Date         Description               Amount       Balance
                   Opening balance                       1,000.00
      01/10/2026   Rent                     -700.00        300.00
      02/10/2026   Salary                  1,150.00      1,450.00
                   Total                      700.00      1,150.00
    TEXT

    assert_nil Pdf::StatementParser.parse([ page ])
  end

  test "settles dates that fit either day order from the statement date" do
    page = <<~TEXT
      Statement date: 15 Dec 2026
      Date         Description               Amount       Balance
                   Opening balance                         500.00
      11/02/2026   Grocery                  -20.00        480.00
      12/10/2026   Late refund               5.00         485.00
      11/09/2026   Fuel                     -40.00        445.00
                   Closing balance                         445.00
    TEXT

    result = Pdf::StatementParser.parse([ page ])

    assert_equal %w[2026-11-02 2026-12-10 2026-11-09], result.transactions.map { |t| t[:date] }
  end

  test "gives up on dates that fit either day order when nothing settles them" do
    page = <<~TEXT
      Date         Description               Amount       Balance
                   Opening balance                         500.00
      01/11/2026   Grocery                  -20.00        480.00
      12/10/2026   Late refund               5.00         485.00
      12/11/2026   Fuel                     -40.00        445.00
                   Closing balance                         445.00
    TEXT

    assert_nil Pdf::StatementParser.parse([ page ])
  end

  test "gives up when either day order would read the rows in sequence" do
    page = <<~TEXT
      Date         Description               Amount       Balance
                   Opening balance                         500.00
      03/04/2026   Grocery                  -20.00        480.00
      03/05/2026   Refund                    5.00         485.00
                   Closing balance                         485.00
    TEXT

    assert_nil Pdf::StatementParser.parse([ page ])
  end

  test "anchors dates without a year to the statement date, not a later promotion date" do
    page = CARD_PAGE.sub("DATE      DESCRIPTION", "PROMOTION ENDS 31 Dec 2027\nDATE      DESCRIPTION")

    result = Pdf::StatementParser.parse([ page ], liability: true)

    assert_equal %w[2027-01-07 2026-12-20 2026-12-22 2027-01-04 2027-01-04 2027-01-04], result.transactions.map { |t| t[:date] }
  end

  test "keeps four digits after a yearless date in the description, not as the year" do
    page = <<~TEXT
      STATEMENT DATE 15 Oct 2024
                PREVIOUS BALANCE                      100.00
      07 OCT    7011 SHELL STATION                     45.00
      09 OCT    GROCER MART                             5.00
      GRAND TOTAL FOR ALL CARD ACCOUNTS:              150.00
    TEXT

    result = Pdf::StatementParser.parse([ page ], liability: true)

    assert_equal %w[2024-10-07 2024-10-09], result.transactions.map { |t| t[:date] }
    assert_equal "7011 SHELL STATION", result.transactions.first[:name]
  end

  test "does not let a balance change that matches by chance overrule the amount's column" do
    page = <<~TEXT
      Date      Description                 Withdrawals      Deposits       Balance
                Opening balance                                            1,000.00
      02 OCT 2026  ATM                          100.00
      02 OCT 2026  DEPOSIT                                      50.00          950.00
      05 OCT 2026  TRANSFER IN                                 100.00
      05 OCT 2026  CARD PURCHASE                 50.00                        1,000.00
      07 OCT 2026  COFFEE                        10.00                          990.00
                Closing balance                                              990.00
    TEXT

    result = Pdf::StatementParser.parse([ page ])

    assert_equal [ -100.0, 50.0, 100.0, -50.0, -10.0 ], result.transactions.map { |t| t[:amount] }
  end
end
