# The AI steps of a PDF import: reading the document, then extracting a statement's
# transactions. PdfImport keeps the record, its state and its rows.
class PdfImport::AiProcessor
  def initialize(pdf_import)
    @pdf_import = pdf_import
  end

  def process
    require_ai_for_extraction!
    provider = route_provider
    # Vision or, for a model without it (a local one), the PDF's extracted text.
    raise Provider::Error, I18n.t("imports.pdf_import.errors.provider_no_pdf_support") unless provider.can_process_pdf?

    response = provider.process_pdf(
      pdf_content: pdf_import.pdf_file_content,
      family: pdf_import.family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown PDF processing error"
      raise Provider::Error, error_message
    end

    result = response.data
    result = result.with(document_type: checked_document_type(result.document_type)) if result.respond_to?(:with)
    pdf_import.update!(
      ai_summary: result.summary,
      document_type: result.document_type
    )

    result
  end

  def extract_transactions
    return unless pdf_import.statement_with_transactions?

    # BankStatementExtractor returns symbol keys, but every reader here (and in
    # generate_rows_from_extracted_data) digs with strings. jsonb keeps the hash
    # exactly as assigned until the record is reloaded, so without this the
    # in-memory read comes back empty and the import produces no rows at all.
    data = (extract_transactions_with_rules || extract_transactions_with_model).deep_stringify_keys
    pdf_import.update!(extracted_data: data)
    data
  end

  # A statement whose rows reconcile against its own balances, or a dated
  # transaction history, is read exactly by rules; only the rest needs a model.
  def extract_transactions_with_rules
    pages = Pdf::TextExtractor.pages(pdf_import.pdf_file_content)
    result = Pdf::StatementParser.parse(pages, liability: pdf_import.credit_card_statement?) ||
      Pdf::TransactionHistoryParser.parse(pages)
    return unless result

    Rails.logger.info("PdfImport #{pdf_import.id}: rule-based parser read #{result.transactions.size} rows")
    {
      transactions: result.transactions,
      period: result.period,
      opening_balance: result.opening_balance&.to_f,
      closing_balance: result.closing_balance&.to_f
    }
  rescue StandardError => e
    Rails.logger.warn("PdfImport #{pdf_import.id}: statement parser failed (#{e.class}), using the model")
    nil
  end

  def extract_transactions_with_model
    require_ai_for_extraction!
    provider = route_provider

    response = provider.extract_bank_statement(
      pdf_content: pdf_import.pdf_file_content,
      family: pdf_import.family,
      liability: pdf_import.credit_card_statement?
    )

    unless response.success?
      error_message = response.error&.message || "Unknown extraction error"
      raise Provider::Error, error_message
    end

    response.data
  end

  private
    attr_reader :pdf_import

    STATEMENT_TYPES = %w[bank_statement credit_card_statement].freeze

    # The model calls a statement a statement reliably, but mixes up a card's and
    # a bank account's often enough that the document's own wording decides
    # between the two. Its text layer is enough; OCR is left to extraction.
    def checked_document_type(document_type)
      return document_type unless document_type.in?(STATEMENT_TYPES)

      text = Pdf::TextExtractor.pages(pdf_import.pdf_file_content, max_pages: 3, ocr: false).join("\n")
      detected = Pdf::StatementKind.detect(text)
      if detected && detected != document_type
        Rails.logger.info("PdfImport #{pdf_import.id}: statement wording reads as #{detected}, not #{document_type}")
      end
      detected || document_type
    rescue StandardError => e
      Rails.logger.warn("PdfImport #{pdf_import.id}: could not check statement type (#{e.class})")
      document_type
    end

    # Asks the router whether a statement can be read, before the job calls a model. The
    # message is the router's reason, worded for the family member who uploaded it.
    def require_ai_for_extraction!
      availability = Ai.availability(:extract_pdf, family: pdf_import.family)
      raise Provider::Error, availability.message_for(nil) unless availability.available?
    end

    # The first provider in extract_pdf's route. Settings can clear the last key between the
    # availability check and this lookup, so a missing provider is the same refusal.
    def route_provider
      Provider::Registry.preferred_llm_provider or
        raise Provider::Error, Ai::Availability.unavailable(:extract_pdf, :not_configured).message_for(nil)
    end
end
