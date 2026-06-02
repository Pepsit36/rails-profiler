# frozen_string_literal: true

require "spec_helper"
require "profiler/mcp/tools/query_test_profiles"

RSpec.describe Profiler::MCP::Tools::QueryTestProfiles do
  before do
    Profiler.configure { |c| c.storage = :memory }
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def store_test_profile(test_name: "MySpec#test", status: "passed", duration: 50.0,
                         framework: "rspec", started_at: Time.now)
    profile = build_profile(
      profile_type: "test",
      duration: duration,
      started_at: started_at,
      collectors_data: {
        "test" => {
          "test_name" => test_name,
          "status" => status,
          "framework" => framework,
          "test_file" => "spec/example_spec.rb",
          "test_line" => 5
        },
        "database" => { "total_queries" => 0, "queries" => [] }
      }
    )
    Profiler.storage.save(profile.token, profile)
    profile
  end

  def call(params = {})
    described_class.call(params)
  end

  describe "with no test profiles" do
    it "returns a 'No test profiles found' message" do
      result = call
      expect(result.first[:text]).to include("No test profiles found")
    end
  end

  describe "with test profiles" do
    before do
      store_test_profile(test_name: "UserSpec#creates", status: "passed", duration: 80.0)
      store_test_profile(test_name: "PostSpec#destroys", status: "failed", duration: 120.0)
      store_test_profile(test_name: "TagSpec#lists", status: "pending", duration: 5.0)
    end

    it "returns a markdown table" do
      result = call
      text = result.first[:text]
      expect(text).to include("# Test Profiles")
      expect(text).to include("|")
    end

    it "includes all test names by default" do
      result = call
      text = result.first[:text]
      expect(text).to include("UserSpec#creates")
      expect(text).to include("PostSpec#destroys")
    end

    describe "filtering by status" do
      it "returns only failed tests" do
        result = call("status" => "failed")
        text = result.first[:text]
        expect(text).to include("PostSpec#destroys")
        expect(text).not_to include("UserSpec#creates")
      end

      it "returns only pending tests" do
        result = call("status" => "pending")
        text = result.first[:text]
        expect(text).to include("TagSpec#lists")
        expect(text).not_to include("PostSpec#destroys")
      end
    end

    describe "filtering by test_name" do
      it "returns only tests whose name includes the term" do
        result = call("test_name" => "user")
        text = result.first[:text]
        expect(text).to include("UserSpec#creates")
        expect(text).not_to include("PostSpec#destroys")
      end

      it "is case-insensitive" do
        result = call("test_name" => "POSTSPEC")
        text = result.first[:text]
        expect(text).to include("PostSpec#destroys")
      end
    end

    describe "filtering by min_duration" do
      it "returns only tests at or above the threshold" do
        result = call("min_duration" => 100)
        text = result.first[:text]
        expect(text).to include("PostSpec#destroys")
        expect(text).not_to include("UserSpec#creates")
        expect(text).not_to include("TagSpec#lists")
      end
    end

    describe "limit parameter" do
      it "respects the limit" do
        result = call("limit" => 2)
        text = result.first[:text]
        expect(text).to include("Found 2 tests")
      end

      it "includes a pagination cursor when limit is reached" do
        result = call("limit" => 2)
        text = result.first[:text]
        expect(text).to include("cursor")
      end
    end
  end

  describe "N+1 column" do
    it "shows ⚠ when N+1 queries are detected" do
      n1_queries = 4.times.map { { "sql" => "SELECT * FROM users WHERE id = 1", "duration" => 1.0 } }
      profile = build_profile(
        profile_type: "test",
        collectors_data: {
          "test" => { "test_name" => "N1Spec#test", "status" => "passed", "framework" => "rspec" },
          "database" => { "total_queries" => 4, "queries" => n1_queries }
        }
      )
      Profiler.storage.save(profile.token, profile)

      result = call
      expect(result.first[:text]).to include("⚠")
    end
  end
end
