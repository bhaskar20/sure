# How an account appears on other statements, so a line in one statement
# ("TRANSFER TO A/C XX4821") can be traced to another of the family's
# accounts, tracked or not. Only partial numbers and names are kept, never a
# full account or card number.
class AccountIdentifier < ApplicationRecord
  include Encryptable

  KINDS = %w[account_last4 card_last4 payment_handle holder_name].freeze
  SOURCES = %w[statement provider user].freeze
  LAST4_KINDS = %w[account_last4 card_last4].freeze

  # Deterministic so the (account, kind, value) uniqueness still holds.
  if encryption_ready?
    encrypts :value, deterministic: true
  end

  belongs_to :account, optional: true
  belongs_to :own_untracked_account, optional: true
  belongs_to :family
  belongs_to :account_statement, optional: true
  belongs_to :learned_by_import, class_name: "Import", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }
  validates :value, presence: true, length: { maximum: 120 }
  validates :value, format: { with: /\A\d{4}\z/ }, if: -> { kind.in?(LAST4_KINDS) }
  validate :one_owner
  validate :family_matches_account

  normalizes :value, with: ->(value) { value.to_s.squish }

  scope :for_visible_accounts, -> { joins(:account).merge(Account.visible) }
  scope :for_untracked_accounts, -> { where.not(own_untracked_account_id: nil) }

  class << self
    # Records what a statement linked to an account says about that account.
    # Idempotent: a statement re-linked or re-read adds nothing twice.
    def remember_from_statement!(statement, document_type: nil, holder_name: nil)
      account = statement&.account
      return [] if account.blank?

      candidates = []
      last4 = statement.account_last4_hint.to_s
      if last4.match?(/\A\d{4}\z/)
        kind = document_type.to_s == "credit_card_statement" || account.accountable_type == "CreditCard" ? "card_last4" : "account_last4"
        candidates << { kind: kind, value: last4 }
      end

      name = holder_name.to_s.squish.first(120)
      candidates << { kind: "holder_name", value: name } if name.length >= 3

      candidates.filter_map do |attrs|
        identifier = find_or_initialize_by(account: account, kind: attrs[:kind], value: attrs[:value])
        next identifier if identifier.persisted?

        identifier.assign_attributes(family_id: account.family_id, source: "statement", account_statement: statement)
        # A savepoint, so a concurrent import recording the same value leaves
        # the surrounding transaction usable.
        transaction(requires_new: true) { identifier.save! }
        identifier
      rescue ActiveRecord::RecordNotUnique
        find_by(account: account, kind: attrs[:kind], value: attrs[:value])
      end
    end

    # Learns the partial numbers and payment handles a statement line names
    # once a reviewer has said which account (tracked or not) the line is
    # about. The statement's own card number is never learned.
    #
    # A handle on an incoming line is the statement holder's own (PayNow
    # "FROM: X ... TO +65 own number"), so handles are learned from outgoing
    # lines only. Values of the statement's own account (exclude_values) and
    # values another account already owns are never learned: either would
    # make every later line naming them ambiguous.
    def learn_from_line!(owner, hints, import: nil, outgoing: true, exclude_values: [])
      owner_key = owner.is_a?(OwnUntrackedAccount) ? :own_untracked_account : :account
      exclude = exclude_values.map { |value| value.to_s.downcase }.to_set
      values = (hints.account_fragments - hints.own_card_fragments).map { |last4| [ owner_key == :account && owner.credit_card? ? "card_last4" : "account_last4", last4 ] }
      # A wallet top-up's handle is usually the holder's own phone, which their
      # bank also prints on incoming lines.
      values += hints.handles.map { |handle| [ "payment_handle", handle ] } if outgoing && hints.wallet_topup.blank?
      values.reject! { |_, value| exclude.include?(value.to_s.downcase) }

      owner_ref = [ owner_key, owner.id ]
      owners_by_value = where(family_id: owner.family_id).to_a.group_by { |other| other.value.to_s.downcase }
      # Accounts created from a statement carry their last four in the name.
      named = owner.family.accounts.where.not(id: owner_key == :account ? owner.id : nil)
        .flat_map { |account| "#{account.name} #{account.institution_name}".scan(Import::CounterpartyClassifier::MASKED_LAST4).flatten }.to_set
      values.filter_map do |kind, value|
        next if named.include?(value) || owners_by_value.fetch(value.to_s.downcase, []).any? { |other| other.owner_ref != owner_ref }

        identifier = find_or_initialize_by(owner_key => owner, kind: kind, value: value)
        if identifier.persisted?
          # Confirmed by a second import's review: no longer one import's to forget.
          identifier.update_columns(learned_by_import_id: nil) if import && identifier.learned_by_import_id && identifier.learned_by_import_id != import.id
          next identifier
        end

        identifier.assign_attributes(family_id: owner.family_id, source: "user", learned_by_import_id: import&.id)
        transaction(requires_new: true) { identifier.save! }
        identifier
      rescue ActiveRecord::RecordNotUnique
        find_by(owner_key => owner, kind: kind, value: value)
      end
    end

    # A statement no longer read for an account (unlinked, or moved to
    # another one) stops vouching for what it said about it. An identifier
    # another statement of that account still shows moves to that statement.
    def release_statement!(statement, keep_account_id: nil, kinds: nil, keep_value: nil)
      scope = where(account_statement_id: statement.id)
      scope = scope.where.not(account_id: keep_account_id) if keep_account_id
      scope = scope.where(kind: kinds) if kinds
      scope.find_each do |identifier|
        next if keep_value && identifier.value == keep_value

        if (other = other_statement_showing(identifier, excluding: statement))
          identifier.update!(account_statement: other)
        else
          identifier.destroy!
        end
      end
    end

    private
      def other_statement_showing(identifier, excluding:)
        candidates = AccountStatement.where(account_id: identifier.account_id).where.not(id: excluding.id)
        if identifier.kind.in?(LAST4_KINDS)
          candidates.find_by(account_last4_hint: identifier.value)
        elsif identifier.kind == "holder_name"
          PdfImport.where(account_statement_id: candidates.select(:id)).find_each do |import|
            holder = import.extracted_data.is_a?(Hash) ? import.extracted_data["account_holder"].to_s.squish : nil
            return import.account_statement if holder == identifier.value
          end
          nil
        end
      end
  end

  def owner_ref
    own_untracked_account_id ? [ :own_untracked_account, own_untracked_account_id ] : [ :account, account_id ]
  end

  private
    def one_owner
      errors.add(:base, :invalid) unless [ account_id, own_untracked_account_id ].compact.one? || [ account, own_untracked_account ].compact.one?
    end

    def family_matches_account
      owner = account || own_untracked_account
      return if owner.blank? || family_id.blank?

      errors.add(:family, :invalid) unless owner.family_id == family_id
    end
end
