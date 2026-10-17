# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"
gem "webmock", "~> 3.18"

# Line coverage of the suite, with a floor enforced by spec/spec_helper.rb.
gem "simplecov", "~> 0.22", require: false

# Optional dependencies
gem "redis", "~> 5.0", require: false
gem "rack-test", "~> 2.0", require: false

# A real multi-threaded server for the specs that measure what a request holds a thread for.
gem "puma", ">= 6.0", require: false

gem "stackprof", "~> 0.2.28", :require => false

# A real database for the ExplainRunner specs (EXPLAIN QUERY PLAN, rolled-back probe).
# gemfiles/rails_7_1.gemfile sets PROFILER_SQLITE3 to "~> 1.4": the ActiveRecord 7.1 adapter refuses 2.x.
gem "sqlite3", ENV.fetch("PROFILER_SQLITE3", ">= 1.4"), require: false
