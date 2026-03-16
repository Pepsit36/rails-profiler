# frozen_string_literal: true

require "bundler/setup"
require "rack"
require "rack/test"
require "active_support"
require "active_support/isolated_execution_state"
require "active_support/notifications"
require "profiler"

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
      is_ajax: attrs[:is_ajax] || false
    }
  )
  profile
end
