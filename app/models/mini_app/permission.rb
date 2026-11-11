# The catalog of permissions a mini app can request, and the assistant tools
# each one unlocks. A tool is callable by a mini app only when it appears here
# and in Assistant.function_classes for the viewing user, so preview and
# guest filtering from the assistant registry still applies.
#
# Labels and descriptions live under `mini_app.permissions.<key>` where <key>
# is the permission with ":" replaced by "_" (for example
# `mini_app.permissions.transactions_write.label`).
class MiniApp::Permission
  CATALOG = {
    "accounts:read" => %w[get_accounts get_holdings get_valuations],
    "transactions:read" => %w[get_transactions get_recurring_transactions get_uncategorized_transactions get_transfer_match_candidates],
    "transactions:write" => %w[create_transaction update_transaction delete_transaction match_transfer unmatch_transfer update_transfer review_transfer],
    "categories:read" => %w[get_categories],
    "categories:write" => %w[create_category update_category delete_category],
    "tags:read" => %w[get_tags],
    "tags:write" => %w[create_tag update_tag],
    "merchants:read" => %w[get_merchants],
    "rules:read" => %w[get_rules get_rule_options preview_rule],
    "rules:write" => %w[create_rule update_rule apply_rule],
    "reports:read" => %w[get_balance_sheet get_income_statement get_budget get_insights],
    "budgets:write" => %w[update_budget],
    "goals:write" => %w[create_goal],
    "valuations:write" => %w[record_valuation set_opening_balance],
    # No tools: it unlocks the bridge's sure/ai/complete method instead.
    "ai:use" => []
  }.freeze

  TOOL_PERMISSIONS = CATALOG.each_with_object({}) do |(permission, tools), map|
    tools.each { |tool| map[tool] = permission }
  end.freeze

  class << self
    def all
      CATALOG.keys
    end

    def valid?(permission)
      CATALOG.key?(permission.to_s)
    end

    def for_tool(name)
      TOOL_PERMISSIONS[name.to_s]
    end

    def write?(permission)
      permission.to_s.end_with?(":write")
    end

    def tools(permission)
      CATALOG.fetch(permission.to_s, [])
    end

    def label(permission)
      I18n.t("mini_app.permissions.#{i18n_key(permission)}.label", default: permission.to_s)
    end

    def description(permission)
      I18n.t("mini_app.permissions.#{i18n_key(permission)}.description", default: "")
    end

    def i18n_key(permission)
      permission.to_s.tr(":", "_")
    end

    # The assistant function classes a mini app may call for this user, before
    # any per-app grant is applied.
    def tool_classes_for(user)
      Assistant.function_classes(user).select { |klass| for_tool(klass.name) }
    end
  end
end
