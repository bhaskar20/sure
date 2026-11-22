# Money coming into a credit card is never income. It is either a payment of
# an earlier bill, or a refund or reversal of a charge. Left as a standard
# inflow, a card payment counts as income and a refund as income in its own
# right while the purchase it reverses still counts as spending.
#
# Before a card statement's transactions are written, each credit is paired
# with the purchase it refunds, from the same statement or already recorded on
# the card:
#
# - A refund of the whole purchase settles it: both are excluded from reports,
#   so neither spending nor income shows money that came straight back. They
#   still move the balance.
# - A partial refund takes the purchase's category, so it nets against it.
# - A credit that refunds nothing it can find is a payment (kind cc_payment),
#   unless its description says it is a refund, reversal or cashback, which
#   stays a standard credit.
#
# Each paired refund records the purchase in transactions.extra["card_refund"],
# so reverting the import can let go of a recorded purchase it settled.
class PdfImport::CardCredits
  EXTRA_KEY = "card_refund".freeze

  REFUND_WORDS = /\b(?:refund(?:ed)?|rfnd|reversal|reversed|revers|return(?:ed)?|chargeback|charge\s*back|cash\s*back|cashback|rebate|dispute|credit\s+adj(?:ustment)?|merchandise\s+credit|cancel(?:led|ed|lation)?|void)\b/i
  PAYMENT_WORDS = /\b(?:payment|paymt|pymt|pmt|thank\s*you|autopay|auto[\s-]*debit|auto[\s-]*pay|bill\s*pay|paid|neft|imps|rtgs|upi|bpay|giro|direct\s+debit|ach)\b/i
  # Words in descriptions that say nothing about which merchant it was.
  NOISE_WORDS = %w[
    refund refunded rfnd reversal reversed revers return returned chargeback charge back cashback cash rebate
    dispute credit adj adjustment merchandise cancel cancelled canceled cancellation void purchase pos debit card
    online www com the and for from with payment transaction txn ref intl international store shop shopping
    services service pte ltd llc inc pvt corp company limited
  ].to_set.freeze

  # How far back a refund looks for its purchase.
  LOOKBACK_DAYS = 120
  # A statement can post a refund a day or two before the purchase it reverses.
  DATE_SLACK_DAYS = 3

  def initialize(account:, transactions:)
    @account = account
    @transactions = transactions
  end

  # Updates the unsaved transactions in place and settles recorded purchases.
  # Entries need ids before this runs, so a refund can name a purchase from the
  # same statement.
  def apply!
    credits = transactions.select { |txn| txn.entry.amount.negative? }.sort_by { |txn| txn.entry.date }
    return if credits.empty?

    @claimed = Set.new
    credits.each { |credit| classify(credit) }
  end

  private
    attr_reader :account, :transactions

    def classify(credit)
      entry = credit.entry
      says_refund = entry.name.to_s.match?(REFUND_WORDS)
      says_payment = !says_refund && entry.name.to_s.match?(PAYMENT_WORDS)

      purchase = find_purchase(entry, says_refund:) unless says_payment
      if purchase
        pair(credit, purchase)
      elsif !says_refund
        credit.kind = "cc_payment"
        credit.category = nil
      end
    end

    # The purchase this credit most likely reverses: the same amount over a
    # partial one, a shared merchant word over none, then the nearest date. A
    # credit whose description does not say "refund" needs the shared word,
    # since otherwise it is a payment that happens to equal some charge.
    def find_purchase(entry, says_refund:)
      words = merchant_words(entry.name)
      refund = -entry.amount

      ranked = purchases(entry).filter_map do |purchase|
        next if @claimed.include?(purchase.id)
        next if purchase.amount < refund

        exact = purchase.amount == refund
        shared = (merchant_words(purchase.name) & words).any?
        next unless shared || (says_refund && exact)

        [ purchase, [ exact ? 0 : 1, shared ? 0 : 1, (entry.date - purchase.date).abs ] ]
      end

      ranked.min_by(&:last)&.first
    end

    def pair(credit, purchase)
      full = purchase.amount == -credit.entry.amount
      @claimed << purchase.id if full

      category = purchase_category(purchase)
      credit.category = category if category
      credit.extra = (credit.extra || {}).merge(EXTRA_KEY => { "entry_id" => purchase.id, "settled" => full })
      return unless full

      credit.entry.excluded = true
      if purchase.new_record?
        purchase.excluded = true
      else
        Entry.where(id: purchase.id).update_all(excluded: true, updated_at: Time.current)
      end
    end

    def purchase_category(purchase)
      purchase.new_record? ? new_transaction_for[purchase]&.category : purchase.entryable&.category
    end

    def new_transaction_for
      @new_transaction_for ||= transactions.to_h { |txn| [ txn.entry, txn ] }.compare_by_identity
    end

    def purchases(entry)
      window = (entry.date - LOOKBACK_DAYS)..(entry.date + DATE_SLACK_DAYS)
      (new_purchases + recorded_purchases).select { |purchase| purchase.currency == entry.currency && window.cover?(purchase.date) }
    end

    def new_purchases
      @new_purchases ||= transactions.map(&:entry).select { |entry| entry.amount.positive? }
    end

    def recorded_purchases
      @recorded_purchases ||= begin
        dates = transactions.map { |txn| txn.entry.date }
        account.entries
          .where(entryable_type: "Transaction", excluded: false)
          .where("entries.amount > 0")
          .where(date: (dates.min - LOOKBACK_DAYS)..(dates.max + DATE_SLACK_DAYS))
          .includes(entryable: :category)
          .to_a
      end
    end

    def merchant_words(name)
      name.to_s.downcase.scan(/[[:alpha:]]{3,}/).reject { |word| NOISE_WORDS.include?(word) }.uniq
    end
end
