# Reads the text of a scanned or image-only PDF with a local OCR command.
#
# PDF_OCR_COMMAND names an executable that takes a PDF path (and optionally a
# maximum page count) and prints each page's text followed by a form feed.
# Sure Desktop sets it to its bundled sure-ocr helper (Apple Vision, on
# device); self-hosted installs can point it at their own wrapper (for example
# around tesseract). Unset means no OCR.
#
# Results are kept in memory for a few documents, since one import reads the
# same PDF several times (summary, transactions). A failure is kept for a few
# minutes, long enough for one import and short enough for a retry to run OCR
# again.
module Pdf::Ocr
  TIMEOUT = 300
  CACHE_SIZE = 4
  FAILURE_TTL = 10.minutes

  class Error < StandardError; end

  @cache = {}
  @mutex = Mutex.new

  class << self
    def available?
      command.present? && File.executable?(command)
    end

    # The text of each page, or nil when OCR is not configured.
    def pages(content, max_pages: nil)
      return nil unless available?

      key = [ command, Digest::SHA256.hexdigest(content.to_s), max_pages ]
      cached = @mutex.synchronize { @cache[key] }
      cached = nil if cached&.dig(:error) && cached[:at] < FAILURE_TTL.ago
      cached ||= remember(key) do
        { pages: run(content, max_pages) }
      rescue Error => e
        { error: e, at: Time.current }
      end
      raise cached[:error] if cached[:error]

      cached[:pages]
    end

    def clear_cache
      @mutex.synchronize { @cache.clear }
    end

    private
      def command
        ENV["PDF_OCR_COMMAND"]
      end

      def timeout = TIMEOUT

      def remember(key)
        value = yield
        @mutex.synchronize do
          @cache.delete(@cache.keys.first) if @cache.size >= CACHE_SIZE
          @cache[key] = value
        end
      end

      # The helper runs in its own process group so a hung run, and anything
      # it started, is killed at the timeout instead of left running.
      def run(content, max_pages)
        Tempfile.create([ "ocr", ".pdf" ], binmode: true) do |file|
          file.write(content)
          file.flush

          Open3.popen3(command, file.path, *max_pages&.to_s, pgroup: true) do |stdin, stdout, stderr, wait|
            stdin.close
            out = Thread.new { stdout.read }
            err = Thread.new { stderr.read }
            # After a timeout the pipes close under these readers.
            [ out, err ].each { |reader| reader.report_on_exception = false }

            # One deadline for the process and its output: a child it leaves
            # behind holding the pipes would otherwise block the reads.
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
            remaining = -> { [ deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0 ].max }
            finished = wait.join(remaining.call) && out.join(remaining.call) && err.join(remaining.call)
            unless finished
              kill_group(wait.pid)
              raise Error, "OCR timed out after #{timeout}s"
            end

            raise Error, "OCR failed: #{err.value.to_s.strip.truncate(200)}" unless wait.value.success?

            out.value.force_encoding(Encoding::UTF_8).scrub.split("\f").map(&:rstrip)
          end
        end
      end

      # pgroup: true makes the helper's pid its group id, which stays valid
      # for killing what it left behind after it has exited itself.
      def kill_group(pid)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
  end
end
