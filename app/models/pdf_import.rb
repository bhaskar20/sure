class PdfImport < Import
  has_one_attached :pdf_file, dependent: :purge_later

  validates :document_type, inclusion: { in: DOCUMENT_TYPES }, allow_nil: true
  validate :account_statement_matches_import

  # Ahead of the rows and entries being destroyed, while the rows still say
  # what each linked counterpart was before.
  before_destroy :release_linked_records!, prepend: true

  class << self
    # PdfImport's importing status doubles as a processing claim: the AI
    # extraction claim from process_with_ai_later (no rows yet) or a regular
    # publish (rows being written). A lost job leaves the claim held forever —
    # ProcessPdfJob's own reclaim only runs when the job is redelivered.
    # Which claim died is observable from the data: no rows attached → the AI
    # claim, reclaim to pending so the user can re-trigger; rows attached →
    # the publish died after import!'s commit, so finalize as complete
    # (pending would let the user publish the same extracted rows again —
    # PdfImport#import! always builds new transactions). Stuck reverts go to
    # revert_failed like every other import, keeping the retry path exposed.
    def clean
      where(status: [ :importing, :reverting ])
        .where("updated_at < ?", Import::STUCK_AFTER.ago)
        .includes(:family)
        .find_each do |pdf_import|
          reap_stuck!(pdf_import)
        rescue => e
          # One bad record must not abort the sweep for the rest.
          Rails.logger.error("PdfImport.clean failed for #{pdf_import.id}: #{e.class}: #{e.message}")
          Sentry.capture_exception(e) { |scope| scope.set_tags(record_type: name, record_id: pdf_import.id) } if defined?(Sentry)
        end
    end

    def reap_stuck!(pdf_import)
      needs_sync = false
      # Read before the lock — see Import.reap_stuck!.
      family = pdf_import.family

      pdf_import.with_lock do
        next unless pdf_import.reapable_since?(Import::STUCK_AFTER.ago)

        previous_status = pdf_import.status
        if previous_status == "reverting"
          pdf_import.update!(status: :revert_failed, error: Import.interrupted_error_message)
        elsif pdf_import.data_committed?
          pdf_import.update!(status: :complete, error: nil)
          needs_sync = true
        else
          pdf_import.update!(status: :pending)
        end

        DebugLogEntry.capture(
          category: "background_jobs",
          level: "warn",
          message: "Reclaimed PdfImport stuck in #{previous_status} for over #{Import::STUCK_AFTER.inspect} (→ #{pdf_import.status})",
          source: name,
          family: family,
          metadata: { record_type: name, record_id: pdf_import.id, previous_status: previous_status, new_status: pdf_import.status }
        )
      end

      # Outside the row lock — see Import.reap_stuck!.
      family.sync_later if needs_sync
    end

    def create_from_upload!(family:, file:, user:)
      statement = AccountStatement.create_from_prepared_upload!(
        family: family,
        account: nil,
        prepared_upload: AccountStatement.prepare_upload!(file)
      )

      create_from_statement!(statement: statement)
    rescue AccountStatement::DuplicateUploadError => e
      raise unless e.statement.manageable_by?(user)

      create_from_statement!(statement: e.statement)
    end

    def create_from_statement!(statement:)
      reusable_import = statement.latest_reusable_pdf_import
      return reusable_import if reusable_import &&
                                reusable_import.account_id == statement.account_id &&
                                reusable_import.date_format == statement.family.date_format

      create!(family: statement.family, account: statement.account, account_statement: statement, date_format: statement.family.date_format, status: :pending)
    end
  end

  # A PdfImport's importing status is a processing claim (AI extraction or
  # publish). Release a lost claim back to pending so the user can re-trigger
  # processing, mirroring ProcessPdfJob's own reclaim; lost reverts keep the
  # base revert_failed behavior.
  def force_fail!(error_message = Import.lost_error_message)
    return super if reverting?

    with_lock do
      return false unless presumed_lost?

      update!(status: :pending)
    end

    true
  end

  def import!
    raise "Account required for PDF import" unless account.present?

    transaction do
      mappings.each(&:create_mappable!)

      # Rows were already filtered against existing records when they were
      # generated, but a provider sync can land in between, so check again here
      # the way TransactionImport#import! does.
      adapter = Account::ProviderImportAdapter.new(account)
      # Entries this statement already consumed during row generation are spoken
      # for. Without excluding them, a statement carrying two same-amount
      # transactions where the account held only one would re-match the surviving
      # row against that same entry and silently drop a genuinely new
      # transaction. Newly synced entries are still caught, because only the
      # already-reconciled ones are excluded.
      claimed = reconciled_entries.pluck(:id)
      reconciled_now = []
      reconciled_at = Time.current

      to_link = []
      new_transactions = rows.filter_map do |row|
        if (existing = already_recorded_entry(adapter, row, claimed))
          claimed << existing.id
          reconciled_now << existing
          next
        end

        counterparty = counterparty_publish_attributes(row)
        transaction = Transaction.new(
          category: counterparty ? nil : mappings.categories.mappable_for(row.category),
          kind: counterparty&.dig(:kind) || "standard",
          entry: Entry.new(
            account: account,
            date: row.date_iso,
            amount: row.signed_amount,
            name: row.name,
            currency: row.currency,
            notes: row.notes,
            import: self,
            import_locked: true,
            # Born reconciled: the statement being imported is the evidence.
            # Set by id rather than association so activerecord-import writes the
            # column directly on the recursive insert.
            reconciled_at: reconciled_at,
            reconciled_by_statement_id: account_statement&.id
          )
        )
        to_link << [ row, transaction ] if counterparty&.dig(:link)
        transaction
      end

      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
      reconcile_entries!(reconciled_now, at: reconciled_at)
      link_counterparts!(to_link)
    end
  end

  # Accounts beyond the import's own that reverting or deleting it changes:
  # the other side of each transfer its transactions are part of. Before
  # publishing there are none; prepare_counterparty_for_publish! keeps only
  # links the publisher may make.
  def preexisting_target_account_ids
    transaction_ids = entries.where(entryable_type: "Transaction").select(:entryable_id)
    counterpart_ids = Transfer.where(outflow_transaction_id: transaction_ids).select(:inflow_transaction_id)
    other_side_ids = Transfer.where(inflow_transaction_id: transaction_ids).select(:outflow_transaction_id)

    Entry.where(entryable_type: "Transaction")
      .where(entryable_id: counterpart_ids).or(Entry.where(entryable_type: "Transaction", entryable_id: other_side_ids))
      .distinct.pluck(:account_id)
  end

  # Rows are edited only while the import waits to be published.
  def configuration_locked?
    !(pending? || failed?)
  end

  # Run as the publisher clicks Publish: a member without preview access
  # publishes plain lines, and a line is only linked to an account the
  # publisher may write to.
  def prepare_counterparty_for_publish!(user)
    return clear_counterparty_classification! unless user&.preview_features_enabled?

    linkable = counterparty_accounts_for(user).unscope(:order).pluck(:id)
    rows.where(counterparty_class: "internal_tracked")
      .where("counterparty_account_id IS NULL OR counterparty_account_id NOT IN (?)", linkable.presence || [ nil ])
      .update_all(counterparty_class: "unknown", counterparty_entry_id: nil)
  end

  # Statement lines are classified as internal or external only while a family
  # member has opted into preview features; the review shows the result only
  # to members who opted in themselves.
  def counterparty_classification_enabled?
    account.present? && family.preview_features_enabled?
  end

  # Drops every classification so publishing imports the lines as plain
  # transactions, for a member who cannot see the classification.
  def clear_counterparty_classification!
    rows.where.not(counterparty_class: nil).update_all(
      counterparty_class: nil, counterparty_account_id: nil, counterparty_entry_id: nil,
      counterparty_confidence: nil, counterparty_reasons: [], counterparty_user_set: false, counterparty_restore: {}
    )
  end

  # Accounts a reviewer may name as the other side of a line: ones they can
  # write to, since publishing links a transaction there.
  def counterparty_accounts_for(user)
    family.accounts.visible.writable_by(user).where.not(id: account_id).alphabetically
  end

  # Counted the way publishing by this reviewer will treat each line: one
  # linked to an account they cannot link to needs a decision.
  def counterparty_summary(user)
    visible_ids = counterparty_accounts_for(user).unscope(:order).pluck(:id).to_set
    counts = Hash.new(0)
    rows.pluck(:counterparty_class, :counterparty_account_id).each do |klass, account_id|
      klass = "unknown" if klass == "internal_tracked" && !visible_ids.include?(account_id)
      counts[klass] += 1
    end
    total = counts.values.sum
    {
      internal: counts["internal_tracked"] + counts["internal_untracked"],
      needs_decision: counts["unknown"],
      total: total,
      classified: total - counts[nil]
    }
  end

  # Re-targeting is destructive: it releases the statement's evidence on the
  # account being left and rebuilds the rows from scratch. Returns false rather
  # than doing any of that when the import is no longer re-targetable, so a
  # back-button or replayed PATCH cannot unwind a published import.
  def assign_account!(account)
    with_lock do
      return false unless reassignable?

      previous_account_id = account_id
      update!(account: account)

      if (statement = account_statement)
        statement.lock!
        statement.link_to_account!(account) if statement.account_id != account.id
      end

      next true if previous_account_id == account.id

      # Matching is per-account, so anything reconciled against the old account
      # is no longer evidence-backed, and the rows have to be judged again.
      release_reconciliations!(previous_account_id)
      if has_extracted_transactions?
        generate_rows_from_extracted_data
        sync_mappings
        refresh_status_after_regeneration!
      end

      true
    end
  end

  # A published import's entries already live in the account it was published
  # to, and a running job owns the record while it is importing or reverting.
  # An import that reconciled every line is still re-targetable: it is complete
  # but committed nothing of its own, and the user may well have picked the
  # wrong account.
  def reassignable?
    !data_committed? && !importing? && !reverting?
  end

  def pdf_uploaded?
    statement_backed? || pdf_file.attached?
  end

  def ai_processed?
    ai_summary.present?
  end

  def process_with_ai_later
    return false unless with_lock { pending? && !ai_processed? && rows_count.zero? && pdf_uploaded? && update!(status: :importing) }

    begin
      ProcessPdfJob.perform_later(self)
      true
    rescue StandardError => e
      Rails.logger.error("Failed to enqueue PDF processing for import #{id}: #{e.class.name} - #{e.message}")
      reload.with_lock { update!(status: :pending) }
      false
    end
  end

  # Reads the PDF with the first model in extract_pdf's route and records its summary and type.
  def process_with_ai
    ai_processor.process.tap { sync_statement_metadata_from_process_result(_1) }
  end

  # Extracts a statement's transactions into extracted_data. Nil for other document types.
  def extract_transactions
    ai_processor.extract_transactions&.tap { sync_statement_metadata_from_extracted_data(_1) }
  end

  # The account type a statement of this document type belongs to.
  STATEMENT_ACCOUNT_TYPES = { "bank_statement" => "Depository", "credit_card_statement" => "CreditCard" }.freeze

  AccountSuggestion = Data.define(:account, :last4)

  # Four digits written as an account number: "••1234", "•••• 1234",
  # "**** 1234", "XXXX-1234", "x1234", "...1234", "ending 1234", "#1234".
  MARKED_ACCOUNT_DIGITS = /(?:[•*]+|\.{2,}|\bx+|\bending\s+(?:in\s+)?|#)[\s-]?(\d{4})(?!\d)/i
  GENERIC_INSTITUTION_WORDS = %w[bank banking the of and card cards credit account accounts savings group limited ltd inc plc co corp financial].freeze

  # Statements often print a symbol where an ISO code is expected ("S$").
  CURRENCY_SYMBOL_CODES = {
    "S$" => "SGD", "A$" => "AUD", "AU$" => "AUD", "C$" => "CAD", "CA$" => "CAD", "NZ$" => "NZD",
    "HK$" => "HKD", "US$" => "USD", "R$" => "BRL", "€" => "EUR", "£" => "GBP", "₹" => "INR", "RM" => "MYR"
  }.freeze

  def self.iso_currency(value)
    raw = value.to_s.strip.upcase
    return nil if raw.blank?

    Money::Currency.new(CURRENCY_SYMBOL_CODES.fetch(raw, raw)).iso_code
  rescue Money::Currency::UnknownCurrencyError
    nil
  end

  def statement_account_type
    STATEMENT_ACCOUNT_TYPES[document_type]
  end

  # The account this statement most likely belongs to, among `accounts` (the
  # ones the reviewer can reach), for the review screen to preselect. Only
  # accounts of the statement's type are considered, and nothing is linked
  # until the reviewer saves it.
  def account_suggestion(accounts)
    return nil if account.present? || statement_account_type.nil?

    candidates = accounts.where(accountable_type: statement_account_type)
    conflicting = candidates.visible.select { |candidate| contradicts_statement?(candidate) }.map(&:id)
    candidates = candidates.where.not(id: conflicting) if conflicting.any?
    found = matched_account(candidates) || account_created_for_this_import(candidates)
    found && AccountSuggestion.new(account: found, last4: statement_last4)
  end

  # Starting values for an account created from this statement. Its balance is
  # the statement's opening balance on the day before the period starts, so
  # once the rows are published the account ends on the closing balance.
  # Without both, balance and date are left for the user to fill in.
  def new_account_attributes
    start_on = parse_statement_date(extracted_data&.dig("period", "start_date")) || account_statement&.period_start_on
    opening = statement_opening_balance
    known_start = opening.present? && start_on.present?

    {
      name: new_account_name,
      institution_name: statement_institution,
      currency: statement_currency_code,
      balance: (opening if known_start),
      opening_balance_date: (start_on - 1.day if known_start)
    }
  end

  # The opening balance as a number. A model can return it as printed
  # ("1,050.00 DR"); anything but a plain number is left for the user.
  def statement_opening_balance
    value = extracted_data&.dig("opening_balance").presence || account_statement&.opening_balance
    case value
    when Numeric then value.to_d
    when String then value.strip.match?(/\A-?[\d,]*\.?\d+\z/) ? value.delete(",").to_d : nil
    end
  end

  def statement_institution
    account_statement&.sanitized_parser_output&.dig("extracted_institution").presence
  end

  # The statement row defaults to the family currency at upload; the one
  # read from the document is the account's own.
  def statement_currency_code
    self.class.iso_currency(account_statement&.sanitized_parser_output&.dig("extracted_currency")) ||
      account_statement&.statement_currency.presence || family.currency
  end

  # "DBS Bank Credit card ••1234": what the statement is, and the digits that
  # let next month's statement find this account again.
  def new_account_name
    kind = I18n.t("imports.pdf_import.new_account_kind.#{statement_account_type.to_s.underscore}", default: "")
    [ statement_institution, kind.presence, statement_last4 && "••#{statement_last4}" ].compact.join(" ").presence
  end

  def statement_last4
    account_statement&.account_last4_hint.presence
  end

  def credit_card_statement?
    document_type == "credit_card_statement" || account&.classification == "liability"
  end

  def bank_statement?
    document_type == "bank_statement"
  end

  def statement_with_transactions?
    document_type.in?(%w[bank_statement credit_card_statement])
  end

  def has_extracted_transactions?
    extracted_data.present? && extracted_data["transactions"].present?
  end

  def extracted_transactions
    extracted_data&.dig("transactions") || []
  end

  def generate_rows_from_extracted_data
    transaction do
      # insert_all! below bypasses ActiveRecord, so the `rows` association is
      # never populated with what it wrote. Reload before destroying, or a second
      # call on the same in-memory record (assign_account! regenerating after
      # ProcessPdfJob already generated) clears a stale empty collection, deletes
      # nothing, and collides on (import_id, source_row_number).
      rows.reload.destroy_all

      unless has_extracted_transactions?
        update_column(:rows_count, 0)
        return
      end

      currency = account&.currency || family.currency
      candidates = extracted_transactions.map.with_index(1) do |txn, index|
        Import::Row.new(
          import: self,
          source_row_number: index,
          date: format_date_for_import(txn["date"]),
          amount: txn["amount"].to_s,
          name: txn["name"].to_s,
          category: txn["category"].to_s,
          notes: txn["notes"].to_s,
          currency: currency
        )
      end

      unmatched, matched_entries = partition_already_recorded(candidates)

      reconcile_entries!(matched_entries)

      classifications = if counterparty_classification_enabled?
        remember_statement_identifiers!
        Import::CounterpartyClassifier.new(self).classify(unmatched)
      else
        []
      end

      mapped_rows = unmatched.map.with_index(1) do |row, index|
        classification = classifications[index - 1]
        {
          import_id: id,
          source_row_number: index,
          date: row.date,
          amount: row.amount,
          name: row.name,
          category: row.category,
          notes: row.notes,
          currency: row.currency,
          counterparty_class: classification&.counterparty_class,
          counterparty_account_id: classification&.account_id,
          counterparty_entry_id: classification&.entry_id,
          counterparty_confidence: classification&.confidence,
          counterparty_reasons: classification&.reasons || []
        }
      end

      Import::Row.insert_all!(mapped_rows) if mapped_rows.any?
      # Drop the now-stale association cache so later reads (sync_mappings, the
      # view) see what was actually written.
      rows.reset
      update_column(:rows_count, mapped_rows.size)
    end
  end

  # Transactions this statement reconciled against records that already existed.
  # Derived from the statement link rather than stored, so it cannot go stale.
  def reconciled_entries
    return Entry.none if account_statement.blank?

    Entry.reconciled_by_statement(account_statement)
  end

  # The half of reconciled_entries this import did not create -- transactions the
  # account already held when the statement arrived. Everything this import
  # creates is born reconciled too, so the two have to be told apart before
  # either count means anything.
  def already_recorded_entries
    reconciled_entries.where.not(id: entries.select(:id))
  end

  # The next three are memoized because the summary dialog and the review screen
  # each read them more than once, and every read is its own COUNT -- rendering
  # the dialog issued roughly fifteen queries for a static summary. They report
  # a finished outcome for display, so a value cached for the life of the
  # request is what callers want; anything re-judging the import recomputes from
  # the entries directly. (`||=` is safe here: 0 is truthy in Ruby.)
  def already_recorded_count
    @already_recorded_count ||= already_recorded_entries.count
  end

  def imported_count
    @imported_count ||= entries.count
  end

  # Rows still on offer. import! creates an entry per row and leaves the rows in
  # place as the record of what was published, so past that point rows_count is
  # a history, not a queue. Memoized mostly for data_committed?, which is two
  # more EXISTS queries every time it is asked.
  def awaiting_review_count
    @awaiting_review_count ||= data_committed? ? 0 : rows_count
  end

  # No query: extracted_data is already in memory.
  def extracted_count
    extracted_transactions.size
  end

  # Whether the statement described transactions the account already had. The
  # difference between "nothing to import" and "nothing was found".
  def reconciled_anything?
    already_recorded_count.positive?
  end

  def send_next_steps_email(user)
    PdfImportMailer.with(
      user: user,
      pdf_import: self
    ).next_steps.deliver_later
  end

  def uploaded?
    pdf_uploaded?
  end

  def configured?
    ai_processed? && rows_count > 0
  end

  def cleaned?
    configured? && rows.all?(&:valid?)
  end

  def publishable?
    account.present? && statement_with_transactions? && cleaned? && mappings.all?(&:valid?)
  end

  def cleaned_from_validation_stats?(invalid_rows_count:)
    account.present? && statement_with_transactions? && super
  end

  def publishable_from_validation_stats?(invalid_rows_count:)
    account.present? && statement_with_transactions? && super
  end

  def column_keys
    %i[date amount name category notes]
  end

  def requires_csv_workflow?
    false
  end

  def pdf_file_content
    return @pdf_file_content if defined?(@pdf_file_content)
    return @pdf_file_content = account_statement.original_file.download if statement_backed?

    @pdf_file_content = pdf_file.download if pdf_file.attached?
  end

  def pdf_filename
    return account_statement.filename if statement_backed?

    pdf_file.filename.to_s if pdf_file.attached?
  end

  def statement_backed?
    account_statement&.original_file&.attached?
  end

  def required_column_keys
    %i[date amount]
  end

  def mapping_steps
    base = []
    # Only include CategoryMapping if rows have non-empty categories
    base << Import::CategoryMapping if rows.where.not(category: [ nil, "" ]).exists?
    # Note: PDF imports use direct account selection in the UI, not AccountMapping
    # AccountMapping is designed for CSV imports where rows have different account values
    base
  end

  private
    def ai_processor = PdfImport::AiProcessor.new(self)

    # A statement's posting date routinely differs by a day or two from the date
    # a provider recorded for the same transaction, so matching allows a small
    # window rather than demanding an exact date.
    RECONCILIATION_DATE_WINDOW = 3

    # Splits candidate rows into those that are genuinely new and the existing
    # entries the rest already correspond to. Matching is per-account, so with no
    # account assigned yet every row is treated as new and judged again once the
    # user picks one (see assign_account!).
    # How a classified line is written. Lines between the family's own
    # accounts carry no category and a transfer kind, so they stay out of
    # income and spending; a line to a tracked account is linked to the
    # other side once both exist.
    def counterparty_publish_attributes(row)
      case row.counterparty_class
      when "internal_tracked"
        target = row.counterparty_account_id && family.accounts.visible.find_by(id: row.counterparty_account_id)
        return nil if target.nil? || target.id == account_id

        kind = row.signed_amount.negative? ? "funds_movement" : Transfer.kind_for_account(target, from_account: account)
        { kind: kind, link: true }
      when "internal_untracked"
        { kind: "funds_movement", link: false }
      end
    end

    # Each link runs in its own savepoint: a counterpart claimed, edited or
    # removed since review leaves that line a plain transaction instead of
    # failing the whole publish.
    def link_counterparts!(pairs)
      pairs.each do |row, transaction|
        counterpart = counterpart_transaction_for(row, transaction)
        next if counterpart.nil?

        # Linking changes the counterpart's kind (and may add a category);
        # remembered so reverting this import can put them back.
        previous = { "entry_id" => counterpart.entry.id, "kind" => counterpart.kind, "category_id" => counterpart.category_id }
        Transfer.transaction(requires_new: true) do
          Transfer::Matcher.new(transaction).match_with!(counterpart)
          row.update_columns(counterparty_restore: previous)
        end
      rescue Transfer::Matcher::Error => e
        DebugLogEntry.capture(
          category: "import",
          level: "warn",
          message: "PdfImport: could not link statement line to its counterpart (#{e.code})",
          source: "pdf_import",
          family: family,
          account: account,
          metadata: { import_id: id, source_row_number: row.source_row_number, counterparty_account_id: row.counterparty_account_id, error_code: e.code }
        )
      end
    end

    # Undoes each transfer publishing made and gives the counterpart back the
    # kind and category it had. A counterpart no longer linked to this
    # import's transaction (unlinked or relinked since) is left as it is now.
    def release_linked_records!
      own_transaction_ids = entries.where(entryable_type: "Transaction").pluck(:entryable_id).to_set
      return if own_transaction_ids.empty?

      rows.where("counterparty_restore <> '{}'::jsonb").find_each do |row|
        state = row.counterparty_restore
        counterpart = Entry.find_by(id: state["entry_id"], entryable_type: "Transaction")&.entryable
        transfer = counterpart&.transfer
        next if transfer.nil?
        next unless own_transaction_ids.include?(transfer.inflow_transaction_id) || own_transaction_ids.include?(transfer.outflow_transaction_id)

        transfer.destroy!
        category_id = family.categories.where(id: state["category_id"]).pick(:id)
        counterpart.reload.update!(kind: state["kind"], category_id: category_id)
      end
    end

    def counterpart_transaction_for(row, transaction)
      scope = Import::CounterpartyClassifier.mirror_scope(
        account_ids: [ row.counterparty_account_id ],
        amounts: [ -transaction.entry.amount ],
        currencies: [ transaction.entry.currency ],
        dates: [ transaction.entry.date ]
      )
      entry = (row.counterparty_entry_id && scope.find_by(id: row.counterparty_entry_id)) ||
        scope.order(Arel.sql(ActiveRecord::Base.sanitize_sql_array([ "ABS(entries.date - ?::date), entries.id", transaction.entry.date ]))).first
      entry&.entryable
    end

    # What the statement says about the account it is imported into, kept so
    # other statements' lines can be traced back to it. A statement moved to
    # another account takes its identifiers with it.
    def remember_statement_identifiers!
      return if account_statement.blank? || account.blank?

      AccountIdentifier.release_statement!(account_statement, keep_account_id: account.id)
      return unless account_statement.account_id == account.id

      AccountIdentifier.remember_from_statement!(
        account_statement,
        document_type: document_type,
        holder_name: extracted_data.is_a?(Hash) ? extracted_data["account_holder"] : nil
      )
    end

    def partition_already_recorded(candidates)
      return [ candidates, [] ] if account.blank?

      adapter = Account::ProviderImportAdapter.new(account)
      claimed = []
      unmatched = []
      matched = []

      candidates.each do |row|
        if (existing = already_recorded_entry(adapter, row, claimed))
          claimed << existing.id
          matched << existing
        else
          unmatched << row
        end
      end

      [ unmatched, matched ]
    end

    # Name is deliberately not part of the match: statement descriptions and
    # provider names for the same transaction rarely agree, and the adapter makes
    # the same choice for provider sync.
    def already_recorded_entry(adapter, row, claimed)
      adapter.find_duplicate_transaction(
        date: row.date_iso,
        amount: row.signed_amount,
        currency: row.currency,
        exclude_entry_ids: claimed,
        date_window: RECONCILIATION_DATE_WINDOW,
        include_provider_entries: true
      )
    rescue ArgumentError, TypeError => e # Date::Error subclasses ArgumentError
      # A row whose date or amount will not parse cannot be judged. Offer it for
      # import rather than dropping it silently -- the review step surfaces it.
      DebugLogEntry.capture(
        category: "import",
        level: "warn",
        message: "PdfImport: could not evaluate statement row for reconciliation (#{e.class})",
        source: "pdf_import",
        family: family,
        account: account,
        metadata: {
          import_id: id,
          account_statement_id: account_statement_id,
          source_row_number: row.source_row_number,
          raw_date: row.date,
          raw_amount: row.amount,
          error_class: e.class.name
        }
      )
      nil
    end

    def reconcile_entries!(entries, at: Time.current)
      return if entries.blank?

      Entry.where(id: entries.map(&:id)).update_all(
        reconciled_at: at,
        reconciled_by_statement_id: account_statement&.id,
        updated_at: at
      )
    end

    # Regeneration can empty the row set (everything now matches) or refill it
    # (the new account matches nothing). Status has to follow, using the same
    # rule ProcessPdfJob applies after initial processing -- otherwise a
    # fully-matched import sits at pending with no rows, which renders as the
    # processing screen forever and cannot be restarted.
    def refresh_status_after_regeneration!
      return if data_committed?
      return unless pending? || complete?

      target = statement_with_transactions? && rows_count > 0 ? "pending" : "complete"
      update!(status: target) unless status.to_s == target
    end

    # Scoped to the account being moved away from. A statement is evidence for
    # exactly one account at a time, but it can back more than one import, so an
    # unscoped release would clear reconciliations another account still relies
    # on. Nothing is reconciled while no account is assigned, so a blank scope
    # has nothing to release.
    def release_reconciliations!(account_scope_id)
      return if account_statement.blank? || account_scope_id.blank?

      Entry.reconciled_by_statement(account_statement).where(account_id: account_scope_id).update_all(
        reconciled_at: nil,
        reconciled_by_statement_id: nil,
        updated_at: Time.current
      )
    end

    # Reverting a statement import unwinds its evidence as well as its rows. The
    # entries it created are already destroyed by the time this runs; the ones it
    # only matched keep marks this statement no longer backs. Releasing and then
    # regenerating re-judges every statement line against what the account
    # actually holds now, so the review screen offers exactly what is missing.
    def revert_derived_state!
      release_reconciliations!(account_id)
      return unless has_extracted_transactions?

      generate_rows_from_extracted_data
      # A line that matched at publish time carried no row and so no mapping.
      # If it no longer matches it is a row again, and needs one.
      sync_mappings
    end

    # A statement whose every line still matches something -- a provider-synced
    # account, say -- reverts to zero rows. Returning that to pending renders the
    # processing screen with no way out, so an import with nothing left to offer
    # finishes as complete, the same way refresh_status_after_regeneration! ends
    # a fully reconciled import.
    def status_after_revert
      statement_with_transactions? && rows_count > 0 ? :pending : :complete
    end

    def format_date_for_import(date_str)
      return "" if date_str.blank?

      Date.parse(date_str).strftime(date_format)
    rescue ArgumentError
      date_str.to_s
    end

    def account_statement_matches_import
      return if account_statement.blank? || (account_statement.family_id == family_id && account_statement.pdf?)

      errors.add(:account_statement, :invalid)
    end

    def matched_account(candidates)
      return nil unless account_statement

      institutions = [ statement_institution, account_statement.institution_name_hint ].compact_blank.uniq
      (institutions.presence || [ nil ]).each do |institution|
        match = AccountStatement::AccountMatcher.best_match(
          family: family,
          accounts: candidates,
          institution_hint: institution,
          account_name_hint: account_statement.account_name_hint,
          account_last4_hint: statement_last4,
          currency: account_statement.statement_currency
        )
        return match.account if match
      end

      # The last four digits alone are below the matcher's threshold, but
      # among accounts of the statement's own type one showing them as its
      # number ("Visa ••1234"), at the statement's bank, is the account.
      return nil unless statement_last4

      by_last4 = candidates.visible.select do |candidate|
        "#{candidate.name} #{candidate.institution_name}".scan(MARKED_ACCOUNT_DIGITS).flatten.include?(statement_last4) &&
          same_institution?(candidate)
      end
      by_last4.one? ? by_last4.first : nil
    end

    # An account that shows a different number ("Altitude ••9999" for a
    # statement ending 1234) is not this statement's, however well the rest of
    # it matches. Only a number written as one counts: a year in a name
    # ("Visa 2024") says nothing.
    def contradicts_statement?(candidate)
      return false unless statement_last4

      numbers = "#{candidate.name} #{candidate.institution_name}".scan(MARKED_ACCOUNT_DIGITS).flatten
      numbers.any? && numbers.exclude?(statement_last4)
    end

    # Creating an account from this screen returns here, so the one account
    # of this type made since the upload is the statement's, provided it is
    # in the statement's currency and, when the statement names its bank,
    # names it too.
    def account_created_for_this_import(candidates)
      recent = candidates.visible.where(created_at: created_at..).to_a
      return nil unless recent.one?

      account = recent.first
      account.currency == statement_currency_code && same_institution?(account) ? account : nil
    end

    # Whether an account can be at the statement's bank: its name or
    # institution carries the bank's own word ("dbs" in "DBS Bank Ltd", "us" in
    # "U.S. Bank"), not just a shared place name. True when the statement
    # names no bank.
    def same_institution?(account)
      brand = institution_words(statement_institution).first
      brand.nil? || institution_words("#{account.name} #{account.institution_name}").include?(brand)
    end

    def institution_words(text)
      text.to_s.downcase.delete(".").scan(/[[:alnum:]]+/) - GENERIC_INSTITUTION_WORDS
    end

    def sync_statement_metadata_from_extracted_data(data)
      return unless statement_backed?

      start_date = data.dig("period", "start_date").presence
      end_date = data.dig("period", "end_date").presence
      opening_bal = data["opening_balance"]
      closing_bal = data["closing_balance"]
      bank_name = data["bank_name"].presence
      last4 = data["account_number"].presence&.to_s&.last(4)
      currency = data["currency"].presence || account_statement.sanitized_parser_output&.dig("extracted_currency").presence

      apply_statement_metadata_updates(
        start_date: start_date,
        end_date: end_date,
        opening_balance: opening_bal,
        closing_balance: closing_bal,
        institution_name: bank_name,
        account_last4: last4,
        currency: currency
      )
    end

    def sync_statement_metadata_from_process_result(result)
      return unless statement_backed?
      return unless result.respond_to?(:extracted_data) && result.extracted_data.is_a?(Hash)

      data = result.extracted_data.deep_stringify_keys
      start_date = data["statement_period_start"].presence
      end_date = data["statement_period_end"].presence
      opening_bal = data["opening_balance"]
      closing_bal = data["closing_balance"]
      institution = data["institution_name"].presence
      currency = data["currency"].presence || account_statement.sanitized_parser_output&.dig("extracted_currency").presence

      apply_statement_metadata_updates(
        start_date: start_date,
        end_date: end_date,
        opening_balance: opening_bal,
        closing_balance: closing_bal,
        institution_name: institution,
        account_last4: nil,
        currency: currency
      )
    end

    def apply_statement_metadata_updates(start_date:, end_date:, opening_balance:, closing_balance:, institution_name:, account_last4:, currency: nil)
      updates = {}
      currency = self.class.iso_currency(currency) || currency

      if currency.present?
        if account_statement.currency.blank? && account_statement.account_id.blank?
          updates[:currency] = currency.to_s.upcase
        end
        parser_output = (account_statement.sanitized_parser_output || {}).dup
        if parser_output["extracted_currency"] != currency.to_s.upcase
          parser_output["extracted_currency"] = currency.to_s.upcase
          updates[:sanitized_parser_output] = parser_output
        end
      end

      # Only sync balances when currency is compatible with the statement's currency,
      # matching AccountStatement::MetadataDetector#detect_from_pdf behavior.
      target_currency = updates[:currency] || account_statement.statement_currency
      currency_compatible = currency.blank? || target_currency.blank? || currency.to_s.casecmp?(target_currency)

      if currency_compatible
        updates[:opening_balance] = opening_balance if opening_balance.present?
        updates[:closing_balance] = closing_balance if closing_balance.present?
      else
        DebugLogEntry.capture(
          category: "import",
          level: "warn",
          message: "PdfImport: extracted balance currency '#{currency}' does not match statement currency '#{target_currency}'",
          source: "pdf_import",
          family: family,
          account: account,
          metadata: {
            import_id: id,
            account_statement_id: account_statement.id,
            extracted_currency: currency,
            statement_currency: target_currency
          }
        )
      end

      bounded_institution = institution_name.presence&.to_s&.strip&.first(200)&.presence
      updates[:institution_name_hint] = bounded_institution if bounded_institution && account_statement.institution_name_hint.blank?
      # The hint above is often a guess from the filename; the name read from
      # the document is kept apart so account suggestions can prefer it.
      if bounded_institution
        parser_output = (updates[:sanitized_parser_output] || account_statement.sanitized_parser_output || {}).dup
        if parser_output["extracted_institution"] != bounded_institution
          parser_output["extracted_institution"] = bounded_institution
          updates[:sanitized_parser_output] = parser_output
        end
      end
      updates[:account_last4_hint] = account_last4 if account_last4.present? && account_statement.account_last4_hint.blank?

      parsed_start = parse_statement_date(start_date)
      parsed_end = parse_statement_date(end_date)

      proposed_start = parsed_start || account_statement.period_start_on
      proposed_end = parsed_end || account_statement.period_end_on

      if proposed_start && proposed_end && proposed_start > proposed_end
        DebugLogEntry.capture(
          category: "import",
          level: "warn",
          message: "PdfImport: extracted statement period is inverted or conflicts with existing period",
          source: "pdf_import",
          family: family,
          account: account,
          metadata: {
            import_id: id,
            account_statement_id: account_statement.id,
            parsed_start: parsed_start&.iso8601,
            parsed_end: parsed_end&.iso8601,
            existing_start: account_statement.period_start_on&.iso8601,
            existing_end: account_statement.period_end_on&.iso8601
          }
        )
      else
        updates[:period_start_on] = parsed_start if parsed_start
        updates[:period_end_on] = parsed_end if parsed_end
      end

      return if updates.empty?

      unless account_statement.update(updates)
        DebugLogEntry.capture(
          category: "import",
          level: "warn",
          message: "PdfImport: failed to sync statement metadata (#{account_statement.errors.full_messages.to_sentence})",
          source: "pdf_import",
          family: family,
          account: account,
          metadata: {
            import_id: id,
            account_statement_id: account_statement.id,
            updates: updates,
            errors: account_statement.errors.messages
          }
        )
      end
    end

    def parse_statement_date(date_str)
      return nil if date_str.blank?

      date = date_str.is_a?(Date) ? date_str : Date.parse(date_str.to_s)
      return date if Import.reasonable_date_range.cover?(date)

      DebugLogEntry.capture(
        category: "import",
        level: "warn",
        message: "PdfImport: statement date '#{date_str}' falls outside reasonable date range",
        source: "pdf_import",
        family: family,
        account: account,
        metadata: {
          import_id: id,
          account_statement_id: account_statement&.id,
          raw_date: date_str,
          parsed_date: date.iso8601
        }
      )
      nil
    rescue Date::Error, ArgumentError => e
      DebugLogEntry.capture(
        category: "import",
        level: "warn",
        message: "PdfImport: failed to parse statement date '#{date_str}' (#{e.message})",
        source: "pdf_import",
        family: family,
        account: account,
        metadata: {
          import_id: id,
          account_statement_id: account_statement&.id,
          raw_date: date_str
        }
      )
      nil
    end
end
