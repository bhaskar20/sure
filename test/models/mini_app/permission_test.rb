require "test_helper"

class MiniApp::PermissionTest < ActiveSupport::TestCase
  test "every catalog tool is a real assistant tool" do
    user = users(:family_admin)
    user.stubs(:preview_features_enabled?).returns(true)
    assistant_tools = Assistant.function_classes(user).map(&:name)

    MiniApp::Permission.all.each do |permission|
      MiniApp::Permission.tools(permission).each do |tool|
        assert_includes assistant_tools, tool, "#{permission} lists unknown tool #{tool}"
      end
    end
  end

  test "maps tools to permissions" do
    assert_equal "transactions:write", MiniApp::Permission.for_tool("update_transaction")
    assert_equal "categories:read", MiniApp::Permission.for_tool(:get_categories)
    assert_nil MiniApp::Permission.for_tool("import_bank_statement")
  end

  test "classifies reads and writes" do
    assert MiniApp::Permission.write?("tags:write")
    assert_not MiniApp::Permission.write?("tags:read")
    assert MiniApp::Permission.valid?("rules:write")
    assert_not MiniApp::Permission.valid?("rules:delete")
  end

  test "every permission has a label and description" do
    MiniApp::Permission.all.each do |permission|
      assert I18n.exists?("mini_app.permissions.#{MiniApp::Permission.i18n_key(permission)}.label"), permission
      assert MiniApp::Permission.description(permission).present?, permission
    end

    assert_equal "Change transactions", MiniApp::Permission.label("transactions:write")
  end

  test "tool classes follow the assistant registry for the user" do
    member_tools = MiniApp::Permission.tool_classes_for(users(:family_member)).map(&:name)
    assert_includes member_tools, "create_category"
    assert_not_includes member_tools, "import_bank_statement"

    guest = users(:family_member)
    guest.role = "guest"
    assert_not_includes MiniApp::Permission.tool_classes_for(guest).map(&:name), "create_category"
  end
end
