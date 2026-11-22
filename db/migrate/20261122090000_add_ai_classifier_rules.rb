# frozen_string_literal: true

# AI merchant detection and AI categorization become built-in rules, like the
# Merchant matcher and Category classifier: every family gets them off, just
# below those two, so the AI only sees what the free steps left. A family that
# already has a rule with the action keeps it and gets no second one.
class AddAiClassifierRules < ActiveRecord::Migration[8.1]
  BUILTIN_ACTION_TYPES = %w[fill_similar_merchants bayes_categorize auto_detect_merchants auto_categorize].freeze
  RULES = [
    [ "auto_detect_merchants", "AI merchant detection" ],
    [ "auto_categorize", "AI categorization" ]
  ].freeze

  def up
    builtin = BUILTIN_ACTION_TYPES.map { connection.quote(_1) }.join(", ")

    RULES.each do |action_type, name|
      family_ids = select_values(<<~SQL)
        SELECT families.id FROM families
        WHERE NOT EXISTS (
          SELECT 1 FROM rules JOIN rule_actions ON rule_actions.rule_id = rules.id
          WHERE rules.family_id = families.id AND rule_actions.action_type = #{connection.quote(action_type)}
        )
      SQL

      family_ids.each do |family_id|
        family = connection.quote(family_id)
        # Rules and rule groups share one position sequence (Rule::Layout).
        after = select_value(<<~SQL).to_i
          SELECT COALESCE(MAX(rules.position), 0) FROM rules
          JOIN rule_actions ON rule_actions.rule_id = rules.id
          WHERE rules.family_id = #{family} AND rule_actions.action_type IN (#{builtin})
        SQL

        execute "UPDATE rules SET position = position + 1 WHERE family_id = #{family} AND position > #{after}"
        execute "UPDATE rule_groups SET position = position + 1 WHERE family_id = #{family} AND position > #{after}"
        execute <<~SQL
          WITH added AS (
            INSERT INTO rules (family_id, name, resource_type, active, position, created_at, updated_at)
            VALUES (#{family}, #{connection.quote(name)}, 'transaction', FALSE, #{after + 1}, NOW(), NOW())
            RETURNING id
          )
          INSERT INTO rule_actions (rule_id, action_type, created_at, updated_at)
          SELECT id, #{connection.quote(action_type)}, NOW(), NOW() FROM added
        SQL
      end
    end
  end

  # Removes the rules this added: off, named as above, with no conditions and
  # only the one action.
  def down
    RULES.each do |action_type, name|
      added = <<~SQL
        SELECT rules.id FROM rules
        WHERE rules.name = #{connection.quote(name)}
          AND NOT EXISTS (SELECT 1 FROM rule_conditions WHERE rule_conditions.rule_id = rules.id)
          AND (SELECT array_agg(action_type) FROM rule_actions WHERE rule_actions.rule_id = rules.id) = ARRAY[#{connection.quote(action_type)}]::varchar[]
      SQL
      ids = select_values(added)
      next if ids.empty?

      list = ids.map { connection.quote(_1) }.join(", ")
      execute "DELETE FROM rule_runs WHERE rule_id IN (#{list})"
      execute "DELETE FROM rule_actions WHERE rule_id IN (#{list})"
      execute "DELETE FROM rules WHERE id IN (#{list})"
    end
  end
end
