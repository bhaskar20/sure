namespace :desktop do
  # Sure Desktop installs created before the app generated Active Record
  # encryption keys stored encryptable columns in plaintext. Encrypt those rows
  # in place, once, so lookups on deterministic columns (such as User#email,
  # whose normalization hides it from Rails' extended queries) find them.
  # Run with ACTIVE_RECORD_ENCRYPTION_SUPPORT_UNENCRYPTED_DATA=true so the
  # plaintext values can be read. Safe to re-run: encrypted rows are rewritten
  # with the same values.
  desc "Encrypt rows written before Active Record encryption was configured"
  task encrypt_existing_data: :environment do
    Rails.application.eager_load!

    models = ActiveRecord::Base.descendants.select do |model|
      !model.abstract_class? && model.encrypted_attributes.present? && model.table_exists?
    end

    models.sort_by(&:name).each do |model|
      count = 0
      model.unscoped.find_each do |record|
        record.encrypt
        count += 1
      end
      puts "#{model.name}: #{count} rows (#{model.encrypted_attributes.to_a.join(', ')})" if count.positive?
    end
  end
end
