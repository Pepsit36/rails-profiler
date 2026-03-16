# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Collectors::CacheCollector do
  let(:profile) { build_profile }
  subject(:collector) { described_class.new(profile) }

  describe "#subscribe and #collect" do
    it "captures cache_read hits and misses" do
      collector.subscribe

      ActiveSupport::Notifications.instrument("cache_read.active_support",
        key: "user:1", hit: true)
      ActiveSupport::Notifications.instrument("cache_read.active_support",
        key: "user:2", hit: false)

      collector.collect
      data = profile.collector_data("cache")

      expect(data[:hits]).to eq(1)
      expect(data[:misses]).to eq(1)
      expect(data[:total_reads]).to eq(2)
    end

    it "captures cache_write events" do
      collector.subscribe

      ActiveSupport::Notifications.instrument("cache_write.active_support", key: "user:3")

      collector.collect
      data = profile.collector_data("cache")
      expect(data[:total_writes]).to eq(1)
    end

    it "captures cache_delete events" do
      collector.subscribe

      ActiveSupport::Notifications.instrument("cache_delete.active_support", key: "user:4")

      collector.collect
      data = profile.collector_data("cache")
      expect(data[:total_deletes]).to eq(1)
    end

    it "computes correct hit_rate" do
      collector.subscribe

      ActiveSupport::Notifications.instrument("cache_read.active_support", key: "k1", hit: true)
      ActiveSupport::Notifications.instrument("cache_read.active_support", key: "k2", hit: true)
      ActiveSupport::Notifications.instrument("cache_read.active_support", key: "k3", hit: false)

      collector.collect
      data = profile.collector_data("cache")
      expect(data[:hit_rate]).to be_within(0.01).of(66.67)
    end

    it "returns 0 hit_rate when no reads" do
      collector.collect
      data = profile.collector_data("cache")
      expect(data[:hit_rate]).to eq(0)
    end
  end

  describe "#toolbar_summary" do
    it "returns hits/total text" do
      collector.instance_variable_set(:@cache_reads, [
        { key: "k1", hit: true },
        { key: "k2", hit: false }
      ])

      summary = collector.toolbar_summary
      expect(summary[:text]).to eq("1/2 hits")
      expect(summary[:color]).to eq("cyan")
    end
  end
end
