# Serves an installed mini app's files to its sandboxed frame. The frame has an
# opaque origin and sends no cookies, so the signed, expiring token in the path
# is the only credential; it grants read access to this one app's files.
#
# The CSP `sandbox` directive gives every served document an opaque origin
# however it is opened, so a frame URL opened at top level (or an uploaded
# SVG) never runs as first-party Sure script with the viewer's cookies.
class MiniAppFramesController < ApplicationController
  # Same flags as the host page's iframe sandbox attribute; never allow-same-origin.
  FRAME_SANDBOX = "allow-scripts allow-forms allow-popups"
  NETWORK_ORIGIN_FORMAT = %r{\Ahttps://[a-z0-9.\-]+(:\d+)?\z}i

  skip_authentication
  skip_before_action :verify_authenticity_token
  skip_before_action :require_onboarding_and_upgrade
  skip_before_action :set_default_chat
  skip_before_action :detect_os

  def show
    mini_app = MiniApp.find_by_frame_token(params[:token])
    return head(:not_found) unless mini_app&.enabled? && mini_app.bundle?

    asset = mini_app.assets.find_by(path: params[:path].presence || mini_app.entry_path)
    return head(:not_found) unless asset

    set_frame_headers(mini_app)
    send_data asset.content, type: asset.content_type, disposition: :inline
  end

  private
    def set_frame_headers(mini_app)
      response.headers["Content-Security-Policy"] = content_security_policy(mini_app)
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Referrer-Policy"] = "no-referrer"
      response.headers["Access-Control-Allow-Origin"] = "*"
    end

    def content_security_policy(mini_app)
      base = "#{request.base_url}/mini_app_frames/#{params[:token]}/"
      origins = mini_app.network_origins.select { |origin| origin.to_s.match?(NETWORK_ORIGIN_FORMAT) }
      connect = origins.any? ? origins.join(" ") : "'none'"

      [
        "sandbox #{FRAME_SANDBOX}",
        "default-src 'none'",
        "script-src #{base} 'unsafe-inline'",
        "style-src #{base} 'unsafe-inline'",
        "img-src #{base} data: blob:",
        "font-src #{base} data:",
        "connect-src #{connect}",
        "form-action 'none'",
        "base-uri 'none'",
        "frame-ancestors 'self'"
      ].join("; ")
    end
end
