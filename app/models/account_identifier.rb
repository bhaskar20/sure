# How an account appears on other statements, so a line in one statement
# ("TRANSFER TO A/C XX4821") can be traced to another of the family's
# accounts. Only partial numbers and names are kept, never a full account or
# card number.
class AccountIdentifier < ApplicationRecord
  include Encryptable

  KINDS = %w[account_last4 card_last4 payment_handle holder_name].freeze
  SOURCES = %w[statement provider user].freeze
  LAST4_KINDS = %w[account_last4 card_last4].freeze

  # Deterministic so the (account, kind, value) uniqueness still holds.
  if encryption_ready?
    encrypts :value, deterministic: true
  end

  belongs_to :account
  belongs_to :family
  belongs_to :account_statement, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }
  validates :value, presence: true, length: { maximum: 120 }
  validates :value, format: { with: /\A\d{4}\z/ }, if: -> { kind.in?(LAST4_KINDS) }
  validate :family_matches_account

  normalizes :value, with: ->(value) { value.to_s.squish }

  scope :for_visible_accounts, -> { joins(:account).merge(Account.visible) }

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

  private
    def family_matches_account
      return if account.blank? || family_id.blank?

      errors.add(:family, :invalid) unless account.family_id == family_id
    end
end
