class AddFailureLogToRuleRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :rule_runs, :failure_log, :jsonb, default: [], null: false
  end
end
