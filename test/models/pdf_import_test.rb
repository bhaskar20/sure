require "test_helper"

class PdfImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @import = imports(:pdf)
    @processed_import = imports(:pdf_processed)
    @import_with_rows = imports(:pdf_with_rows)
  end

  test "processing without a model that can read statements fails with the router's reason" do
    use_ai_routes(extract_pdf: %w[embed/nomic-embed-text])
    Provider::Registry.expects(:preferred_llm_provider).never

    error = assert_raises(Provider::Error) { @import.process_with_ai }

    assert_equal Ai::Availability.unavailable(:extract_pdf, :capability_missing).message_for(nil), error.message
  end

  test "a key cleared after the availability check is the same refusal, not a NoMethodError" do
    Ai.stubs(:availability).returns(Ai::Availability.available(:extract_pdf))
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    error = assert_raises(Provider::Error) { @import.process_with_ai }

    assert_equal Ai::Availability.unavailable(:extract_pdf, :not_configured).message_for(nil), error.message
  end

  test "pdf_uploaded? returns false when no file attached" do
    assert_not @import.pdf_uploaded?
  end

  test "pdf_uploaded? returns true for statement backed import" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)

    assert import.pdf_uploaded?
    assert import.statement_backed?
    assert_equal statement.original_file.download, import.pdf_file_content
    assert_equal statement.filename, import.pdf_filename
  end

  test "ai_processed? returns false when no summary present" do
    assert_not @import.ai_processed?
  end

  test "ai_processed? returns true when summary present" do
    assert @processed_import.ai_processed?
  end

  test "uploaded? delegates to pdf_uploaded?" do
    assert_not @import.uploaded?
  end

  test "configured? requires AI processed and rows" do
    assert_not @import.configured?
    assert_not @processed_import.configured?
    assert @import_with_rows.configured?
  end

  test "cleaned? requires configured and valid rows" do
    assert_not @import.cleaned?
    assert_not @processed_import.cleaned?
  end

  test "publishable? requires bank statement with cleaned rows and valid mappings" do
    assert_not @import.publishable?
    assert_not @processed_import.publishable?
  end

  test "status detail cleaned check requires account and transaction statement" do
    @import_with_rows.update!(account: accounts(:depository), document_type: "bank_statement")

    assert @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 0)
    assert_not @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 1)

    @import_with_rows.update!(account: nil)
    assert_not @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 0)

    @import_with_rows.update!(account: accounts(:depository), document_type: "other")
    assert_not @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 0)
  end

  test "column_keys returns transaction columns" do
    assert_equal %i[date amount name category notes], @import.column_keys
  end

  test "required_column_keys returns date and amount" do
    assert_equal %i[date amount], @import.required_column_keys
  end

  test "document_type validates against allowed types" do
    @import.document_type = "bank_statement"
    assert @import.valid?

    @import.document_type = "invalid_type"
    assert_not @import.valid?
    assert @import.errors[:document_type].present?
  end

  test "document_type allows nil" do
    @import.document_type = nil
    assert @import.valid?
  end

  test "process_with_ai uses a provider that can only read extracted text" do
    Ai.stubs(:availability).returns(Ai::Availability.available(:extract_pdf))
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)
    result = Provider::LlmConcept::PdfProcessingResult.new(summary: "Monthly statement", document_type: "bank_statement", extracted_data: {})
    provider = mock
    provider.stubs(:can_process_pdf?).returns(true)
    provider.expects(:process_pdf).returns(Provider::Response.new(success?: true, data: result, error: nil))
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    import.process_with_ai

    assert_equal "Monthly statement", import.reload.ai_summary
    assert_equal "bank_statement", import.document_type
  end

  test "process_with_ai corrects a card statement the model called a bank statement" do
    Ai.stubs(:availability).returns(Ai::Availability.available(:extract_pdf))
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)
    result = Provider::LlmConcept::PdfProcessingResult.new(summary: "Monthly statement", document_type: "bank_statement", extracted_data: {})
    provider = mock
    provider.stubs(:can_process_pdf?).returns(true)
    provider.expects(:process_pdf).returns(Provider::Response.new(success?: true, data: result, error: nil))
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    Pdf::TextExtractor.stubs(:pages).returns([ "Credit Limit 5,000.00  Minimum Amount Due 120.00  Payment Due Date 15 Dec" ])

    returned = import.process_with_ai

    assert_equal "credit_card_statement", import.reload.document_type
    assert_equal "credit_card_statement", returned.document_type, "the job routes on the returned type"
  end

  test "process_with_ai refuses a provider that cannot read PDFs at all" do
    Ai.stubs(:availability).returns(Ai::Availability.available(:extract_pdf))
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)
    provider = mock
    provider.stubs(:can_process_pdf?).returns(false)
    provider.expects(:process_pdf).never
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    error = assert_raises(Provider::Error) { import.process_with_ai }
    assert_equal I18n.t("imports.pdf_import.errors.provider_no_pdf_support"), error.message
  end

  test "extract_transactions reads a reconciling text statement without the LLM" do
    use_no_ai
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)
    import.update!(document_type: "credit_card_statement")
    Pdf::TextExtractor.stubs(:pages).returns([ <<~TEXT ])
      STATEMENT DATE 15 Nov 2026
                PREVIOUS BALANCE                      40.00
      07 NOV    BILL PAYMENT                          40.00 CR
      08 NOV    COFFEE PLACE                           5.50
      09 NOV    BOOK SHOP                             12.00
      GRAND TOTAL FOR ALL CARD ACCOUNTS:              17.50
    TEXT
    Provider::Registry.expects(:preferred_llm_provider).never

    data = import.extract_transactions

    assert_equal [ 40.0, -5.5, -12.0 ], data["transactions"].map { |t| t["amount"] }
    assert_equal 17.5, data["closing_balance"]
    assert_equal 3, import.reload.extracted_transactions.size
  end

  test "extract_transactions reads a dated transaction history without the LLM" do
    use_no_ai
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)
    import.update!(document_type: "bank_statement")
    Pdf::TextExtractor.stubs(:pages).returns([ <<~TEXT ])
      Saturday, 15 Nov 2026
      COFFEE PLACE                              SGD - 4.50
      BOOK SHOP                                 SGD - 12.00
      Thursday, 13 Nov 2026
      SALARY EXAMPLE CO                         SGD 2,500.00
    TEXT
    Provider::Registry.expects(:preferred_llm_provider).never

    data = import.extract_transactions

    assert_equal [ -4.5, -12.0, 2500.0 ], data["transactions"].map { |t| t["amount"] }
    assert_equal %w[2026-11-15 2026-11-15 2026-11-13], data["transactions"].map { |t| t["date"] }
  end

  test "extract_transactions falls back to the LLM when the text does not reconcile" do
    Ai.stubs(:availability).returns(Ai::Availability.available(:extract_pdf))
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)
    import.update!(document_type: "bank_statement")
    Pdf::TextExtractor.stubs(:pages).returns([ "Page 1 of 1" ])
    provider = mock
    provider.expects(:extract_bank_statement).returns(Provider::Response.new(
      success?: true,
      data: { transactions: [ { date: "2026-11-02", amount: -9.0, name: "Lunch" } ] },
      error: nil
    ))
    provider.stubs(:structured_json).returns(Provider::Response.new(success?: false, data: nil, error: Provider::Error.new("offline")))
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    data = import.extract_transactions

    assert_equal [ "Lunch" ], data["transactions"].map { |t| t["name"] }
  end

  test "process_with_ai_later enqueues ProcessPdfJob" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)

    assert_enqueued_with job: ProcessPdfJob, args: [ import ] do
      assert import.process_with_ai_later
    end

    assert_equal "importing", import.reload.status
  end

  test "process_with_ai_later does not enqueue duplicate jobs while importing" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)

    assert_enqueued_jobs 1, only: ProcessPdfJob do
      assert import.process_with_ai_later
      assert_not import.reload.process_with_ai_later
    end

    assert_equal "importing", import.reload.status
  end

  test "process_with_ai_later does not claim import without pdf content" do
    assert_no_enqueued_jobs only: ProcessPdfJob do
      assert_not @import.process_with_ai_later
    end

    assert_equal "pending", @import.reload.status
  end

  test "process_with_ai_later resets pending when enqueue fails" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)
    ProcessPdfJob.stubs(:perform_later).raises(StandardError, "queue offline")

    assert_not import.process_with_ai_later
    assert_equal "pending", import.reload.status
  end

  test "generate_rows_from_extracted_data creates import rows" do
    import = imports(:pdf_with_rows)
    import.rows.destroy_all
    import.update_column(:rows_count, 0)

    import.generate_rows_from_extracted_data

    assert_equal 2, import.rows.count
    assert_equal 2, import.rows_count

    coffee_row = import.rows.find_by(name: "Coffee Shop")
    assert_not_nil coffee_row
    assert_equal "-50.0", coffee_row.amount
    assert_equal "Food & Drink", coffee_row.category

    salary_row = import.rows.find_by(name: "Salary")
    assert_not_nil salary_row
    assert_equal "1500.0", salary_row.amount
  end

  test "generate_rows_from_extracted_data does nothing without extracted transactions" do
    @import.generate_rows_from_extracted_data
    assert_equal 0, @import.rows.count
  end

  test "extracted_transactions returns transactions from extracted_data" do
    assert_equal 2, @import_with_rows.extracted_transactions.size
    assert_equal "Coffee Shop", @import_with_rows.extracted_transactions.first["name"]
  end

  test "extracted_transactions returns empty array when no data" do
    assert_equal [], @import.extracted_transactions
  end

  test "has_extracted_transactions? returns true with transactions" do
    assert @import_with_rows.has_extracted_transactions?
  end

  test "has_extracted_transactions? returns false without transactions" do
    assert_not @import.has_extracted_transactions?
  end

  test "mapping_steps is empty when no categories in rows" do
    # PDF imports use direct account selection in UI, not AccountMapping
    assert_equal [], @import.mapping_steps
  end

  test "mapping_steps includes CategoryMapping when rows have categories" do
    @import_with_rows.rows.create!(
      source_row_number: 1,
      date: "01/15/2024",
      amount: -50.00,
      currency: "USD",
      name: "Test Transaction",
      category: "Groceries"
    )
    assert_equal [ Import::CategoryMapping ], @import_with_rows.mapping_steps
  end

  test "mapping_steps does not include AccountMapping even when account is nil" do
    # PDF imports handle account selection via direct UI, not mapping system
    assert_nil @import.account
    assert_not_includes @import.mapping_steps, Import::AccountMapping
  end

  test "destroying import purges attached pdf_file" do
    @import.pdf_file.attach(
      io: StringIO.new("fake-pdf-content"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )

    attachment_id = @import.pdf_file.id
    assert ActiveStorage::Attachment.exists?(attachment_id)

    perform_enqueued_jobs do
      @import.destroy!
    end

    assert_not ActiveStorage::Attachment.exists?(attachment_id)
  end

  test "destroying statement backed import keeps statement file" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)
    attachment_id = statement.original_file.id

    perform_enqueued_jobs do
      import.destroy!
    end

    assert ActiveStorage::Attachment.exists?(attachment_id)
  end

  test "statement backed import prevents source statement destroy" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)

    assert_no_difference "AccountStatement.count" do
      assert_not statement.destroy
    end

    assert_equal statement, import.reload.account_statement
  end

  test "statement backed import memoizes pdf content" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)
    statement.original_file.expects(:download).once.returns("%PDF-test")

    assert_equal "%PDF-test", import.pdf_file_content
    assert_equal "%PDF-test", import.pdf_file_content
  end

  test "statement backed import reuse requires current account and date format" do
    statement = create_pdf_statement
    stale_import = PdfImport.create_from_statement!(statement: statement)
    formats = Family::DATE_FORMATS.map(&:last)
    alternate_date_format = (formats - [ statement.family.date_format ]).first || "#{statement.family.date_format}-alternate"
    stale_import.update!(account: nil, date_format: alternate_date_format)

    fresh_import = PdfImport.create_from_statement!(statement: statement)

    assert_not_equal stale_import, fresh_import
    assert_equal statement.account, fresh_import.account
    assert_equal statement.family.date_format, fresh_import.date_format
  end

  test "statement backed import reuses matching reusable import" do
    statement = create_pdf_statement
    existing_import = PdfImport.create_from_statement!(statement: statement)

    assert_equal existing_import, PdfImport.create_from_statement!(statement: statement)
  end

  test "assigning account links statement backed import statement" do
    statement = create_pdf_statement(account: nil)
    import = PdfImport.create_from_statement!(statement: statement)
    account = accounts(:depository)

    import.assign_account!(account)

    assert_equal account, import.reload.account
    assert_equal account, statement.reload.account
    assert statement.linked?
  end

  test "statement backed import requires pdf statement" do
    csv_statement = AccountStatement.create_from_upload!(
      family: @import.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    import = PdfImport.new(family: @import.family, account_statement: csv_statement)

    assert_not import.valid?
    assert import.errors[:account_statement].present?
  end

  test "statement backed import requires statement from same family" do
    statement = AccountStatement.create_from_upload!(
      family: families(:empty),
      account: nil,
      file: uploaded_file(
        filename: "other_family_statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )
    import = PdfImport.new(family: @import.family, account_statement: statement)

    assert_not import.valid?
    assert import.errors[:account_statement].present?
  end

  test "suggests the account of the statement's type that carries its last four digits" do
    import = statement_import(document_type: "credit_card_statement", last4: "4321")
    card = accounts(:credit_card)
    card.update!(name: "Everyday Card ••4321")
    accounts(:depository).update!(name: "Savings 4321")

    suggestion = import.account_suggestion(@import.family.accounts)

    assert_equal card, suggestion.account
    assert_equal "4321", suggestion.last4
  end

  test "suggests nothing once an account is chosen, or for documents that are not statements" do
    accounts(:credit_card).update!(name: "Card ••4321")
    import = statement_import(document_type: "credit_card_statement", last4: "4321")

    import.document_type = "financial_document"
    assert_nil import.account_suggestion(@import.family.accounts)

    import.document_type = "credit_card_statement"
    import.account = accounts(:credit_card)
    assert_nil import.account_suggestion(@import.family.accounts)
  end

  test "suggests the account created from the import when nothing else matches" do
    import = statement_import(document_type: "bank_statement", last4: nil)
    assert_nil import.account_suggestion(@import.family.accounts)

    created = @import.family.accounts.create!(name: "New savings", balance: 0, currency: "USD", accountable: Depository.new)

    assert_equal created, import.account_suggestion(@import.family.accounts).account
  end

  test "does not suggest another card at the same bank whose digits differ" do
    import = statement_import(document_type: "credit_card_statement", last4: "4321", institution: "Example Bank")
    accounts(:credit_card).update!(name: "Example Bank Altitude ••9999", institution_name: "Example Bank")

    assert_nil import.account_suggestion(@import.family.accounts)
  end

  test "does not take a newly created account from another bank for this statement" do
    import = statement_import(document_type: "bank_statement", last4: nil, institution: "Example Bank")
    @import.family.accounts.create!(name: "Other savings", institution_name: "Another Bank", balance: 0, currency: "USD", accountable: Depository.new)

    assert_nil import.account_suggestion(@import.family.accounts)
  end

  test "a year in an account's name does not stop it being suggested" do
    import = statement_import(document_type: "credit_card_statement", last4: "4321", institution: "Example Bank")
    card = accounts(:credit_card)
    card.update!(name: "Example Bank Visa 2024", institution_name: "Example Bank")

    assert_equal card, import.account_suggestion(@import.family.accounts)&.account
  end

  test "does not take a newly created account named for another bank" do
    import = statement_import(document_type: "bank_statement", last4: nil, institution: "Example Bank")
    @import.family.accounts.create!(name: "Other Lender 360 Savings", balance: 0, currency: "USD", accountable: Depository.new)

    assert_nil import.account_suggestion(@import.family.accounts)
  end

  test "does not suggest another bank's card that happens to show the same digits" do
    import = statement_import(document_type: "credit_card_statement", last4: "2024", institution: "Example Bank")
    accounts(:credit_card).update!(name: "Other Lender Rewards ••2024", institution_name: "Other Lender")

    assert_nil import.account_suggestion(@import.family.accounts)
  end

  test "does not take a newly created account that only shares a place name with the bank" do
    import = statement_import(document_type: "credit_card_statement", last4: nil, institution: "Standard Chartered Bank (Singapore) Limited")
    @import.family.accounts.create!(name: "Citibank Singapore Rewards", balance: 0, currency: "USD", accountable: CreditCard.new)

    assert_nil import.account_suggestion(@import.family.accounts)
  end

  test "new account starts at the statement's opening balance the day before its period" do
    import = statement_import(document_type: "credit_card_statement", last4: "4321", institution: "Example Bank")
    import.update!(extracted_data: { "period" => { "start_date" => "2026-10-16", "end_date" => "2026-11-15" }, "opening_balance" => 387.24, "transactions" => [] })

    attributes = import.new_account_attributes

    assert_equal "Example Bank Credit card ••4321", attributes[:name]
    assert_equal "Example Bank", attributes[:institution_name]
    assert_equal BigDecimal("387.24"), attributes[:balance]
    assert_equal Date.new(2026, 10, 15), attributes[:opening_balance_date]
  end

  test "new account takes the currency printed on the statement, even as a symbol" do
    import = statement_import(document_type: "credit_card_statement", last4: nil)
    output = import.account_statement.sanitized_parser_output.merge("extracted_currency" => "S$")
    import.account_statement.update_columns(sanitized_parser_output: output)

    assert_equal "SGD", import.new_account_attributes[:currency]
    assert_equal "EUR", PdfImport.iso_currency("eur")
    assert_nil PdfImport.iso_currency("XX$")
  end

  test "new account leaves a printed opening balance it cannot read to the user" do
    import = statement_import(document_type: "bank_statement", last4: nil)
    import.update!(extracted_data: { "period" => { "start_date" => "2026-10-01" }, "opening_balance" => "1,050.00 DR", "transactions" => [] })
    import.account_statement.update_columns(opening_balance: nil)

    assert_nil import.new_account_attributes[:balance]
  end

  test "new account leaves the balance to the user when the statement has no opening balance" do
    import = statement_import(document_type: "bank_statement", last4: nil)
    import.update!(extracted_data: { "period" => { "start_date" => "2026-10-01" }, "transactions" => [] })
    import.account_statement.update_columns(opening_balance: nil)

    attributes = import.new_account_attributes

    assert_nil attributes[:balance]
    assert_nil attributes[:opening_balance_date]
    assert_equal "Account", attributes[:name]
  end

  test "new account takes the product name and subtype the enricher read" do
    bank = statement_import(document_type: "bank_statement", last4: "4060", institution: "DBS")
    bank.update!(extracted_data: { "account_details" => { "account_name" => "Multiplier Account", "subtype" => "savings" }, "transactions" => [] })

    assert_equal "DBS Multiplier Account ••4060", bank.new_account_attributes[:name]
    assert_equal "savings", bank.new_account_attributes[:subtype]
  end

  test "new card account takes the card terms the enricher read" do
    card = statement_import(document_type: "credit_card_statement", last4: nil, institution: "DBS")
    card.update!(extracted_data: { "account_details" => { "available_credit" => 800.0, "apr" => 26.9, "due_day" => 3 }, "transactions" => [] })
    card.account_statement.update_columns(period_end_on: Date.new(2026, 11, 14))

    assert_equal({ available_credit: 800.0, apr: 26.9, due_day: 3, statement_close_day: 14 }, card.new_account_attributes[:accountable_attributes])
  end

  test "linking a statement fills the account details it is missing and keeps the rest" do
    import = statement_import(document_type: "credit_card_statement", last4: nil, institution: "DBS")
    import.update!(extracted_data: { "account_details" => { "available_credit" => 800.0, "minimum_payment" => 25.0, "due_day" => 3 }, "transactions" => [] })
    card = @import.family.accounts.create!(name: "Card", balance: 0, currency: "USD", institution_name: nil,
      accountable: CreditCard.new(due_day: 20, minimum_payment: 10))
    card.accountable.lock_attr!(:minimum_payment)

    assert import.assign_account!(card)

    card.reload
    assert_equal "DBS", card.institution_name
    assert_equal 800, card.accountable.available_credit
    assert_equal 10, card.accountable.minimum_payment, "a locked value is the user's"
    assert_equal 20, card.accountable.due_day, "a day the user set stays"
  end

  private

    def statement_import(document_type:, last4:, institution: nil)
      statement = create_pdf_statement(account: nil)
      output = (statement.sanitized_parser_output || {}).merge("extracted_institution" => institution).compact
      statement.update_columns(account_last4_hint: last4, institution_name_hint: nil, account_name_hint: nil, sanitized_parser_output: output)
      import = PdfImport.create_from_statement!(statement: statement.reload)
      import.update!(document_type: document_type, account: nil)
      import
    end

    def create_pdf_statement(account: accounts(:depository))
      AccountStatement.create_from_upload!(
        family: @import.family,
        account: account,
        file: uploaded_file(
          filename: "sample_bank_statement.pdf",
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread
        )
      )
    end
end
