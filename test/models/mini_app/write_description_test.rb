require "test_helper"

class MiniApp::WriteDescriptionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "formats amounts as money in the account's currency" do
    lines = describe("create_transaction", "account_id" => @account.id, "amount" => 25, "name" => "Piggy Bank savings")

    assert_equal Money.new(25, @account.currency).format, value_for(lines, "Amount")
    assert_equal @account.name, value_for(lines, "Account")
  end

  test "prefers the currency the call names" do
    lines = describe("create_goal", "target_amount" => "30899.37", "currency" => "EUR")

    assert_equal Money.new(BigDecimal("30899.37"), "EUR").format, value_for(lines, "Target amount")
  end

  test "lists plain arrays as text instead of JSON" do
    lines = describe("create_goal", "linked_account_names" => [ "Marcus High-Yield Savings", "Ally" ])

    assert_equal "Marcus High-Yield Savings, Ally", value_for(lines, "Funding accounts")
  end

  test "shows an amount it cannot read as given" do
    lines = describe("create_transaction", "amount" => "lots")

    assert_equal "lots", value_for(lines, "Amount")
  end

  private
    def describe(tool, arguments)
      MiniApp::WriteDescription.new(user: @user, tool: tool, arguments: arguments).lines
    end

    def value_for(lines, label)
      lines.find { |line| line[:label] == label }&.dig(:value)
    end
end
