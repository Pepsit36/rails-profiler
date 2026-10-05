# frozen_string_literal: true

# Boots the spec Rails application (spec/support/rails_app.rb) under a real Puma with a fixed
# number of threads, for the specs that measure what a request holds a server thread for.
# Run as a separate process by PumaAppServer; prints the port it listens on, and the id of a
# test run that stays in progress with no output, then serves until it is killed.
#
#   ruby spec/support/puma_app_server_boot.rb THREADS

$stdout.sync = true
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "bundler/setup"
require "profiler"
require_relative "rails_app"
require "profiler/test_runner/run_store"
require "puma"
require "puma/server"

Profiler.configure do |config|
  config.enabled = true
  config.collectors = []
  config.track_http = false
end

run = Profiler::TestRunner.run_store.create(files: [], framework: "rspec")
Profiler::TestRunner.run_store.update(run.id, status: "running")

threads = Integer(ARGV.fetch(0))
server = Puma::Server.new(Rails.application, nil, min_threads: threads, max_threads: threads)
server.add_tcp_listener("127.0.0.1", 0)

puts "PORT=#{server.connected_ports.first}"
puts "RUN=#{run.id}"
server.run.join
