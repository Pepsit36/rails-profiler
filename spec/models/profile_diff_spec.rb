# frozen_string_literal: true

require "spec_helper"
require "profiler/profile_diff"

RSpec.describe Profiler::ProfileDiff do
  before do
    Profiler.configure do |c|
      c.regression_duration_threshold = 10
      c.regression_memory_threshold = 10
      c.regression_query_threshold = 0
    end
  end

  def build_db_profile(attrs = {})
    db = attrs.delete(:database) || {}
    build_profile(attrs.merge(collectors_data: { "database" => db }))
  end

  describe "#same_endpoint?" do
    it "returns true when path and method match" do
      a = build_profile(path: "/users", method: "GET")
      b = build_profile(path: "/users", method: "GET")
      expect(described_class.new(a, b).same_endpoint?).to be true
    end

    it "returns false when paths differ" do
      a = build_profile(path: "/users")
      b = build_profile(path: "/posts")
      expect(described_class.new(a, b).same_endpoint?).to be false
    end

    it "returns false when methods differ" do
      a = build_profile(path: "/users", method: "GET")
      b = build_profile(path: "/users", method: "POST")
      expect(described_class.new(a, b).same_endpoint?).to be false
    end
  end

  describe "#compute" do
    it "returns the expected top-level keys" do
      a = build_profile
      b = build_profile
      result = described_class.new(a, b).compute
      expect(result.keys).to include(:profile_a, :profile_b, :same_endpoint, :metrics, :collectors)
    end

    it "includes profile summaries with token and path" do
      a = build_profile(token: "aaa", path: "/a")
      b = build_profile(token: "bbb", path: "/b")
      result = described_class.new(a, b).compute
      expect(result[:profile_a][:token]).to eq("aaa")
      expect(result[:profile_b][:token]).to eq("bbb")
    end

    it "includes collector keys" do
      a = build_profile
      b = build_profile
      result = described_class.new(a, b).compute
      expect(result[:collectors].keys).to include(:database, :cache, :views, :http)
    end
  end

  describe "metric diff status" do
    context "when duration improves (decreases)" do
      it "marks status as improved" do
        a = build_profile(duration: 200.0)
        b = build_profile(duration: 100.0)
        result = described_class.new(a, b).compute
        expect(result[:metrics][:duration][:status]).to eq(:improved)
      end
    end

    context "when duration regresses (increases beyond threshold)" do
      it "marks status as regression" do
        a = build_profile(duration: 100.0)
        b = build_profile(duration: 200.0)
        result = described_class.new(a, b).compute
        expect(result[:metrics][:duration][:status]).to eq(:regression)
      end
    end

    context "when change is within threshold" do
      it "marks status as neutral" do
        a = build_profile(duration: 100.0)
        b = build_profile(duration: 105.0) # 5% increase, below 10% threshold
        result = described_class.new(a, b).compute
        expect(result[:metrics][:duration][:status]).to eq(:neutral)
      end
    end

    context "when duration is identical" do
      it "marks status as neutral" do
        a = build_profile(duration: 100.0)
        b = build_profile(duration: 100.0)
        result = described_class.new(a, b).compute
        expect(result[:metrics][:duration][:status]).to eq(:neutral)
      end
    end
  end

  describe "delta computation" do
    it "computes correct delta and delta_pct for duration" do
      a = build_profile(duration: 200.0)
      b = build_profile(duration: 150.0)
      metric = described_class.new(a, b).compute[:metrics][:duration]
      expect(metric[:delta]).to eq(-50.0)
      expect(metric[:delta_pct]).to eq(-25.0)
    end

    it "returns nil delta_pct when value_a is zero" do
      a = build_profile(duration: 0.0)
      b = build_profile(duration: 100.0)
      metric = described_class.new(a, b).compute[:metrics][:duration]
      expect(metric[:delta_pct]).to be_nil
    end
  end

  describe "with collector data" do
    it "computes db_queries metric correctly" do
      a = build_profile(collectors_data: { "database" => { "total_queries" => 10, "total_duration" => 50.0 } })
      b = build_profile(collectors_data: { "database" => { "total_queries" => 5, "total_duration" => 25.0 } })
      metrics = described_class.new(a, b).compute[:metrics]
      expect(metrics[:db_queries][:value_a]).to eq(10)
      expect(metrics[:db_queries][:value_b]).to eq(5)
      expect(metrics[:db_queries][:status]).to eq(:improved)
    end

    it "handles missing collectors gracefully" do
      a = build_profile(collectors_data: {})
      b = build_profile(collectors_data: {})
      expect { described_class.new(a, b).compute }.not_to raise_error
    end

    it "returns nil metrics when both profiles have no collector data" do
      a = build_profile(collectors_data: {})
      b = build_profile(collectors_data: {})
      metrics = described_class.new(a, b).compute[:metrics]
      expect(metrics[:db_queries]).to be_nil
    end
  end

  describe "cache hit rate" do
    it "marks improvement when hit rate increases" do
      a = build_profile(collectors_data: { "cache" => { "hit_rate" => 60.0 } })
      b = build_profile(collectors_data: { "cache" => { "hit_rate" => 80.0 } })
      metric = described_class.new(a, b).compute[:metrics][:cache_hit_rate]
      expect(metric[:status]).to eq(:improved)
    end

    it "marks regression when hit rate decreases significantly" do
      a = build_profile(collectors_data: { "cache" => { "hit_rate" => 80.0 } })
      b = build_profile(collectors_data: { "cache" => { "hit_rate" => 50.0 } })
      metric = described_class.new(a, b).compute[:metrics][:cache_hit_rate]
      expect(metric[:status]).to eq(:regression)
    end

    it "handles value_a == 0 without division by zero (returns nil delta_pct)" do
      a = build_profile(collectors_data: { "cache" => { "hit_rate" => 0.0 } })
      b = build_profile(collectors_data: { "cache" => { "hit_rate" => 50.0 } })
      metric = described_class.new(a, b).compute[:metrics][:cache_hit_rate]
      expect(metric[:delta_pct]).to be_nil
      expect(metric[:status]).to eq(:improved)
    end

    it "marks a rise from zero as a regression for a :lower-direction metric" do
      a = build_profile(collectors_data: { "database" => { "total_queries" => 0 } })
      b = build_profile(collectors_data: { "database" => { "total_queries" => 50 } })
      metric = described_class.new(a, b).compute[:metrics][:db_queries]
      expect(metric[:delta_pct]).to be_nil
      expect(metric[:status]).to eq(:regression)
    end
  end

  describe "regression_cache_threshold configuration" do
    it "uses regression_cache_threshold for cache hit rate" do
      Profiler.configure { |c| c.regression_cache_threshold = 0 }
      a = build_profile(collectors_data: { "cache" => { "hit_rate" => 80.0 } })
      b = build_profile(collectors_data: { "cache" => { "hit_rate" => 79.0 } })
      metric = described_class.new(a, b).compute[:metrics][:cache_hit_rate]
      expect(metric[:status]).to eq(:regression)
    end
  end
end
