require "test_helper"

class Provider::Openai::BankStatementExtractorTest < ActiveSupport::TestCase
  setup do
    @client = mock("openai_client")
    @model = "gpt-4.1"
  end

  test "extracts transactions from PDF content" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "Test Bank",
            "account_holder" => "John Doe",
            "account_number" => "1234",
            "statement_period" => {
              "start_date" => "2024-01-01",
              "end_date" => "2024-01-31"
            },
            "opening_balance" => 5000.00,
            "closing_balance" => 4500.00,
            "transactions" => [
              { "date" => "2024-01-15", "description" => "Coffee Shop", "amount" => -5.50 },
              { "date" => "2024-01-20", "description" => "Salary Deposit", "amount" => 3000.00 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    # Mock the PDF text extraction
    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 bank statement text" ])

    result = extractor.extract

    assert_equal "Test Bank", result[:bank_name]
    assert_equal "John Doe", result[:account_holder]
    assert_equal "1234", result[:account_number]
    assert_equal 5000.00, result[:opening_balance]
    assert_equal 4500.00, result[:closing_balance]
    assert_equal 2, result[:transactions].size

    first_txn = result[:transactions].first
    assert_equal "2024-01-15", first_txn[:date]
    assert_equal "Coffee Shop", first_txn[:name]
    assert_equal(-5.50, first_txn[:amount])
  end

  test "handles empty PDF content" do
    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "",
      model: @model
    )

    assert_raises(Provider::Openai::Error) do
      extractor.extract
    end
  end

  test "handles nil PDF content" do
    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: nil,
      model: @model
    )

    assert_raises(Provider::Openai::Error) do
      extractor.extract
    end
  end

  test "deduplicates transactions across chunk boundaries" do
    # First chunk response
    first_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "Test Bank",
            "account_holder" => "John Doe",
            "account_number" => "1234",
            "statement_period" => { "start_date" => "2024-01-01", "end_date" => "2024-01-31" },
            "opening_balance" => 5000.00,
            "closing_balance" => 4500.00,
            "transactions" => [
              { "date" => "2024-01-15", "description" => "Coffee Shop", "amount" => -5.50 },
              { "date" => "2024-01-16", "description" => "Grocery Store", "amount" => -50.00 }
            ]
          }.to_json
        }
      } ]
    }

    # Second chunk response with duplicate at boundary
    second_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "transactions" => [
              { "date" => "2024-01-16", "description" => "Grocery Store", "amount" => -50.00 },
              { "date" => "2024-01-17", "description" => "Gas Station", "amount" => -40.00 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).twice.returns(first_response, second_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    # Mock multiple pages that will create multiple chunks
    extractor.stubs(:extract_pages_from_pdf).returns([
      "Page 1 " * 500,  # ~3500 chars, first chunk
      "Page 2 " * 500   # ~3500 chars, second chunk
    ])

    result = extractor.extract

    # Should deduplicate the "Grocery Store" transaction at chunk boundary
    assert_equal 3, result[:transactions].size
    names = result[:transactions].map { |t| t[:name] }
    assert_includes names, "Coffee Shop"
    assert_includes names, "Grocery Store"
    assert_includes names, "Gas Station"
  end

  test "keeps identical transactions within one chunk" do
    @client.expects(:chat).returns(chat_response(content: {
      "transactions" => [
        { "date" => "2024-01-22", "description" => "Funds Transfer", "amount" => -3.50 },
        { "date" => "2024-01-22", "description" => "Funds Transfer", "amount" => -3.50 }
      ]
    }.to_json))

    result = build_extractor.extract

    assert_equal [ -3.50, -3.50 ], result[:transactions].map { |t| t[:amount] }
  end

  test "flips a sign the running balance contradicts on a bank statement" do
    @client.expects(:chat).returns(chat_response(content: {
      "opening_balance" => 1000.00,
      "transactions" => [
        { "date" => "2024-01-02", "description" => "Top-up", "amount" => -10.00, "balance" => 990.00 },
        { "date" => "2024-01-03", "description" => "Salary", "amount" => 500.00, "balance" => 1490.00 },
        { "date" => "2024-01-04", "description" => "FAST Collection", "amount" => 400.00, "balance" => 1090.00 },
        { "date" => "2024-01-05", "description" => "Bill Payment", "amount" => -90.00, "balance" => 1000.00 }
      ]
    }.to_json))

    result = build_extractor(liability: false).extract

    assert_equal [ -10.00, 500.00, -400.00, -90.00 ], result[:transactions].map { |t| t[:amount] }
    assert result[:transactions].none? { |t| t.key?(:balance) }
  end

  test "follows a credit card balance that rises with charges" do
    @client.expects(:chat).returns(chat_response(content: {
      "opening_balance" => 200.00,
      "transactions" => [
        { "date" => "2024-01-02", "description" => "Grocer", "amount" => -50.00, "balance" => 250.00 },
        { "date" => "2024-01-03", "description" => "Airline", "amount" => -300.00, "balance" => 550.00 },
        { "date" => "2024-01-04", "description" => "Payment received", "amount" => 200.00, "balance" => 350.00 },
        { "date" => "2024-01-05", "description" => "Refund credit", "amount" => -20.00, "balance" => 330.00 }
      ]
    }.to_json))

    result = build_extractor(liability: true).extract

    assert_equal [ -50.00, -300.00, 200.00, 20.00 ], result[:transactions].map { |t| t[:amount] }
  end

  test "keeps the model's signs when too few rows can be balance-checked" do
    @client.expects(:chat).returns(chat_response(content: {
      "opening_balance" => 1000.00,
      "transactions" => [
        { "date" => "2024-01-02", "description" => "Collection", "amount" => 100.00, "balance" => 900.00 },
        { "date" => "2024-01-03", "description" => "Coffee", "amount" => -4.00 },
        { "date" => "2024-01-04", "description" => "Misread", "amount" => -7.00, "balance" => 123.45 }
      ]
    }.to_json))

    result = build_extractor.extract

    assert_equal [ 100.00, -4.00, -7.00 ], result[:transactions].map { |t| t[:amount] }
  end

  test "keeps unsigned amounts as they are, since most rows disagree with any convention" do
    @client.expects(:chat).returns(chat_response(content: {
      "opening_balance" => 1000.00,
      "transactions" => [
        { "date" => "2024-01-02", "description" => "Top-up", "amount" => 10.00, "balance" => 990.00 },
        { "date" => "2024-01-03", "description" => "Rent", "amount" => 400.00, "balance" => 590.00 },
        { "date" => "2024-01-04", "description" => "Salary", "amount" => 500.00, "balance" => 1090.00 },
        { "date" => "2024-01-05", "description" => "Bill Payment", "amount" => 90.00, "balance" => 1000.00 }
      ]
    }.to_json))

    result = build_extractor(liability: false).extract

    assert_equal [ 10.00, 400.00, 500.00, 90.00 ], result[:transactions].map { |t| t[:amount] }
  end

  test "fixes a single mis-signed row when the caller says it is a bank account" do
    @client.expects(:chat).returns(chat_response(content: {
      "opening_balance" => 1000.00,
      "transactions" => [
        { "date" => "2024-01-02", "description" => "Top-up", "amount" => -10.00, "balance" => 990.00 },
        { "date" => "2024-01-03", "description" => "Rent", "amount" => -400.00, "balance" => 590.00 },
        { "date" => "2024-01-04", "description" => "FAST Collection salary", "amount" => -500.00, "balance" => 1090.00 },
        { "date" => "2024-01-05", "description" => "Bill Payment", "amount" => -90.00, "balance" => 1000.00 }
      ]
    }.to_json))

    result = build_extractor(liability: false).extract

    assert_equal [ -10.00, -400.00, 500.00, -90.00 ], result[:transactions].map { |t| t[:amount] }
  end

  test "follows a card balance that rises with charges when the caller says it is a card" do
    @client.expects(:chat).returns(chat_response(content: {
      "opening_balance" => 200.00,
      "transactions" => [
        { "date" => "2024-01-02", "description" => "Grocer", "amount" => 50.00, "balance" => 250.00 },
        { "date" => "2024-01-03", "description" => "Airline", "amount" => -300.00, "balance" => 550.00 },
        { "date" => "2024-01-04", "description" => "Payment received", "amount" => 200.00, "balance" => 350.00 }
      ]
    }.to_json))

    result = build_extractor(liability: true).extract

    assert_equal [ -50.00, -300.00, 200.00 ], result[:transactions].map { |t| t[:amount] }
  end

  test "keeps the signs of a card that prints what is owed as a negative balance" do
    @client.expects(:chat).returns(chat_response(content: {
      "opening_balance" => -200.00,
      "transactions" => [
        { "date" => "2024-01-02", "description" => "Grocer", "amount" => -50.00, "balance" => -250.00 },
        { "date" => "2024-01-03", "description" => "Airline", "amount" => -50.00, "balance" => -300.00 },
        { "date" => "2024-01-04", "description" => "Payment received", "amount" => 200.00, "balance" => -100.00 }
      ]
    }.to_json))

    result = build_extractor(liability: true).extract

    assert_equal [ -50.00, -50.00, 200.00 ], result[:transactions].map { |t| t[:amount] }
  end

  test "reads an overdrawn balance marked DR" do
    @client.expects(:chat).returns(chat_response(content: {
      "opening_balance" => "1,000.00 DR",
      "transactions" => [
        { "date" => "2024-01-02", "description" => "ATM", "amount" => -50.00, "balance" => "1,050.00 DR" },
        { "date" => "2024-01-03", "description" => "Card purchase", "amount" => -20.00, "balance" => "1,070.00 DR" },
        { "date" => "2024-01-04", "description" => "Salary", "amount" => -900.00, "balance" => "170.00 DR" }
      ]
    }.to_json))

    result = build_extractor(liability: false).extract

    assert_equal [ -50.00, -20.00, 900.00 ], result[:transactions].map { |t| t[:amount] }
  end

  test "reads balance markers written against the number" do
    @client.expects(:chat).returns(chat_response(content: {
      "opening_balance" => "1,000.00DR",
      "transactions" => [
        { "date" => "2024-01-02", "description" => "ATM", "amount" => -50.00, "balance" => "1,050.00Dr." },
        { "date" => "2024-01-03", "description" => "Card purchase", "amount" => -20.00, "balance" => "1,070.00-" },
        { "date" => "2024-01-04", "description" => "Salary", "amount" => -900.00, "balance" => "(170.00)" }
      ]
    }.to_json))

    result = build_extractor(liability: false).extract

    assert_equal [ -50.00, -20.00, 900.00 ], result[:transactions].map { |t| t[:amount] }
  end

  test "checks a newest-first statement in date order" do
    @client.expects(:chat).returns(chat_response(content: {
      "opening_balance" => 1000.00,
      "transactions" => [
        { "date" => "2024-01-05", "description" => "Bill Payment", "amount" => -90.00, "balance" => 1000.00 },
        { "date" => "2024-01-04", "description" => "FAST Collection salary", "amount" => -500.00, "balance" => 1090.00 },
        { "date" => "2024-01-03", "description" => "Rent", "amount" => -400.00, "balance" => 590.00 },
        { "date" => "2024-01-02", "description" => "Top-up", "amount" => -10.00, "balance" => 990.00 }
      ]
    }.to_json))

    result = build_extractor(liability: false).extract

    assert_equal [ -90.00, 500.00, -400.00, -10.00 ], result[:transactions].map { |t| t[:amount] }
  end

  test "normalizes transaction amounts" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "transactions" => [
              { "date" => "2024-01-15", "description" => "Test 1", "amount" => "-$5.50" },
              { "date" => "2024-01-16", "description" => "Test 2", "amount" => "1,234.56" },
              { "date" => "2024-01-17", "description" => "Test 3", "amount" => -100 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 text" ])

    result = extractor.extract

    assert_equal(-5.50, result[:transactions][0][:amount])
    assert_equal 1234.56, result[:transactions][1][:amount]
    assert_equal(-100.0, result[:transactions][2][:amount])
  end

  test "handles malformed JSON response gracefully" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => "This is not valid JSON"
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 text" ])

    result = extractor.extract

    # Should return empty transactions on parse error
    assert_equal [], result[:transactions]
  end

  test "omits response_format entirely when json_mode is none" do
    @client.expects(:chat).with do |request|
      !request[:parameters].key?(:response_format)
    end.returns(chat_response)

    extractor = build_extractor(json_mode: "none")

    extractor.extract

    assert_equal "none", extractor.json_mode
  end

  test "asks for json_object by default, preserving pre-fix behaviour" do
    @client.expects(:chat).with do |request|
      request[:parameters][:response_format] == { type: "json_object" }
    end.returns(chat_response)

    build_extractor.extract
  end

  test "resolves json_mode from LLM_JSON_MODE when none is passed" do
    @client.expects(:chat).with do |request|
      !request[:parameters].key?(:response_format)
    end.returns(chat_response)

    with_env_overrides("LLM_JSON_MODE" => "none") do
      build_extractor.extract
    end
  end

  test "an explicit json_mode wins over LLM_JSON_MODE" do
    @client.expects(:chat).with do |request|
      request[:parameters][:response_format] == { type: "json_object" }
    end.returns(chat_response)

    with_env_overrides("LLM_JSON_MODE" => "none") do
      build_extractor(json_mode: "json_object").extract
    end
  end

  test "strips a markdown fenced reply so none mode still parses" do
    fenced = "```json\n" + { "transactions" => [ { "date" => "2024-01-15", "description" => "Coffee", "amount" => -5.50 } ] }.to_json + "\n```"
    @client.expects(:chat).returns(chat_response(content: fenced))

    result = build_extractor(json_mode: "none").extract

    assert_equal 1, result[:transactions].size
    assert_equal "Coffee", result[:transactions][0][:name]
  end

  private
    def chat_response(content: nil)
      {
        "choices" => [ {
          "message" => {
            "content" => content || { "transactions" => [] }.to_json
          }
        } ]
      }
    end

    def build_extractor(json_mode: nil, liability: nil)
      extractor = Provider::Openai::BankStatementExtractor.new(
        client: @client,
        pdf_content: "dummy",
        model: @model,
        json_mode: json_mode,
        liability: liability
      )
      extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 text" ])
      extractor
    end
end
