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

  # The web process, its threads and the Sidekiq processes all read, change and rewrite the same
  # file: without a lock, two writers each save what they read and one change is lost.
  describe "concurrent writes" do
    let(:threads) { 9 }
    let(:keys_per_thread) { 25 }

    after do
      threads.times { |t| keys_per_thread.times { |k| ENV.delete("PROFILER_UNIT_T#{t}_#{k}") } }
    end

    it "keeps every override set from concurrent threads, each with its own store" do
      FileUtils.rm_f(File.join(tmp_dir, "env_overrides.json"))

      Array.new(threads) do |t|
        Thread.new do
          own = described_class.new
          keys_per_thread.times { |k| own.set("PROFILER_UNIT_T#{t}_#{k}", "v#{k}") }
        end
      end.each(&:join)

      expect(store.all_overrides.size).to eq(threads * keys_per_thread)
    end

    it "keeps the other entries while concurrent threads reset and set" do
      keys = Array.new(threads) { |t| "PROFILER_UNIT_T#{t}_0" }
      keys.each { |key| store.set(key, "before") }

      Array.new(threads) do |t|
        Thread.new do
          own = described_class.new
          keys_per_thread.times do
            own.reset(keys[t])
            own.set(keys[t], "after")
          end
        end
      end.each(&:join)

      overrides = store.all_overrides
      expect(overrides.keys).to include(*keys)
      expect(keys.map { |key| overrides.dig(key, "value") }).to all(eq("after"))
    end

    it "leaves no temporary file behind" do
      store.set("PROFILER_UNIT_T0_0", "v")
      expect(Dir.children(tmp_dir)).to contain_exactly("env_overrides.json", "env_overrides.json.lock")
    end
  end

  describe "partial and total resets, concurrently with sets" do
    let(:threads) { 6 }

    after do
      threads.times { |t| ENV.delete("PROFILER_UNIT_R#{t}") }
      ENV.delete("PROFILER_UNIT_KEEP")
    end

    def restored?(entry)
      entry.is_a?(Hash) && entry["value"] == described_class::RESTORE_SENTINEL
    end

    def raw_file
      JSON.parse(File.read(File.join(tmp_dir, "env_overrides.json")))
    end

    it "reset of one key leaves the other overrides active in the file and in ENV" do
      store.set("PROFILER_UNIT_R0", "a")
      store.set("PROFILER_UNIT_KEEP", "b")

      store.reset("PROFILER_UNIT_R0")

      expect(store.all_overrides.keys).to include("PROFILER_UNIT_KEEP")
      expect(store.all_overrides.keys).not_to include("PROFILER_UNIT_R0")
      expect(ENV["PROFILER_UNIT_R0"]).to be_nil
    end

    it "reset_all leaves a restore marker for every key, and no active override" do
      store.set("PROFILER_UNIT_R0", "a")
      store.set("PROFILER_UNIT_KEEP", "b")

      store.reset_all

      expect(store.all_overrides).to be_empty
      expect(raw_file.keys).to include("PROFILER_UNIT_R0", "PROFILER_UNIT_KEEP")
      expect(raw_file.values.map { |e| restored?(e) }).to all(be(true))
    end

    it "a partial reset after a total one keeps the earlier restore marker" do
      store.set("PROFILER_UNIT_R0", "a")
      store.reset_all
      marker = raw_file["PROFILER_UNIT_R0"]

      store.reset("PROFILER_UNIT_R0")

      expect(raw_file["PROFILER_UNIT_R0"]).to eq(marker)
    end

    it "reset of a key without an entry is a no-op that leaves the file alone" do
      store.set("PROFILER_UNIT_KEEP", "b")
      before = raw_file

      expect(store.reset("PROFILER_UNIT_NEVER_SET")).to be_falsey

      expect(raw_file).to eq(before)
    end

    it "keeps one consistent file when threads set, reset and reset_all at the same time" do
      FileUtils.rm_f(File.join(tmp_dir, "env_overrides.json"))

      Array.new(threads) do |t|
        Thread.new do
          own = described_class.new
          20.times do |i|
            own.set("PROFILER_UNIT_R#{t}", "v#{i}")
            own.reset("PROFILER_UNIT_R#{t}") if i.odd?
            own.reset_all if t.zero? && (i % 5).zero?
          end
        end
      end.each(&:join)

      parsed = nil
      expect { parsed = raw_file }.not_to raise_error
      expect(parsed.keys).to all(start_with("PROFILER_UNIT_R"))
      expect(Dir.children(tmp_dir)).to contain_exactly("env_overrides.json", "env_overrides.json.lock")
    end
  end

  describe "the file it reads" do
    it "reads a file that holds something else than an object as no override" do
      File.write(File.join(tmp_dir, "env_overrides.json"), "[1, 2]")

      expect(store.all_overrides).to eq({})
    end

    it "reads a file that does not parse as no override" do
      File.write(File.join(tmp_dir, "env_overrides.json"), "{oops")

      expect(store.all_overrides).to eq({})
    end
  end

  describe ".reserved_key?" do
    it "protects the test runner marker, whatever its case" do
      expect(described_class.reserved_key?(described_class::TEST_RUNNER_CHILD_ENV)).to be(true)
      expect(described_class.reserved_key?(described_class::TEST_RUNNER_CHILD_ENV.downcase)).to be(true)
      expect(described_class.reserved_key?("PROFILER_UNIT_PROBE")).to be(false)
    end
  end

  describe "a reset that restores an unset key" do
    after { ENV.delete("PROFILER_UNIT_RESTORED_HERE") }

    it "removes it from ENV when it had no value before the override" do
      store.set("PROFILER_UNIT_RESTORED_HERE", "temp")
      ENV["PROFILER_UNIT_RESTORED_HERE"] = "temp"
      store.apply!

      store.reset("PROFILER_UNIT_RESTORED_HERE")
      store.apply!

      expect(ENV.key?("PROFILER_UNIT_RESTORED_HERE")).to be(false)
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

  describe "EnvKeyPolicy enforcement" do
    context "when a persisted override contains a protected key" do
      before do
        Profiler.configure do |c|
          c.enabled = true
          c.tmp_path = Pathname.new(tmp_dir)
        end
        # Simulate a legacy override file with a protected key like DATABASE_URL
        File.write(
          File.join(tmp_dir, "env_overrides.json"),
          JSON.generate("DATABASE_URL" => { "value" => "postgres://attacker", "original" => "postgres://trusted" })
        )
      end

      after do
        ENV.delete("DATABASE_URL")
        Profiler.instance_variable_set(:@env_override_store, nil)
        FileUtils.rm_rf(tmp_dir)
      end

      it "#apply! does not restore protected keys" do
        stub_rails_env("development")
        store.apply!
        expect(ENV["DATABASE_URL"]).to be_nil
      end

      it "#reset removes protected keys from the file instead of keeping a RESTORE entry" do
        stub_rails_env("development")
        store.apply!  # Apply first to populate process originals
        store.reset("DATABASE_URL")

        # Verify the key was removed from the file, not left as RESTORE
        overrides = store.all_overrides
        expect(overrides).not_to have_key("DATABASE_URL")
      end

      it "#reset_all removes protected keys from the file entirely" do
        stub_rails_env("development")
        store.apply!
        store.reset_all

        # Verify protected keys are not in the file
        overrides = store.all_overrides
        expect(overrides).not_to have_key("DATABASE_URL")
      end
    end

    context "when restore_env is called with a protected key" do
      before do
        Profiler.configure do |c|
          c.enabled = true
          c.tmp_path = Pathname.new(tmp_dir)
        end
      end

      after do
        ENV.delete("RUBYOPT")
        Profiler.instance_variable_set(:@env_override_store, nil)
        FileUtils.rm_rf(tmp_dir)
      end

      it "does not restore protected keys to ENV even if they are in the file" do
        stub_rails_env("development")
        # Create an override entry for a protected key
        File.write(
          File.join(tmp_dir, "env_overrides.json"),
          JSON.generate("RUBYOPT" => { "value" => "-w", "original" => "-Werror" })
        )

        store.apply!
        expect(ENV["RUBYOPT"]).to be_nil
      end
    end
  end
end
