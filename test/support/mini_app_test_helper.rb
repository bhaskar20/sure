module MiniAppTestHelper
  def mini_app_manifest(overrides = {})
    {
      "id" => "test-app",
      "name" => "Test App",
      "version" => "1.0.0",
      "permissions" => %w[transactions:read categories:read]
    }.merge(overrides.deep_stringify_keys)
  end

  # Builds a zip in memory. `files` maps archive paths to contents; a
  # miniapp.json is added from `manifest` unless `files` already has one.
  def mini_app_zip(files = {}, manifest: mini_app_manifest, entry: true)
    files = files.dup
    files["miniapp.json"] ||= manifest.to_json if manifest
    files["index.html"] ||= "<!doctype html><p>hi</p>" if entry

    buffer = Zip::OutputStream.write_buffer(StringIO.new) do |zip|
      files.each do |path, content|
        zip.put_next_entry(path)
        zip.write(content)
      end
    end
    StringIO.new(buffer.string)
  end

  def mini_app_zip_with_symlink(link_name, target)
    buffer = Zip::OutputStream.write_buffer(StringIO.new) do |zip|
      zip.put_next_entry("miniapp.json")
      zip.write(mini_app_manifest.to_json)
      zip.put_next_entry("index.html")
      zip.write("<p>hi</p>")

      entry = Zip::Entry.new("", link_name)
      entry.fstype = Zip::FSTYPE_UNIX
      entry.instance_variable_set(:@ftype, :symlink)
      zip.put_next_entry(entry)
      zip.write(target)
    end
    StringIO.new(buffer.string)
  end
end
