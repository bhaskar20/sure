# lucide-rails (0.7.x) loads its gzipped icon archive with File.read, which on
# Windows opens the file in text mode, corrupts the binary data, and makes every
# page that renders an icon fail with Zlib::GzipFile::Error (seen in the Sure
# Desktop Windows build). Read it in binary mode; correct on every platform.
Rails.application.config.to_prepare do
  next unless defined?(LucideRails::IconProvider)

  LucideRails::IconProvider.singleton_class.prepend(Module.new do
    def memory
      @memory ||= begin
        archive = LucideRails::GEM_ROOT.join("icons/stripped.bin.gz")
        data = ActiveSupport::Gzip.decompress(File.binread(archive))
        data.split("\x00").to_h { |entry| entry.split(",", 2) }
      end
    end
  end)
end
