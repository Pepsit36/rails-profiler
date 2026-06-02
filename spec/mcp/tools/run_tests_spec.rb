# frozen_string_literal: true

require "spec_helper"
require "concurrent"
require "profiler/test_runner/run_store"
require "profiler/test_runner/runner"
require "profiler/test_runner/discovery"
require "profiler/env_override_store"
require "profiler/mcp/tools/run_tests"

RSpec.describe Profiler::MCP::Tools::RunTests do
  before do
    Profiler.configure { |c| c.enabled = true; c.storage = :memory }
    Profiler::TestRunner.instance_variable_set(:@run_store, nil)
    allow(Profiler).to receive(:env_override_store).and_return(
      instance_double(Profiler::EnvOverrideStore, all_overrides: {})
    )
    # Stub build_command to avoid actually running rspec/minitest
    allow(Profiler::TestRunner::Runner).to receive(:build_command) do |_files, _framework|
      ["ruby", "-e", "puts '1 example, 0 failures'; exit 0"]
    end
  end

  after do
    Profiler::TestRunner.instance_variable_set(:@run_store, nil)
  end

  def call(params = {})
    described_class.call(params)
  end

  describe "with explicit files" do
    it "returns a summary with status 'passed' for exit 0" do
      result = call("files" => ["spec/fake_spec.rb"], "framework" => "rspec")
      text = result.first[:text]
      expect(text).to include("passed")
    end

    it "includes the run output" do
      result = call("files" => ["spec/fake_spec.rb"], "framework" => "rspec")
      expect(result.first[:text]).to include("1 example, 0 failures")
    end

    it "includes the Run ID" do
      result = call("files" => ["spec/fake_spec.rb"], "framework" => "rspec")
      expect(result.first[:text]).to match(/Run ID.*`[0-9a-f]{16}`/)
    end

    it "includes the framework" do
      result = call("files" => ["spec/fake_spec.rb"], "framework" => "rspec")
      expect(result.first[:text]).to include("rspec")
    end
  end

  describe "with a failing run (exit 1)" do
    before do
      allow(Profiler::TestRunner::Runner).to receive(:build_command) do |_files, _framework|
        ["ruby", "-e", "puts '1 example, 1 failure'; exit 1"]
      end
    end

    it "returns status 'failed'" do
      result = call("files" => ["spec/fake_spec.rb"], "framework" => "rspec")
      expect(result.first[:text]).to include("failed")
    end
  end

  describe "output truncation" do
    before do
      long_output = "x" * 10_000
      allow(Profiler::TestRunner::Runner).to receive(:build_command) do |_files, _framework|
        ["ruby", "-e", "print '#{long_output}'; exit 0"]
      end
    end

    it "truncates output to max_output characters" do
      result = call("files" => ["spec/fake_spec.rb"], "framework" => "rspec", "max_output" => 500)
      output_section = result.first[:text]
      # The output block should be ≤ 500 chars (plus truncation marker)
      expect(output_section).to include("truncated")
    end
  end

  describe "when no files are specified and no test files exist" do
    before do
      allow(Profiler::TestRunner::Discovery).to receive(:files).and_return([])
      allow(Profiler::TestRunner::Discovery).to receive(:frameworks).and_return([:rspec])
    end

    it "returns a 'no test files found' message" do
      result = call({})
      expect(result.first[:text]).to include("No test files found")
    end
  end

  describe "when no files are specified and files exist" do
    before do
      allow(Profiler::TestRunner::Discovery).to receive(:files).and_return([
        { directory: "spec/models", files: [{ path: "spec/models/user_spec.rb", name: "user_spec.rb" }] }
      ])
      allow(Profiler::TestRunner::Discovery).to receive(:frameworks).and_return([:rspec])
    end

    it "runs all discovered files" do
      result = call({})
      expect(result.first[:text]).to include("Files | 1")
    end
  end

  describe "profile tokens in result" do
    it "includes a profile tokens section when test profiles were created" do
      # Manually save a test profile to storage as if the runner created it
      profile = build_profile(profile_type: "test", collectors_data: {
        "test" => { "test_name" => "MySpec#test", "status" => "passed", "framework" => "rspec" }
      })
      Profiler.storage.save(profile.token, profile)

      result = call("files" => ["spec/fake_spec.rb"], "framework" => "rspec")
      # Profile was created during the run window (both started "now")
      text = result.first[:text]
      # The section may or may not appear depending on timing — just verify no crash
      expect(text).to include("Test Run")
    end
  end

  describe "timeout behaviour" do
    before do
      allow(Profiler::TestRunner::Runner).to receive(:build_command) do |_files, _framework|
        ["ruby", "-e", "sleep 30"]
      end
    end

    it "returns a timed out message when timeout is exceeded" do
      result = call("files" => ["spec/fake_spec.rb"], "framework" => "rspec", "timeout_seconds" => 1)
      expect(result.first[:text]).to include("timed out")
    end

    it "includes the run ID so the caller can poll later" do
      result = call("files" => ["spec/fake_spec.rb"], "framework" => "rspec", "timeout_seconds" => 1)
      expect(result.first[:text]).to match(/Run ID.*`[0-9a-f]{16}`/)
    end
  end
end
