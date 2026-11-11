# A mini app being developed on the same machine, loaded from a loopback URL.
# Only loopback hosts are ever contacted, so dev mode cannot be used to make
# Sure's server reach into other networks.
class MiniApp::DevServer
  class Invalid < MiniApp::Error; end

  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 3
  MAX_MANIFEST_BYTES = 256.kilobytes

  attr_reader :base_url

  class << self
    def loopback_url?(url)
      uri = URI.parse(url.to_s)
      (uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)) && LOOPBACK_HOSTS.include?(uri.hostname.to_s.downcase) &&
        uri.userinfo.nil?
    rescue URI::InvalidURIError
      false
    end
  end

  def initialize(url)
    invalid!(:not_loopback) unless self.class.loopback_url?(url)

    uri = URI.parse(url.to_s.strip)
    uri.query = nil
    uri.fragment = nil
    uri.path = "#{uri.path.to_s.sub(%r{/[^/]*\.[^/]*\z}, "").chomp("/")}/"
    @base_url = uri.to_s
  end

  def manifest_url
    URI.join(base_url, MiniApp::Package::MANIFEST_PATH).to_s
  end

  def fetch_manifest!
    MiniApp::Manifest.parse(fetch_manifest_body)
  rescue MiniApp::Manifest::Invalid => e
    raise Invalid.new(e.errors)
  end

  private
    def fetch_manifest_body
      uri = URI.parse(manifest_url)
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri, "Accept" => "application/json"))
      end

      invalid!(:bad_response, status: response.code) unless response.is_a?(Net::HTTPSuccess)
      body = response.body.to_s
      invalid!(:manifest_too_large) if body.bytesize > MAX_MANIFEST_BYTES
      body
    rescue SocketError, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
      invalid!(:unreachable, url: manifest_url)
    end

    def invalid!(key, **options)
      raise Invalid.new([ I18n.t("mini_app.dev_server.errors.#{key}", **options) ])
    end
end
