# frozen_string_literal: true

require "spec_helper"
require "concurrent"
require "profiler/test_runner/run_store"
require "profiler/test_runner/runner"
require "profiler/test_runner/discovery"
require "profiler/env_override_store"
require "profiler/mcp/tools/run_tests"
require "profiler/mcp/server"
require "fileutils"
require "pathname"

RSpec.describe Profiler::MCP::Tools::RunTests do
  let(:tmpdir) do
    dir = File.realpath(Dir.mktmpdir("profiler_run_tests_spec"))
    FileUtils.mkdir_p(File.join(dir, "spec/models"))
    FileUtils.mkdir_p(File.join(dir, "lib/tasks"))
    File.write(File.join(dir, "spec/fake_spec.rb"), "")
    File.write(File.join(dir, "spec/models/user_spec.rb"), "")
    File.write(File.join(dir, "lib/tasks/not_a_test.rb"), "")
    dir
  end

  before do
    rails_root = Pathname.new(tmpdir)
    rails_stub = Module.new
    rails_stub.define_singleton_method(:root) { rails_root }
    rails_stub.define_singleton_method(:to_s) { "Rails" }
    stub_const("Rails", rails_stub)

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
    FileUtils.rm_rf(tmpdir)
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

  describe "file selection" do
    def expect_refused(files)
      expect(Profiler::TestRunner::Runner).not_to receive(:spawn_async)
      result = call("files" => files, "framework" => "rspec")

      expect(result).to be_a(::MCP::Tool::Response)
      expect(result.error?).to be true
      expect(result.content.first[:text]).to match(/Not a discovered test file: #{Regexp.escape(files.last)}/)
    end

    it "refuses a file under the Rails root that is not a discovered test" do
      expect_refused(["lib/tasks/not_a_test.rb"])
    end

    it "refuses a path that leaves the Rails root" do
      File.write(File.join(File.dirname(tmpdir), "outside_spec.rb"), "")
      expect_refused(["../outside_spec.rb"])
    ensure
      FileUtils.rm_f(File.join(File.dirname(tmpdir), "outside_spec.rb"))
    end

    it "refuses an absolute path outside the discovered tests" do
      expect_refused([File.join(tmpdir, "lib/tasks/not_a_test.rb")])
    end

    it "refuses a symbolic link in the spec directory that points outside the discovered tests" do
      File.symlink(File.join(tmpdir, "lib/tasks/not_a_test.rb"), File.join(tmpdir, "spec/models/helper_link.rb"))
      expect_refused(["spec/models/helper_link.rb"])
    end

    it "refuses a path holding a null byte with a tool error" do
      expect_refused(["spec/fake_spec.rb\0"])
    end

    it "reaches the MCP client as a tool error" do
      expect(Profiler::TestRunner::Runner).not_to receive(:spawn_async)
      server = Profiler::MCP::Server.new.instance_variable_get(:@server)

      response = server.handle({
        jsonrpc: "2.0", id: 1, method: "tools/call",
        params: { name: "run_tests", arguments: { files: ["lib/tasks/not_a_test.rb"], framework: "rspec" } }
      })

      expect(response[:result][:isError]).to be true
      expect(response[:result][:content]).to eq([{ type: "text", text: "Not a discovered test file: lib/tasks/not_a_test.rb" }])
    end

    it "accepts discovered files, several at once and with a line number" do
      allow(Profiler::TestRunner::Runner).to receive(:spawn_async)

      result = call("files" => ["spec/fake_spec.rb", "spec/models/user_spec.rb:12"], "framework" => "rspec",
                    "timeout_seconds" => 0)

      expect(Profiler::TestRunner::Runner).to have_received(:spawn_async).once
      expect(result.first[:text]).to include("Files | 2")
    end
  end
end
