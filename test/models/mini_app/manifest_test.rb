require "test_helper"

class MiniApp::ManifestTest < ActiveSupport::TestCase
  include MiniAppTestHelper

  test "parses a minimal manifest and fills defaults" do
    manifest = MiniApp::Manifest.parse(mini_app_manifest.to_json)

    assert_equal "test-app", manifest.id
    assert_equal "Test App", manifest.name
    assert_equal "index.html", manifest.entry
    assert_equal "blocks", manifest.icon
    assert_equal [ "page" ], manifest.slots
    assert_equal [], manifest.network
    assert_equal %w[transactions:read categories:read], manifest.permissions
    assert_equal "test-app", manifest.to_h["id"]
  end

  test "accepts a hash with symbol keys and a numeric version" do
    manifest = MiniApp::Manifest.parse(id: "sym-app", name: "Sym", version: 2)

    assert_equal "2", manifest.version
  end

  test "collects every error at once" do
    error = assert_raises(MiniApp::Manifest::Invalid) do
      MiniApp::Manifest.parse(mini_app_manifest("id" => "Bad ID!", "name" => "", "version" => "1 0"))
    end

    assert_equal 3, error.errors.size
  end

  test "rejects malformed JSON and non-objects" do
    assert_raises(MiniApp::Manifest::Invalid) { MiniApp::Manifest.parse("{nope") }
    assert_raises(MiniApp::Manifest::Invalid) { MiniApp::Manifest.parse("[1, 2]") }
  end

  test "rejects unknown permissions and slots other than page" do
    error = assert_raises(MiniApp::Manifest::Invalid) do
      MiniApp::Manifest.parse(mini_app_manifest("permissions" => %w[transactions:read admin:everything], "slots" => %w[page widget]))
    end

    assert_match "admin:everything", error.errors.join
    assert_match "widget", error.errors.join
  end

  test "rejects an entry outside the bundle and overlong text" do
    error = assert_raises(MiniApp::Manifest::Invalid) do
      MiniApp::Manifest.parse(mini_app_manifest("entry" => "../index.html", "description" => "x" * 501))
    end

    assert_equal 2, error.errors.size
  end

  test "normalizes https network origins" do
    manifest = MiniApp::Manifest.parse(mini_app_manifest("network" => [ "https://API.example.com/", "https://api.example.com:8443" ]))

    assert_equal [ "https://api.example.com", "https://api.example.com:8443" ], manifest.network
  end

  test "rejects network entries that are not plain https origins" do
    [ "http://api.example.com", "https://api.example.com/path", "https://*.example.com", "https://user@api.example.com", "*" ].each do |origin|
      assert_raises(MiniApp::Manifest::Invalid, origin) do
        MiniApp::Manifest.parse(mini_app_manifest("network" => [ origin ]))
      end
    end
  end
end
