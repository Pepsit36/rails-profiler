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

    it "counts only real overrides, not the restore markers left by a reset" do
      Profiler.configuration.enabled = false
      File.write(
        File.join(tmp_dir, "env_overrides.json"),
        JSON.generate(
          "PROFILER_UNIT_PROBE" => { "value" => value, "original" => nil },
          "PROFILER_UNIT_RESTORED" => { "value" => described_class::RESTORE_SENTINEL, "original" => "x" }
        )
      )
      store.apply_at_boot!(logger)
      expect(log.string).to include("1 persisted environment override in ")
    end

    it "says nothing when the file holds restore markers only" do
      Profiler.configuration.enabled = false
      File.write(
        File.join(tmp_dir, "env_overrides.json"),
        JSON.generate("PROFILER_UNIT_RESTORED" => { "value" => described_class::RESTORE_SENTINEL, "original" => "x" })
      )
      store.apply_at_boot!(logger)
      expect(log.string).to be_empty
    end

    it "applies and says nothing when the overrides are allowed" do
      store.apply_at_boot!(logger)
      expect(ENV["PROFILER_UNIT_PROBE"]).to eq(value)
      expect(log.string).to be_empty
    end
  end

  # A file shipped with a deployment carries the "original" values of the machine that wrote it.
  # Where the overrides are blocked, a reset must not write them into ENV: only the keys this
  # process changed itself are restored, to the values it had before.
  describe "#reset and #reset_all where the overrides are blocked" do
    let(:file) { File.join(tmp_dir, "env_overrides.json") }

    before do
      File.write(
        file,
        JSON.generate(
          "PROFILER_UNIT_A" => { "value" => "dev-override", "original" => "dev-machine-value" },
          "PROFILER_UNIT_B" => { "value" => "dev-override", "original" => nil }
        )
      )
      ENV["PROFILER_UNIT_A"] = "deployed-a"
      ENV["PROFILER_UNIT_B"] = "deployed-b"
    end

    after do
      ENV.delete("PROFILER_UNIT_A")
      ENV.delete("PROFILER_UNIT_B")
    end

    shared_examples "a reset that leaves the deployed environment alone" do
      it "reset keeps ENV and only marks the key as restored in the file" do
        store.reset("PROFILER_UNIT_A")
        expect(ENV["PROFILER_UNIT_A"]).to eq("deployed-a")
        expect(JSON.parse(File.read(file)).dig("PROFILER_UNIT_A", "value"))
          .to eq(described_class::RESTORE_SENTINEL)
      end

      it "reset_all keeps ENV, deleting nothing" do
        store.reset_all
        expect(ENV["PROFILER_UNIT_A"]).to eq("deployed-a")
        expect(ENV["PROFILER_UNIT_B"]).to eq("deployed-b")
        expect(store.all_overrides).to be_empty
      end

      it "restores a key this process changed itself to the value it had before" do
        store.set("PROFILER_UNIT_A", "changed-here")
        ENV["PROFILER_UNIT_A"] = "changed-here"
        store.delete("PROFILER_UNIT_B")
        ENV.delete("PROFILER_UNIT_B")

        store.reset_all
        expect(ENV["PROFILER_UNIT_A"]).to eq("deployed-a")
        expect(ENV["PROFILER_UNIT_B"]).to eq("deployed-b")
      end

      it "reset restores a key this process changed itself, once" do
        store.set("PROFILER_UNIT_A", "changed-here")
        ENV["PROFILER_UNIT_A"] = "changed-here"
        store.reset("PROFILER_UNIT_A")
        expect(ENV["PROFILER_UNIT_A"]).to eq("deployed-a")

        ENV["PROFILER_UNIT_A"] = "set-by-someone-else"
        store.reset("PROFILER_UNIT_A")
        expect(ENV["PROFILER_UNIT_A"]).to eq("set-by-someone-else")
      end

      it "reset restores a key this process changed even once its entry is gone from the file" do
        store.set("PROFILER_UNIT_A", "changed-here")
        ENV["PROFILER_UNIT_A"] = "changed-here"
        FileUtils.rm_f(file)

        expect(store.reset("PROFILER_UNIT_A")).to be(true)
        expect(ENV["PROFILER_UNIT_A"]).to eq("deployed-a")
      end

      it "reset leaves a key alone when it has no entry and this process never changed it" do
        FileUtils.rm_f(file)
        expect(store.reset("PROFILER_UNIT_A")).to be(false)
        expect(ENV["PROFILER_UNIT_A"]).to eq("deployed-a")
      end
    end

    context "in production, with the profiler enabled" do
      before { stub_rails_env("production") }

      it_behaves_like "a reset that leaves the deployed environment alone"
    end

    context "with the profiler disabled" do
      before { Profiler.configuration.enabled = false }

      it_behaves_like "a reset that leaves the deployed environment alone"
    end

    context "where the overrides are allowed" do
      it "reset restores the original value recorded in the file, as before" do
        store.reset("PROFILER_UNIT_A")
        expect(ENV["PROFILER_UNIT_A"]).to eq("dev-machine-value")
      end

      it "reset_all restores every original value recorded in the file, as before" do
        store.reset_all
        expect(ENV["PROFILER_UNIT_A"]).to eq("dev-machine-value")
        expect(ENV).not_to have_key("PROFILER_UNIT_B")
      end
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
