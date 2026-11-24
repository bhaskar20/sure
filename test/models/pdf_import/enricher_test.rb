require "test_helper"

class PdfImport::EnricherTest < ActiveSupport::TestCase
  HISTORY_TEXT = <<~TEXT
    DBS Multiplier Account                 271-142964-0
    Available Balance       Ledger Balance        Transactions as of:
    SGD 1,234.56            SGD 1,234.56          16 Nov 2026
    Saturday, 15 Nov 2026
    TRF TOP-UP TO PAYLAH! : 93415445 TF584861794742962660        SGD - 12.00
    Thursday, 13 Nov 2026
    SALARY EXAMPLE CO GIRO 000123                                SGD 2,500.00
  TEXT

  setup do
    @account = accounts(:depository)
    @family = @account.family
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: nil,
      file: uploaded_file(
        filename: "statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )
    statement.update_columns(account_last4_hint: nil, sanitized_parser_output: {})
    @import = PdfImport.create_from_statement!(statement: statement.reload)
    @import.update!(document_type: "bank_statement", account: nil)
    Pdf::TextExtractor.stubs(:pages).returns([ HISTORY_TEXT ])
    @provider = mock
  end

  test "fills the statement's details the document prints and works the opening balance back from the rows" do
    answers(fill_statement_gaps: {
      "currency" => "S$", "institution_name" => "DBS", "account_name" => "Multiplier Account",
      "account_last4" => "9640", "account_subtype" => "savings", "closing_balance" => 1234.56, "opening_balance" => nil
    })
    data = enrich(rows: [ -12.0, 2500.0 ])

    assert_equal "SGD", data["currency"]
    assert_equal "DBS", data["bank_name"]
    assert_equal "9640", data["account_number"]
    assert_equal "Multiplier Account", data.dig("account_details", "account_name")
    assert_equal "savings", data.dig("account_details", "subtype")
    assert_equal 1234.56, data["closing_balance"]
    assert_equal(-1253.44, data["opening_balance"])
    assert_includes data["ai_filled"], "closing_balance"
  end

  test "drops figures and digits the document does not print, and values Sure cannot use" do
    answers(fill_statement_gaps: {
      "currency" => "XYZ", "account_last4" => "9999", "account_subtype" => "brokerage", "closing_balance" => 5000.0
    })
    data = enrich(rows: [ -12.0, 2500.0 ])

    assert_nil data["currency"]
    assert_nil data["account_number"]
    assert_nil data["closing_balance"]
    assert_nil data["opening_balance"]
    assert_nil data.dig("account_details", "subtype")
  end

  test "replaces a read balance that disagrees with the rows by one worked out from the known balance" do
    answers(fill_statement_gaps: { "closing_balance" => 1234.56 })
    data = enrich(rows: [ -12.0, 2500.0 ], opening_balance: 100.0)

    assert_equal 100.0, data["opening_balance"]
    assert_equal 2588.0, data["closing_balance"]
  end

  test "never asks for what the rules already read" do
    @provider.expects(:structured_json).with { |args| args[:operation] == "fill_statement_gaps" && (args[:schema][:properties].keys & %w[opening_balance closing_balance]).empty? }
      .returns(response({}))
    @provider.stubs(:structured_json).with { |args| args[:operation] == "clean_transaction_names" }.returns(response({ "names" => [] }))

    enrich(rows: [ -12.0 ], opening_balance: 10.0, closing_balance: -2.0)
  end

  test "reads card terms and treats card balances as the amount owed" do
    @import.update!(document_type: "credit_card_statement")
    answers(fill_statement_gaps: {
      "available_credit" => 1234.56, "minimum_payment" => 12.0, "apr" => 99.5, "payment_due_date" => "#{Date.current.year}-#{Date.current.month.to_s.rjust(2, "0")}-15",
      "closing_balance" => 2500.0
    })
    data = enrich(rows: [ -12.0, 2500.0 ])

    assert_equal 1234.56, data.dig("account_details", "available_credit")
    assert_equal 12.0, data.dig("account_details", "minimum_payment")
    assert_nil data.dig("account_details", "apr"), "99.5 is not printed"
    assert_equal 15, data.dig("account_details", "due_day")
    assert_equal 2500.0, data["closing_balance"]
    assert_equal 4988.0, data["opening_balance"], "money in lowers what is owed"
  end

  test "gives each transaction a readable name and keeps the bank's text in its notes" do
    answers(fill_statement_gaps: {}, clean_transaction_names: { "names" => [
      { "i" => 0, "name" => "PayLah! top-up" }, { "i" => 1, "name" => "Salary from Example Co" }, { "i" => 7, "name" => "Out of range" }
    ] })
    data = enrich(rows: [ -12.0, 2500.0 ])

    assert_equal [ "PayLah! top-up", "Salary from Example Co" ], data["transactions"].map { |row| row["name"] }
    assert_equal "row 0", data["transactions"].first["notes"]
    assert_equal [ "row 0", "row 1" ], data["transactions"].map { |row| row["original_name"] }
    assert_includes data["ai_filled"], "transaction_names"
  end

  test "keeps the bank's text ahead of a reference already in the notes" do
    answers(fill_statement_gaps: {}, clean_transaction_names: { "names" => [ { "i" => 0, "name" => "Transfer to savings" } ] })
    transactions = [ { "date" => "2026-11-10", "amount" => -50.0, "name" => "FUND TRANSFER TO A/C XX4821 SELF", "notes" => "TF58123" } ]
    data = PdfImport::Enricher.new(@import, provider: @provider).enrich({ "transactions" => transactions })

    row = data["transactions"].sole
    assert_equal [ "Transfer to savings", "FUND TRANSFER TO A/C XX4821 SELF", "FUND TRANSFER TO A/C XX4821 SELF TF58123" ],
      row.values_at("name", "original_name", "notes")
  end

  test "keeps what extraction found when the model fails" do
    @provider.stubs(:structured_json).returns(Provider::Response.new(success?: false, data: nil, error: Provider::Error.new("offline")))
    data = enrich(rows: [ -12.0 ], closing_balance: 5.0)

    assert_equal [ "row 0" ], data["transactions"].map { |row| row["name"] }
    assert_equal 5.0, data["closing_balance"]
    assert_nil data["ai_filled"]
  end

  private
    def enrich(rows:, **known)
      transactions = rows.each_with_index.map { |amount, i| { "date" => "2026-11-1#{i}", "amount" => amount, "name" => "row #{i}" } }
      data = { "transactions" => transactions, "period" => { "start_date" => "2026-11-10", "end_date" => "2026-11-15" } }
      known.each { |key, value| data[key.to_s] = value }
      PdfImport::Enricher.new(@import, provider: @provider).enrich(data)
    end

    def answers(**by_operation)
      by_operation[:clean_transaction_names] ||= { "names" => [] }
      by_operation.each do |operation, answer|
        @provider.stubs(:structured_json).with { |args| args[:operation] == operation.to_s }.returns(response(answer))
      end
    end

    def response(data)
      Provider::Response.new(success?: true, data: data, error: nil)
    end
end
