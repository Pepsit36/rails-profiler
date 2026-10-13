# frozen_string_literal: true

# Loads the application with the profiler's test profiling, without spec/rails_helper.rb,
# which switches the profiler to the memory store for the engine's own request specs.
ENV["RAILS_ENV"] ||= "test"
# test_app's config/initializers/dev_env_vars.rb points DATABASE_URL at the development database.
ENV["DATABASE_URL"] = "sqlite3:storage/test.sqlite3"
require File.expand_path("../config/environment", __dir__)
require "rspec/rails"
require "profiler/test_helpers/rspec_support"

RSpec.configure do |config|
  config.use_transactional_fixtures = true

  # What Profiler::TestHelpers::RSpecSupport.install(config) sets up, except for the line
  # number: as of 0.32.1, install reads example.line_number, which an RSpec 3.13 around hook
  # does not answer (NoMethodError in every example), so it is read from the metadata here.
  config.around(:each) do |example|
    Profiler::TestProfiler.profile(
      test_name: example.full_description,
      test_file: example.file_path,
      test_line: example.metadata[:line_number],
      framework: :rspec
    ) { example.run }
  end
  config.after(:suite) { Profiler::TestHelpers::Reporter.print }
end
