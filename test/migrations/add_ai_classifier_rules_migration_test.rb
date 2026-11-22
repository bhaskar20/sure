# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261122090000_add_ai_classifier_rules")

class AddAiClassifierRulesMigrationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.rules.destroy_all
  end

  test "adds the AI rules off, just below the matcher and Bayes" do
    matcher = builtin_rule("Merchant matcher", "fill_similar_merchants", 1)
    bayes = builtin_rule("Category classifier", "bayes_categorize", 2)
    mine = builtin_rule("Mine", "set_transaction_category", 3)
    group = @family.rule_groups.create!(name: "Later", position: 4)

    run_migration

    assert_equal [
      [ "Merchant matcher", true, "fill_similar_merchants" ],
      [ "Category classifier", true, "bayes_categorize" ],
      [ "AI merchant detection", false, "auto_detect_merchants" ],
      [ "AI categorization", false, "auto_categorize" ],
      [ "Mine", true, "set_transaction_category" ]
    ], @family.rules.ordered.includes(:actions).map { |rule| [ rule.name, rule.active?, rule.actions.sole.action_type ] }
    assert_equal [ 1, 2, 5 ], [ matcher, bayes, mine ].map { _1.reload.position }
    assert_equal 6, group.reload.position
  end

  test "a family that already has an AI rule keeps it and gets no second one" do
    builtin_rule("Merchant matcher", "fill_similar_merchants", 1)
    own = builtin_rule("My AI", "auto_categorize", 2)

    run_migration

    assert_equal [ own ], @family.classifier_rules("auto_categorize").to_a
    assert_equal 1, @family.classifier_rules("auto_detect_merchants").count
  end

  test "a family without built-in rules gets the AI rules at the top" do
    mine = builtin_rule("Mine", "set_transaction_category", 1)

    run_migration

    assert_equal [ "AI merchant detection", "AI categorization", "Mine" ], @family.rules.ordered.map(&:name)
    assert_equal 3, mine.reload.position
  end

  test "down removes only the rules it added" do
    own = builtin_rule("AI categorization", "auto_categorize", 1)
    own.conditions.create!(condition_type: "transaction_name", operator: "like", value: "coffee")

    run_migration
    ActiveRecord::Migration.suppress_messages { AddAiClassifierRules.new.down }

    assert_equal [ own ], @family.rules.reload.to_a
  end

  private
    def builtin_rule(name, action_type, position)
      value = action_type == "set_transaction_category" ? @family.categories.first.id : nil
      @family.rules.create!(name:, resource_type: "transaction", active: true, position:,
                            actions_attributes: [ { action_type:, value: } ])
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages { AddAiClassifierRules.new.up }
    end
end
