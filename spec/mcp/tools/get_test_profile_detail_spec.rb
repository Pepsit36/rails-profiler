# frozen_string_literal: true

require "spec_helper"
require "profiler/mcp/tools/get_test_profile_detail"

RSpec.describe Profiler::MCP::Tools::GetTestProfileDetail do
  before do
    Profiler.configure { |c| c.storage = :memory }
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def store_test_profile(test_name: "MySpec#test", status: "passed", exception_message: nil,
                         skip_reason: nil, queries: [], cache_ops: nil)
    profile = build_profile(
      profile_type: "test",
      duration: 75.5,
      collectors_data: {
        "test" => {
          "test_name" => test_name,
          "status" => status,
          "framework" => "rspec",
          "test_file" => "spec/models/my_spec.rb",
          "test_line" => 12,
          "exception_message" => exception_message,
          "skip_reason" => skip_reason,
          "assertions" => 3
        },
        "database" => {
          "total_queries" => queries.size,
          "total_duration" => queries.sum { |q| q["duration"].to_f },
          "queries" => queries
        },
        "cache" => cache_ops
      }.compact
    )
    Profiler.storage.save(profile.token, profile)
    profile
  end

  def call(params)
    described_class.call(params)
  end

  describe "parameter validation" do
    it "returns an error when token is missing" do
      result = call({})
      expect(result.first[:text]).to include("Error")
      expect(result.first[:text]).to include("token")
    end
  end

  describe "profile not found" do
    it "returns a not found message for unknown token" do
      result = call("token" => "nonexistent_token")
      expect(result.first[:text]).to include("Test profile not found")
    end

    it "returns a not found message for non-test profile" do
      profile = build_profile(profile_type: "http")
      Profiler.storage.save(profile.token, profile)
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("Test profile not found")
    end
  end

  describe "token: 'latest'" do
    it "returns the most recent test profile" do
      store_test_profile(test_name: "OldSpec#test")
      latest = store_test_profile(test_name: "NewSpec#test")

      result = call("token" => "latest")
      expect(result.first[:text]).to include("Test Profile Detail")
    end

    it "returns not found when no test profiles exist" do
      result = call("token" => "latest")
      expect(result.first[:text]).to include("Test profile not found")
    end
  end

  describe "with a passing test" do
    let!(:profile) { store_test_profile(test_name: "UserSpec#creates a user", status: "passed") }

    it "includes the Overview section" do
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("## Overview")
    end

    it "includes the test name" do
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("UserSpec#creates a user")
    end

    it "includes the status" do
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("passed")
    end

    it "includes the file and line" do
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("spec/models/my_spec.rb")
    end

    it "includes the duration" do
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("75.5ms")
    end
  end

  describe "with a failed test" do
    let!(:profile) do
      store_test_profile(
        test_name: "BrokenSpec#fails",
        status: "failed",
        exception_message: "expected true but was false"
      )
    end

    it "includes the Exception section" do
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("## Exception")
    end

    it "includes the exception message" do
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("expected true but was false")
    end
  end

  describe "with a skipped test" do
    let!(:profile) do
      store_test_profile(
        test_name: "PendingSpec#skipped",
        status: "pending",
        skip_reason: "not yet implemented"
      )
    end

    it "includes the Skip reason section" do
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("Skip reason")
    end

    it "includes the skip message" do
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("not yet implemented")
    end
  end

  describe "with database queries" do
    let(:queries) do
      [
        { "sql" => "SELECT * FROM users", "duration" => 10.0 },
        { "sql" => "SELECT * FROM posts WHERE user_id = 1", "duration" => 5.0 }
      ]
    end
    let!(:profile) { store_test_profile(queries: queries) }

    it "includes the Database section" do
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("## Database")
    end

    it "shows the query count" do
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("2 queries")
    end
  end

  describe "N+1 detection" do
    let(:n1_queries) do
      4.times.map { { "sql" => "SELECT * FROM tags WHERE post_id = 1", "duration" => 1.0 } }
    end
    let!(:profile) { store_test_profile(queries: n1_queries) }

    it "includes the N+1 Patterns section" do
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("N+1 Patterns")
    end
  end

  describe "with cache operations" do
    let!(:profile) do
      store_test_profile(
        cache_ops: {
          "total_reads" => 5,
          "total_writes" => 2,
          "total_deletes" => 1,
          "total_misses" => 3
        }
      )
    end

    it "includes the Cache section" do
      result = call("token" => profile.token)
      expect(result.first[:text]).to include("## Cache")
    end

    it "shows the operation counts" do
      result = call("token" => profile.token)
      text = result.first[:text]
      expect(text).to include("Reads: 5")
      expect(text).to include("Writes: 2")
    end
  end
end
