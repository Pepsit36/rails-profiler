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

# The Pry console (pry-rails): the specs for the Pry instrumentation run against the real Pry#evaluate_ruby.
gem "pry", "~> 0.15", require: false

# A real multi-threaded server for the specs that measure what a request holds a thread for.
gem "puma", ">= 6.0", require: false

gem "stackprof", "~> 0.2.28", :require => false

# OpenTelemetry export (config.otel_enabled): the gem does not depend on it, the application adds these two
# to its own Gemfile. Here for the specs that run against the real SDK.
gem "opentelemetry-sdk", "~> 1.4", require: false
gem "opentelemetry-exporter-otlp", "~> 0.26", require: false

# OpenTelemetry metrics (same opt-in). Alpha: the metrics SDK's API changes between releases, so all three are pinned
# to an exact version. The application that enables metrics pins them the same way (see docs/configuration.md).
gem "opentelemetry-metrics-api", "= 0.10.0", require: false
gem "opentelemetry-metrics-sdk", "= 0.21.0", require: false
gem "opentelemetry-exporter-otlp-metrics", "= 0.14.0", require: false

# A real database for the ExplainRunner specs (EXPLAIN QUERY PLAN, rolled-back probe).
# gemfiles/rails_7_1.gemfile sets PROFILER_SQLITE3 to "~> 1.4": the ActiveRecord 7.1 adapter refuses 2.x.
gem "sqlite3", ENV.fetch("PROFILER_SQLITE3", ">= 1.4"), require: false

# A client that sends its payload through Net::HTTP's body_stream, for the specs of the outgoing body capture.
gem "rest-client", "~> 2.1", require: false
