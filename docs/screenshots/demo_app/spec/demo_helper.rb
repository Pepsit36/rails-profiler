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

  Profiler::TestHelpers::RSpecSupport.install(config)
end
