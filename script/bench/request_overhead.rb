# frozen_string_literal: true

# What the profiler adds to a request, in milliseconds, in the default configuration.
#
#   bundle exec ruby script/bench/request_overhead.rb                # stackprof installed
#   bundle exec ruby script/bench/request_overhead.rb --no-stackprof # what most applications have
#   bundle exec ruby script/bench/request_overhead.rb --threads 8    # cost of one SQL event while
#                                                                    # 8 other requests are profiled
#
# A minimal Rails application with 30 resourceful controllers (210 routes) answers a page that
# runs 20 SQL queries, 15 of them the same statement, renders 3 partials and returns about 20 KB
# of HTML. Storage is in memory. Prints the mean over the measured requests, after a warm-up.

if ARGV.include?("--no-stackprof")
  # As in an application that does not bundle stackprof: it is not a runtime dependency of the gem.
  module Kernel
    alias_method :__bench_require, :require
    def require(name)
      raise LoadError, "cannot load such file -- stackprof" if name == "stackprof"

      __bench_require(name)
    end
  end
end

ENV["RAILS_ENV"] = "development"

require "bundler/setup"
require "logger"
require "tmpdir"
require "json"
require "rails"
require "action_controller/railtie"
require "profiler"
require "profiler/railtie"
require "profiler/engine"

ITERATIONS = Integer(ENV.fetch("ITERATIONS", 300))
WARMUP = 50
HTML = "<html><body>#{"<p>row</p>" * 2_000}</body></html>"

PAGE = lambda do |_env|
  20.times do |i|
    sql = i < 15 ? "SELECT * FROM comments WHERE post_id = ?" : "SELECT * FROM table_#{i} WHERE id = ?"
    ActiveSupport::Notifications.instrument("sql.active_record", sql: sql, name: "Load", binds: []) {}
  end
  3.times do |i|
    ActiveSupport::Notifications.instrument("render_partial.action_view", identifier: "app/views/rows/_row#{i}.html.erb") {}
  end
  [200, { "content-type" => "text/html" }, [HTML]]
end

class BenchApp < Rails::Application
  config.root = Dir.mktmpdir("profiler-bench")
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "b" * 64
  config.hosts.clear
  config.profiler.enabled = true
  config.profiler.storage = :memory

  routes.append do
    30.times { |i| resources :"things#{i}" }
    get "/page", to: PAGE
  end
end
BenchApp.initialize!

def run(app, n)
  env = Rack::MockRequest.env_for("/page", "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost")
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  n.times do
    _status, _headers, body = app.call(env.dup)
    body.each { |_| }
    body.close if body.respond_to?(:close)
  end
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0 / n
end

def request_overhead
  Profiler.configuration.enabled = false # the middleware lets the request through untouched
  run(BenchApp, WARMUP)
  bare_ms = run(BenchApp, ITERATIONS)
  Profiler.configuration.enabled = true
  run(BenchApp, WARMUP)
  full_ms = run(BenchApp, ITERATIONS)
  profile = Profiler.storage.list(limit: 1).first
  size = profile.to_json.bytesize
  sections = %w[routes env].to_h { |k| [k, profile.collectors_data[k].to_json.bytesize] }

  puts format("stackprof=%-5s ruby=%s  without profiler %.3f ms/req, with profiler %.3f ms/req, overhead +%.3f ms",
              defined?(StackProf) ? "yes" : "no", RUBY_VERSION, bare_ms, full_ms, full_ms - bare_ms)
  puts "stored profile: #{size} bytes (routes section #{sections["routes"]}, env section #{sections["env"]})"
end

# The cost of one sql.active_record event emitted by a request that is not profiled (a thread
# of the server's pool, or an unprofiled path) while +others+ requests are being profiled.
def sql_event_cost(others)
  ready = Queue.new
  release = Queue.new
  threads = Array.new(others) do
    Thread.new do
      collector = Profiler::Collectors::DatabaseCollector.new(Profiler::Models::Profile.new)
      collector.subscribe
      ready << true
      release.pop
      collector.unsubscribe
    end
  end
  others.times { ready.pop }

  n = 20_000
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  n.times { ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1", name: "Load", binds: []) {} }
  us = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1_000_000.0 / n
  others.times { release << true }
  threads.each(&:join)
  us
end

if (i = ARGV.index("--threads"))
  others = Integer(ARGV[i + 1])
  [0, others].each do |count|
    puts format("one SQL event on an unprofiled thread, %2d requests profiled meanwhile: %.2f us", count, sql_event_cost(count))
  end
else
  request_overhead
end
