# One of the family's own accounts that Sure does not track, such as a wallet
# or an account at a bank the family has not added. Statement lines moving
# money to or from it are transfers, not income or spending; it has no
# balance of its own.
class OwnUntrackedAccount < ApplicationRecord
  belongs_to :family
  has_many :account_identifiers, dependent: :destroy
  has_many :transactions, dependent: :nullify
  has_many :import_rows, class_name: "Import::Row", foreign_key: :counterparty_untracked_account_id, dependent: :nullify, inverse_of: false

  normalizes :name, with: ->(name) { name.to_s.squish }

  validates :name, presence: true, length: { maximum: 120 }
  validate :name_unique_in_family

  scope :alphabetically, -> { order(Arel.sql("lower(name)"), :id) }

  private
    def name_unique_in_family
      return if name.blank? || family_id.blank?

      taken = self.class.where(family_id: family_id).where("lower(name) = ?", name.downcase).where.not(id: id).exists?
      errors.add(:name, :taken) if taken
    end
end
