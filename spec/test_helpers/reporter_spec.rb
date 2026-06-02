# frozen_string_literal: true

require "spec_helper"
require "profiler/test_helpers/reporter"

RSpec.describe Profiler::TestHelpers::Reporter do
  before do
    Profiler.configure do |c|
      c.enabled = true
      c.storage = :memory
    end
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  def store_test_profile(test_name: "SomeSpec#test", status: "passed", duration: 50.0,
                         exception_message: nil, queries: [], n1_queries: nil)
    all_queries = queries.dup
    if n1_queries
      # Add n1_queries identical queries to trigger N+1 detection
      n1_queries.times { all_queries << { "sql" => "SELECT * FROM users WHERE id = 1", "duration" => 1.0 } }
    end

    profile = build_profile(
      profile_type: "test",
      duration: duration,
      collectors_data: {
        "test" => {
          "test_name" => test_name,
          "test_file" => "spec/models/example_spec.rb",
          "test_line" => 10,
          "framework" => "rspec",
          "status" => status,
          "exception_message" => exception_message
        },
        "database" => {
          "total_queries" => all_queries.size,
          "total_duration" => all_queries.sum { |q| q["duration"].to_f },
          "queries" => all_queries
        }
      }
    )
    Profiler.storage.save(profile.token, profile)
    profile
  end

  describe ".print" do
    context "when profiler is disabled" do
      before { Profiler.configure { |c| c.enabled = false } }

      it "prints nothing" do
        store_test_profile
        output = capture_stdout { described_class.print }
        expect(output).to be_empty
      end
    end

    context "when there are no test profiles" do
      it "prints nothing" do
        output = capture_stdout { described_class.print }
        expect(output).to be_empty
      end
    end

    context "with passing tests" do
      before do
        store_test_profile(test_name: "UserSpec#creates a user", status: "passed", duration: 120.0)
        store_test_profile(test_name: "PostSpec#validates presence", status: "passed", duration: 30.0)
      end

      it "includes the 'Profiler Test Report' header" do
        output = capture_stdout { described_class.print }
        expect(output).to include("Profiler Test Report")
      end

      it "shows passed count" do
        output = capture_stdout { described_class.print }
        expect(output).to include("2 passed")
      end

      it "includes the slowest tests section" do
        output = capture_stdout { described_class.print }
        expect(output).to include("Slowest tests")
      end

      it "lists the test names in the slowest section" do
        output = capture_stdout { described_class.print }
        expect(output).to include("UserSpec#creates a user")
      end
    end

    context "with failed tests" do
      before do
        store_test_profile(
          test_name: "BrokenSpec#fails always",
          status: "failed",
          exception_message: "expected 1 to eq 2"
        )
      end

      it "shows failed count" do
        output = capture_stdout { described_class.print }
        expect(output).to include("1 failed")
      end

      it "includes the Failed tests section" do
        output = capture_stdout { described_class.print }
        expect(output).to include("Failed tests")
      end

      it "shows the exception message" do
        output = capture_stdout { described_class.print }
        expect(output).to include("expected 1 to eq 2")
      end
    end

    context "with N+1 patterns" do
      before do
        store_test_profile(
          test_name: "N1Spec#triggers n+1",
          status: "passed",
          n1_queries: 4
        )
      end

      it "includes the N+1 patterns section" do
        output = capture_stdout { described_class.print }
        expect(output).to include("N+1")
      end
    end

    context "with pending tests" do
      before do
        store_test_profile(test_name: "PendingSpec#skipped", status: "pending")
      end

      it "shows pending count" do
        output = capture_stdout { described_class.print }
        expect(output).to include("1 pending")
      end
    end
  end

  describe ".has_n1?" do
    it "returns false when fewer than 3 queries" do
      profile = build_profile(profile_type: "test", collectors_data: {
        "database" => { "queries" => [{ "sql" => "SELECT 1", "duration" => 1.0 }] }
      })
      expect(described_class.has_n1?(profile)).to be false
    end

    it "returns true when the same query appears 3+ times" do
      queries = 4.times.map { { "sql" => "SELECT * FROM users WHERE id = 1", "duration" => 1.0 } }
      profile = build_profile(profile_type: "test", collectors_data: {
        "database" => { "queries" => queries }
      })
      expect(described_class.has_n1?(profile)).to be true
    end
  end
end
