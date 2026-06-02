# frozen_string_literal: true

require "spec_helper"
require "profiler/test_profiler"
require "profiler/collectors/database_collector"
require "profiler/collectors/cache_collector"
require "profiler/collectors/exception_collector"
require "profiler/collectors/env_collector"
require "profiler/collectors/flamegraph_collector"

RSpec.describe Profiler::TestProfiler do
  before do
    Profiler.configure do |c|
      c.enabled = true
      c.storage = :memory
      c.track_memory = false
    end
  end

  def profile(test_name: "MySpec#test", test_file: "spec/my_spec.rb", test_line: 1, framework: :rspec, &block)
    Profiler::TestProfiler.profile(
      test_name: test_name,
      test_file: test_file,
      test_line: test_line,
      framework: framework,
      &block
    )
  end

  def latest_test_profile
    Profiler.storage.list(limit: 10).find { |p| p.profile_type == "test" }
  end

  describe "when profiler is disabled" do
    before { Profiler.configure { |c| c.enabled = false } }

    it "calls the block without profiling" do
      called = false
      profile { called = true }
      expect(called).to be true
    end

    it "saves nothing to storage" do
      profile { "noop" }
      expect(latest_test_profile).to be_nil
    end
  end

  describe "RSpec paths" do
    let(:execution_result) { double("ExecutionResult") }
    let(:example_double)   { double("Example", execution_result: execution_result) }

    before { allow(execution_result).to receive(:exception).and_return(nil) }

    context "when test passes" do
      before { allow(execution_result).to receive(:status).and_return(:passed) }

      it "saves a profile with status 'passed'" do
        profile { example_double }
        p = latest_test_profile
        expect(p).not_to be_nil
        expect(p.collector_data("test")["status"]).to eq("passed")
      end

      it "saves a profile of type 'test'" do
        profile { example_double }
        expect(latest_test_profile.profile_type).to eq("test")
      end
    end

    context "when test fails" do
      let(:exception) { double("Exception", message: "expected true but got false") }

      before do
        allow(execution_result).to receive(:status).and_return(:failed)
        allow(execution_result).to receive(:exception).and_return(exception)
      end

      it "saves a profile with status 'failed'" do
        profile { example_double }
        expect(latest_test_profile.collector_data("test")["status"]).to eq("failed")
      end

      it "captures the exception message" do
        profile { example_double }
        expect(latest_test_profile.collector_data("test")["exception_message"]).to eq("expected true but got false")
      end
    end

    context "when test is pending" do
      before { allow(execution_result).to receive(:status).and_return(:pending) }

      it "saves a profile with status 'pending'" do
        profile { example_double }
        expect(latest_test_profile.collector_data("test")["status"]).to eq("pending")
      end
    end
  end

  describe "Minitest paths" do
    let(:minitest_result) { double("MinitestResult", assertions: 3) }

    context "when test passes" do
      before do
        allow(minitest_result).to receive(:passed?).and_return(true)
        allow(minitest_result).to receive(:skipped?).and_return(false)
      end

      it "saves a profile with status 'passed'" do
        profile(framework: :minitest) { minitest_result }
        expect(latest_test_profile.collector_data("test")["status"]).to eq("passed")
      end

      it "captures assertions count" do
        profile(framework: :minitest) { minitest_result }
        expect(latest_test_profile.collector_data("test")["assertions"]).to eq(3)
      end
    end

    context "when test fails" do
      let(:failure) { double("Failure", message: "assertion failed") }

      before do
        allow(minitest_result).to receive(:passed?).and_return(false)
        allow(minitest_result).to receive(:skipped?).and_return(false)
        allow(minitest_result).to receive(:failure).and_return(failure)
      end

      it "saves a profile with status 'failed'" do
        profile(framework: :minitest) { minitest_result }
        expect(latest_test_profile.collector_data("test")["status"]).to eq("failed")
      end

      it "captures the failure message" do
        profile(framework: :minitest) { minitest_result }
        expect(latest_test_profile.collector_data("test")["exception_message"]).to eq("assertion failed")
      end
    end

    context "when test is skipped" do
      let(:skip_failure) { double("SkipFailure", message: "skip: not ready") }

      before do
        allow(minitest_result).to receive(:passed?).and_return(false)
        allow(minitest_result).to receive(:skipped?).and_return(true)
        allow(minitest_result).to receive(:failure).and_return(skip_failure)
      end

      it "saves a profile with status 'pending'" do
        profile(framework: :minitest) { minitest_result }
        expect(latest_test_profile.collector_data("test")["status"]).to eq("pending")
      end

      it "captures the skip reason" do
        profile(framework: :minitest) { minitest_result }
        expect(latest_test_profile.collector_data("test")["skip_reason"]).to eq("skip: not ready")
      end
    end
  end

  describe "exception propagation" do
    it "re-raises the exception" do
      expect {
        profile { raise RuntimeError, "boom" }
      }.to raise_error(RuntimeError, "boom")
    end

    it "still saves the profile with status 'failed'" do
      profile { raise RuntimeError, "boom" } rescue nil
      p = latest_test_profile
      expect(p).not_to be_nil
      expect(p.collector_data("test")["status"]).to eq("failed")
    end

    it "includes the exception class and message" do
      profile { raise RuntimeError, "boom" } rescue nil
      msg = latest_test_profile.collector_data("test")["exception_message"]
      expect(msg).to include("RuntimeError")
      expect(msg).to include("boom")
    end
  end

  describe "memory tracking" do
    before { Profiler.configure { |c| c.track_memory = true } }

    it "records a non-nil memory delta" do
      profile { "noop" }
      expect(latest_test_profile.memory).not_to be_nil
    end
  end

  describe "storage" do
    it "saves one profile per test run" do
      profile(test_name: "Test A") { "noop" }
      profile(test_name: "Test B") { "noop" }
      test_profiles = Profiler.storage.list(limit: 10).select { |p| p.profile_type == "test" }
      expect(test_profiles.size).to eq(2)
    end

    it "stores the test file path as profile.path" do
      profile(test_file: "spec/models/user_spec.rb") { "noop" }
      expect(latest_test_profile.path).to eq("spec/models/user_spec.rb")
    end
  end
end
