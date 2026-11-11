# A mini app's own stored data: a JSON document under a collection and key,
# scoped to one installed app (and so to one family).
class MiniApp::Record < ApplicationRecord
  COLLECTION_FORMAT = /\A[a-z0-9_\-]{1,64}\z/
  MAX_KEY_LENGTH = 255
  MAX_DATA_BYTES = 256.kilobytes
  MAX_RECORDS_PER_APP = 5_000

  belongs_to :mini_app

  validates :collection, format: { with: COLLECTION_FORMAT }
  validates :key, presence: true, length: { maximum: MAX_KEY_LENGTH }
  validates :key, uniqueness: { scope: %i[mini_app_id collection] }
  validate :data_must_be_present_and_small
  validate :app_quota_not_exceeded, on: :create

  scope :in_collection, ->(collection) { where(collection: collection) }
  scope :with_key_prefix, ->(prefix) {
    prefix.present? ? where("key LIKE ?", "#{sanitize_sql_like(prefix)}%") : all
  }
  scope :ordered, -> { order(:key) }

  private
    def data_must_be_present_and_small
      if data.nil?
        errors.add(:data, :blank)
      elsif data.to_json.bytesize > MAX_DATA_BYTES
        errors.add(:data, :too_large, size: ActiveSupport::NumberHelper.number_to_human_size(MAX_DATA_BYTES))
      end
    end

    def app_quota_not_exceeded
      return if mini_app.nil?
      if mini_app.records.count >= MAX_RECORDS_PER_APP
        errors.add(:base, :quota_exceeded, count: MAX_RECORDS_PER_APP)
      end
    end
end
