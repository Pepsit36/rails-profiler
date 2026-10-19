# frozen_string_literal: true

require "spec_helper"
require "open3"

# OpenTelemetry is an optional dependency, as stackprof is: nothing of it is required, declared
# or touched unless config.otel_enabled is true, and a missing gem is a log line, never an error.
RSpec.describe "OpenTelemetry as an optional dependency" do
  let(:root) { File.expand_path("../..", __dir__) }

  def run_isolated(script, hide_gems:, hidden: /\Aopentelemetry/)
    prelude = <<~RUBY
      module Kernel
        alias_method :__orig_require, :require
        def require(name)
          raise LoadError, "cannot load such file -- \#{name}" if #{hide_gems} && name.to_s.match?(#{hidden.inspect})
          __orig_require(name)
        end
      end
    RUBY
    code = "#{prelude}\n#{script}"
    Open3.capture2e(RbConfig.ruby, "-I", File.join(root, "lib"), "-e", code, chdir: root)
  end

  let(:profile_a_request) do
    <<~RUBY
      require "bundler/setup"
      require "rack"
      require "active_support"
      require "active_support/notifications"
      require "profiler"
      require "profiler/middleware/profiler_middleware"
      require "profiler/storage/memory_store"
      Profiler.configure { |c| c.enabled = true; c.authorization_mode = :allow_all; c.collectors = []; c.skip_paths = []; c.track_memory = false }
      Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
      app = Profiler::Middleware::ProfilerMiddleware.new(->(_) { [200, { "Content-Type" => "text/plain" }, ["ok"]] })
      status, headers, = app.call(Rack::MockRequest.env_for("/"))
      abort("not profiled") unless status == 200 && (headers["x-profiler-token"] || headers["X-Profiler-Token"])
      loaded = $LOADED_FEATURES.grep(/opentelemetry/)
      abort("opentelemetry loaded: \#{loaded.first(3)}") unless loaded.empty?
      puts "OK"
    RUBY
  end

  it "declares no opentelemetry dependency in the gemspec" do
    spec = Gem::Specification.load(File.join(root, "profiler.gemspec"))
    names = (spec.dependencies + spec.development_dependencies).map(&:name)
    expect(names.grep(/opentelemetry/)).to be_empty
  end

  it "loads, profiles and never requires opentelemetry when otel_enabled is false (gems installed)" do
    output, status = run_isolated(profile_a_request, hide_gems: false)
    expect(status).to be_success, output
    expect(output).to include("OK")
  end

  it "loads and profiles when the opentelemetry gems cannot be loaded at all" do
    output, status = run_isolated(profile_a_request, hide_gems: true)
    expect(status).to be_success, output
    expect(output).to include("OK")
  end

  it "warns clearly, once per signal, and raises nothing when enabled without the gems" do
    script = <<~RUBY
      require "bundler/setup"
      require "rack"
      require "active_support"
      require "active_support/notifications"
      require "profiler"
      require "profiler/middleware/profiler_middleware"
      require "profiler/storage/memory_store"
      require "stringio"
      log = StringIO.new
      Profiler.configure do |c|
        c.enabled = true; c.authorization_mode = :allow_all; c.collectors = []; c.skip_paths = []; c.track_memory = false
        c.otel_enabled = true; c.otel_otlp_endpoint = "http://localhost:4318/v1/traces"
        c.logger = Logger.new(log)
      end
      Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
      app = Profiler::Middleware::ProfilerMiddleware.new(->(_) { [200, { "Content-Type" => "text/plain" }, ["ok"]] })
      2.times do
        status, headers, = app.call(Rack::MockRequest.env_for("/"))
        abort("not profiled") unless status == 200 && (headers["x-profiler-token"] || headers["X-Profiler-Token"])
      end
      # One warning per signal (traces, metrics), however many requests.
      lines = log.string.lines.grep(/OpenTelemetry (traces|metrics) gems are not available/)
      abort("expected two warnings, got \#{lines.size}: \#{log.string}") unless lines.size == 2
      puts "OK"
    RUBY
    require "logger"
    output, status = run_isolated(script, hide_gems: true)
    expect(status).to be_success, output
    expect(output).to include("OK")
  end

  # The signals are independent: the gems of one missing leaves the other working, with one
  # warning naming the missing one.
  def partial_script(expect_warning:, expect_provider:)
    <<~RUBY
      require "bundler/setup"
      require "logger"
      require "stringio"
      require "profiler"
      require "profiler/otel/sdk"
      log = StringIO.new
      Profiler.configure do |c|
        c.otel_enabled = true; c.otel_otlp_endpoint = "http://localhost:4318/v1/traces"; c.logger = Logger.new(log)
      end
      traces = Profiler::Otel::Sdk.tracer_provider
      metrics = Profiler::Otel::Sdk.meter_provider
      abort("traces provider: \#{traces.inspect}") if #{expect_provider == :traces} != !traces.nil?
      abort("metrics provider: \#{metrics.inspect}") if #{expect_provider == :metrics} != !metrics.nil?
      lines = log.string.lines.grep(/#{expect_warning} gems are not available/)
      abort("expected one #{expect_warning} warning, got \#{log.string}") unless lines.size == 1 && log.string.lines.size == 1
      puts "OK"
    RUBY
  end

  it "warns for the metrics gems alone, and still exports traces, when only the metrics gems are missing" do
    output, status = run_isolated(partial_script(expect_warning: "metrics", expect_provider: :traces),
                                  hide_gems: true, hidden: %r{\Aopentelemetry-metrics|otlp_metrics\z})
    expect(status).to be_success, output
    expect(output).to include("OK")
  end

  it "warns for the trace gems alone, and still exports metrics, when only the trace exporter is missing" do
    output, status = run_isolated(partial_script(expect_warning: "traces", expect_provider: :metrics),
                                  hide_gems: true, hidden: %r{\Aopentelemetry/exporter/otlp\z})
    expect(status).to be_success, output
    expect(output).to include("OK")
  end

  it "does not touch OpenTelemetry in this process with otel_enabled false" do
    Profiler::Otel::Sdk.reset!
    expect(Profiler::Otel::Sdk).not_to receive(:require)
    profile = Profiler::Models::Profile.new
    profile.trace_id = "a" * 32
    profile.span_id = "b" * 16
    expect(Profiler::Otel::TraceExporter.export(profile)).to be(false)
    expect(Profiler::Otel::Sdk.tracer_provider).to be_nil
    expect(Profiler::Otel::Sdk.meter_provider).to be_nil
    expect(Profiler::Otel::MetricsExporter.export(profile)).to be(false)
  end
end
