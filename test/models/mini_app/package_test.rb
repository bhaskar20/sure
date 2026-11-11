require "test_helper"

class MiniApp::PackageTest < ActiveSupport::TestCase
  include MiniAppTestHelper

  test "reads a bundle into a manifest, assets and a checksum" do
    io = mini_app_zip({ "app.js" => "console.log(1)", "img/logo.svg" => "<svg/>" })
    expected_sha = Digest::SHA256.hexdigest(io.string)

    result = MiniApp::Package.new(io).read!

    assert_equal "test-app", result[:manifest].id
    assert_equal expected_sha, result[:sha256]
    assets = result[:assets].index_by { |asset| asset[:path] }
    assert_equal %w[app.js img/logo.svg index.html], assets.keys.sort
    assert_equal "text/javascript", assets["app.js"][:content_type]
    assert_equal "image/svg+xml", assets["img/logo.svg"][:content_type]
    assert_equal "text/html", assets["index.html"][:content_type]
  end

  test "strips a single wrapping folder" do
    io = mini_app_zip({ "my-app/miniapp.json" => mini_app_manifest.to_json, "my-app/index.html" => "<p>hi</p>" }, manifest: nil, entry: false)

    result = MiniApp::Package.new(io).read!

    assert_equal [ "index.html" ], result[:assets].map { |asset| asset[:path] }
  end

  test "ignores macOS metadata entries" do
    io = mini_app_zip({ "__MACOSX/._index.html" => "junk", ".DS_Store" => "junk" })

    assert_equal [ "index.html" ], MiniApp::Package.new(io).read![:assets].map { |asset| asset[:path] }
  end

  test "rejects path traversal" do
    assert_invalid mini_app_zip({ "../evil.js" => "x" }), "../evil.js"
    assert_invalid mini_app_zip({ "js/../../evil.js" => "x" }), "evil.js"
  end

  test "rejects absolute paths" do
    io = StringIO.new(mini_app_zip({ "Xevil.js" => "x" }).string.gsub("Xevil.js", "/evil.js"))

    assert_invalid io, "/evil.js"
  end

  test "rejects symlinks" do
    assert_invalid mini_app_zip_with_symlink("link.js", "/etc/passwd"), "link.js"
  end

  test "rejects a missing manifest or entry file" do
    assert_invalid mini_app_zip({}, manifest: nil), "miniapp.json"
    assert_invalid mini_app_zip({}, entry: false), "index.html"
  end

  test "reports manifest errors" do
    assert_invalid mini_app_zip({}, manifest: mini_app_manifest("id" => "!")), "\"id\""
  end

  test "rejects data that is not a zip" do
    assert_invalid StringIO.new("plain text"), "not a valid zip"
    assert_invalid StringIO.new(""), "empty"
  end

  test "rejects an oversized upload before unpacking" do
    io = StringIO.new("0" * (MiniApp::Package::MAX_ZIP_BYTES + 1))
    Zip::File.expects(:open_buffer).never

    assert_invalid io, "larger than"
  end

  test "rejects too many files" do
    files = (1..MiniApp::Package::MAX_FILES).to_h { |i| [ "f#{i}.txt", "x" ] }

    assert_invalid mini_app_zip(files), "more than #{MiniApp::Package::MAX_FILES} files"
  end

  test "rejects bundles that unpack beyond the size limit" do
    io = mini_app_zip({ "big.txt" => "a" * (MiniApp::Package::MAX_UNPACKED_BYTES + 1) })
    assert io.string.bytesize < MiniApp::Package::MAX_ZIP_BYTES

    assert_invalid io, "add up to more than"
  end

  private
    def assert_invalid(io, message_fragment)
      error = assert_raises(MiniApp::Package::Invalid) { MiniApp::Package.new(io).read! }
      assert_match message_fragment, error.errors.join(" ")
    end
end
