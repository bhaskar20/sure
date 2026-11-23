# Whether a statement import may write the other side of a transfer into this
# account before the account's own statement arrives. Such a "provisional leg"
# is only written where it cannot move a figure the family entered itself and
# where nothing else will bring the other side.
module Account::ProvisionalLegs
  extend ActiveSupport::Concern

  # How far either side of a line another entry still counts as its other side.
  PROVISIONAL_LEG_WINDOW = 7

  def accepts_provisional_leg?
    provisional_leg_blocker.nil?
  end

  # Why this account never takes a leg: a provider-linked account gets the
  # other side from its sync, a balance the family set is the truth, and an
  # account valued rather than run from transactions (investment, property,
  # loan) would show a lone transaction misleadingly.
  def provisional_leg_blocker
    return @provisional_leg_blocker if defined?(@provisional_leg_blocker)

    @provisional_leg_blocker =
      if !active? then :inactive
      elsif !manual? then :linked
      elsif balance_type != :cash then :not_cash
      elsif hand_set_balance? then :hand_set_balance
      end
  end

  def reload(*)
    remove_instance_variable(:@provisional_leg_blocker) if defined?(@provisional_leg_blocker)
    super
  end

  # Why a leg for this particular line is not written: the account-wide
  # reasons, another currency, an entry already there that looks like the
  # other side, or a statement of this account covering the date (it would
  # have shown the line).
  def provisional_leg_blocker_for(date:, amount:, currency:)
    blocker = provisional_leg_blocker
    return blocker if blocker
    return :currency if currency != self.currency
    return :existing_entry if likely_other_side?(date: date, amount: amount, currency: currency)
    :statement_covers if account_statements_covering?(date)
  end

  # Any balance update, or an opening balance other than zero. Whoever wrote
  # it (the family, a restored export, a CSV of balances, a statement's
  # opening balance), it is a figure a leg must not move.
  def hand_set_balance?
    entries.joins("INNER JOIN valuations ON valuations.id = entries.entryable_id AND entries.entryable_type = 'Valuation'")
      .where(valuations: { kind: %w[reconciliation current_anchor] }).exists? ||
      (has_opening_anchor? && !opening_anchor_balance.to_d.zero?)
  end

  private
    # amount is the leg's own amount. Entries already part of a transfer are
    # someone else's other side (including legs written earlier in the same
    # publish), so a series of equal transfers each gets its own leg.
    def likely_other_side?(date:, amount:, currency:)
      # Only what the linker could also have used: posted, not excluded, not split.
      entries.where(entryable_type: "Transaction", amount: amount, currency: currency, parent_entry_id: nil, excluded: false)
        .excluding_pending.excluding_split_parents
        .where(date: (date - PROVISIONAL_LEG_WINDOW)..(date + PROVISIONAL_LEG_WINDOW))
        .where("NOT EXISTS (SELECT 1 FROM transfers WHERE transfers.inflow_transaction_id = entries.entryable_id OR transfers.outflow_transaction_id = entries.entryable_id)")
        .exists?
    end

    def account_statements_covering?(date)
      AccountStatement.where(account_id: id).where("period_start_on <= :date AND period_end_on >= :date", date: date).exists?
    end
end
