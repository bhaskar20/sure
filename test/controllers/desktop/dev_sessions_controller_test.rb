require "test_helper"

class Desktop::DevSessionsControllerTest < ActionDispatch::IntegrationTest
  TOKEN = "dev-login-token-for-tests".freeze

  test "lists accounts for the desktop dev launcher" do
    with_dev_login do
      get desktop_dev_accounts_path, params: { token: TOKEN }
    end

    assert_response :success
    emails = response.parsed_body.map { |account| account["email"] }
    assert_includes emails, users(:family_admin).email
    assert_equal emails.sort, emails
    assert_equal %w[email family name role], response.parsed_body.first.keys.sort
  end

  test "signs in as the chosen account and lands on the dashboard" do
    with_dev_login do
      post desktop_dev_sign_in_path, params: { token: TOKEN, email: users(:family_admin).email }
    end

    assert_redirected_to root_path
    assert cookies[:session_token].present?
  end

  test "rejects a wrong token" do
    with_dev_login do
      get desktop_dev_accounts_path, params: { token: "nope" }
      assert_response :not_found
      post desktop_dev_sign_in_path, params: { token: "nope", email: users(:family_admin).email }
      assert_response :not_found
    end
    assert cookies[:session_token].blank?
  end

  test "does not exist unless the dev launcher enabled it" do
    with_self_hosting do
      ClimateControl.modify("SURE_DESKTOP" => "1", "SURE_DESKTOP_DEV_LOGIN_TOKEN" => nil) do
        get desktop_dev_accounts_path, params: { token: "" }
      end
    end
    assert_response :not_found

    with_self_hosting do
      ClimateControl.modify("SURE_DESKTOP" => nil, "SURE_DESKTOP_DEV_LOGIN_TOKEN" => TOKEN) do
        get desktop_dev_accounts_path, params: { token: TOKEN }
      end
    end
    assert_response :not_found
  end

  test "unknown accounts are not found" do
    with_dev_login do
      post desktop_dev_sign_in_path, params: { token: TOKEN, email: "nobody@example.com" }
    end
    assert_response :not_found
  end

  private
    def with_dev_login(&block)
      ClimateControl.modify("SURE_DESKTOP" => "1", "SURE_DESKTOP_DEV_LOGIN_TOKEN" => TOKEN) do
        with_self_hosting(&block)
      end
    end
end
