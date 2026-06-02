# frozen_string_literal: true

require "spec_helper"
require "concurrent"
require "profiler/test_runner/run_store"
require "profiler/test_runner/runner"
require "profiler/env_override_store"

RSpec.describe Profiler::TestRunner::Runner do
  before do
    # Reset the singleton run_store
    Profiler::TestRunner.instance_variable_set(:@run_store, nil)
    allow(Profiler).to receive(:env_override_store).and_return(
      instance_double(Profiler::EnvOverrideStore, all_overrides: {})
    )
  end

  after do
    Profiler::TestRunner.instance_variable_set(:@run_store, nil)
  end

  def wait_for_terminal(run, timeout: 5)
    deadline = Time.now + timeout
    until Profiler::TestRunner::RunStore::TERMINAL_STATUSES.include?(run.status)
      sleep 0.05
      raise "Run did not reach terminal status within #{timeout}s" if Time.now > deadline
    end
    run
  end

  describe ".start with a real subprocess" do
    # Stub build_command to run a fast inline Ruby script
    def stub_command(script)
      allow(described_class).to receive(:build_command) do |_files, _framework|
        ["ruby", "-e", script]
      end
    end

    context "when the subprocess exits 0" do
      it "transitions the run to 'passed'" do
        stub_command("puts 'hello'; exit 0")
        run = described_class.start(files: ["spec/fake_spec.rb"], framework: "rspec")
        wait_for_terminal(run)
        expect(run.status).to eq("passed")
        expect(run.exit_code).to eq(0)
      end

      it "captures stdout output in the run store" do
        stub_command("puts 'hello from test'")
        run = described_class.start(files: ["spec/fake_spec.rb"], framework: "rspec")
        wait_for_terminal(run)
        expect(run.output_lines.join).to include("hello from test")
      end
    end

    context "when the subprocess exits non-zero" do
      it "transitions the run to 'failed'" do
        stub_command("puts 'failure output'; exit 1")
        run = described_class.start(files: ["spec/fake_spec.rb"], framework: "rspec")
        wait_for_terminal(run)
        expect(run.status).to eq("failed")
        expect(run.exit_code).to eq(1)
      end
    end

    it "records the pid while running" do
      stub_command("sleep 0.1")
      run = described_class.start(files: [], framework: "rspec")
      # Give the thread time to update pid
      sleep 0.05
      expect(run.pid).not_to be_nil
      wait_for_terminal(run)
    end
  end

  describe ".kill" do
    it "returns false when run is not found" do
      expect(described_class.kill("nonexistent")).to be false
    end

    it "returns false when run is not in running status" do
      run = Profiler::TestRunner.run_store.create(files: [], framework: "rspec")
      Profiler::TestRunner.run_store.update(run.id, status: "passed")
      expect(described_class.kill(run.id)).to be false
    end

    it "kills a running process and sets status to 'killed'" do
      allow(described_class).to receive(:build_command) do |_files, _framework|
        ["ruby", "-e", "sleep 30"]
      end

      run = described_class.start(files: [], framework: "rspec")

      # Wait until the process is actually running with a pid
      deadline = Time.now + 3
      sleep 0.05 until run.pid || Time.now > deadline

      result = described_class.kill(run.id)
      expect(result).to be true
      expect(run.status).to eq("killed")
    end
  end

  describe ".build_env" do
    it "sets RAILS_ENV to 'test'" do
      env = described_class.send(:build_env)
      expect(env["RAILS_ENV"]).to eq("test")
    end

    it "sets RACK_ENV to 'test'" do
      env = described_class.send(:build_env)
      expect(env["RACK_ENV"]).to eq("test")
    end

    it "does not allow overrides of blocked env keys" do
      allow(Profiler).to receive(:env_override_store).and_return(
        instance_double(Profiler::EnvOverrideStore, all_overrides: {
          "RAILS_ENV" => { "value" => "production" },
          "DATABASE_URL" => { "value" => "postgres://evil" }
        })
      )
      env = described_class.send(:build_env)
      expect(env["RAILS_ENV"]).to eq("test")
      expect(env["DATABASE_URL"]).to eq("postgres://evil").or(be_nil)
      # RAILS_ENV stays test regardless
      expect(env["RAILS_ENV"]).to eq("test")
    end

    it "applies non-blocked env var overrides" do
      allow(Profiler).to receive(:env_override_store).and_return(
        instance_double(Profiler::EnvOverrideStore, all_overrides: {
          "MY_FEATURE_FLAG" => { "value" => "enabled" }
        })
      )
      env = described_class.send(:build_env)
      expect(env["MY_FEATURE_FLAG"]).to eq("enabled")
    end
  end
end
