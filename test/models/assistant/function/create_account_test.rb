require "test_helper"

class Assistant::Function::CreateAccountTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @function = Assistant::Function::CreateAccount.new(@user)
  end

  test "creates a manual account owned by the user" do
    result = nil

    assert_difference "@user.family.accounts.count", 1 do
      result = @function.call(
        "name" => "Brokerage", "accountable_type" => "Investment", "currency" => "sgd",
        "balance" => 100, "opening_balance_date" => "2023-01-01"
      )
    end

    assert result[:success]
    account = Account.find(result[:account][:id])
    assert_equal "SGD", account.currency
    assert_equal @user, account.owner
    assert_equal "Investment", account.accountable_type
    assert_equal Date.new(2023, 1, 1), Account::OpeningBalanceManager.new(account).opening_date
  end

  test "defaults the currency to the family currency" do
    result = @function.call("name" => "Wallet", "accountable_type" => "Depository")

    assert result[:success]
    assert_equal @user.family.currency, result[:account][:currency]
  end

  test "rejects an unknown type, currency or date" do
    assert_equal "invalid_type", @function.call("name" => "X", "accountable_type" => "Bogus")[:error]
    assert_equal "invalid_currency", @function.call("name" => "X", "accountable_type" => "Depository", "currency" => "ZZZ")[:error]
    assert_equal "invalid_date", @function.call("name" => "X", "accountable_type" => "Depository", "opening_balance_date" => "soon")[:error]
    assert_equal "invalid_name", @function.call("name" => " ", "accountable_type" => "Depository")[:error]
  end

  test "is not offered to guests" do
    guest = users(:family_admin).tap { |user| user.stubs(:guest?).returns(true) }

    assert_not_includes Assistant.function_classes(guest), Assistant::Function::CreateAccount
  end
end
