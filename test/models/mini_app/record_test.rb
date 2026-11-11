require "test_helper"

class MiniApp::RecordTest < ActiveSupport::TestCase
  setup do
    @app = mini_apps(:recategorizer)
  end

  test "stores any JSON value" do
    assert @app.records.create!(collection: "notes", key: "a", data: { "text" => "hi" }).persisted?
    assert @app.records.create!(collection: "notes", key: "b", data: [ 1, 2 ]).persisted?
    assert @app.records.create!(collection: "notes", key: "c", data: "plain").persisted?
  end

  test "validates collection, key and data" do
    record = @app.records.new(collection: "Bad Name", key: "", data: nil)

    assert_not record.valid?
    assert record.errors.added?(:collection, :invalid, value: "Bad Name")
    assert record.errors.added?(:key, :blank)
    assert record.errors.added?(:data, :blank)

    record = @app.records.new(collection: "notes", key: "k" * 256, data: {})
    assert_not record.valid?
    assert record.errors.of_kind?(:key, :too_long)
  end

  test "limits the size of one record" do
    record = @app.records.new(collection: "notes", key: "big", data: { "blob" => "x" * MiniApp::Record::MAX_DATA_BYTES })

    assert_not record.valid?
    assert record.errors.of_kind?(:data, :too_large)
  end

  test "keys are unique per app and collection, not across apps" do
    existing = mini_app_records(:recategorizer_settings)

    assert_not @app.records.new(collection: existing.collection, key: existing.key, data: {}).valid?
    assert @app.records.new(collection: "other", key: existing.key, data: {}).valid?
    assert mini_apps(:budget_peek).records.new(collection: existing.collection, key: existing.key, data: {}).valid?
  end

  test "enforces the per-app record quota" do
    now = Time.current
    rows = (MiniApp::Record::MAX_RECORDS_PER_APP - @app.records.count).times.map do |i|
      { mini_app_id: @app.id, collection: "bulk", key: "k#{i}", data: {}, created_at: now, updated_at: now }
    end
    MiniApp::Record.insert_all!(rows)

    record = @app.records.new(collection: "bulk", key: "one-more", data: {})
    assert_not record.valid?
    assert record.errors.of_kind?(:base, :quota_exceeded)

    assert mini_apps(:budget_peek).records.new(collection: "bulk", key: "one-more", data: {}).valid?
  end

  test "prefix scope treats LIKE wildcards literally" do
    @app.records.create!(collection: "notes", key: "100%_done", data: {})
    @app.records.create!(collection: "notes", key: "100 done", data: {})

    assert_equal [ "100%_done" ], @app.records.in_collection("notes").with_key_prefix("100%_").pluck(:key)
  end
end
