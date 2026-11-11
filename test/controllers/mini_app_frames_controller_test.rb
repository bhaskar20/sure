require "test_helper"

class MiniAppFramesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @mini_app = mini_apps(:recategorizer)
    @token = @mini_app.frame_token
  end

  test "serves the entry file without a session, with the frame's security headers" do
    get mini_app_frame_url(token: @token, path: "index.html")

    assert_response :success
    assert_equal "text/html", response.media_type
    assert_includes response.body, "Recategorizer"

    csp = response.headers["Content-Security-Policy"]
    base = "http://www.example.com/mini_app_frames/#{@token}/"
    assert_equal [
      "sandbox allow-scripts allow-forms allow-popups",
      "default-src 'none'",
      "script-src #{base} 'unsafe-inline'",
      "style-src #{base} 'unsafe-inline'",
      "img-src #{base} data: blob:",
      "font-src #{base} data:",
      "connect-src 'none'",
      "form-action 'none'",
      "base-uri 'none'",
      "frame-ancestors 'self'"
    ].join("; "), csp
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_match(/inline/, response.headers["Content-Disposition"])
  end

  test "serves the entry when no path is given" do
    get "/mini_app_frames/#{@token}"

    assert_response :success
    assert_includes response.body, "Recategorizer"
  end

  test "serves other bundle files with their content type" do
    get mini_app_frame_url(token: @token, path: "app.js")

    assert_response :success
    assert_equal "text/javascript", response.media_type
  end

  test "every served file is sandboxed to an opaque origin, even when opened at top level" do
    @mini_app.assets.create!(path: "logo.svg", content_type: "image/svg+xml",
                             content: %(<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>))

    [ "index.html", "app.js", "logo.svg" ].each do |path|
      get mini_app_frame_url(token: @token, path: path)

      assert_response :success
      directives = response.headers["Content-Security-Policy"].split(";").map(&:strip)
      sandbox = directives.find { |directive| directive.start_with?("sandbox") }
      assert_equal "sandbox allow-scripts allow-forms allow-popups", sandbox, path
      assert_not_includes sandbox, "allow-same-origin", path
    end
  end

  test "allows the manifest's network origins in connect-src" do
    @mini_app.update!(manifest: @mini_app.manifest.merge("network" => [ "https://api.example.com" ]))

    get mini_app_frame_url(token: @token, path: "index.html")

    assert_includes response.headers["Content-Security-Policy"], "connect-src https://api.example.com;"
  end

  test "missing files are not found" do
    get mini_app_frame_url(token: @token, path: "nope.js")

    assert_response :not_found
  end

  test "disabled apps are not served" do
    @mini_app.disable!

    get mini_app_frame_url(token: @token, path: "index.html")

    assert_response :not_found
  end

  test "garbage tokens are not found" do
    get mini_app_frame_url(token: "garbage", path: "index.html")

    assert_response :not_found
  end

  test "expired tokens are not found" do
    travel MiniApp::FRAME_TOKEN_EXPIRY + 1.minute do
      get mini_app_frame_url(token: @token, path: "index.html")
    end

    assert_response :not_found
  end

  test "a token for a deleted app is not found" do
    @mini_app.destroy!

    get mini_app_frame_url(token: @token, path: "index.html")

    assert_response :not_found
  end
end
