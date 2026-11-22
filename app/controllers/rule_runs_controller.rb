class RuleRunsController < ApplicationController
  FAILED_TRANSACTIONS_SHOWN = 20

  def show
    @rule_run = RuleRun.joins(:rule).where(rules: { family_id: Current.family.id }).find(params[:id])
    failed_ids = @rule_run.failure_transaction_ids
    @failed_transaction_count = failed_ids.size
    @failed_transactions = Current.family.transactions
                                   .where(id: failed_ids.first(FAILED_TRANSACTIONS_SHOWN))
                                   .includes(:entry)
                                   .to_a
                                   .sort_by { |transaction| transaction.entry.date }
                                   .reverse
  end
end
