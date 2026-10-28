# frozen_string_literal: true

require "spec_helper"
require "open3"
require "json"
require "tmpdir"
require "fileutils"

# Runs a real `rails runner` (Rails::Command) on a throwaway application, in a child process,
# and reads back the profiles it saved before exiting.
RSpec.describe "Profiling rails runner" do
  let(:app_script) do
    <<~'RUBY'
      require "bundler/setup"
      require "logger"
      require "rails"
      require "action_controller/railtie"
      require "profiler"

      class RunnerProbeApp < Rails::Application
        config.root = ENV.fetch("PROBE_ROOT")
        config.eager_load = false
        config.secret_key_base = "x" * 64
        config.logger = Logger.new(File.join(ENV.fetch("PROBE_ROOT"), "boot.log"))
        config.hosts.clear
        Profiler.configure { |c| c.storage = :memory; c.track_memory = false }
        ENV["PROBE_TRACK_RUNNER"]&.then { |v| Profiler.configure { |c| c.track_runner = (v == "true") } }
        ENV["PROBE_RUNNER_SKIP"]&.then { |v| Profiler.configure { |c| c.runner_skip = [v] } }
      end
    RUBY
  end

  def run_runner(*args, rails_env: "development", env: {}, files: {})
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config", "application.rb"), app_script)
      File.write(File.join(root, "config", "environment.rb"), "RunnerProbeApp.initialize!\n")
      files.each { |name, body| File.write(File.join(root, name), body) }
      out = File.join(root, "profiles.json")
      driver = File.join(root, "driver.rb")
      File.write(driver, <<~RUBY)
        require "json"
        at_exit do
          next unless defined?(Profiler) && Profiler.storage.respond_to?(:list)
          profiles = Profiler.storage.list(limit: 50).select { |p| p.profile_type == "console" }
          File.write(#{out.inspect}, JSON.dump(profiles.map { |p| p.collector_data("console").merge("status" => p.status, "method" => p.method, "exception" => p.collector_data("exception")) }))
        end
        APP_PATH = File.expand_path("config/application", Dir.pwd)
        require "rails/command"
        Rails::Command.invoke("runner", ARGV)
      RUBY
      child_env = { "RAILS_ENV" => rails_env, "PROBE_ROOT" => root }.merge(env)
      lib = File.expand_path("../lib", __dir__)
      _stdout, stderr, status = Open3.capture3(child_env, RbConfig.ruby, "-I", lib, driver, *args, chdir: root)
      profiles = File.exist?(out) ? JSON.parse(File.read(out)) : []
      { profiles: profiles, status: status, stderr: stderr }
    end
  end

  it "records a runner expression with its return value" do
    result = run_runner("1 + 1")

    expect(result[:status]).to be_success
    expect(result[:profiles].size).to eq(1)
    profile = result[:profiles].first
    expect(profile["expression"]).to eq("1 + 1")
    expect(profile["source"]).to eq("runner")
    expect(profile["return_value"]).to eq("2")
    expect(profile["method"]).to eq("RUNNER")
    expect(profile["status"]).to eq(200)
  end

  it "records a script by its path" do
    result = run_runner("job.rb", files: { "job.rb" => "$ran = :ok" })

    expect(result[:profiles].map { |p| p["expression"] }).to eq(["job.rb"])
  end

  it "records a failing runner as failed, with its exception, and still raises" do
    result = run_runner('raise ArgumentError, "boom"')

    expect(result[:status]).not_to be_success
    expect(result[:stderr]).to include("boom")
    profile = result[:profiles].first
    expect(profile["status"]).to eq(500)
    expect(profile["exception"].to_json).to include("boom")
  end

  it "records nothing when track_runner is false" do
    expect(run_runner("1 + 1", env: { "PROBE_TRACK_RUNNER" => "false" })[:profiles]).to be_empty
  end

  it "records nothing in the test environment by default" do
    expect(run_runner("1 + 1", rails_env: "test")[:profiles]).to be_empty
  end

  it "records in the test environment when track_runner is forced on" do
    expect(run_runner("1 + 1", rails_env: "test", env: { "PROBE_TRACK_RUNNER" => "true" })[:profiles].size).to eq(1)
  end

  it "leaves out the expressions of runner_skip" do
    result = run_runner("1 + 1", env: { "PROBE_RUNNER_SKIP" => "1 + 1" })

    expect(result[:profiles]).to be_empty
  end

  it "leaves out the profiler's own runner code by default" do
    expect(run_runner("Profiler.version")[:profiles]).to be_empty
  end
end
