# frozen_string_literal: true

require "bundler/setup"
require "profiler"

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
