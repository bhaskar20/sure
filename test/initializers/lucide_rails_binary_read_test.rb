require "test_helper"

class LucideRailsBinaryReadTest < ActiveSupport::TestCase
  setup do
    @original = LucideRails::IconProvider.instance_variable_get(:@memory)
    LucideRails::IconProvider.instance_variable_set(:@memory, nil)
  end

  teardown do
    LucideRails::IconProvider.instance_variable_set(:@memory, @original)
  end

  test "loads the icon archive in binary mode" do
    archive = LucideRails::GEM_ROOT.join("icons/stripped.bin.gz")
    bytes = File.binread(archive)
    File.expects(:binread).with(archive).returns(bytes)
    File.expects(:read).with(archive).never

    svg = LucideRails::IconProvider.icon("house")

    assert_includes svg, "<path"
  end
end
