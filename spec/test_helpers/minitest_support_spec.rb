# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# Runs a real Minitest suite through the integration. It runs in a child process:
# install prepends a module to Minitest::Test, which cannot be undone in this one.
RSpec.describe "Profiler::TestHelpers::MinitestSupport" do
  # Runs the given test class body under the integration and returns the test
  # profiles it recorded, keyed by test name, plus the child process output.
  def run_suite(test_body, prelude: "")
    Dir.mktmpdir do |dir|
      script = File.join(dir, "suite.rb")
      out = File.join(dir, "profiles.json")
      File.write(script, <<~RUBY)
        require "json"
        require "active_support"
        require "active_support/notifications"
        require "profiler"
        require "profiler/storage/memory_store"
        require "profiler/test_helpers/minitest_support"

        Profiler.configure do |c|
          c.enabled = true
          c.storage = :memory
          c.track_memory = false
        end
        Profiler::TestHelpers::MinitestSupport.install
        $body_runs = Hash.new(0)
        #{prelude}

        class SampleTest < Minitest::Test
        #{test_body}
        end

        # Written at exit, so it is there even when an error escapes the run.
        at_exit do
          profiles = Profiler.storage.list(limit: 50).select { |p| p.profile_type == "test" }
          data = profiles.to_h { |p| [p.collector_data("test")["test_name"], p.collector_data("test")] }
          File.write(#{out.inspect}, JSON.dump("profiles" => data, "body_runs" => $body_runs))
        end

        Minitest.run(%w[--seed 1])
      RUBY

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), script)
      expect(File).to exist(out), "the suite did not finish (exit #{status.exitstatus}):\n#{stdout}\n#{stderr}"
      JSON.parse(File.read(out)).merge("script" => script, "output" => stdout + stderr, "status" => status)
    end
  end

  it "records a passing test as passed, with its location and assertion count" do
    result = run_suite(<<~RUBY)
      def test_passes
        assert true
        assert_equal 1, 1
      end
    RUBY

    data = result["profiles"].fetch("SampleTest#test_passes")
    expect(data["status"]).to eq("passed")
    expect(data["framework"]).to eq("minitest")
    expect(data["test_file"]).to eq(result["script"])
    expect(data["test_line"]).to be > 1
    expect(data["assertions"]).to eq(2)
  end

  it "records a failing test as failed, with its message" do
    result = run_suite(<<~RUBY)
      def test_fails
        assert_equal 2, 1
      end
    RUBY

    data = result["profiles"].fetch("SampleTest#test_fails")
    expect(data["status"]).to eq("failed")
    expect(data["exception_message"]).to include("Expected: 2")
  end

  it "records a test raising an error as failed" do
    result = run_suite(<<~RUBY)
      def test_raises
        raise ArgumentError, "bad input"
      end
    RUBY

    data = result["profiles"].fetch("SampleTest#test_raises")
    expect(data["status"]).to eq("failed")
    expect(data["exception_message"]).to include("bad input")
  end

  it "records a skipped test as pending, with its reason" do
    result = run_suite(<<~RUBY)
      def test_skipped
        skip "later"
      end
    RUBY

    data = result["profiles"].fetch("SampleTest#test_skipped")
    expect(data["status"]).to eq("pending")
    expect(data["skip_reason"]).to eq("later")
  end

  it "fails a test the profiler fails after, once, and runs the next ones" do
    result = run_suite(<<~RUBY, prelude: <<~PRELUDE)
      def test_counted
        $body_runs["test_counted"] += 1
        assert true
      end

      def test_other
        $body_runs["test_other"] += 1
        assert true
      end
    RUBY
      # Stands for any bug in the profiler raising a NoMethodError once the
      # test has run, as the RSpec hook did with line_number.
      Profiler::Collectors::TestCollector.prepend(Module.new do
        def update_status(*)
          raise NoMethodError, "profiler bug"
        end
      end)
    PRELUDE

    expect(result["body_runs"]).to eq("test_counted" => 1, "test_other" => 1)
    expect(result["output"]).to include("NoMethodError: profiler bug")
    expect(result["output"]).to include("2 runs, 2 assertions, 0 failures, 2 errors")
  end

  it "fails a test the profiler fails before, without running it" do
    result = run_suite(<<~RUBY, prelude: <<~PRELUDE)
      def test_counted
        $body_runs["test_counted"] += 1
        assert true
      end
    RUBY
      Profiler::TestProfiler.prepend(Module.new do
        def run(&)
          raise NoMethodError, "profiler bug"
        end
      end)
    PRELUDE

    expect(result["body_runs"]).to eq({})
    expect(result["output"]).to include("1 runs, 0 assertions, 0 failures, 1 errors")
  end

  it "profiles a test whose method has no location as passed, running it once" do
    result = run_suite(<<~RUBY)
      def self.runnable_methods = super + ["test_ghost"]

      def respond_to_missing?(name, include_private = false) = name.to_s == "test_ghost" || super

      def method_missing(name, *args)
        return super unless name.to_s == "test_ghost"

        $body_runs["test_ghost"] += 1
        assert true
      end
    RUBY

    data = result["profiles"].fetch("SampleTest#test_ghost")
    expect(data["status"]).to eq("passed")
    expect(data["test_file"]).to eq("")
    expect(data["test_line"]).to eq(0)
    expect(result["body_runs"]).to eq("test_ghost" => 1)
  end
end
