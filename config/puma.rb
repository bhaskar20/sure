# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.

rails_env = ENV.fetch("RAILS_ENV", "development")

# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# to prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = ENV.fetch("RAILS_MAX_THREADS") { 3 }
threads threads_count, threads_count

if rails_env == "production"
  # If you are running more than 1 thread per process, the workers count
  # should be equal to the number of processors (CPU cores) in production.
  #
  # It defaults to 1 because it's impossible to reliably detect how many
  # CPU cores are available. Make sure to set the `WEB_CONCURRENCY` environment
  # variable to match the number of processors.
  workers_count = Integer(ENV.fetch("WEB_CONCURRENCY") { 1 })
  # Always set: Puma defaults workers to WEB_CONCURRENCY, so 1 would otherwise start a one-worker cluster.
  workers(workers_count > 1 ? workers_count : 0)

  preload_app!
end

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
# The bind host is controlled via the Rails-native `BINDING` env var (set to
# `0.0.0.0` in containers, or `::` for IPv6 dual-stack). See docs/hosting/docker.md.
# Sure Desktop binds loopback only (see the end of this file).
port ENV.fetch("PORT") { 3000 } unless ENV["SURE_DESKTOP"] == "1"

# Specifies the `environment` that Puma will run in.
environment rails_env

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

pidfile ENV["PIDFILE"] if ENV["PIDFILE"]

if rails_env == "development"
  # Specifies a very generous `worker_timeout` so that the worker
  # isn't killed by Puma when suspended by a debugger.
  worker_timeout 3600
end

# Sure Desktop: the packaged app runs everything on this machine. Puma listens
# on loopback only, and Sidekiq runs inside the Puma process (embedded mode), so
# the desktop launcher supervises one Ruby process instead of a web + worker pair.
if ENV["SURE_DESKTOP"] == "1"
  bind "tcp://127.0.0.1:#{ENV.fetch("PORT") { 3000 }}"

  desktop_sidekiq = nil
  start_sidekiq = lambda do
    # Mirrors config/sidekiq.yml, which embedded mode does not read.
    desktop_sidekiq = Sidekiq.configure_embed do |config|
      config.queues = %w[scheduled,10 high_priority,4 medium_priority,2 low_priority,1 default,1]
      config.concurrency = Integer(ENV.fetch("SIDEKIQ_CONCURRENCY") { 2 })
      # Jobs still running when Sure quits are pushed back to the queue after
      # this many seconds; it must end before the launcher's 15s hard stop.
      config[:timeout] = 8
      config.capsule("ai") do |cap|
        cap.concurrency = 1
        cap.queues = %w[ai_high_priority ai_low_priority]
      end
    end
    desktop_sidekiq.run
  end
  # Puma runs after_stopped from its SIGTERM handler, where Ruby forbids the
  # mutexes Sidekiq's shutdown takes ("can't be called from trap context").
  # Stop it on its own thread so in-flight jobs are pushed back to the queue.
  stop_sidekiq = -> { Thread.new { desktop_sidekiq&.stop }.join }

  # Puma 7 renamed on_booted/on_stopped; keep working on either name.
  respond_to?(:after_booted) ? after_booted(&start_sidekiq) : on_booted(&start_sidekiq)
  respond_to?(:after_stopped) ? after_stopped(&stop_sidekiq) : on_stopped(&stop_sidekiq)
end
