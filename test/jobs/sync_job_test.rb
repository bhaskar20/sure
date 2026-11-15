require "test_helper"

class SyncJobTest < ActiveJob::TestCase
  test "sync is performed" do
    syncable = accounts(:depository)

    sync = syncable.syncs.create!(window_start_date: 2.days.ago.to_date)

    sync.expects(:perform).once

    SyncJob.perform_now(sync)
  end

  test "a sync waits while another sync of the same syncable is running" do
    syncable = accounts(:depository)
    syncable.syncs.create!(status: :syncing)
    sync = syncable.syncs.create!

    sync.expects(:perform).never

    assert_enqueued_with(job: SyncJob, args: [ sync, { balances_only: true } ]) do
      SyncJob.perform_now(sync, balances_only: true)
    end
    assert sync.reload.pending?
  end

  test "a running sync older than the visible window does not hold others back" do
    syncable = accounts(:depository)
    syncable.syncs.create!(status: :syncing, created_at: (Sync::VISIBLE_FOR + 1.minute).ago)
    sync = syncable.syncs.create!

    sync.expects(:perform).once

    assert_no_enqueued_jobs only: SyncJob do
      SyncJob.perform_now(sync)
    end
  end

  test "a running sync of another syncable does not hold a sync back" do
    accounts(:investment).syncs.create!(status: :syncing)
    sync = accounts(:depository).syncs.create!

    sync.expects(:perform).once

    SyncJob.perform_now(sync)
  end
end
