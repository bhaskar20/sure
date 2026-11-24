# Decides, for each statement line about to be imported into an account,
# whether the money went to or came from another of the family's own accounts.
#
# Account-specific evidence (a partial account number the line names, a
# mirror entry already recorded in another account, a wallet the family
# tracks) is weighed against generic "this is my own money" evidence (a SELF
# marker, a family member's name, a wallet top-up). Only a line with strong
# evidence is classified as a transfer to a tracked account; weaker evidence is
# offered as a suggestion for the user to confirm, and conflicting evidence is
# never applied.
#
# The family's own accounts outside Sure (OwnUntrackedAccount) take part with
# the identifiers and names they have; they are keyed "untracked:<id>" so
# they never collide with a tracked account, and have no entries to mirror.
class Import::CounterpartyClassifier
  Classification = Data.define(:counterparty_class, :account_id, :entry_id, :confidence, :reasons, :untracked_account_id) do
    def initialize(untracked_account_id: nil, **rest)
      super
    end
  end

  UNTRACKED_PREFIX = "untracked:"

  CLASSES = %w[internal_tracked internal_untracked external unknown].freeze

  # Matches the window a confirmed transfer allows comfortably inside
  # Transfer::Matcher::DATE_WINDOW, so a suggested pair can always be linked.
  MIRROR_DATE_WINDOW = 7

  APPLY_THRESHOLD = "0.8".to_d
  SUGGEST_THRESHOLD = "0.5".to_d
  CONFLICT_THRESHOLD = "0.5".to_d
  # A weak account-specific signal is still worth naming alongside generic
  # own-money evidence.
  CANDIDATE_FLOOR = "0.3".to_d

  WEIGHTS = {
    identifier: "0.6".to_d,
    mirror: "0.5".to_d,
    wallet_account: "0.5".to_d,
    name_account: "0.4".to_d,
    holder_account: "0.3".to_d,
    only_card: "0.3".to_d,
    card_payment_to_card: "0.2".to_d,
    generic_bonus: "0.3".to_d
  }.freeze

  GENERIC_WEIGHTS = {
    self_marker: "0.4".to_d,
    own_name: "0.4".to_d,
    wallet_topup: "0.3".to_d,
    card_payment: "0.4".to_d,
    card_payment_received: "0.4".to_d
  }.freeze

  TITLES = %w[MR MRS MS MISS DR MX SHRI SMT].freeze
  MASKED_LAST4 = /(?:[•*xX#]+\s?|ending\s+(?:in\s+)?|\.\.\.)(\d{4})(?!\d)/i

  # Entries that could be the other side of a line: a plain, posted,
  # unsplit transaction with the opposite amount near the line's date, not
  # already part of a transfer.
  def self.mirror_scope(account_ids:, amounts:, currencies:, dates:)
    Entry
      .where(account_id: account_ids, entryable_type: "Transaction", excluded: false, parent_entry_id: nil)
      .where(amount: amounts.uniq, currency: currencies.uniq)
      .where(date: (dates.min - MIRROR_DATE_WINDOW)..(dates.max + MIRROR_DATE_WINDOW))
      .excluding_pending
      .excluding_split_parents
      .where("NOT EXISTS (SELECT 1 FROM transfers WHERE transfers.inflow_transaction_id = entries.entryable_id OR transfers.outflow_transaction_id = entries.entryable_id)")
  end

  attr_reader :import

  def initialize(import)
    @import = import
  end

  def account
    import.account
  end

  # rows: unsaved or saved Import::Row records of this import, in order.
  # Returns one Classification per row (nil when the import has no account).
  def classify(rows)
    return Array.new(rows.size) if account.blank?

    mirrors = mirror_candidates(rows)
    claimed_entry_ids = Set.new

    rows.map do |row|
      classify_row(row, mirrors, claimed_entry_ids)
    rescue ArgumentError, TypeError
      # A row whose date or amount will not parse is left to the review step.
      nil
    end
  end

  private
    def classify_row(row, mirrors, claimed_entry_ids)
      hints = Transaction::CounterpartyParser.parse(row.counterparty_text)
      scores = Hash.new { |hash, key| hash[key] = { score: 0.to_d, reasons: [] } }
      generic = 0.to_d
      generic_reasons = []

      own_last4s = own_last4_values
      counterparty_fragments = hints.account_fragments - hints.own_card_fragments - own_last4s
      counterparty_fragments.each do |last4|
        last4_index.fetch(last4, []).each do |account_id|
          add(scores, account_id, :identifier, { "code" => "identifier", "value" => "••#{last4}" })
        end
      end

      # On an incoming line the handle is usually the holder's own (PayNow
      # "FROM: X ... TO +65 own number"), never the counterparty.
      handles = row.signed_amount.negative? ? [] : hints.handles
      handles.each do |handle|
        handle_index.fetch(handle, []).each do |account_id|
          add(scores, account_id, :identifier, { "code" => "identifier", "value" => handle })
        end
      end

      if hints.wallet_topup.present?
        # A wallet the parser knows is the family's own money; any other word
        # after a top-up ("TOP UP STARHUB") only counts if an account bears it.
        if hints.known_wallet
          generic += GENERIC_WEIGHTS[:wallet_topup]
          generic_reasons << { "code" => "wallet_topup", "value" => hints.wallet_topup }
        end
        accounts_named(hints.wallet_topup).each do |account_id|
          add(scores, account_id, :wallet_account, { "code" => "account_name", "value" => hints.wallet_topup })
        end
      end

      # A line naming a household member and someone else ("FROM: ACME TO:
      # RAVI SHARMA") is about the other party; the member is just the holder.
      own_names, other_names = hints.names.partition { |name| own_person?(name) }
      own_names = [] if other_names.any?
      (own_names + other_names).each do |name|
        if own_names.include?(name)
          generic += GENERIC_WEIGHTS[:own_name]
          generic_reasons << { "code" => "own_name", "value" => name }
          holder_accounts_for(name).each do |account_id|
            add(scores, account_id, :holder_account, { "code" => "holder_name", "value" => name })
          end
        else
          accounts_named(name).each do |account_id|
            add(scores, account_id, :name_account, { "code" => "account_name", "value" => name })
          end
        end
      end

      if hints.self_marker
        generic += GENERIC_WEIGHTS[:self_marker]
        generic_reasons << { "code" => "self_marker" }
      end

      if hints.card_payment && account.liability?
        # On a card's own statement the bill was paid from one of the family's
        # bank accounts; a mirror entry there says which.
        generic += GENERIC_WEIGHTS[:card_payment_received]
        generic_reasons << { "code" => "card_payment_received" }
      elsif hints.card_payment
        # Paying a card bill is the family's own money even before the card's
        # account is known.
        generic += GENERIC_WEIGHTS[:card_payment]
        generic_reasons << { "code" => "card_payment" }
        card_ids = card_account_ids
        card_ids.each do |account_id|
          if scores.key?(account_id)
            add(scores, account_id, :card_payment_to_card, { "code" => "card_payment_to_card" })
          elsif card_ids.one? && counterparty_fragments.none?
            # A line naming a card number the family does not track is about
            # some other card.
            add(scores, account_id, :only_card, { "code" => "only_card" })
          end
        end
      end

      mirror = best_mirror(row, mirrors, claimed_entry_ids, scores)
      if mirror
        add(scores, mirror.account_id, :mirror, { "code" => "mirror_entry", "date" => mirror.date.iso8601 })
      end

      decide(scores, generic.clamp(0, 1), generic_reasons, mirror, claimed_entry_ids)
    end

    def decide(scores, generic, generic_reasons, mirror, claimed_entry_ids)
      ranked = scores.sort_by { |_, data| -data[:score] }
      strong = ranked.select { |_, data| data[:score] >= CONFLICT_THRESHOLD }

      if strong.size > 1
        reasons = strong.flat_map { |account_id, data| tag(data[:reasons], account_id) }
        return Classification.new(counterparty_class: "unknown", account_id: nil, entry_id: nil, confidence: nil,
          reasons: [ { "code" => "conflict" } ] + reasons + generic_reasons)
      end

      best_account_id, best = ranked.first
      # Two accounts with the same evidence: naming either would be a guess.
      best = nil if best && ranked.second && ranked.second.last[:score] == best[:score]
      if best && best[:score] >= CANDIDATE_FLOOR && untracked_key?(best_account_id)
        total = (best[:score] + (generic.positive? ? WEIGHTS[:generic_bonus] : 0)).clamp(0, 1)
        if total >= SUGGEST_THRESHOLD
          # Naming the wrong untracked account only mislabels a transfer, so
          # what the family taught it is enough to apply.
          return Classification.new(counterparty_class: "internal_untracked", account_id: nil, entry_id: nil, confidence: total.round(4),
            reasons: tag(best[:reasons], best_account_id) + generic_reasons, untracked_account_id: untracked_id(best_account_id))
        end
      elsif best && best[:score] >= CANDIDATE_FLOOR
        total = best[:score]
        total += WEIGHTS[:generic_bonus] if generic.positive?
        total = total.clamp(0, 1)
        entry_id = mirror&.account_id == best_account_id ? mirror.id : nil
        reasons = tag(best[:reasons], best_account_id) + generic_reasons

        if total >= APPLY_THRESHOLD
          claimed_entry_ids << entry_id if entry_id
          return Classification.new(counterparty_class: "internal_tracked", account_id: best_account_id, entry_id: entry_id, confidence: total.round(4), reasons: reasons)
        elsif total >= SUGGEST_THRESHOLD
          return Classification.new(counterparty_class: "unknown", account_id: best_account_id, entry_id: entry_id, confidence: total.round(4), reasons: reasons)
        end
      end

      if generic.positive?
        Classification.new(counterparty_class: "internal_untracked", account_id: nil, entry_id: nil, confidence: generic.round(4), reasons: generic_reasons)
      else
        Classification.new(counterparty_class: "external", account_id: nil, entry_id: nil, confidence: nil, reasons: [])
      end
    end

    def add(scores, account_id, weight_key, reason)
      entry = scores[account_id]
      # Each kind of evidence counts once per account, however often it repeats.
      return if entry[:reasons].any? { |existing| existing["code"] == reason["code"] && existing["value"] == reason["value"] }
      return if entry[:reasons].any? { |existing| existing["weight"] == weight_key.to_s }

      entry[:score] += WEIGHTS.fetch(weight_key)
      entry[:reasons] << reason.merge("weight" => weight_key.to_s)
    end

    def tag(reasons, key)
      owner = untracked_key?(key) ? { "untracked_account_id" => untracked_id(key) } : { "account_id" => key }
      reasons.map { |reason| reason.except("weight").merge(owner) }
    end

    def untracked_key?(key)
      key.to_s.start_with?(UNTRACKED_PREFIX)
    end

    def untracked_id(key)
      key.to_s.delete_prefix(UNTRACKED_PREFIX)
    end

    def untracked_key(id)
      "#{UNTRACKED_PREFIX}#{id}"
    end

    def untracked_accounts
      @untracked_accounts ||= import.family.own_untracked_accounts.to_a
    end

    # Accounts a line may name: the family's visible accounts other than the
    # one being imported into.
    def other_accounts
      @other_accounts ||= import.family.accounts.visible.where.not(id: account.id).to_a
    end

    def other_account_ids
      @other_account_ids ||= other_accounts.map(&:id).to_set
    end

    def identifiers
      @identifiers ||= import.family.account_identifiers.for_visible_accounts.to_a +
        import.family.account_identifiers.for_untracked_accounts.to_a
    end

    # The key an identifier's owner scores under, or nil when the owner cannot
    # be named on this line (the import's own account, or a hidden one).
    def owner_key(identifier)
      return untracked_key(identifier.own_untracked_account_id) if identifier.own_untracked_account_id
      identifier.account_id if other_account_ids.include?(identifier.account_id)
    end

    def last4_index
      @last4_index ||= begin
        index = Hash.new { |hash, key| hash[key] = [] }
        identifiers.each do |identifier|
          key = owner_key(identifier)
          next unless key && identifier.kind.in?(AccountIdentifier::LAST4_KINDS)

          index[identifier.value] << key unless index[identifier.value].include?(key)
        end
        # Accounts created from a statement carry their last four in the name
        # ("DBS Altitude ••8105"); keep honouring that.
        other_accounts.each do |other|
          "#{other.name} #{other.institution_name}".scan(MASKED_LAST4).flatten.each do |last4|
            index[last4] << other.id unless index[last4].include?(other.id)
          end
        end
        index
      end
    end

    def handle_index
      @handle_index ||= identifiers.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |identifier, index|
        key = owner_key(identifier)
        next unless key && identifier.kind == "payment_handle"

        index[identifier.value.downcase] << key unless index[identifier.value.downcase].include?(key)
      end
    end

    # The import account's own numbers: a line naming them is about this
    # account (its own card on a purchase), not a counterparty.
    def own_last4_values
      @own_last4_values ||= begin
        values = identifiers.select { |identifier| identifier.account_id == account.id && identifier.kind.in?(AccountIdentifier::LAST4_KINDS) }.map(&:value)
        values << import.statement_identifier_last4 if import.respond_to?(:statement_identifier_last4) && import.statement_identifier_last4
        values += "#{account.name} #{account.institution_name}".scan(MASKED_LAST4).flatten
        values.uniq
      end
    end

    def card_account_ids
      @card_account_ids ||= other_accounts.select(&:credit_card?).map(&:id)
    end

    # Accounts whose name or institution carries the given words, e.g. a
    # "PAYLAH" top-up and an account named "DBS PayLah!".
    def accounts_named(text)
      words = name_words(text)
      return [] if words.empty?

      other_accounts.select { |other| (words - name_words("#{other.name} #{other.institution_name}")).empty? }.map(&:id) +
        untracked_accounts.select { |untracked| (words - name_words(untracked.name)).empty? }.map { |untracked| untracked_key(untracked.id) }
    end

    def holder_accounts_for(name)
      identifiers.select do |identifier|
        identifier.kind == "holder_name" && other_account_ids.include?(identifier.account_id) && same_person?(name, person_words(identifier.value))
      end.map(&:account_id).uniq
    end

    # A family member, or a holder named on one of the family's statements.
    # Word order and titles are ignored: banks print "SHARMA RAVI" and
    # "MR RAVI SHARMA" for the same person.
    def own_person?(name)
      own_people.any? { |person| same_person?(name, person) }
    end

    # Whether a printed name is the person with these name words. Every full
    # word must be one of theirs, and each of their names not printed in full
    # must appear as an initial ("A SHARMA" for Arjun Sharma). Extra initials
    # are allowed: banks add middle initials ("RAVI K SHARMA").
    def same_person?(name, person)
      tokens = name_tokens(name)
      full = tokens.reject { |token| token.length == 1 }.to_set
      initials = tokens.select { |token| token.length == 1 }
      return false if full.empty? || full.size + initials.size < 2 || !full.subset?(person)

      (person - full).all? { |word| initials.include?(word[0]) }
    end

    def name_tokens(name)
      name.to_s.upcase.scan(/[[:alpha:]]+/).reject { |word| word.in?(TITLES) }
    end

    def own_people
      @own_people ||= begin
        people = import.family.users.map { |user| person_words("#{user.first_name} #{user.last_name}") }
        people += identifiers.select { |identifier| identifier.kind == "holder_name" }.map { |identifier| person_words(identifier.value) }
        people.select { |words| words.size >= 2 }.to_set
      end
    end

    def person_words(name)
      name_words(name).reject { |word| word.in?(TITLES) || word.length == 1 }.to_set
    end

    def name_words(text)
      text.to_s.upcase.scan(/[[:alnum:]]+/).reject { |word| word.length < 2 || word.match?(/\A\d+\z/) }.uniq
    end

    MirrorCandidate = Data.define(:id, :account_id, :date, :amount)

    # Entries in the family's other accounts that could be the other side of
    # one of these rows: the opposite amount, same currency, near the date,
    # and not already part of a transfer.
    def mirror_candidates(rows)
      wanted = rows.filter_map do |row|
        { amount: -row.signed_amount, date: Date.iso8601(row.date_iso), currency: row.currency }
      rescue ArgumentError, TypeError
        nil
      end
      return [] if wanted.empty? || other_account_ids.empty?

      self.class.mirror_scope(
        account_ids: other_account_ids.to_a,
        amounts: wanted.map { |w| w[:amount] },
        currencies: wanted.map { |w| w[:currency] },
        dates: wanted.map { |w| w[:date] }
      ).pluck(:id, :account_id, :date, :amount, :currency)
        .map { |id, account_id, date, amount, currency| [ MirrorCandidate.new(id:, account_id:, date:, amount:), currency ] }
    end

    # A mirror in an account the line already points at wins. When that
    # evidence is strong, a same-amount entry elsewhere is ignored, so it
    # cannot turn a clear match into a conflict; weak evidence only breaks
    # the tie.
    def best_mirror(row, mirrors, claimed_entry_ids, scores)
      amount = -row.signed_amount
      date = Date.iso8601(row.date_iso)

      candidates = mirrors
        .select { |mirror, currency| currency == row.currency && mirror.amount == amount && (mirror.date - date).abs <= MIRROR_DATE_WINDOW && !claimed_entry_ids.include?(mirror.id) }
        .map(&:first)
      strong_ids = scores.select { |_, data| data[:score] >= CONFLICT_THRESHOLD }.keys
      candidates = candidates.select { |mirror| strong_ids.include?(mirror.account_id) } if strong_ids.any?
      candidates.min_by { |mirror| [ scores.key?(mirror.account_id) ? 0 : 1, (mirror.date - date).abs, mirror.id ] }
    end
end
