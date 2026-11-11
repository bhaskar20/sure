# Describes what a write tool call would change, for the host-drawn
# confirmation dialog. It is built on the server from the call's own
# arguments, and ids are resolved against the family's data, so the person
# sees the actual record and values the app sent, not what the app's UI
# claims. Unknown ids are shown as not found rather than dropped.
class MiniApp::WriteDescription
  MAX_LINES = 12
  MAX_VALUE_LENGTH = 200

  # Argument names that hold a reference, and what they refer to.
  REFERENCES = {
    "transaction_id" => :transaction,
    "counterpart_transaction_id" => :transaction,
    "account_id" => :account,
    "target_account_id" => :account,
    "category_id" => :category,
    "parent_id" => :category,
    "replacement_id" => :category,
    "merchant_id" => :merchant,
    "tag_ids" => :tags,
    "rule_id" => :rule
  }.freeze

  # What a bare `id` argument refers to, by tool.
  SUBJECTS = {
    "update_transaction" => :transaction,
    "delete_transaction" => :transaction,
    "update_category" => :category,
    "delete_category" => :category
  }.freeze

  attr_reader :user, :tool, :arguments

  def initialize(user:, tool:, arguments:)
    @user = user
    @tool = tool.to_s
    @arguments = arguments.is_a?(Hash) ? arguments.stringify_keys : {}
  end

  # [{ label:, value: }], references first, in argument order.
  def lines
    entries = arguments.reject { |_, value| value.nil? || value == "" }
    references, values = entries.partition { |name, _| reference_kind(name) }
    all = (references + values).map { |name, value| { label: label_for(name), value: describe(name, value) } }

    return all if all.size <= MAX_LINES

    all.first(MAX_LINES - 1) + [ { label: t("more_label"), value: t("more", count: all.size - (MAX_LINES - 1)) } ]
  end

  private
    def family
      user.family
    end

    def reference_kind(name)
      name == "id" ? SUBJECTS[tool] : REFERENCES[name]
    end

    def label_for(name)
      name = "#{SUBJECTS[tool]}_id" if name == "id" && SUBJECTS[tool]
      I18n.t("mini_app.bridge.confirm.fields.#{name}", default: name.humanize)
    end

    def describe(name, value)
      kind = reference_kind(name)
      text = kind ? describe_reference(kind, value) : describe_value(value)
      text.to_s.truncate(MAX_VALUE_LENGTH)
    end

    def describe_reference(kind, value)
      if kind == :tags
        ids = Array(value).map(&:to_s)
        return describe_value(value) if ids.empty?

        names = family.tags.where(id: ids.select { |id| UuidFormat.valid?(id) }).pluck(:id, :name).to_h
        return ids.map { |id| names[id] || not_found(id) }.join(", ")
      end

      id = value.to_s
      record = UuidFormat.valid?(id) ? find_reference(kind, id) : nil
      record ? describe_record(kind, record) : not_found(id)
    end

    def find_reference(kind, id)
      case kind
      when :transaction
        family.transactions.joins(:entry).where(entries: { account_id: Account.accessible_by(user).select(:id) })
              .includes(entry: :account).find_by(id: id)
      when :account then Account.accessible_by(user).where(family_id: family.id).find_by(id: id)
      when :category then family.categories.find_by(id: id)
      when :merchant then family.merchants.find_by(id: id) || family.transactions.find_by(merchant_id: id)&.merchant
      when :rule then family.rules.find_by(id: id)
      end
    end

    def describe_record(kind, record)
      case kind
      when :transaction
        entry = record.entry
        [ entry.name, entry.amount_money.format, I18n.l(entry.date), entry.account&.name ].compact_blank.join(" · ")
      when :account then record.name
      when :category then record.name_with_parent
      when :rule then record.name.presence || t("unnamed_rule")
      else record.name
      end
    end

    def describe_value(value)
      case value
      when true then t("yes")
      when false then t("no")
      when Hash, Array then value.to_json
      else value.to_s
      end
    end

    def not_found(id)
      t("not_found", id: id.to_s.truncate(64))
    end

    def t(key, **options)
      I18n.t("mini_app.bridge.confirm.#{key}", **options)
    end
end
