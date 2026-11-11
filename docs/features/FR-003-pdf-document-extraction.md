# FR-003: Extract any supported data from an uploaded PDF

| Field | Value |
| --- | --- |
| Status | Proposed |
| Priority | P1 |
| Owner | — |
| Branch | — |
| PR | — |
| Depends on | — |

## Problem

People get most of their financial records as PDFs: bank and card statements,
brokerage and pension statements, loan and mortgage statements, payslips,
utility and subscription bills, receipts, insurance and tax documents. Sure
can already turn a bank or credit card statement into transactions, but any
other PDF is only classified and summarized. The user then has to read it and
type the balances, holdings, trades or bills into Sure by hand.

## Requirements

- One upload flow takes any PDF. Sure works out what the document is and
  which core data it contains, without the user choosing a type first.
- Sure extracts every kind of core data it supports from the document:

  | Document examples | Data extracted |
  | --- | --- |
  | Bank and credit card statements | Transactions, opening/closing balance, statement period |
  | Brokerage, pension and retirement statements | Holdings (security, quantity, price, value), trades, cash balance |
  | Loan, mortgage and property statements | Balance or valuation, interest rate, payment amounts |
  | Payslips | Income transaction, with gross, deductions and net where available |
  | Utility, phone and subscription bills | A bill or recurring transaction (payee, amount, due date, frequency) |
  | Receipts and invoices | A transaction, or a match to an existing one, with the PDF attached |
  | Any document naming an account | The account it belongs to, or a proposal to create one |

- Extracted records are **categorized**: transactions get categories,
  merchants and tags using the family's existing categories and rules, and
  securities are matched to known securities.
- Extracted records are **matched to what already exists**: the right
  account (existing account matching), and transactions or balances already in
  Sure are recognized so they are not imported twice (existing reconciliation).
- The user **reviews before anything is saved**. The review shows each
  extracted record grouped by type, its confidence, and the page it came from,
  and lets the user edit, exclude or re-assign records, then publish.
- Publishing writes through the existing import machinery and models, so
  balances, syncs and holdings update as they would for any other import, and
  the import can be reverted.
- A document with several kinds of data (for example an investment statement
  with holdings, trades and a cash balance) produces all of them from one
  upload.
- Documents with no extractable core data (a contract, a letter) are still
  stored and summarized for the assistant, as today, and the user is told
  nothing was extracted.
- Text PDFs and scanned PDFs (images only) both work.
- It works with every configured LLM provider, including the local model in
  Sure Desktop, falling back to text extraction where a model cannot read
  PDFs or images directly.
- Failures and partial extractions are logged with `DebugLogEntry.capture`,
  with the document type and provider, so support can see what went wrong.

## Out of scope

- File types other than PDF (images, spreadsheets, email); a later feature can
  reuse the pipeline.
- Automatic publishing without review.
- Fetching documents automatically from email or bank portals.
- Filing tax returns or any legal interpretation of documents.

## What exists today

- `PdfImport` (`app/models/pdf_import.rb`) with `ProcessPdfJob`
  (`app/jobs/process_pdf_job.rb`): uploads a PDF, asks the LLM to classify and
  summarize it (`Provider::Openai::PdfProcessor`), adds it to the vector store,
  and, for `bank_statement` and `credit_card_statement` only, extracts
  transactions (`BankStatementExtractor`) into import rows for review.
- Document types today: `bank_statement`, `credit_card_statement`,
  `investment_statement`, `financial_document`, `contract`, `other`
  (`Import::DOCUMENT_TYPES`).
- `AccountStatement` with account matching, metadata detection and coverage;
  duplicate-upload detection; reconciliation of already-recorded entries.
- Text extraction (`Pdf::TextExtractor`, `pdf-reader`), and vision processing
  by converting pages to images when the model supports it.
- Existing importers for trades (`TradeImport`), accounts and valuations that
  the new extractors can feed.

## Recommended approach

Extend `PdfImport` rather than build a second pipeline:

1. **Classify** into a richer set of document types (add payslip, bill,
   receipt, loan statement, retirement statement, …), and return which data
   kinds the document contains.
2. **Extract per data kind** with one extractor each (transactions exist;
   add holdings, trades, balances/valuations, bills, account details), each
   with a strict JSON schema, so a document runs every extractor it needs.
3. **Normalize and categorize** extracted records with existing auto
   categorization, merchant detection, rules and security resolution.
4. **Match and reconcile** with existing account matching and reconciliation,
   extended to holdings, trades and balances.
5. **Review** in one screen with a section per data kind, then publish each
   kind through its existing import or model path inside one revertable
   import.

## Acceptance criteria

- [ ] Uploading a bank or credit card statement still produces transactions
      as today (no regression).
- [ ] An investment statement produces holdings, trades and cash balance for
      review, and publishing updates the account's holdings and balance.
- [ ] A loan or property statement produces a balance or valuation on the
      matched account.
- [ ] A payslip produces an income transaction; a bill produces a bill or
      recurring transaction; a receipt matches or creates a transaction with
      the PDF attached.
- [ ] Extracted transactions are categorized using the family's categories
      and rules.
- [ ] Records already in Sure are recognized and not imported twice.
- [ ] Nothing is saved until the user publishes, and a published import can
      be reverted.
- [ ] A scanned (image-only) PDF is extracted.
- [ ] Extraction works with the OpenAI-compatible and Anthropic providers and
      with Sure Desktop's local model, with a clear message when the
      configured model cannot handle the document.
- [ ] Each extractor has Minitest coverage with fixture PDFs and recorded
      (VCR) or stubbed LLM responses; lint, Biome and Brakeman pass.

## Touches

Expected areas; refine before building.

- `app/models/pdf_import.rb`, `app/models/import.rb` (`DOCUMENT_TYPES`),
  `app/jobs/process_pdf_job.rb`.
- `app/models/provider/openai/pdf_processor.rb`,
  `app/models/provider/openai/bank_statement_extractor.rb`, and new extractors
  beside it; the Anthropic provider's equivalents.
- `app/models/account_statement/` (matching, metadata), `app/models/pdf/`.
- Import review views and controllers under `app/views/imports/` and
  `app/controllers/import/`.
- Test fixtures: sample PDFs for each document type, with no real personal
  data.

## Decisions

None yet.

## Open questions

- **Which document types first?** Suggested order: investment and retirement
  statements, loan/property statements, bills, payslips, receipts.
- **OCR for scanned PDFs** when the model has no vision support, such as the
  small local models: bundle an OCR engine (for example Tesseract), or require
  a vision-capable model for scanned documents?
- **Unknown accounts:** create the account automatically during review, or
  only offer to create it?
- **Bills:** create recurring transactions, or the bills/goals objects the
  assistant already supports (`create_bill`)?
- **Receipt line items:** split the transaction by line item, or attach the
  PDF and record the total only?
- **Large documents:** a page limit, or chunked extraction for long annual
  statements?
- **Batch upload:** several PDFs at once in the first version?

## Blockers

Waiting on answers to the open questions about scope and OCR before moving to
`Ready`.

## Progress

- 2026-11-11: Request recorded, with a survey of the existing PDF import.

## Handoff

Not started.
