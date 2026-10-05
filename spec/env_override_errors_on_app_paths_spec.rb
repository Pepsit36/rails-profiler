# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "logger"
require "stringio"
require "profiler/instrumentation/sidekiq_middleware"
require "profiler/collectors/env_collector"

# The env override errors reach the profiler's own callers (BUG-09), never the application: the
# paths of its requests, jobs and boot only warn when the overrides file cannot be read.
RSpec.describe "Env override errors on the application's paths" do
  around do |example|
    Dir.mktmpdir do |root|
      @tmp_path = Pathname.new(root)
      example.run
    end
  ensure
    Profiler.instance_variable_set(:@env_override_store, nil)
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.tmp_path = @tmp_path
    end
    # A directory where the overrides file should be: reading it raises Errno::EISDIR.
    FileUtils.mkdir_p(@tmp_path.join("env_overrides.json"))
  end

  it "makes the profiler's own callers see the error" do
    expect { Profiler.env_override_store.all_overrides }.to raise_error(Profiler::EnvOverrideStore::Error, /EISDIR|directory/i)
  end

  it "lets a Sidekiq job run" do
    allow(Profiler::JobProfiler).to receive(:profile).and_yield
    ran = false

    log = capture_profiler_log do
      Profiler::Instrumentation::SidekiqMiddleware.new.call(double("worker"), { "class" => "W", "jid" => "1" }, "q") do
        ran = true
      end
    end
    expect(log).to match(/ERROR -- : \[Profiler\] EnvOverrideStore: failed to apply overrides/)
    expect(ran).to be true
  end

  it "lets the env collector collect, and the Env tab read ENV when the profile is displayed" do
    profile = Profiler::Models::Profile.new
    expect { Profiler::Collectors::EnvCollector.new(profile).collect }.not_to raise_error
    expect { Profiler::ProcessSnapshot.hydrate(profile) }.not_to raise_error
    expect(profile.collector_data("env")[:total]).to be > 0
  end

  it "lets the application boot" do
    allow(Profiler.env_override_store).to receive(:blocked_reason).and_return(:disabled)
    log = StringIO.new

    expect(capture_profiler_log { Profiler.env_override_store.apply_at_boot!(Logger.new(log)) })
      .to match(/\[Profiler\] EnvOverrideStore: failed to check overrides at boot/)
  end

  it "lets a console line run" do
    expect(capture_profiler_log { Profiler.env_override_store.apply! }).to match(/failed to apply overrides/)
  end
end
