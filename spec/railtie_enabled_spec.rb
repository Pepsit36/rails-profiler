# frozen_string_literal: true

require "spec_helper"
require "open3"
require "json"
require "tmpdir"
require "fileutils"

# Boots a real, throwaway Rails application in a child process for each case: what is under
# test is when the railtie reads `enabled`, which only a real boot with the application's own
# config/initializers/profiler.rb shows.
RSpec.describe "Railtie honoring enabled from the application's initializers" do
  def boot_script
    <<~'RUBY'
      require "bundler/setup"
      require "logger"
      require "json"
      require "rails"
      require "action_controller/railtie"
      require "active_job/railtie"
      require "irb"

      # Stands in for Sidekiq: records whether the railtie configured it.
      module Sidekiq
        CALLS = []
        def self.configure_server; CALLS << "server"; end
        def self.configure_client; CALLS << "client"; end
      end

      require "profiler"

      class ProbeApp < Rails::Application
        config.root = ENV.fetch("PROBE_ROOT")
        config.eager_load = false
        config.secret_key_base = "x" * 64
        config.logger = Logger.new(File.join(ENV.fetch("PROBE_ROOT"), "boot.log"))
        config.hosts.clear
        config.active_job.queue_adapter = :inline
        if ENV["PROBE_APPLICATION_RB"]
          Profiler.configure { |c| c.enabled = false; c.storage = :memory; c.track_tests = false }
        end
        ENV["PROBE_CONFIG_PROFILER"]&.then { |v| config.profiler.enabled = (v == "true") }
        config.profiler.no_such_option = 1 if ENV["PROBE_CONFIG_PROFILER_UNKNOWN"]
      end

      ran = []
      Rails::Initializable::Initializer.prepend(Module.new do
        define_method(:run) { |*args| ran << name.to_s; super(*args) }
      end)

      ProbeApp.initialize!
      ProbeApp.load_console
      ProbeApp.routes.draw do
        get "/ping", to: ->(_env) { [200, { "content-type" => "text/html" }, ["<html><body>ok</body></html>"]] }
      end

      class ProbeJob < ActiveJob::Base
        def perform; end
      end

      response = Rack::MockRequest.new(ProbeApp).get("/ping", "REMOTE_ADDR" => "127.0.0.1")
      ProbeJob.perform_now

      profiler_middlewares = ProbeApp.middleware.map(&:name).grep(/\AProfiler::/)

      puts JSON.generate(
        "enabled" => Profiler.configuration.enabled,
        "storage" => Profiler.configuration.storage.to_s,
        "track_tests" => Profiler.configuration.track_tests,
        "middleware" => profiler_middlewares,
        "stack_top" => ProbeApp.middleware.map(&:name).first(3),
        "sidekiq" => Sidekiq::CALLS,
        "active_job" => defined?(Profiler::Instrumentation::ActiveJobInstrumentation) ?
          ActiveJob::Base.include?(Profiler::Instrumentation::ActiveJobInstrumentation) : false,
        "test_profiler" => !defined?(Profiler::TestProfiler).nil?,
        "irb" => defined?(Profiler::Instrumentation::IrbInstrumentation) ?
          IRB::Context.ancestors.include?(Profiler::Instrumentation::IrbInstrumentation) : false,
        "net_http" => Net::HTTP.ancestors.map(&:to_s).grep(/\AProfiler::/),
        "token_header" => response.headers["X-Profiler-Token"],
        "profiles" => Profiler.storage.list(limit: 100).size,
        "ran" => ran,
        "declared" => Profiler::Railtie.initializers.map { |i| i.name.to_s }
      )
    RUBY
  end

  def boot(rails_env:, initializer:, env: {})
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config", "initializers"))
      File.write(File.join(root, "config", "initializers", "profiler.rb"), initializer) if initializer
      script = File.join(root, "boot.rb")
      File.write(script, boot_script)

      child_env = { "RAILS_ENV" => rails_env, "RACK_ENV" => rails_env, "PROBE_ROOT" => root }.merge(env)
      lib = File.expand_path("../lib", __dir__)
      out, err, status = Open3.capture3(child_env, RbConfig.ruby, "-I", lib, script, chdir: root)
      raise "boot failed (#{rails_env}):\n#{err}" unless status.success?

      JSON.parse(out.lines.last).merge("log" => File.read(File.join(root, "boot.log")))
    end
  end

  def expect_nothing_installed(result)
    expect(result["middleware"]).to be_empty
    expect(result["sidekiq"]).to be_empty
    expect(result["active_job"]).to be(false)
    expect(result["test_profiler"]).to be(false)
    expect(result["irb"]).to be(false)
    expect(result["net_http"]).to be_empty
    expect(result["token_header"]).to be_nil
    expect(result["profiles"]).to eq(0)
  end

  context "when config/initializers/profiler.rb disables the profiler in development" do
    let(:result) { boot(rails_env: "development", initializer: "Profiler.configure { |c| c.enabled = false }") }

    it "inserts no middleware, installs no instrumentation and captures nothing" do
      expect(result["enabled"]).to be(false)
      expect_nothing_installed(result)
    end
  end

  context "when config/initializers/profiler.rb disables the profiler in test" do
    let(:result) { boot(rails_env: "test", initializer: "Profiler.configure { |c| c.enabled = false }") }

    it "loads no test profiler either" do
      expect(result["track_tests"]).to be(true)
      expect_nothing_installed(result)
    end
  end

  context "when the profiler is left enabled, the default in development" do
    let(:result) { boot(rails_env: "development", initializer: nil) }

    it "inserts both middlewares, profiler first, installs the instrumentation and captures the request" do
      expect(result["enabled"]).to be(true)
      expect(result["middleware"]).to eq(%w[Profiler::Middleware::ProfilerMiddleware Profiler::Middleware::CorsMiddleware])
      expect(result["sidekiq"]).to eq(%w[server client])
      expect(result["active_job"]).to be(true)
      expect(result["irb"]).to be(true)
      expect(result["token_header"]).to be_a(String)
      expect(result["profiles"]).to be >= 1
    end
  end

  context "when the application inserts its own middleware at the top of the stack" do
    let(:initializer) do
      <<~RUBY
        class AppTopMiddleware
          def initialize(app) = @app = app
          def call(env) = @app.call(env)
        end
        Rails.application.config.middleware.insert_before 0, AppTopMiddleware
      RUBY
    end

    it "keeps it above the profiler's middlewares, as before" do
      result = boot(rails_env: "development", initializer: initializer)
      expect(result["stack_top"]).to eq(%w[AppTopMiddleware Profiler::Middleware::ProfilerMiddleware
                                           Profiler::Middleware::CorsMiddleware])
    end
  end

  context "when config/initializers/profiler.rb enables the profiler in production" do
    let(:result) { boot(rails_env: "production", initializer: "Profiler.configure { |c| c.enabled = true }") }

    it "inserts the middlewares, installs the instrumentation and captures the request" do
      expect(result["enabled"]).to be(true)
      expect(result["storage"]).to eq("memory")
      expect(result["middleware"]).to eq(%w[Profiler::Middleware::ProfilerMiddleware Profiler::Middleware::CorsMiddleware])
      expect(result["sidekiq"]).to eq(%w[server client])
      expect(result["active_job"]).to be(true)
      expect(result["irb"]).to be(true)
      expect(result["token_header"]).to be_a(String)
      expect(result["profiles"]).to be >= 1
    end
  end

  context "when config/application.rb configures the profiler" do
    let(:result) { boot(rails_env: "development", initializer: nil, env: { "PROBE_APPLICATION_RB" => "1" }) }

    it "keeps the application's values instead of the Rails defaults" do
      expect(result["enabled"]).to be(false)
      expect(result["storage"]).to eq("memory")
      expect_nothing_installed(result)
    end
  end

  context "when config/application.rb sets config.profiler" do
    it "applies config.profiler.enabled = false" do
      result = boot(rails_env: "development", initializer: nil, env: { "PROBE_CONFIG_PROFILER" => "false" })
      expect(result["enabled"]).to be(false)
      expect_nothing_installed(result)
    end

    it "applies any option it names" do
      result = boot(rails_env: "production", initializer: nil, env: { "PROBE_CONFIG_PROFILER" => "true" })
      expect(result["enabled"]).to be(true)
      expect(result["middleware"]).not_to be_empty
    end

    it "warns about a key that is not an option and boots" do
      result = boot(rails_env: "development", initializer: nil, env: { "PROBE_CONFIG_PROFILER_UNKNOWN" => "1" })
      expect(result["log"]).to include("config.profiler.no_such_option is not a profiler option, ignored")
      expect(result["enabled"]).to be(true)
    end

    it "lets config/initializers/profiler.rb have the last word" do
      result = boot(rails_env: "development", initializer: "Profiler.configure { |c| c.enabled = true }",
                    env: { "PROBE_CONFIG_PROFILER" => "false" })
      expect(result["enabled"]).to be(true)
      expect(result["middleware"]).not_to be_empty
    end
  end

  # The decisions that depend on `enabled` run once every load_config_initializers has run,
  # and before the middleware stack is built; the defaults are set before, so that the
  # application's initializers override them.
  describe "initializer order" do
    let(:result) { boot(rails_env: "development", initializer: nil) }

    it "runs the decisions after the application's initializers and before build_middleware_stack" do
      ran = result["ran"]
      loads = ran.each_index.select { |i| ran[i] == "load_config_initializers" }
      early = %w[profiler.set_configs profiler.insert_middleware profiler.load_collectors]
      deferred = %w[profiler.remove_disabled_middleware profiler.setup_test_profiler
                    profiler.setup_job_instrumentation profiler.apply_env_overrides]

      expect(early.map { |name| ran.index(name) }).to all(be < loads.min)
      expect(deferred.map { |name| ran.index(name) }).to all(be > loads.max)
      expect(deferred.map { |name| ran.index(name) }).to all(be < ran.index("build_middleware_stack"))
    end
  end
end
