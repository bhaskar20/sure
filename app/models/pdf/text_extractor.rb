# The text of each page of a PDF, in order. Callers decide how to join the
# pages and how to handle a PDF the reader cannot open; errors propagate.
#
# A PDF without a real text layer (a scan, or an app export saved as images
# with only a "Page 1 of 17" footer as text) is read with local OCR when
# Pdf::Ocr is configured.
module Pdf::TextExtractor
  # Characters per page below which the text layer is only page furniture.
  MIN_TEXT_PER_PAGE = 50

  # ocr: false for callers inside a web request, where OCR's seconds (or its
  # timeout) would hold the request.
  def self.pages(content, max_pages: nil, ocr: true)
    pages = PDF::Reader.new(StringIO.new(content.to_s)).pages.map(&:text)
    pages = Pdf::Ocr.pages(content, max_pages: max_pages) || pages if ocr && image_only?(pages)
    max_pages ? pages.first(max_pages) : pages
  end

  def self.image_only?(pages)
    pages.sum { |text| text.gsub(/\s/, "").length } < MIN_TEXT_PER_PAGE * [ pages.size, 1 ].max
  end
end
