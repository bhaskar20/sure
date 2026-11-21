require "test_helper"

class Pdf::OcrTest < ActiveSupport::TestCase
  setup do
    Pdf::Ocr.clear_cache
    @dir = Dir.mktmpdir
    @command = File.join(@dir, "fake-ocr")
    # Prints two pages and records its arguments, as sure-ocr would.
    File.write(@command, <<~SH)
      #!/bin/sh
      echo "$@" >> "#{@dir}/calls"
      printf 'page one\\n\\fpage two\\n\\f'
    SH
    File.chmod(0o755, @command)
  end

  teardown do
    Pdf::Ocr.clear_cache
    FileUtils.rm_rf(@dir)
  end

  test "returns nil when no OCR command is configured" do
    with_env_overrides("PDF_OCR_COMMAND" => nil) do
      assert_not Pdf::Ocr.available?
      assert_nil Pdf::Ocr.pages("%PDF")
    end
  end

  test "reads each page from the command and reuses the result for the same document" do
    with_env_overrides("PDF_OCR_COMMAND" => @command) do
      assert_equal [ "page one", "page two" ], Pdf::Ocr.pages("%PDF one")
      assert_equal [ "page one", "page two" ], Pdf::Ocr.pages("%PDF one")
      Pdf::Ocr.pages("%PDF one", max_pages: 1)
    end

    calls = File.readlines(File.join(@dir, "calls"), chomp: true)
    assert_equal 2, calls.size
    assert_match(/\.pdf\z/, calls.first)
    assert_match(/\.pdf 1\z/, calls.second)
  end

  test "raises when the command fails" do
    File.write(@command, "#!/bin/sh\necho 'cannot open PDF' >&2\nexit 1\n")

    with_env_overrides("PDF_OCR_COMMAND" => @command) do
      error = assert_raises(Pdf::Ocr::Error) { Pdf::Ocr.pages("%PDF") }
      assert_match(/cannot open PDF/, error.message)
    end
  end

  test "kills a run that outlasts the timeout" do
    File.write(@command, "#!/bin/sh\necho started >> '#{@dir}/calls'\nsleep 30\n")
    Pdf::Ocr.stubs(:timeout).returns(1)

    with_env_overrides("PDF_OCR_COMMAND" => @command) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(Pdf::Ocr::Error) { Pdf::Ocr.pages("%PDF slow") }

      assert_match(/timed out/, error.message)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
    end
  end

  test "remembers a failure so the same document is not run again" do
    File.write(@command, "#!/bin/sh\necho run >> '#{@dir}/calls'\necho 'cannot open PDF' >&2\nexit 1\n")

    with_env_overrides("PDF_OCR_COMMAND" => @command) do
      2.times { assert_raises(Pdf::Ocr::Error) { Pdf::Ocr.pages("%PDF broken") } }
    end

    assert_equal 1, File.readlines(File.join(@dir, "calls")).size
  end

  test "times out when a child the helper started keeps its output open" do
    File.write(@command, "#!/bin/sh\nsleep 30 &\necho started\n")
    Pdf::Ocr.stubs(:timeout).returns(1)

    with_env_overrides("PDF_OCR_COMMAND" => @command) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(Pdf::Ocr::Error) { Pdf::Ocr.pages("%PDF lingering") }

      assert_match(/timed out/, error.message)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
    end
  end

  test "runs OCR again once a remembered failure is old" do
    File.write(@command, "#!/bin/sh\necho run >> '#{@dir}/calls'\nexit 1\n")

    with_env_overrides("PDF_OCR_COMMAND" => @command) do
      assert_raises(Pdf::Ocr::Error) { Pdf::Ocr.pages("%PDF flaky") }
      travel 11.minutes do
        assert_raises(Pdf::Ocr::Error) { Pdf::Ocr.pages("%PDF flaky") }
      end
    end

    assert_equal 2, File.readlines(File.join(@dir, "calls")).size
  end
end
