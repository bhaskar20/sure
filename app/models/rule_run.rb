class RuleRun < ApplicationRecord
  # Enough to find the transactions in the failure log without letting one
  # failed batch bloat the row.
  FAILURE_LOG_TRANSACTION_LIMIT = 50
  FAILURE_LOG_ENTRY_LIMIT = 20

  belongs_to :rule

  validates :execution_type, inclusion: { in: %w[manual scheduled immediate] }
  validates :status, inclusion: { in: %w[pending success failed] }
  validates :executed_at, presence: true
  validates :transactions_queued, numericality: { greater_than_or_equal_to: 0 }
  validates :transactions_processed, numericality: { greater_than_or_equal_to: 0 }
  validates :transactions_modified, numericality: { greater_than_or_equal_to: 0 }
  validates :pending_jobs_count, numericality: { greater_than_or_equal_to: 0 }

  scope :recent, -> { order(executed_at: :desc) }
  scope :for_rule, ->(rule) { where(rule: rule) }
  scope :successful, -> { where(status: "success") }
  scope :failed, -> { where(status: "failed") }
  scope :pending, -> { where(status: "pending") }

  def pending?
    status == "pending"
  end

  def success?
    status == "success"
  end

  def failed?
    status == "failed"
  end

  def transactions_blocked
    [ transactions_processed - transactions_modified, 0 ].max
  end

  # Offers the result of an immediate run through the sync toast, like
  # Family::SyncCompleteEvent. A full-page refresh would wipe forms that are
  # still open, such as the drawer the person just edited in; the toast waits
  # until they are done.
  # Best-effort: the rules already ran, so a failed broadcast must not fail
  # (and retry) the job that called it, which would repeat its AI work.
  def self.offer_immediate_result(family)
    family.broadcast_replace_to(
      family,
      target: "sync-toast",
      partial: "shared/notifications/sync_toast"
    )
  rescue StandardError => e
    Rails.logger.warn("RuleRun.offer_immediate_result failed for family #{family.id}: #{e.class}: #{e.message}")
    nil
  end

  # Thread-safe method to complete a job and update the run
  def complete_job!(modified_count: 0)
    drained = false

    with_lock do
      drained = pending_jobs_count == 1
      self.transactions_modified += modified_count
      self.pending_jobs_count = [ pending_jobs_count - 1, 0 ].max

      # Preserve a previously recorded failure while still draining pending jobs.
      self.status = "success" if pending_jobs_count <= 0 && !failed?

      save!
    end

    # A Sidekiq retry of a job that failed before finds nothing left to
    # drain, so its changes are offered on their own.
    offer_job_results if pending_jobs_count.zero? && (drained || modified_count.positive?)
  end

  def fail_job!(error:, source:, transaction_ids: [])
    should_log = false
    drained = false

    with_lock do
      should_log = !failed?
      drained = pending_jobs_count == 1
      self.pending_jobs_count = [ pending_jobs_count - 1, 0 ].max
      self.status = "failed"
      append_error_message(error)
      append_failure_log(error:, source:, transaction_ids:)

      save!
    end

    capture_failure_debug_log(error:, source:, transaction_ids:) if should_log
    # Earlier jobs of the run may already have changed transactions. A retry
    # of a job that already failed drains nothing, so it offers nothing again.
    offer_job_results if drained
  end

  # Records a failure the runner caught outside the async jobs.
  def record_failure!(error:, source:, transaction_ids: [])
    with_lock do
      self.status = "failed"
      append_error_message(error)
      append_failure_log(error:, source:, transaction_ids:)
      save!
    end
  end

  FailureEntry = Data.define(:message, :error_class, :source, :transaction_count, :transaction_ids, :occurred_at) do
    def self.from_log(attrs)
      new(
        message: attrs["message"].to_s,
        error_class: attrs["error_class"],
        source: attrs["source"],
        transaction_count: attrs["transaction_count"].to_i,
        transaction_ids: Array(attrs["transaction_ids"]),
        occurred_at: (Time.zone.parse(attrs["occurred_at"]) if attrs["occurred_at"].present?)
      )
    end
  end

  # Newest first. Runs recorded before the failure log existed only kept
  # error_message, so those show its lines alone.
  def failure_entries
    if failure_log.present?
      failure_log.map { |attrs| FailureEntry.from_log(attrs) }.reverse
    else
      error_message.to_s.split("\n").reject(&:blank?).map { |message| FailureEntry.from_log("message" => message) }
    end
  end

  def failure_transaction_ids
    failure_entries.flat_map(&:transaction_ids).uniq
  end

  private
    def append_error_message(error)
      existing_error_messages = error_message.to_s.split("\n").reject(&:blank?)
      self.error_message = (existing_error_messages + [ "#{error.class}: #{error.message}" ]).uniq.join("\n")
    end

    def append_failure_log(error:, source:, transaction_ids:)
      ids = Array(transaction_ids).compact
      entry = {
        "occurred_at" => Time.current.iso8601,
        "source" => source,
        "error_class" => error.class.name,
        "message" => error.message,
        "transaction_count" => ids.size,
        "transaction_ids" => ids.first(FAILURE_LOG_TRANSACTION_LIMIT)
      }
      self.failure_log = (Array(failure_log) + [ entry ]).last(FAILURE_LOG_ENTRY_LIMIT)
    end

    # The jobs of an immediate run with AI actions offer what they changed once
    # the last one is done; ApplyImmediateRulesJob offers the run's other changes.
    def offer_job_results
      return unless execution_type == "immediate" && transactions_modified.positive?

      self.class.offer_immediate_result(rule.family)
    end

    def capture_failure_debug_log(error:, source:, transaction_ids:)
      DebugLogEntry.capture(
        category: "rule_run",
        level: "error",
        message: "Rule run failed: #{error.class}: #{error.message}",
        source: source,
        family: rule.family,
        metadata: {
          rule_run_id: id,
          rule_id: rule_id,
          rule_name: rule_name,
          execution_type: execution_type,
          error_class: error.class.name,
          error_message: error.message,
          transaction_count: transaction_ids.size,
          transaction_ids: transaction_ids,
          backtrace: Array(error.backtrace).first(10)
        }
      )
    end
end
