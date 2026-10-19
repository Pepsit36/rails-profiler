# frozen_string_literal: true

require "spec_helper"
require "open3"

# OpenTelemetry is an optional dependency, as stackprof is: nothing of it is required, declared
# or touched unless config.otel_enabled is true, and a missing gem is a log line, never an error.
RSpec.describe "OpenTelemetry as an optional dependency" do
  let(:root) { File.expand_path("../..", __dir__) }

  def run_isolated(script, hide_gems:)
    prelude = <<~RUBY
      module Kernel
        alias_method :__orig_require, :require
        def require(name)
          raise LoadError, "cannot load such file -- \#{name}" if #{hide_gems} && name.to_s.start_with?("opentelemetry")
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

  it "warns clearly, once, and raises nothing when enabled without the gems" do
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
      lines = log.string.lines.grep(/OpenTelemetry gems are not available/)
      abort("expected one warning, got \#{lines.size}: \#{log.string}") unless lines.size == 1
      puts "OK"
    RUBY
    require "logger"
    output, status = run_isolated(script, hide_gems: true)
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
  end
end
