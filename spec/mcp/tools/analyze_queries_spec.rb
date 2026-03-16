# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::MCP::Tools::AnalyzeQueries do
  before do
    Profiler.configure { |c| c.slow_query_threshold = 100 }
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def store_profile_with_queries(queries)
    profile = build_profile
    profile.add_collector_data("database", { "queries" => queries })
    Profiler.storage.save(profile.token, profile)
    profile.token
  end

  def call(params)
    described_class.call(params)
  end

  describe "missing token" do
    it "returns an error message" do
      result = call({})
      expect(result.first[:type]).to eq("text")
      expect(result.first[:text]).to include("Error")
      expect(result.first[:text]).to include("token")
    end
  end

  describe "profile not found" do
    it "returns a not found message" do
      result = call({ "token" => "nonexistent" })
      expect(result.first[:text]).to include("Profile not found")
    end
  end

  describe "no database data" do
    it "returns a no queries found message" do
      profile = build_profile
      Profiler.storage.save(profile.token, profile)

      result = call({ "token" => profile.token })
      expect(result.first[:text]).to include("No database queries found")
    end
  end

  describe "with slow queries" do
    it "includes the slow queries section" do
      token = store_profile_with_queries([
        { "sql" => "SELECT * FROM users WHERE id = 1", "duration" => 500.0, "cached" => false }
      ])

      result = call({ "token" => token })
      expect(result.first[:text]).to include("⚠️ Slow Queries")
    end
  end

  describe "with duplicate queries (N+1)" do
    it "includes the duplicate queries section" do
      token = store_profile_with_queries([
        { "sql" => "SELECT * FROM posts WHERE user_id = 1", "duration" => 5.0, "cached" => false },
        { "sql" => "SELECT * FROM posts WHERE user_id = 2", "duration" => 5.0, "cached" => false },
        { "sql" => "SELECT * FROM posts WHERE user_id = 3", "duration" => 5.0, "cached" => false }
      ])

      result = call({ "token" => token })
      expect(result.first[:text]).to include("⚠️ Duplicate Queries")
    end
  end

  describe "with a clean profile" do
    it "shows no slow queries message" do
      token = store_profile_with_queries([
        { "sql" => "SELECT * FROM users", "duration" => 5.0, "cached" => false }
      ])

      result = call({ "token" => token })
      expect(result.first[:text]).to include("✅ No Slow Queries")
    end

    it "shows no duplicate queries message" do
      token = store_profile_with_queries([
        { "sql" => "SELECT * FROM users", "duration" => 5.0, "cached" => false }
      ])

      result = call({ "token" => token })
      expect(result.first[:text]).to include("✅ No Duplicate Queries")
    end
  end

  describe ".normalize_sql" do
    it "replaces positional parameters with ?" do
      sql = "SELECT * FROM users WHERE id = $1 AND org = $2"
      normalized = described_class.normalize_sql(sql)
      expect(normalized).not_to include("$1")
      expect(normalized).not_to include("$2")
    end

    it "replaces numeric literals with ?" do
      sql = "SELECT * FROM users WHERE id = 42"
      normalized = described_class.normalize_sql(sql)
      expect(normalized).not_to include("42")
    end

    it "replaces single-quoted strings with ?" do
      sql = "SELECT * FROM users WHERE name = 'alice'"
      normalized = described_class.normalize_sql(sql)
      expect(normalized).not_to include("'alice'")
    end

    it "normalizes two structurally identical queries to the same form" do
      sql1 = "SELECT * FROM posts WHERE user_id = 1"
      sql2 = "SELECT * FROM posts WHERE user_id = 2"
      expect(described_class.normalize_sql(sql1)).to eq(described_class.normalize_sql(sql2))
    end
  end
end
