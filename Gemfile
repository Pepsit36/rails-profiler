# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"
gem "webmock", "~> 3.18"

# Optional dependencies
gem "redis", "~> 5.0", require: false
gem "rack-test", "~> 2.0", require: false

# A real multi-threaded server for the specs that measure what a request holds a thread for.
gem "puma", ">= 6.0", require: false

gem "stackprof", "~> 0.2.28", :require => false

# A real database for the ExplainRunner specs (EXPLAIN QUERY PLAN, rolled-back probe).
gem "sqlite3", ">= 1.4", require: false
