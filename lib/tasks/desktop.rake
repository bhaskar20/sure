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

namespace :desktop do
  DEV_TESTER_EMAIL = "desktop-tester@example.com".freeze
  DEV_MEMBER_EMAIL = "dev-member@example.com".freeze
  # Local development fixtures only: the task refuses to run outside a
  # Sure Desktop dev data folder (scripts/local-rails.sh --dev).
  DEV_PASSWORD = "SureDesktop-dev1!".freeze

  # Test accounts plus a large demo family for Sure Desktop development:
  #   desktop-tester@example.com / dev-member@example.com  (password: DEV_PASSWORD)
  #     one household: checking + credit card, categories, ~2 months of
  #     transactions and a categorization rule
  #   user@example.com / Password1!  (+ partner_user@example.com)
  #     Sure's full demo dataset (demo_data:default)
  # Safe to re-run: existing accounts are left as they are.
  desc "Seed Sure Desktop dev data with test accounts and the demo family"
  task dev_seed: :environment do
    abort "desktop:dev_seed only runs against Sure Desktop dev data (scripts/local-rails.sh --dev)" unless ENV["SURE_DESKTOP_DEV"] == "1"

    if User.exists?(email: DEV_TESTER_EMAIL)
      puts "Test accounts exist (#{DEV_TESTER_EMAIL}, #{DEV_MEMBER_EMAIL})"
    else
      seed_desktop_test_household
      puts "Created test accounts #{DEV_TESTER_EMAIL} and #{DEV_MEMBER_EMAIL}"
    end

    # The demo family normally signs in as user@example.com; if someone already
    # signed up with that address in dev, it goes to demo@example.com instead.
    demo_email = [ "user@example.com", "demo@example.com" ].find do |email|
      user = User.find_by(email: email)
      user.nil? || user.family.accounts.exists?
    end
    if demo_email.nil?
      puts "Skipping the demo family: user@ and demo@example.com are both taken by empty accounts"
    elsif User.find_by(email: demo_email)
      puts "Demo family exists (#{demo_email})"
    else
      puts "Loading the demo family as #{demo_email} (about a minute)…"
      Demo::Generator.new(seed: 42).generate_default_data!(skip_clear: true, email: demo_email)
    end

    puts <<~MSG

      Sign in with:
        #{DEV_TESTER_EMAIL} / #{DEV_PASSWORD}   (admin, small household)
        #{DEV_MEMBER_EMAIL} / #{DEV_PASSWORD}   (member of the same household)
    MSG
    puts "  #{demo_email} / Password1!   (demo family, lots of data)" if demo_email
  end

  def seed_desktop_test_household
    ActiveRecord::Base.transaction do
      family = Family.create!(name: "Desk Tester", currency: "USD", locale: "en", country: "US",
                              timezone: "America/New_York", date_format: "%m-%d-%Y")
      [
        [ DEV_TESTER_EMAIL, "Desk", "Tester", "admin" ],
        [ DEV_MEMBER_EMAIL, "Dev", "Member", "member" ]
      ].each do |email, first, last, role|
        user = family.users.create!(email: email, first_name: first, last_name: last, role: role,
                                    password: DEV_PASSWORD, onboarded_at: Time.current)
        user.update!(ai_enabled: true, show_ai_sidebar: true)
      end

      categories = {
        "Housing" => "#6471eb", "Groceries" => "#4da568", "Income" => "#e99537",
        "Transportation" => "#df4e92", "Entertainment" => "#c44fe9", "Dining" => "#eb5429"
      }.to_h { |name, color| [ name, family.categories.create!(name: name, color: color, lucide_icon: "shapes") ] }

      opened = 75.days.ago.to_date
      checking = Account.create_and_sync(
        { family: family, name: "Mock Checking", balance: 5_250.75, currency: "USD",
          accountable_type: "Depository", accountable_attributes: { subtype: "checking" } },
        skip_initial_sync: true, opening_balance_date: opened
      )
      card = Account.create_and_sync(
        { family: family, name: "Mock Visa", balance: 0, currency: "USD",
          accountable_type: "CreditCard", accountable_attributes: {} },
        skip_initial_sync: true, opening_balance_date: opened
      )

      add = lambda do |account, days_ago, name, amount, category|
        account.entries.create!(name: name, amount: amount, currency: "USD", date: days_ago.days.ago.to_date,
                                entryable: Transaction.new(category: category && categories.fetch(category)))
      end
      # Amounts: positive = money out, negative = money in.
      [ 60, 30 ].each do |d|
        add.(checking, d, "Mock Rent", 1_200, "Housing")
        add.(checking, d - 2, "Mock Payroll", -3_100, "Income")
        add.(checking, d - 5, "Mock Visa payment", 250, nil)
        add.(card, d - 5, "Payment received", -250, nil)
      end
      add.(checking, 15, "Mock Payroll", -3_100, "Income")
      [ [ 58, 54.20 ], [ 44, 81.13 ], [ 31, 67.90 ], [ 17, 92.41 ], [ 3, 48.75 ] ].each do |d, amt|
        add.(card, d, "Mock Grocery Mart", amt, "Groceries")
      end
      [ [ 55, 42.10 ], [ 38, 39.80 ], [ 20, 45.25 ], [ 6, 41.00 ] ].each do |d, amt|
        add.(card, d, "Mock Gas Station", amt, "Transportation")
      end
      [ 52, 22, 2 ].each { |d| add.(card, d, "Mock Streaming", 15.99, "Entertainment") }
      [ [ 47, 63.40 ], [ 26, 38.15 ], [ 9, 74.80 ] ].each { |d, amt| add.(card, d, "Mock Bistro", amt, "Dining") }
      # Uncategorized, for trying rules and AI categorization.
      [ [ 12, 4.85, "Mock Coffee Shop" ], [ 8, 6.25, "Mock Coffee Shop" ], [ 4, 129.99, "Mock Electronics" ] ].each do |d, amt, name|
        add.(card, d, name, amt, nil)
      end

      family.rules.create!(
        resource_type: "transaction", name: "Coffee is dining",
        conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "Coffee" } ],
        actions_attributes: [ { action_type: "set_transaction_category", value: categories.fetch("Dining").id } ]
      )

      [ checking, card ].each(&:sync_later)
    end
  end
end
