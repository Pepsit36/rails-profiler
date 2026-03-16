# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Collectors::DatabaseCollector do
  let(:profile) { build_profile }
  subject(:collector) { described_class.new(profile) }

  before do
    Profiler.configure do |c|
      c.slow_query_threshold = 100
      c.max_queries_warning = 50
    end
  end

  describe "#subscribe and #collect with real ActiveSupport::Notifications" do
    it "captures sql.active_record notifications" do
      collector.subscribe

      ActiveSupport::Notifications.instrument("sql.active_record", {
        sql: "SELECT * FROM users",
        name: "User Load",
        binds: [],
        connection: nil
      })

      collector.collect
      data = profile.collector_data("database")

      expect(data[:total_queries]).to eq(1)
      expect(data[:queries].first[:sql]).to eq("SELECT * FROM users")
    end

    it "skips SCHEMA queries" do
      collector.subscribe

      ActiveSupport::Notifications.instrument("sql.active_record", {
        sql: "SELECT tablename FROM pg_tables",
        name: "SCHEMA",
        binds: [],
        connection: nil
      })

      collector.collect
      data = profile.collector_data("database")
      expect(data[:total_queries]).to eq(0)
    end

    it "skips BEGIN/COMMIT/ROLLBACK queries" do
      collector.subscribe

      %w[BEGIN COMMIT ROLLBACK].each do |stmt|
        ActiveSupport::Notifications.instrument("sql.active_record", {
          sql: stmt,
          name: "TRANSACTION",
          binds: [],
          connection: nil
        })
      end

      collector.collect
      data = profile.collector_data("database")
      expect(data[:total_queries]).to eq(0)
    end

    it "counts slow queries" do
      collector.subscribe

      # We can't easily control timing in integration style, so we'll test
      # the toolbar_summary color logic by manipulating @queries directly
      collector.collect # empty collect

      slow_query = Profiler::Models::SqlQuery.new(sql: "SELECT 1", duration: 500.0)
      collector.instance_variable_set(:@queries, [slow_query])

      summary = collector.toolbar_summary
      expect(summary[:color]).to eq("red")
    end
  end

  describe "#toolbar_summary" do
    it "returns green when no slow queries and under warning threshold" do
      collector.instance_variable_set(:@queries, [
        Profiler::Models::SqlQuery.new(sql: "SELECT 1", duration: 5.0)
      ])
      expect(collector.toolbar_summary[:color]).to eq("green")
    end

    it "returns red when there are slow queries" do
      collector.instance_variable_set(:@queries, [
        Profiler::Models::SqlQuery.new(sql: "SELECT 1", duration: 500.0)
      ])
      expect(collector.toolbar_summary[:color]).to eq("red")
    end

    it "returns orange when many queries but none slow" do
      Profiler.configure { |c| c.max_queries_warning = 2 }
      collector.instance_variable_set(:@queries, [
        Profiler::Models::SqlQuery.new(sql: "SELECT 1", duration: 5.0),
        Profiler::Models::SqlQuery.new(sql: "SELECT 2", duration: 5.0),
        Profiler::Models::SqlQuery.new(sql: "SELECT 3", duration: 5.0)
      ])
      expect(collector.toolbar_summary[:color]).to eq("orange")
    end

    it "includes query count and duration in text" do
      collector.instance_variable_set(:@queries, [
        Profiler::Models::SqlQuery.new(sql: "SELECT 1", duration: 10.0)
      ])
      expect(collector.toolbar_summary[:text]).to include("1 queries")
    end
  end

  describe "#collect computed fields" do
    it "computes total_duration, slow_queries, cached_queries" do
      queries = [
        Profiler::Models::SqlQuery.new(sql: "SELECT 1", duration: 200.0),
        Profiler::Models::SqlQuery.new(sql: "SELECT 2", duration: 5.0, name: "CACHE"),
        Profiler::Models::SqlQuery.new(sql: "SELECT 3", duration: 50.0)
      ]
      collector.instance_variable_set(:@queries, queries)
      allow(collector).to receive(:instance_variable_get).with(:@subscription).and_return(nil)

      # Call collect without a real subscription to unsubscribe
      collector.instance_variable_set(:@subscription, nil)
      collector.collect

      data = profile.collector_data("database")
      expect(data[:total_queries]).to eq(3)
      expect(data[:total_duration]).to be_within(0.1).of(255.0)
      expect(data[:slow_queries]).to eq(1)
      expect(data[:cached_queries]).to eq(1)
    end
  end
end
