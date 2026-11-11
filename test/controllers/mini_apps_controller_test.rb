require "test_helper"

class MiniAppsControllerTest < ActionDispatch::IntegrationTest
  include MiniAppTestHelper

  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    [ @admin, @member ].each { |user| enable_preview(user) }
    @mini_app = mini_apps(:recategorizer)
    sign_in @admin
  end

  test "redirects users without preview access" do
    enable_preview(@admin, false)

    get mini_apps_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "bridge is preview gated too" do
    enable_preview(@admin, false)

    post_bridge(@mini_app, { jsonrpc: "2.0", id: 1, method: "ping" })

    assert_redirected_to root_path
  end

  test "index lists apps and the install form for admins" do
    get mini_apps_url

    assert_response :success
    assert_select "h2", text: "Recategorizer"
    assert_select "h2", text: "Budget Peek"
    assert_select "input[type=file][name=bundle]"
  end

  test "members see only enabled apps and no install form" do
    sign_in @member

    get mini_apps_url

    assert_response :success
    assert_select "h2", text: "Recategorizer"
    assert_select "h2", text: "Budget Peek", count: 0
    assert_select "input[type=file][name=bundle]", count: 0
  end

  test "show renders the sandboxed host page and records the open" do
    get mini_app_url(@mini_app)

    assert_response :success
    assert_not_nil @mini_app.reload.last_opened_at

    assert_select "[data-controller='mini-app-host'][data-mini-app-host-bridge-url-value='#{bridge_mini_app_path(@mini_app)}']"
    assert_select "iframe[data-mini-app-host-target='frame']" do |frames|
      frame = frames.first
      assert_equal "allow-scripts allow-forms allow-popups", frame["sandbox"]
      assert_not_includes frame["sandbox"], "allow-same-origin"
      assert_equal "no-referrer", frame["referrerpolicy"]
      assert_match %r{/mini_app_frames/[^/]+/index\.html\z}, frame["src"]
    end
    assert_select "dialog[data-mini-app-host-target='confirmDialog'] [data-mini-app-host-target='confirmMessage']"
    assert_select "dialog [data-action='mini-app-host#approve']"
    assert_select "dialog [data-action='mini-app-host#decline'][autofocus]"
    assert_select "dialog button[data-mini-app-host-target='approveButton'][disabled]"
    assert_select "dialog dl[data-mini-app-host-target='confirmDetails']"
    assert_select "dialog template[data-mini-app-host-target='confirmDetailRow']"
  end

  test "show loads a dev server app from its URL, still sandboxed" do
    @mini_app.update!(source: "dev_server", dev_url: "http://localhost:5173/", bundle_sha256: nil)

    get mini_app_url(@mini_app)

    assert_select "iframe[src='http://localhost:5173/index.html']" do |frames|
      assert_not_includes frames.first["sandbox"], "allow-same-origin"
    end
    assert_match "network restrictions do not apply", response.body
  end

  test "consent says a dev server app's network access is not restricted" do
    @mini_app.update!(source: "dev_server", dev_url: "http://localhost:5173/", bundle_sha256: nil)

    get consent_mini_app_url(@mini_app)

    assert_response :success
    assert_match "Sure cannot limit which servers it contacts", response.body
    assert_no_match "cannot contact any server outside Sure", response.body
  end

  test "consent says a bundle without network origins is offline" do
    get consent_mini_app_url(@mini_app)

    assert_match "cannot contact any server outside Sure", response.body
  end

  test "members can open enabled apps" do
    sign_in @member

    get mini_app_url(@mini_app)

    assert_response :success
  end

  test "guests can open enabled apps" do
    @member.update!(role: :guest)
    sign_in @member

    get mini_app_url(@mini_app)

    assert_response :success
  end

  test "disabled apps do not open" do
    get mini_app_url(mini_apps(:budget_peek))

    assert_redirected_to mini_apps_path
  end

  test "another family's app is not found" do
    other = MiniApp.create!(
      family: families(:empty), app_key: "other-app", name: "Other", version: "1.0.0",
      source: "bundle", manifest: mini_app_manifest("id" => "other-app")
    )

    get mini_app_url(other)
    assert_response :not_found

    get consent_mini_app_url(other)
    assert_response :not_found

    delete mini_app_url(other)
    assert_response :not_found
    assert MiniApp.exists?(other.id)
  end

  test "admin installs a zip and lands on consent" do
    upload = Rack::Test::UploadedFile.new(mini_app_zip, "application/zip", original_filename: "test-app.zip")

    assert_difference -> { @admin.family.mini_apps.count }, 1 do
      post mini_apps_url, params: { bundle: upload }
    end

    app = @admin.family.mini_apps.find_by!(app_key: "test-app")
    assert_redirected_to consent_mini_app_path(app)
    assert_equal [], app.granted_permissions
    assert app.assets.exists?(path: "index.html")
    assert app.bundle_sha256.present?

    follow_redirect!
    assert_response :success
    assert_select "input[type=checkbox][name='mini_app[granted_permissions][]'][value='transactions:read']"
    assert_select "code", text: app.bundle_sha256
  end

  test "a zip reusing an installed app's id needs the replace box ticked" do
    app = mini_apps(:recategorizer)
    app.update!(write_policy: "allow")
    manifest = mini_app_manifest("id" => app.app_key, "version" => "2.0.0", "permissions" => %w[transactions:read])
    zip = -> { Rack::Test::UploadedFile.new(mini_app_zip({}, manifest: manifest), "application/zip", original_filename: "x.zip") }

    post mini_apps_url, params: { bundle: zip.call }

    assert_redirected_to mini_apps_path
    assert_match "already installed", flash[:alert]
    assert_equal "1.0.0", app.reload.version

    post mini_apps_url, params: { bundle: zip.call, upgrade: "1" }

    assert_redirected_to consent_mini_app_path(app)
    app.reload
    assert_equal "2.0.0", app.version
    assert_equal %w[transactions:read], app.granted_permissions
    assert app.confirm_writes?
  end

  test "the install form offers the replace option" do
    get new_mini_app_url

    assert_response :success
    assert_select "input[type=checkbox][name=upgrade][value='1']"
  end

  test "an invalid bundle is refused with a message" do
    upload = Rack::Test::UploadedFile.new(StringIO.new("not a zip"), "application/zip", original_filename: "bad.zip")

    assert_no_difference -> { MiniApp.count } do
      post mini_apps_url, params: { bundle: upload }
    end

    assert_redirected_to mini_apps_path
    assert flash[:alert].present?
  end

  test "install without a source is refused" do
    post mini_apps_url

    assert_redirected_to mini_apps_path
    assert flash[:alert].present?
  end

  test "members cannot install, change, review or remove apps" do
    sign_in @member
    upload = Rack::Test::UploadedFile.new(mini_app_zip, "application/zip", original_filename: "test-app.zip")

    assert_no_difference -> { MiniApp.count } do
      post mini_apps_url, params: { bundle: upload }
    end
    assert_redirected_to accounts_path

    get consent_mini_app_url(@mini_app)
    assert_redirected_to accounts_path

    patch mini_app_url(@mini_app), params: { mini_app: { status: "disabled", granted_permissions: [ "" ] } }
    assert_redirected_to accounts_path
    assert @mini_app.reload.enabled?
    assert_includes @mini_app.granted_permissions, "transactions:write"

    delete mini_app_url(@mini_app)
    assert_redirected_to accounts_path
    assert MiniApp.exists?(@mini_app.id)
  end

  test "admin updates grants and write policy" do
    patch mini_app_url(@mini_app), params: {
      mini_app: { granted_permissions: [ "", "transactions:read", "tags:read", "rules:write" ], write_policy: "allow" }
    }

    assert_redirected_to mini_app_path(@mini_app)
    @mini_app.reload
    assert_equal %w[transactions:read tags:read].sort, @mini_app.granted_permissions.sort
    assert_equal "allow", @mini_app.write_policy
  end

  test "unticking every permission revokes all grants" do
    patch mini_app_url(@mini_app), params: { mini_app: { granted_permissions: [ "" ], write_policy: "confirm" } }

    assert_equal [], @mini_app.reload.granted_permissions
  end

  test "admin disables and re-enables an app" do
    patch mini_app_url(@mini_app), params: { mini_app: { status: "disabled" } }
    assert_redirected_to mini_apps_path
    assert @mini_app.reload.disabled?
    assert_equal 4, @mini_app.granted_permissions.size

    patch mini_app_url(@mini_app), params: { mini_app: { status: "enabled" } }
    assert @mini_app.reload.enabled?
  end

  test "disabling stops frame serving and bridge calls" do
    token = @mini_app.frame_token
    patch mini_app_url(@mini_app), params: { mini_app: { status: "disabled" } }

    get mini_app_frame_url(token: token, path: "index.html")
    assert_response :not_found

    post_bridge(@mini_app, { jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "get_transactions", arguments: {} } })
    assert_response :success
    assert_equal -32004, response.parsed_body.dig("error", "code")
  end

  test "uninstall removes the app, its files, storage and activity" do
    app_id = @mini_app.id
    assert MiniApp::Asset.where(mini_app_id: app_id).exists?

    delete mini_app_url(@mini_app)

    assert_redirected_to mini_apps_path
    assert_not MiniApp.exists?(app_id)
    assert_not MiniApp::Asset.where(mini_app_id: app_id).exists?
    assert_not MiniApp::Record.where(mini_app_id: app_id).exists?
    assert_not MiniApp::Activity.where(mini_app_id: app_id).exists?
  end

  test "activity lists the app's calls for admins" do
    get activity_mini_app_url(@mini_app)

    assert_response :success
    assert_select "code", text: "get_transactions"
  end

  test "members cannot read the activity log" do
    sign_in @member

    get activity_mini_app_url(@mini_app)

    assert_redirected_to accounts_path
  end

  test "bridge answers ping" do
    post_bridge(@mini_app, { jsonrpc: "2.0", id: 1, method: "ping" })

    assert_response :success
    assert_equal({ "jsonrpc" => "2.0", "id" => 1, "result" => {} }, response.parsed_body)
  end

  test "bridge denies a tool the app was not granted and logs it" do
    assert_difference -> { @mini_app.activities.where(outcome: "denied").count }, 1 do
      post_bridge(@mini_app, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "get_tags", arguments: {} } })
    end

    assert_response :success
    error = response.parsed_body["error"]
    assert_equal -32003, error["code"]
    assert_equal "tags:read", error.dig("data", "permission")
  end

  test "bridge asks for confirmation before a write" do
    post_bridge(@mini_app, { jsonrpc: "2.0", id: 3, method: "tools/call",
                             params: { name: "create_category", arguments: { name: "Snacks" } } })

    assert_equal -32005, response.parsed_body.dig("error", "code")
  end

  test "bridge runs a write the person confirmed and records a decline" do
    message = { jsonrpc: "2.0", id: 4, method: "tools/call",
                params: { name: "create_category", arguments: { name: "Snacks" } } }

    assert_difference -> { @mini_app.activities.where(outcome: "ok", write: true).count }, 1 do
      post_bridge(@mini_app, message, confirmed: true)
    end
    assert_nil response.parsed_body["error"]
    assert_equal 4, response.parsed_body["id"]
    assert_not response.parsed_body.dig("result", "isError")

    post_bridge(@mini_app, message.merge(id: 5), declined: true)
    assert_equal -32006, response.parsed_body.dig("error", "code")
    assert_equal "declined", @mini_app.activities.order(:created_at).last.outcome
  end

  test "bridge refuses another family's app" do
    other = MiniApp.create!(
      family: families(:empty), app_key: "other-app", name: "Other", version: "1.0.0",
      source: "bundle", manifest: mini_app_manifest("id" => "other-app")
    )

    post_bridge(other, { jsonrpc: "2.0", id: 1, method: "ping" })

    assert_response :not_found
  end

  private
    def enable_preview(user, enabled = true)
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => enabled))
    end

    def post_bridge(mini_app, message, confirmed: false, declined: false)
      post bridge_mini_app_url(mini_app),
           params: { message: message, confirmed: confirmed, declined: declined }.to_json,
           headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    end
end
