# One file of an installed mini app bundle, served to its sandboxed frame.
class MiniApp::Asset < ApplicationRecord
  MAX_PATH_LENGTH = 255
  DEFAULT_CONTENT_TYPE = "application/octet-stream".freeze
  CONTENT_TYPES = {
    ".html" => "text/html",
    ".htm" => "text/html",
    ".js" => "text/javascript",
    ".mjs" => "text/javascript",
    ".css" => "text/css",
    ".json" => "application/json",
    ".map" => "application/json",
    ".svg" => "image/svg+xml",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".ico" => "image/x-icon",
    ".woff" => "font/woff",
    ".woff2" => "font/woff2",
    ".ttf" => "font/ttf",
    ".otf" => "font/otf",
    ".wasm" => "application/wasm",
    ".txt" => "text/plain",
    ".md" => "text/markdown"
  }.freeze

  belongs_to :mini_app

  validates :path, presence: true, uniqueness: { scope: :mini_app_id }
  validates :content_type, presence: true
  validate :path_must_be_safe

  before_validation :set_byte_size

  class << self
    # A relative path inside the bundle: no leading slash, no backslashes,
    # no empty, "." or ".." segments and no control characters.
    def valid_path?(path)
      return false unless path.is_a?(String)
      return false if path.empty? || path.length > MAX_PATH_LENGTH
      return false if path.start_with?("/") || path.include?("\\") || path.match?(/[[:cntrl:]]/)
      path.split("/", -1).none? { |segment| segment.empty? || segment == "." || segment == ".." }
    end

    def content_type_for(path)
      CONTENT_TYPES.fetch(File.extname(path.to_s).downcase, DEFAULT_CONTENT_TYPE)
    end
  end

  def html?
    content_type == "text/html"
  end

  private
    def set_byte_size
      self.byte_size = content.to_s.bytesize
    end

    def path_must_be_safe
      errors.add(:path, :invalid) unless self.class.valid_path?(path)
    end
end
