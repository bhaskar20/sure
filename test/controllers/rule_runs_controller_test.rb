require "test_helper"

class RuleRunsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @rule = @family.rules.create!(
      name: "AI rule",
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "auto_categorize") ]
    )
    @transaction = @family.transactions.first
    @rule_run = @rule.rule_runs.create!(
      rule_name: @rule.name,
      execution_type: "manual",
      status: "pending",
      transactions_queued: 1,
      pending_jobs_count: 1,
      executed_at: Time.current
    )
    @rule_run.fail_job!(error: RuntimeError.new("Context budget exceeded"), source: "AutoCategorizeJob", transaction_ids: [ @transaction.id ])
  end

  test "shows the failure log with the affected transactions" do
    get rule_run_url(@rule_run)

    assert_response :success
    assert_includes response.body, "Context budget exceeded"
    assert_includes response.body, "AutoCategorizeJob"
    assert_includes response.body, ERB::Util.html_escape(@transaction.entry.name)
  end

  test "does not show runs of another family" do
    other_rule = families(:empty).rules.create!(
      name: "Other",
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "auto_categorize") ]
    )
    other_run = other_rule.rule_runs.create!(
      execution_type: "manual", status: "failed", executed_at: Time.current
    )

    get rule_run_url(other_run)

    assert_response :not_found
  end

  test "rules page links failed runs to their failure log" do
    get rules_url

    assert_response :success
    assert_select "a[href=?][data-turbo-frame=modal]", rule_run_path(@rule_run)
  end
end
