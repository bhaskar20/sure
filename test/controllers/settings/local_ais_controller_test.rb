require "test_helper"

class Settings::LocalAisControllerTest < ActionDispatch::IntegrationTest
  setup do
    # Local AI is instance-wide, like the instance settings under Self-Hosting.
    users(:family_admin).update!(role: :super_admin)
  end

  test "shows the local AI page inside Sure Desktop" do
    sign_in users(:family_admin)

    with_desktop do
      get settings_local_ai_path
    end

    assert_response :success
    assert_select "[data-controller='desktop-local-ai']"
    assert_select "[data-desktop-local-ai-target='enabled']"
    assert_select "template[data-desktop-local-ai-target='modelTemplate']"
    strings = JSON.parse(css_select("[data-controller='desktop-local-ai']").first["data-desktop-local-ai-strings-value"])
    assert_equal I18n.t("settings.local_ais.show.status.off"), strings["off"]
    assert_includes strings["running"], "%{name}", "the page fills in the model name"
  end

  test "lists local AI in the settings navigation only inside Sure Desktop" do
    sign_in users(:family_admin)

    with_desktop { get settings_preferences_path }
    assert_select "a[href='#{settings_local_ai_path}']"

    with_self_hosting { get settings_preferences_path }
    assert_select "a[href='#{settings_local_ai_path}']", count: 0
  end

  test "is not available outside Sure Desktop" do
    sign_in users(:family_admin)

    with_self_hosting { get settings_local_ai_path }

    assert_response :forbidden
  end

  test "is only for people who manage instance settings" do
    sign_in users(:family_member)

    with_desktop { get settings_local_ai_path }

    assert_redirected_to settings_preferences_path
  end

  private
    def with_desktop(&block)
      ClimateControl.modify("SURE_DESKTOP" => "1") { with_self_hosting(&block) }
    end
end
