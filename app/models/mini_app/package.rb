# Reads an uploaded mini app zip into a manifest and a list of files, refusing
# anything that could escape the bundle or exhaust memory.
class MiniApp::Package
  class Invalid < MiniApp::Error; end

  MAX_ZIP_BYTES = 10.megabytes
  MAX_UNPACKED_BYTES = 20.megabytes
  MAX_FILES = 300
  MANIFEST_PATH = "miniapp.json".freeze
  IGNORED_SEGMENTS = %w[__MACOSX .DS_Store].freeze

  def initialize(io)
    @io = io
  end

  def read!
    data = read_zip_bytes
    files = unpack(data)
    files = strip_wrapping_folder(files)

    manifest_source = files.delete(MANIFEST_PATH) || invalid!(:missing_manifest)
    manifest = MiniApp::Manifest.parse(manifest_source)
    invalid!(:missing_entry, entry: manifest.entry) unless files.key?(manifest.entry)

    {
      manifest: manifest,
      assets: files.map do |path, content|
        { path: path, content_type: MiniApp::Asset.content_type_for(path), content: content }
      end,
      sha256: Digest::SHA256.hexdigest(data)
    }
  rescue MiniApp::Manifest::Invalid => e
    raise Invalid.new(e.errors)
  end

  private
    attr_reader :io

    def read_zip_bytes
      io.rewind if io.respond_to?(:rewind)
      data = io.read(MAX_ZIP_BYTES + 1).to_s.b
      invalid!(:empty) if data.empty?
      invalid!(:too_large, size: human_size(MAX_ZIP_BYTES)) if data.bytesize > MAX_ZIP_BYTES
      data
    end

    def unpack(data)
      files = {}
      unpacked_bytes = 0

      Zip::File.open_buffer(StringIO.new(data)) do |zip|
        zip.each do |entry|
          name = entry.name.to_s
          next if ignored?(name)
          invalid!(:unsafe_path, path: name) if entry.symlink?
          next if entry.directory?
          invalid!(:unsafe_path, path: name) unless entry.file? && MiniApp::Asset.valid_path?(name)
          invalid!(:too_many_files, count: MAX_FILES) if files.size >= MAX_FILES

          remaining = MAX_UNPACKED_BYTES - unpacked_bytes
          invalid!(:unpacked_too_large, size: human_size(MAX_UNPACKED_BYTES)) if entry.size.to_i > remaining

          content = entry.get_input_stream { |stream| stream.read(remaining + 1) }.to_s.b
          invalid!(:unpacked_too_large, size: human_size(MAX_UNPACKED_BYTES)) if content.bytesize > remaining

          unpacked_bytes += content.bytesize
          files[name] = content
        end
      end

      files
    rescue Zip::Error, Zlib::Error
      invalid!(:not_a_zip)
    end

    # Archives made by zipping a folder put everything under one directory;
    # accept that layout by dropping the shared prefix.
    def strip_wrapping_folder(files)
      return files if files.key?(MANIFEST_PATH)

      prefixes = files.keys.map { |path| path.split("/", 2) }
      return files unless prefixes.all? { |parts| parts.size == 2 }
      return files unless prefixes.map(&:first).uniq.size == 1

      files.transform_keys { |path| path.split("/", 2).last }
    end

    def ignored?(name)
      name.split("/").any? { |segment| IGNORED_SEGMENTS.include?(segment) }
    end

    def human_size(bytes)
      ActiveSupport::NumberHelper.number_to_human_size(bytes)
    end

    def invalid!(key, **options)
      raise Invalid.new([ I18n.t("mini_app.package.errors.#{key}", **options) ])
    end
end
