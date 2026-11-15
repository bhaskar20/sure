require "test_helper"

class Assistant::Function::RecordValuationsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:other_asset)
    @function = Assistant::Function::RecordValuations.new(@user)
    @source = "Net worth tracker spreadsheet (grade: B)"
  end

  test "records every value with the shared citation" do
    result = nil

    assert_difference "@account.entries.valuations.count", 2 do
      result = @function.call(params([ { "date" => "2024-02-29", "amount" => 900 }, { "date" => "2024-01-31", "amount" => 800 } ]))
    end

    assert result[:success]
    assert_equal 2, result[:recorded_count]
    assert_equal %w[2024-01-31 2024-02-29], result[:recorded].map { |item| item[:date] }
    assert_equal [ @source ], @account.entries.valuations.where(date: [ Date.new(2024, 1, 31), Date.new(2024, 2, 29) ]).pluck(:notes).uniq
  end

  test "reports a bad item without stopping the rest" do
    result = @function.call(params([ { "date" => "nope", "amount" => 1 }, { "date" => "2024-01-31", "amount" => 800 } ]))

    assert_not result[:success]
    assert_equal 1, result[:recorded_count]
    assert_equal "invalid_date", result[:failed].first[:error]
  end

  test "fails the whole call for a bad citation or account" do
    assert_equal "invalid_source_citation", @function.call(params([ { "date" => "2024-01-31", "amount" => 1 } ], source: ""))[:error]
    assert_equal "account_not_found", @function.call(params([ { "date" => "2024-01-31", "amount" => 1 } ], account_id: SecureRandom.uuid))[:error]
  end

  test "limits the batch size" do
    items = Array.new(Assistant::Function::RecordValuations::MAX_VALUATIONS + 1) { { "date" => "2024-01-31", "amount" => 1 } }

    assert_equal "too_many_valuations", @function.call(params(items))[:error]
    assert_equal "invalid_valuations", @function.call(params([]))[:error]
  end

  private
    def params(valuations, source: @source, account_id: @account.id)
      { "account_id" => account_id, "source" => source, "valuations" => valuations }
    end
end
