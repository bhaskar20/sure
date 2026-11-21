require "test_helper"

class Pdf::TextExtractorTest < ActiveSupport::TestCase
  setup do
    @content = file_fixture("account_statements/trade_republic_it_2026_04.pdf").binread
  end

  test "returns the text of each page" do
    pages = Pdf::TextExtractor.pages(@content)

    assert pages.any?
    assert_match(/Trade Republic/i, pages.join("\n"))
  end

  test "stops after max_pages" do
    PDF::Reader.any_instance.stubs(:pages).returns(%w[one two three].map { |text| stub(text: text) })

    assert_equal %w[one two], Pdf::TextExtractor.pages(@content, max_pages: 2)
  end

  test "raises for content that is not a PDF" do
    assert_raises(PDF::Reader::MalformedPDFError) { Pdf::TextExtractor.pages("not a pdf") }
  end

  test "reads a PDF whose only text is page numbers with OCR" do
    PDF::Reader.any_instance.stubs(:pages).returns([ stub(text: "Page 1 of 2"), stub(text: " Page 2 of 2") ])
    Pdf::Ocr.expects(:pages).with(@content, max_pages: nil).returns([ "scanned one", "scanned two" ])

    assert_equal [ "scanned one", "scanned two" ], Pdf::TextExtractor.pages(@content)
  end

  test "keeps the text layer when there is one, and the empty pages when OCR is off" do
    Pdf::Ocr.expects(:pages).never
    assert Pdf::TextExtractor.pages(@content).any?(&:present?)

    PDF::Reader.any_instance.stubs(:pages).returns([ stub(text: "") ])
    Pdf::Ocr.unstub(:pages)
    Pdf::Ocr.stubs(:pages).returns(nil)
    assert_equal [ "" ], Pdf::TextExtractor.pages(@content)
  end

  test "leaves OCR out when the caller asks it to" do
    PDF::Reader.any_instance.stubs(:pages).returns([ stub(text: "Page 1 of 1") ])
    Pdf::Ocr.expects(:pages).never

    assert_equal [ "Page 1 of 1" ], Pdf::TextExtractor.pages(@content, ocr: false)
  end
end
