# A validated `miniapp.json`. Parsing never trusts the input: unknown keys are
# dropped, every value is type-checked, and errors are collected so a developer
# sees every problem at once.
class MiniApp::Manifest
  class Invalid < MiniApp::Error; end

  ID_FORMAT = /\A[a-z0-9][a-z0-9.\-]{2,63}\z/
  VERSION_FORMAT = /\A[0-9A-Za-z.+\-]{1,32}\z/
  ICON_FORMAT = /\A[a-z0-9\-]{1,40}\z/
  MAX_NAME_LENGTH = 60
  MAX_DESCRIPTION_LENGTH = 500
  MAX_AUTHOR_LENGTH = 100
  MAX_NETWORK_ORIGINS = 20
  SLOTS = %w[page].freeze
  DEFAULT_ENTRY = "index.html".freeze
  DEFAULT_ICON = "blocks".freeze

  attr_reader :id, :name, :version, :description, :entry, :icon, :permissions,
              :slots, :network, :author, :homepage

  class << self
    def parse(input)
      hash = coerce_hash(input)
      new(hash)
    end

    private
      def coerce_hash(input)
        hash = case input
        when Hash then input
        when String then JSON.parse(input)
        else raise Invalid.new([ error(:not_an_object) ])
        end
        raise Invalid.new([ error(:not_an_object) ]) unless hash.is_a?(Hash)
        hash.deep_stringify_keys
      rescue JSON::ParserError
        raise Invalid.new([ error(:malformed_json) ])
      end

      def error(key, **options)
        I18n.t("mini_app.manifest.errors.#{key}", **options)
      end
  end

  def initialize(hash)
    @errors = []
    @id = parse_id(hash["id"])
    @name = parse_string(hash["name"], :name, required: true, max: MAX_NAME_LENGTH)
    @version = parse_version(hash["version"])
    @description = parse_string(hash["description"], :description, max: MAX_DESCRIPTION_LENGTH)
    @entry = parse_entry(hash.fetch("entry", DEFAULT_ENTRY))
    @icon = parse_icon(hash.fetch("icon", DEFAULT_ICON))
    @permissions = parse_permissions(hash.fetch("permissions", []))
    @slots = parse_slots(hash.fetch("slots", SLOTS))
    @network = parse_network(hash.fetch("network", []))
    @author = parse_string(hash["author"], :author, max: MAX_AUTHOR_LENGTH)
    @homepage = parse_homepage(hash["homepage"])

    raise Invalid.new(@errors) if @errors.any?
  end

  def to_h
    {
      "id" => id,
      "name" => name,
      "version" => version,
      "description" => description,
      "entry" => entry,
      "icon" => icon,
      "permissions" => permissions,
      "slots" => slots,
      "network" => network,
      "author" => author,
      "homepage" => homepage
    }.compact
  end

  private
    def add_error(key, **options)
      @errors << I18n.t("mini_app.manifest.errors.#{key}", **options)
      nil
    end

    def parse_id(value)
      return add_error(:invalid_id) unless value.is_a?(String) && value.match?(ID_FORMAT)
      value
    end

    def parse_string(value, field, required: false, max:)
      if value.nil? || value == ""
        return required ? add_error(:blank, field: field) : nil
      end
      return add_error(:not_a_string, field: field) unless value.is_a?(String)
      return add_error(:too_long, field: field, count: max) if value.length > max
      value.strip
    end

    def parse_version(value)
      value = value.to_s if value.is_a?(Numeric)
      return add_error(:invalid_version) unless value.is_a?(String) && value.match?(VERSION_FORMAT)
      value
    end

    def parse_entry(value)
      return add_error(:invalid_entry) unless value.is_a?(String) && MiniApp::Asset.valid_path?(value)
      value
    end

    def parse_icon(value)
      return add_error(:invalid_icon) unless value.is_a?(String) && value.match?(ICON_FORMAT)
      value
    end

    def parse_permissions(value)
      return add_error(:not_a_list, field: :permissions) unless string_list?(value)
      unknown = value - MiniApp::Permission.all
      add_error(:unknown_permissions, permissions: unknown.join(", ")) if unknown.any?
      value.uniq
    end

    def parse_slots(value)
      return add_error(:not_a_list, field: :slots) unless string_list?(value)
      unsupported = value - SLOTS
      add_error(:unsupported_slots, slots: unsupported.join(", ")) if unsupported.any?
      value.empty? ? SLOTS.dup : value.uniq
    end

    def parse_network(value)
      return add_error(:not_a_list, field: :network) unless string_list?(value)
      return add_error(:too_many_origins, count: MAX_NETWORK_ORIGINS) if value.size > MAX_NETWORK_ORIGINS

      value.filter_map do |origin|
        normalized = normalize_origin(origin)
        normalized || add_error(:invalid_origin, origin: origin)
      end.uniq
    end

    def parse_homepage(value)
      return nil if value.nil? || value == ""
      uri = URI.parse(value.to_s)
      return add_error(:invalid_homepage) unless uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP)
      return add_error(:invalid_homepage) if uri.host.blank?
      value
    rescue URI::InvalidURIError
      add_error(:invalid_homepage)
    end

    # An origin is "https://host" or "https://host:port" with no path, query,
    # credentials or wildcard, so it can be placed in a CSP connect-src safely.
    def normalize_origin(origin)
      uri = URI.parse(origin)
      return nil unless uri.is_a?(URI::HTTPS) && uri.host.present?
      return nil if uri.userinfo || uri.query || uri.fragment
      return nil unless uri.path.blank? || uri.path == "/"
      return nil unless uri.host.match?(/\A[a-z0-9.\-]+\z/i)

      port = uri.port == 443 ? "" : ":#{uri.port}"
      "https://#{uri.host.downcase}#{port}"
    rescue URI::InvalidURIError
      nil
    end

    def string_list?(value)
      value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
    end
end
