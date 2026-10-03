# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "logger"
require "stringio"
require "profiler/instrumentation/sidekiq_middleware"
require "profiler/console_profiler"
require "profiler/instrumentation/irb_instrumentation"

RSpec.describe Profiler::EnvOverrideStore do
  subject(:store) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir }
  let(:value) { "unit-override-value-must-not-be-logged" }

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.tmp_path = Pathname.new(tmp_dir)
    end
    File.write(
      File.join(tmp_dir, "env_overrides.json"),
      JSON.generate("PROFILER_UNIT_PROBE" => { "value" => value, "original" => nil })
    )
  end

  after do
    ENV.delete("PROFILER_UNIT_PROBE")
    Profiler.instance_variable_set(:@env_override_store, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def stub_rails_env(name)
    stub_const("Rails", double("Rails", env: ActiveSupport::StringInquirer.new(name)))
  end

  describe "#apply!" do
    it "applies the overrides when the profiler is enabled outside production" do
      stub_rails_env("development")
      store.apply!
      expect(ENV["PROFILER_UNIT_PROBE"]).to eq(value)
    end

    it "applies nothing when the profiler is disabled" do
      Profiler.configuration.enabled = false
      store.apply!
      expect(ENV["PROFILER_UNIT_PROBE"]).to be_nil
    end

    it "applies the overrides when disabled if apply_env_overrides_when_disabled is set" do
      Profiler.configuration.enabled = false
      Profiler.configuration.apply_env_overrides_when_disabled = true
      store.apply!
      expect(ENV["PROFILER_UNIT_PROBE"]).to eq(value)
    end

    it "applies nothing in production, even enabled and with apply_env_overrides_when_disabled" do
      stub_rails_env("production")
      Profiler.configuration.apply_env_overrides_when_disabled = true
      store.apply!
      expect(ENV["PROFILER_UNIT_PROBE"]).to be_nil
    end
  end

  describe "#apply_at_boot!" do
    let(:log) { StringIO.new }
    let(:logger) { Logger.new(log) }

    it "warns once, with the file and the key count, and never the key or the value" do
      Profiler.configuration.enabled = false
      store.apply_at_boot!(logger)
      store.apply_at_boot!(logger)

      expect(log.string.lines.size).to eq(1)
      expect(log.string).to include("WARN")
      expect(log.string).to include("1 persisted environment override in #{tmp_dir}/env_overrides.json")
      expect(log.string).to include("the profiler is disabled")
      expect(log.string).not_to include(value)
      expect(log.string).not_to include("PROFILER_UNIT_PROBE")
    end

    it "says nothing when there is no override to leave out" do
      Profiler.configuration.enabled = false
      FileUtils.rm_f(File.join(tmp_dir, "env_overrides.json"))
      store.apply_at_boot!(logger)
      expect(log.string).to be_empty
    end

    it "applies and says nothing when the overrides are allowed" do
      store.apply_at_boot!(logger)
      expect(ENV["PROFILER_UNIT_PROBE"]).to eq(value)
      expect(log.string).to be_empty
    end
  end

  describe "callers that re-apply the overrides at run time" do
    before { Profiler.instance_variable_set(:@env_override_store, store) }

    it "Sidekiq middleware applies nothing in production" do
      stub_rails_env("production")
      allow(Profiler::JobProfiler).to receive(:profile).and_yield
      Profiler::Instrumentation::SidekiqMiddleware.new.call(double, { "class" => "W" }, "q") {}
      expect(ENV["PROFILER_UNIT_PROBE"]).to be_nil
    end

    it "Sidekiq middleware applies nothing when the profiler is disabled" do
      Profiler.configuration.enabled = false
      allow(Profiler::JobProfiler).to receive(:profile).and_yield
      Profiler::Instrumentation::SidekiqMiddleware.new.call(double, { "class" => "W" }, "q") {}
      expect(ENV["PROFILER_UNIT_PROBE"]).to be_nil
    end

    it "console evaluation applies nothing in production" do
      stub_rails_env("production")
      context = Class.new { def evaluate(line, _line_no, *_args) = line }
                  .prepend(Profiler::Instrumentation::IrbInstrumentation).new
      allow(Profiler::ConsoleProfiler).to receive(:profile).and_yield
      context.evaluate("1 + 1", 1)
      expect(ENV["PROFILER_UNIT_PROBE"]).to be_nil
    end
  end
end
