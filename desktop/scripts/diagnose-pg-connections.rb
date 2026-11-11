# Connects to a running PostgreSQL several times with the bundled pg gem,
# with and without SSL / GSSAPI negotiation, and prints each outcome. Used by
# the Windows runtime build to pin down connection failures during db:prepare.
#
#   ruby diagnose-pg-connections.rb PORT PASSWORD
require "pg"

port, password = ARGV
puts "pg #{PG::VERSION}, libpq #{PG.library_version}"

variants = {
  "default" => {},
  "sslmode=disable" => { sslmode: "disable" },
  "gssencmode=disable" => { gssencmode: "disable" },
  "both disabled" => { sslmode: "disable", gssencmode: "disable" }
}

variants.each do |label, extra|
  %w[postgres postgres template1 postgres].each_with_index do |dbname, i|
    params = { host: "127.0.0.1", port: port.to_i, user: "sure", password: password, dbname: dbname, connect_timeout: 10 }.merge(extra)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      conn = PG.connect(params)
      value = conn.exec("select 1").getvalue(0, 0)
      conn.close
      result = "ok (select 1 = #{value})"
    rescue PG::Error => e
      result = "FAILED #{e.class}: #{e.message.strip}"
    end
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    puts format("%-20s #%d %-10s %5dms  %s", label, i + 1, dbname, ms, result)
  end
end
