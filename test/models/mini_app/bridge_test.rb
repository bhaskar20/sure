require "test_helper"

class MiniApp::BridgeTest < ActiveSupport::TestCase
  setup do
    @app = mini_apps(:recategorizer)
    @admin = users(:family_admin)
    @member = users(:family_member)
    @transaction = transactions(:one)
    @category = categories(:subcategory)
  end

  test "ui/initialize describes the app, effective permissions and family" do
    result = bridge.handle(rpc("ui/initialize"))[:result]

    assert_equal "2026-11-11", result[:protocolVersion]
    assert_equal 1, result[:bridgeVersion]
    assert_equal "recategorizer", result[:app][:id]
    assert_equal @app.granted_permissions.sort, result[:permissions].sort
    assert_equal "confirm", result[:writePolicy]
    assert_equal "admin", result[:user][:role]
    assert_equal @admin.family.currency, result[:family][:currency]
    assert_equal({ tools: {}, storage: {}, events: {} }, result[:capabilities])
  end

  test "ping answers with an empty result and echoes the id" do
    response = bridge.handle(rpc("ping", id: "abc"))

    assert_equal({ jsonrpc: "2.0", id: "abc", result: {} }, response)
  end

  test "rejects malformed messages" do
    assert_equal(-32700, bridge.handle("{not json")[:error][:code])
    assert_equal(-32600, bridge.handle({ "method" => "ping", "id" => 1 })[:error][:code])
    assert_equal(-32600, bridge.handle([ 1, 2 ])[:error][:code])
    assert_equal(-32602, bridge.handle(rpc("ping", params: [ 1 ]))[:error][:code])
    assert_equal(-32601, bridge.handle(rpc("transactions/destroy_all"))[:error][:code])
  end

  test "accepts a JSON string message" do
    assert_equal({}, bridge.handle(rpc("ping").to_json)[:result])
  end

  test "tools/list offers only granted catalog tools" do
    tools = bridge.handle(rpc("tools/list"))[:result][:tools]
    names = tools.map { |tool| tool[:name] }

    assert_includes names, "get_transactions"
    assert_includes names, "update_transaction"
    assert_includes names, "get_categories"
    assert_not_includes names, "get_tags", "requested but not granted"
    assert_not_includes names, "get_accounts", "not requested"
    assert_not_includes names, "import_bank_statement", "not in the mini app catalog"

    update = tools.find { |tool| tool[:name] == "update_transaction" }
    assert_equal "transactions:write", update[:permission]
    assert update[:write]
    assert_equal "object", update[:inputSchema][:type]
  end

  test "tools/list hides write tools from guests" do
    @member.update!(role: :guest)
    names = bridge(user: @member).handle(rpc("tools/list"))[:result][:tools].map { |tool| tool[:name] }

    assert_includes names, "get_transactions"
    assert_not_includes names, "update_transaction"
  end

  test "a granted read runs the tool and logs ok" do
    assert_difference -> { @app.activities.count }, 1 do
      @response = call_tool("get_categories")
    end

    result = @response[:result]
    assert_nil result[:isError]
    assert_kind_of Hash, result[:structuredContent]
    assert_equal result[:structuredContent], JSON.parse(result[:content].first[:text])

    activity = @app.activities.order(:created_at).last
    assert activity.ok?
    assert_equal "get_categories", activity.tool
    assert_equal "categories:read", activity.permission
    assert_equal @admin, activity.user
    assert_not activity.write
  end

  test "a read whose permission was requested but not granted is denied and logged" do
    assert_difference -> { @app.activities.where(outcome: "denied").count }, 1 do
      @response = call_tool("get_tags")
    end

    assert_equal(-32003, @response[:error][:code])
    assert_equal "tags:read", @response[:error][:data][:permission]
    assert_equal "permission_not_granted", @app.activities.order(:created_at).last.error_message
  end

  test "a write without its permission is denied and changes nothing" do
    @app.update_grants!(permissions: %w[transactions:read categories:read])
    original_category = @transaction.category

    response = call_tool("update_transaction", { "id" => @transaction.id, "category_id" => @category.id })

    assert_equal(-32003, response[:error][:code])
    assert_equal "transactions:write", response[:error][:data][:permission]
    assert_equal original_category, @transaction.reload.category
    activity = @app.activities.order(:created_at).last
    assert activity.denied?
    assert activity.write
  end

  test "a write needs confirmation, then runs when confirmed" do
    args = { "id" => @transaction.id, "category_id" => @category.id }

    assert_no_difference -> { @app.activities.count } do
      @response = call_tool("update_transaction", args)
    end

    error = @response[:error]
    assert_equal(-32005, error[:code])
    assert_equal "update_transaction", error[:data][:tool]
    assert_equal "transactions:write", error[:data][:permission]
    assert_equal "Recategorizer wants to update a transaction.", error[:data][:summary]
    entry = @transaction.entry
    assert_equal [
      { label: "Transaction", value: "#{entry.name} · #{entry.amount_money.format} · #{I18n.l(entry.date)} · #{entry.account.name}" },
      { label: "Category", value: @category.name_with_parent }
    ], error[:data][:details]
    assert_not_equal @category, @transaction.reload.category

    response = call_tool("update_transaction", args, confirmed: true)

    assert_nil response[:error]
    assert_equal true, response[:result][:structuredContent]["success"]
    assert_equal @category, @transaction.reload.category

    activity = @app.activities.order(:created_at).last
    assert activity.ok?
    assert activity.write
    assert_equal "update_transaction", activity.tool
    assert_equal @transaction.id, activity.summary.dig("arguments", "id")
  end

  test "the confirmation describes the real target and values, not what the app claims" do
    other_family_category = Category.where.not(family_id: @admin.family_id).first
    args = { "id" => @transaction.id, "amount" => 999_999, "category_id" => other_family_category&.id || SecureRandom.uuid,
             "tag_ids" => [ "not-a-uuid" ], "notes" => "x" * 500 }

    details = call_tool("update_transaction", args)[:error][:data][:details]
    by_label = details.index_by { |line| line[:label] }

    assert_match @transaction.entry.name, by_label["Transaction"][:value]
    assert_match "(not found)", by_label["Category"][:value]
    assert_equal "not-a-uuid (not found)", by_label["Tags"][:value]
    assert_equal Money.new(999_999, @admin.family.currency).format, by_label["Amount"][:value]
    assert_operator by_label["Notes"][:value].length, :<=, MiniApp::WriteDescription::MAX_VALUE_LENGTH
    assert_equal %w[Transaction Category Tags Amount Notes], details.map { |line| line[:label] }
  end

  test "writes run without confirmation under the allow policy" do
    @app.update!(write_policy: "allow")

    response = call_tool("update_transaction", { "id" => @transaction.id, "category_id" => @category.id })

    assert_nil response[:error]
    assert_equal @category, @transaction.reload.category
  end

  test "a declined write is refused and logged as declined" do
    original_category = @transaction.category

    assert_difference -> { @app.activities.where(outcome: "declined").count }, 1 do
      @response = call_tool("update_transaction", { "id" => @transaction.id, "category_id" => @category.id }, declined: true)
    end

    assert_equal(-32006, @response[:error][:code])
    assert_equal original_category, @transaction.reload.category
  end

  test "a guest cannot write even when the permission is granted" do
    @member.update!(role: :guest)

    response = call_tool("update_transaction", { "id" => @transaction.id, "category_id" => @category.id },
                         user: @member, confirmed: true)

    assert_equal(-32003, response[:error][:code])
    assert_not_equal @category, @transaction.reload.category
    assert @app.activities.order(:created_at).last.denied?
  end

  test "a guest can still read" do
    @member.update!(role: :guest)

    assert_nil call_tool("get_transactions", {}, user: @member)[:error]
  end

  test "a disabled app is refused for every method" do
    @app.disable!

    assert_equal(-32004, bridge.handle(rpc("ui/initialize"))[:error][:code])
    assert_equal(-32004, bridge.handle(rpc("sure/storage/get", params: { collection: "settings", key: "preferences" }))[:error][:code])

    assert_difference -> { @app.activities.where(outcome: "denied").count }, 1 do
      @response = call_tool("get_categories")
    end
    assert_equal(-32004, @response[:error][:code])
  end

  test "tools outside the mini app catalog are refused" do
    %w[import_bank_statement search_family_files no_such_tool].each do |name|
      response = call_tool(name)

      assert_equal(-32601, response[:error][:code], name)
      assert @app.activities.order(:created_at).last.denied?
    end
  end

  test "invalid tools/call params are refused" do
    assert_equal(-32602, bridge.handle(rpc("tools/call", params: { arguments: {} }))[:error][:code])
    assert_equal(-32602, bridge.handle(rpc("tools/call", params: { name: "get_categories", arguments: [ 1 ] }))[:error][:code])
  end

  test "a user from another family is refused without running anything" do
    outsider = users(:empty)

    assert_no_difference -> { MiniApp::Activity.count } do
      @response = call_tool("get_categories", {}, user: outsider)
    end
    assert_equal(-32003, @response[:error][:code])
    assert_equal(-32003, bridge(user: outsider).handle(rpc("ui/initialize"))[:error][:code])
    assert_equal(-32003, bridge(user: outsider).handle(rpc("sure/storage/get", params: { collection: "settings", key: "preferences" }))[:error][:code])
  end

  test "a raising tool returns a generic error and logs the class name only" do
    Assistant::Function::GetCategories.any_instance.stubs(:call).raises(ActiveRecord::StatementInvalid, "PG::Error: SELECT secret FROM users")

    response = call_tool("get_categories")

    assert response[:result][:isError]
    assert_equal "The tool failed to run.", response[:result][:structuredContent]["error"]
    assert_not_includes response.to_json, "secret"

    activity = @app.activities.order(:created_at).last
    assert activity.error?
    assert_equal "ActiveRecord::StatementInvalid", activity.error_message
  end

  test "a tool that reports a failure is logged as an error with its code" do
    @app.update!(write_policy: "allow")

    response = call_tool("update_transaction", { "id" => SecureRandom.uuid, "name" => "x" })

    assert_equal false, response[:result][:structuredContent]["success"]
    activity = @app.activities.order(:created_at).last
    assert activity.error?
    assert_equal "not_found", activity.error_message
  end

  test "tool calls are rate limited per app and user" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    MiniApp::Bridge.any_instance.stubs(:run_tool).returns({})

    MiniApp::Bridge::RATE_LIMIT.times { assert_nil call_tool("get_categories")[:error] }

    assert_difference -> { @app.activities.where(outcome: "denied", error_message: "rate_limited").count }, 1 do
      assert_equal(-32029, call_tool("get_categories")[:error][:code])
      assert_equal(-32029, call_tool("get_categories")[:error][:code])
    end

    assert_nil call_tool("get_categories", {}, user: @member)[:error], "another user has their own budget"
    assert_nil bridge.handle(rpc("ping"))[:error], "non-tool methods are not limited"
  end

  test "storage set, get, list and delete" do
    set = bridge.handle(rpc("sure/storage/set", params: { collection: "notes", key: "a", data: { "n" => 1 } }))[:result]
    assert_equal({ "n" => 1 }, set[:data])

    got = bridge.handle(rpc("sure/storage/get", params: { collection: "notes", key: "a" }))[:result]
    assert_equal({ "n" => 1 }, got[:data])
    assert got[:updatedAt].present?

    bridge.handle(rpc("sure/storage/set", params: { collection: "notes", key: "a", data: { "n" => 2 } }))
    assert_equal({ "n" => 2 }, @app.records.find_by(collection: "notes", key: "a").data)

    assert bridge.handle(rpc("sure/storage/delete", params: { collection: "notes", key: "a" }))[:result][:deleted]
    assert_nil bridge.handle(rpc("sure/storage/get", params: { collection: "notes", key: "a" }))[:result][:data]
    assert_not bridge.handle(rpc("sure/storage/delete", params: { collection: "notes", key: "a" }))[:result][:deleted]
  end

  test "storage list pages by key with a prefix and cursor" do
    %w[b2 a1 b1 b3].each do |key|
      bridge.handle(rpc("sure/storage/set", params: { collection: "items", key: key, data: { "k" => key } }))
    end

    first = bridge.handle(rpc("sure/storage/list", params: { collection: "items", prefix: "b", limit: 2 }))[:result]
    assert_equal %w[b1 b2], first[:items].map { |item| item[:key] }
    assert first[:nextCursor].present?

    second = bridge.handle(rpc("sure/storage/list", params: { collection: "items", prefix: "b", limit: 2, cursor: first[:nextCursor] }))[:result]
    assert_equal %w[b3], second[:items].map { |item| item[:key] }
    assert_nil second[:nextCursor]
  end

  test "storage rejects invalid params" do
    assert_equal(-32602, bridge.handle(rpc("sure/storage/get", params: { collection: "Bad Name", key: "a" }))[:error][:code])
    assert_equal(-32602, bridge.handle(rpc("sure/storage/get", params: { collection: "notes" }))[:error][:code])
    assert_equal(-32602, bridge.handle(rpc("sure/storage/set", params: { collection: "notes", key: "a" }))[:error][:code])
    assert_equal(-32602, bridge.handle(rpc("sure/storage/list", params: { collection: "notes", limit: 0 }))[:error][:code])
    assert_equal(-32602, bridge.handle(rpc("sure/storage/list", params: { collection: "notes", cursor: "%%%" }))[:error][:code])

    too_big = { "blob" => "x" * (MiniApp::Record::MAX_DATA_BYTES + 1) }
    response = bridge.handle(rpc("sure/storage/set", params: { collection: "notes", key: "a", data: too_big }))
    assert_equal(-32602, response[:error][:code])
    assert response[:error][:data][:errors].any?
  end

  test "storage is isolated between apps and families" do
    other_app = MiniApp.create!(
      family: @app.family, app_key: "other-app", name: "Other", version: "1.0.0", source: "bundle",
      manifest: { "id" => "other-app", "permissions" => [] }
    )
    other_family = families(:empty)
    foreign_app = MiniApp.create!(
      family: other_family, app_key: "recategorizer", name: "Recategorizer", version: "1.0.0", source: "bundle",
      manifest: { "id" => "recategorizer", "permissions" => [] }
    )

    params = { collection: "settings", key: "preferences" }
    assert bridge.handle(rpc("sure/storage/get", params: params))[:result][:data].present?
    assert_nil bridge(app: other_app).handle(rpc("sure/storage/get", params: params))[:result][:data]
    assert_nil bridge(app: foreign_app, user: users(:empty)).handle(rpc("sure/storage/get", params: params))[:result][:data]

    bridge(app: other_app).handle(rpc("sure/storage/set", params: params.merge(data: { "mine" => true })))
    bridge(app: other_app).handle(rpc("sure/storage/delete", params: params))
    assert @app.records.exists?(collection: "settings", key: "preferences"), "another app cannot delete this app's record"

    bridge(app: foreign_app, user: users(:empty)).handle(rpc("sure/storage/set", params: { collection: "x", key: "k", data: { "v" => 1 } }))
    items = bridge.handle(rpc("sure/storage/list", params: { collection: "x" }))[:result][:items]
    assert_empty items
  end

  private
    def bridge(app: @app, user: @admin)
      MiniApp::Bridge.new(mini_app: app, user: user)
    end

    def rpc(method, params: nil, id: 1)
      message = { "jsonrpc" => "2.0", "id" => id, "method" => method }
      message["params"] = params.is_a?(Hash) ? params.deep_stringify_keys : params unless params.nil?
      message
    end

    def call_tool(name, arguments = {}, user: @admin, confirmed: false, declined: false)
      bridge(user: user).handle(rpc("tools/call", params: { name: name, arguments: arguments }), confirmed: confirmed, declined: declined)
    end
end
