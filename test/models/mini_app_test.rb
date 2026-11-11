require "test_helper"

class MiniAppTest < ActiveSupport::TestCase
  include MiniAppTestHelper

  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @app = mini_apps(:recategorizer)
  end

  test "installs a bundle with its files and no grants" do
    io = mini_app_zip({ "app.js" => "1" })

    app = MiniApp.install_bundle!(family: @family, user: @admin, io: io)

    assert app.persisted?
    assert app.enabled?
    assert app.bundle?
    assert_equal "test-app", app.app_key
    assert_equal @admin, app.installed_by
    assert_equal Digest::SHA256.hexdigest(io.string), app.bundle_sha256
    assert_equal [], app.granted_permissions
    assert app.confirm_writes?
    assert_equal %w[transactions:read categories:read], app.requested_permissions
    assert_equal %w[app.js index.html], app.assets.order(:path).pluck(:path)
    assert_equal 1, app.assets.find_by(path: "app.js").byte_size
  end

  test "upgrading replaces files and manifest, keeps storage, drops grants no longer requested and asks before writes again" do
    @app.update!(write_policy: "allow")
    @app.disable!
    record_ids = @app.records.ids
    activity_count = @app.activities.count
    manifest = mini_app_manifest("id" => "recategorizer", "version" => "2.0.0", "permissions" => %w[transactions:read categories:write rules:read])

    upgraded = assert_no_difference "MiniApp.count" do
      MiniApp.install_bundle!(family: @family, user: users(:family_member), io: mini_app_zip({ "v2.js" => "2" }, manifest: manifest),
                              upgrade: true)
    end

    assert_equal @app.id, upgraded.id
    upgraded.reload
    assert_equal "2.0.0", upgraded.version
    assert_equal %w[categories:write transactions:read], upgraded.granted_permissions.sort
    assert_equal %w[index.html v2.js], upgraded.assets.order(:path).pluck(:path)
    assert_equal record_ids, upgraded.records.ids
    assert_equal activity_count, upgraded.activities.count
    assert upgraded.disabled?
    assert upgraded.confirm_writes?
    assert_equal @admin, upgraded.installed_by
  end

  test "a bundle reusing an installed app's id is refused unless the admin confirms the upgrade" do
    @app.update!(write_policy: "allow")
    before = @app.reload.attributes.slice("version", "manifest", "granted_permissions", "write_policy", "bundle_sha256")
    asset_ids = @app.assets.ids
    manifest = mini_app_manifest("id" => "recategorizer", "version" => "9.9.9", "permissions" => %w[transactions:read])

    error = assert_raises(MiniApp::Error) do
      MiniApp.install_bundle!(family: @family, user: @admin, io: mini_app_zip({ "evil.js" => "1" }, manifest: manifest))
    end

    assert_match "already installed", error.message
    assert_equal before, @app.reload.attributes.slice("version", "manifest", "granted_permissions", "write_policy", "bundle_sha256")
    assert_equal asset_ids.sort, @app.assets.ids.sort
  end

  test "an upgrade cannot switch an app between bundle and dev server" do
    stub_request(:get, "http://localhost:5173/miniapp.json")
      .to_return(status: 200, body: mini_app_manifest("id" => "recategorizer").to_json, headers: { "Content-Type" => "application/json" })

    error = assert_raises(MiniApp::Error) do
      MiniApp.install_dev_server!(family: @family, user: @admin, url: "http://localhost:5173/", upgrade: true)
    end

    assert_match "different source", error.message
    assert @app.reload.bundle?
    assert_nil @app.dev_url
  end

  test "a failed install leaves nothing behind" do
    assert_no_difference [ "MiniApp.count", "MiniApp::Asset.count" ] do
      assert_raises(MiniApp::Package::Invalid) do
        MiniApp.install_bundle!(family: @family, user: @admin, io: mini_app_zip({ "../x" => "1" }))
      end
    end
  end

  test "the same app can be installed in two families independently" do
    other = MiniApp.install_bundle!(family: families(:empty), user: users(:intro_user),
                                    io: mini_app_zip({}, manifest: mini_app_manifest("id" => "recategorizer")))

    assert_not_equal @app.id, other.id
    assert_equal [], other.granted_permissions
  end

  test "grants are limited to requested catalog permissions" do
    @app.update_grants!(permissions: %w[transactions:read tags:read rules:write made:up], write_policy: "allow")

    assert_equal %w[transactions:read tags:read], @app.reload.granted_permissions
    assert_not @app.confirm_writes?
    assert @app.granted?("tags:read")
    assert_not @app.granted?("rules:write")
  end

  test "updating grants keeps the write policy unless one is given" do
    @app.update_grants!(permissions: [ "transactions:read" ])

    assert @app.reload.confirm_writes?
    assert_raises(ActiveRecord::RecordInvalid) { @app.update_grants!(permissions: [], write_policy: "always") }
  end

  test "rejects grants outside the requested permissions" do
    @app.granted_permissions = [ "accounts:read" ]

    assert_not @app.valid?
    assert @app.errors.of_kind?(:granted_permissions, :not_requested)
  end

  test "effective permissions strip writes for guests and are empty outside the family" do
    member = users(:family_member)
    assert_equal @app.granted_permissions, @app.effective_permissions_for(member)

    member.role = "guest"
    assert_equal %w[transactions:read categories:read], @app.effective_permissions_for(member)

    assert_equal [], @app.effective_permissions_for(users(:intro_user))
    assert_equal [], @app.effective_permissions_for(nil)
  end

  test "enable and disable toggle status" do
    @app.disable!
    assert @app.reload.disabled?
    assert_equal [ mini_apps(:budget_peek), @app ].map(&:id).sort, @family.mini_apps.where(status: "disabled").ids.sort

    @app.enable!
    assert @app.reload.enabled?
    assert_includes MiniApp.enabled, @app
  end

  test "manifest helpers" do
    assert_equal "index.html", @app.entry_path
    assert_equal [], @app.network_origins
    assert_not @app.dev_server?
  end

  test "frame tokens round-trip and expire after 12 hours" do
    token = @app.frame_token

    assert_no_match %r{[/+=]}, token
    assert_equal @app, MiniApp.find_by_frame_token(token)

    travel 11.hours do
      assert_equal @app, MiniApp.find_by_frame_token(token)
    end
    travel 13.hours do
      assert_nil MiniApp.find_by_frame_token(token)
    end
  end

  test "frame tokens cannot be forged or reused for another purpose" do
    assert_nil MiniApp.find_by_frame_token(nil)
    assert_nil MiniApp.find_by_frame_token("garbage")
    assert_nil MiniApp.find_by_frame_token(@app.signed_id(purpose: :other))
    assert_nil MiniApp.find_by_frame_token(@app.frame_token.reverse)
  end

  test "frame tokens stop working once the app is removed" do
    token = @app.frame_token
    @app.destroy!

    assert_nil MiniApp.find_by_frame_token(token)
  end

  test "destroying removes files, storage and activity" do
    assert_difference({ "MiniApp::Asset.count" => -2, "MiniApp::Record.count" => -1, "MiniApp::Activity.count" => -2 }) do
      @app.destroy!
    end
  end

  test "dev mode is available in development and Sure Desktop only" do
    assert MiniApp.dev_mode_available?

    Rails.env.stubs(:test?).returns(false)
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    with_env_overrides("SURE_DESKTOP" => nil) do
      assert_not MiniApp.dev_mode_available?, "self-hosted servers must not offer dev mode"
    end

    with_env_overrides("SURE_DESKTOP" => "1") do
      assert MiniApp.dev_mode_available?
    end
  end

  test "installs from a loopback dev server" do
    stub_request(:get, "http://localhost:5173/miniapp.json")
      .to_return(status: 200, body: mini_app_manifest("id" => "dev-app").to_json, headers: { "Content-Type" => "application/json" })

    app = MiniApp.install_dev_server!(family: @family, user: @admin, url: "http://localhost:5173/index.html")

    assert app.dev_server?
    assert_equal "http://localhost:5173/", app.dev_url
    assert_equal "dev-app", app.app_key
    assert_empty app.assets
  end

  test "dev server installs refuse non-loopback URLs without a request" do
    [ "http://example.com/", "http://10.0.0.1:3000/", "file:///etc/passwd", "http://user@localhost/", "http://localhost.evil.com/" ].each do |url|
      assert_raises(MiniApp::DevServer::Invalid, url) do
        MiniApp.install_dev_server!(family: @family, user: @admin, url: url)
      end
    end
    assert_not_requested :any, /.*/
  end

  test "dev server installs report an unreachable server" do
    stub_request(:get, "http://127.0.0.1:4000/app/miniapp.json").to_raise(Errno::ECONNREFUSED)

    error = assert_raises(MiniApp::DevServer::Invalid) do
      MiniApp.install_dev_server!(family: @family, user: @admin, url: "http://127.0.0.1:4000/app")
    end
    assert_match "Could not reach", error.message
  end

  test "dev server installs are refused when dev mode is unavailable" do
    MiniApp.stubs(:dev_mode_available?).returns(false)

    assert_raises(MiniApp::DevServer::Invalid) do
      MiniApp.install_dev_server!(family: @family, user: @admin, url: "http://localhost:5173/")
    end
  end

  test "activity log records outcomes newest first" do
    activity = MiniApp::Activity.log!(mini_app: @app, user: @admin, rpc_method: "tools/call", tool: "update_transaction",
                                      permission: "transactions:write", outcome: :declined, write: true,
                                      error_message: "x" * 2_000)

    assert activity.declined?
    assert_equal 1_000, activity.error_message.length
    assert_equal activity, @app.activities.recent.first
    assert_equal 2, @app.activities.recent(2).size
    assert_raises(ActiveRecord::RecordInvalid) { MiniApp::Activity.log!(mini_app: @app, rpc_method: "ping", outcome: "maybe") }
  end
end
