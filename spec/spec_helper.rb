# frozen_string_literal: true

# The specs read source files that carry non-ASCII characters; under LANG=C Ruby would decode
# them as US-ASCII and the suite would fail to load. Pin UTF-8 whatever the locale.
Encoding.default_external = Encoding::UTF_8

# Coverage starts before anything under lib/ is loaded, so every line the suite reaches counts.
require "simplecov"
SimpleCov.start do
  enable_coverage :line
  add_filter "/spec/"
  track_files "lib/**/*.rb"
  # The whole suite measures about 92.1% on Ruby 3.3: the floor stops a
  # regression without failing on run-to-run noise. Checked in the CI only, which always runs the
  # whole suite: a run of a few files is far below it, and would fail for no reason.
  minimum_coverage 92.0 if ENV["CI"]
end

require "bundler/setup"
require "rack"
require "rack/test"
require "active_support"
require "active_support/isolated_execution_state"
require "active_support/notifications"
require "profiler"
# What the railtie does in an application where the profiler is enabled; the suite runs as one.
Profiler::Instrumentation::ThreadContextPropagation.install!

# Explicitly load components not auto-loaded outside of Rails
require "profiler/models/profile"
require "profiler/models/sql_query"
require "profiler/models/timeline_event"
require "profiler/storage/memory_store"
require "profiler/storage/file_store"
require "profiler/storage/redis_store"
require "profiler/collectors/http_collector"
require "profiler/middleware/toolbar_injector"
require "profiler/middleware/cors_middleware"
require "profiler/middleware/profiler_middleware"
require "profiler/mcp/tools/analyze_queries"
require "profiler/collectors/job_collector"
require "profiler/job_profiler"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Clean up after each test
  config.after(:each) do
    Profiler.instance_variable_set(:@configuration, nil)
    Profiler.instance_variable_set(:@storage, nil)
    Profiler::Collectors::CircuitBreaker.reset!
  end
end

def build_profile(attrs = {})
  profile = Profiler::Models::Profile.from_hash(
    {
      token: attrs[:token] || SecureRandom.hex(16),
      path: attrs[:path] || "/test",
      method: attrs[:method] || "GET",
      status: attrs[:status] || 200,
      duration: attrs[:duration] || 10.0,
      memory: attrs[:memory],
      started_at: (attrs[:started_at] || Time.now).iso8601,
      finished_at: (attrs[:finished_at] || Time.now + 0.01).iso8601,
      params: attrs[:params] || {},
      headers: attrs[:headers] || {},
      response_headers: attrs[:response_headers] || {},
      collectors_data: attrs[:collectors_data] || {},
      tabs: attrs[:tabs] || [],
      parent_token: attrs[:parent_token],
      trace_id: attrs[:trace_id],
      span_id: attrs[:span_id],
      parent_span_id: attrs[:parent_span_id],
      server_port: attrs[:server_port],
      url_scheme: attrs[:url_scheme],
      is_ajax: attrs[:is_ajax] || false,
      profile_type: attrs[:profile_type] || "http"
    }
  )
  profile
end

def build_job_profile(attrs = {})
  build_profile(attrs.merge(
    method: "JOB",
    status: attrs[:status] || 200,
    profile_type: "job",
    collectors_data: attrs[:collectors_data] || {
      "job" => {
        "job_class" => attrs[:job_class] || "TestJob",
        "job_id" => attrs[:job_id] || SecureRandom.hex(8),
        "queue" => attrs[:queue] || "default",
        "arguments" => attrs[:arguments] || [],
        "executions" => attrs[:executions] || 0,
        "status" => attrs[:job_status] || "completed"
      }
    }
  ))
end

# What the profiler logged through Profiler.log while the block ran (config.logger).
def capture_profiler_log
  io = StringIO.new
  previous = Profiler.configuration.logger
  Profiler.configuration.logger = Logger.new(io)
  yield
  io.string
ensure
  Profiler.configuration.logger = previous
end
