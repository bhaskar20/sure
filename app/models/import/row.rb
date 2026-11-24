class Import::Row < ApplicationRecord
  belongs_to :import, counter_cache: true

  validates :amount, numericality: true, allow_blank: true
  validates :currency, presence: true

  validate :date_valid
  validate :required_columns
  validate :currency_is_valid

  scope :ordered, -> { order(:source_row_number, :id) }

  def tags_list
    if tags.blank?
      [ "" ]
    else
      split_tags(tags).map(&:strip)
    end
  end

  def date_iso
    Date.strptime(date, import.date_format).iso8601
  end

  # The statement's own words for the line, which classifying it as internal
  # or external reads: the printed description rather than a readable name
  # written for it, plus whatever reference the notes add to it.
  def counterparty_text
    original = original_name.to_s.strip
    if original.empty?
      # Rows renamed before the original was kept separately: the enricher
      # put the printed text in the notes, so it is read first.
      return [ notes, name ].compact_blank.join(" ") if renamed_without_original?
      return [ name, notes ].compact_blank.join(" ")
    end

    [ original, notes.to_s.strip.delete_prefix(original).squish ].compact_blank.join(" ")
  end

  def signed_amount
    if import.type == "TradeImport"
      price.to_d * apply_trade_signage_convention(qty.to_d)
    else
      apply_transaction_signage_convention(amount.to_d)
    end
  end

  def update_and_sync(params)
    assign_attributes(params)
    save!(validate: false)
    import.sync_mappings
  end

  COUNTERPARTY_CHOICES = %w[internal_untracked external unknown].freeze

  # The reviewer's pick from the Counterparty column: "account:<id>" for one of
  # the family's accounts, "untracked:<id>" for one of its accounts outside
  # Sure, or a class without an account. The caller checks that the account
  # is one the reviewer may name.
  def counterparty_choice
    return if counterparty_class.blank?
    return "account:#{counterparty_account_id}" if counterparty_class == "internal_tracked" && counterparty_account_id.present?
    return "untracked:#{counterparty_untracked_account_id}" if counterparty_class == "internal_untracked" && counterparty_untracked_account_id.present?

    # Linked to an account deleted since; publishing treats it as a plain line.
    counterparty_class == "internal_tracked" ? "unknown" : counterparty_class
  end

  def counterparty_choice=(choice)
    choice = choice.to_s
    if choice.start_with?("account:")
      account_id = choice.delete_prefix("account:")
      return if account_id.blank?

      self.counterparty_entry_id = nil unless account_id == counterparty_account_id
      self.counterparty_class = "internal_tracked"
      self.counterparty_account_id = account_id
      self.counterparty_untracked_account_id = nil
    elsif choice.start_with?("untracked:")
      untracked_id = choice.delete_prefix("untracked:")
      return if untracked_id.blank?

      self.counterparty_class = "internal_untracked"
      self.counterparty_untracked_account_id = untracked_id
      self.counterparty_account_id = nil
      self.counterparty_entry_id = nil
    elsif choice.in?(COUNTERPARTY_CHOICES)
      self.counterparty_class = choice
      self.counterparty_account_id = nil
      self.counterparty_entry_id = nil
      self.counterparty_untracked_account_id = nil
    else
      return
    end
    self.counterparty_user_set = true
  end

  def counterparty_internal?
    counterparty_class.in?(%w[internal_tracked internal_untracked])
  end

  private
    def renamed_without_original?
      notes.present? && import.is_a?(PdfImport) && import.extracted_data.is_a?(Hash) &&
        Array(import.extracted_data["ai_filled"]).include?("transaction_names")
    end

    # Supports historical comma-delimited exports and pipe-delimited templates.
    # Backslash escapes comma, pipe, and backslash so tag names can contain either delimiter.
    def split_tags(value)
      split_escaped_tags(value, tag_delimiter_for(value))
    end

    def tag_delimiter_for(value)
      return "," if unescaped_delimiter?(value, ",")
      return "|" if unescaped_delimiter?(value, "|")

      ","
    end

    def unescaped_delimiter?(value, delimiter)
      escaping = false

      value.each_char do |char|
        if escaping
          escaping = false
        elsif char == "\\"
          escaping = true
        elsif char == delimiter
          return true
        end
      end

      false
    end

    def split_escaped_tags(value, delimiter)
      tag_names = []
      current = +""
      escaping = false

      value.each_char do |char|
        if escaping
          current << (char.in?([ delimiter, ",", "|", "\\" ]) ? char : "\\#{char}")
          escaping = false
        elsif char == "\\"
          escaping = true
        elsif char == delimiter
          tag_names << current
          current = +""
        else
          current << char
        end
      end

      current << "\\" if escaping
      tag_names << current
    end

    # In the Sure system, positive quantities == "inflows"
    def apply_trade_signage_convention(value)
      value * (import.signage_convention == "inflows_positive" ? 1 : -1)
    end

    # In the Sure system, positive amounts == "outflows", so we must reverse signage
    def apply_transaction_signage_convention(value)
      if import.amount_type_strategy == "signed_amount"
        value * (import.signage_convention == "inflows_positive" ? -1 : 1)
      elsif import.amount_type_strategy == "custom_column"
        legacy_identifier = import.amount_type_inflow_value
        selected_identifier =
          if import.amount_type_identifier_value.present?
            import.amount_type_identifier_value
          else
            legacy_identifier
          end

        inflow_treatment =
          if import.amount_type_inflow_value.in?(%w[inflows_positive inflows_negative])
            import.amount_type_inflow_value
          elsif import.signage_convention.in?(%w[inflows_positive inflows_negative])
            import.signage_convention
          else
            "inflows_positive"
          end

        if entity_type == selected_identifier
          value * (inflow_treatment == "inflows_positive" ? -1 : 1)
        else
          value * (inflow_treatment == "inflows_positive" ? 1 : -1)
        end
      else
        raise "Unknown amount type strategy for import: #{import.amount_type_strategy}"
      end
    end

    def required_columns
      import.required_column_keys.each do |required_key|
        errors.add(required_key, "is required") if self[required_key].blank?
      end
    end

    def date_valid
      return if date.blank?

      parsed_date = Date.strptime(date, import.date_format) rescue nil

      if parsed_date.nil?
        errors.add(:date, "must exactly match the format: #{import.date_format}")
        return
      end

      min_date = Entry.min_supported_date
      max_date = Date.current

      if parsed_date < min_date || parsed_date > max_date
        errors.add(:date, "must be between #{min_date} and #{max_date}")
      end
    end

    def currency_is_valid
      return true if currency.blank?

      begin
        Money::Currency.new(currency)
      rescue Money::Currency::UnknownCurrencyError
        errors.add(:currency, "is not a valid currency code")
      end
    end
end
