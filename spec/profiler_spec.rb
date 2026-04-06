# frozen_string_literal: true

require "profiler/collectors/flamegraph_collector"

RSpec.describe Profiler do
  it "has a version number" do
    expect(Profiler::VERSION).not_to be nil
  end

  describe ".configure" do
    it "yields configuration" do
      expect { |b| Profiler.configure(&b) }.to yield_with_args(Profiler::Configuration)
    end

    it "sets configuration" do
      Profiler.configure do |config|
        config.enabled = true
      end

      expect(Profiler.configuration.enabled).to be true
    end
  end

  describe ".enabled?" do
    it "returns configuration enabled state" do
      Profiler.configure do |config|
        config.enabled = true
      end

      expect(Profiler.enabled?).to be true
    end
  end

  describe ".storage" do
    it "returns storage backend" do
      Profiler.configure do |config|
        config.storage = :memory
      end

      expect(Profiler.storage).to be_a(Profiler::Storage::MemoryStore)
    end
  end

  describe ".measure" do
    before do
      Profiler.configure { |c| c.enabled = true }
      Thread.current[:profiler_flamegraph_collector] = nil
    end

    after do
      Thread.current[:profiler_flamegraph_collector] = nil
    end

    it "yields the block and returns its value" do
      result = Profiler.measure("test.operation") { 42 }
      expect(result).to eq(42)
    end

    it "yields transparently when profiler is disabled" do
      Profiler.configure { |c| c.enabled = false }
      called = false
      Profiler.measure("test") { called = true }
      expect(called).to be true
    end

    it "yields transparently when no flamegraph collector is active" do
      Thread.current[:profiler_flamegraph_collector] = nil
      called = false
      Profiler.measure("test") { called = true }
      expect(called).to be true
    end

    it "records a custom event on the flamegraph collector" do
      profile = build_profile
      collector = Profiler::Collectors::FlameGraphCollector.new(profile)
      Thread.current[:profiler_flamegraph_collector] = collector

      Profiler.measure("payment.stripe_charge") { "ok" }

      events = collector.instance_variable_get(:@events)
      expect(events.size).to eq(1)
      expect(events.first.category).to eq("custom")
      expect(events.first.name).to eq("payment.stripe_charge")
    end

    it "records metadata in the event payload" do
      profile = build_profile
      collector = Profiler::Collectors::FlameGraphCollector.new(profile)
      Thread.current[:profiler_flamegraph_collector] = collector

      Profiler.measure("payment.stripe_charge", metadata: { amount: 1000 }) { "ok" }

      events = collector.instance_variable_get(:@events)
      expect(events.first.payload).to eq({ amount: 1000 })
    end

    it "records accurate start and end times" do
      profile = build_profile
      collector = Profiler::Collectors::FlameGraphCollector.new(profile)
      Thread.current[:profiler_flamegraph_collector] = collector

      before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Profiler.measure("timed.op") { sleep(0.01) }
      after = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      event = collector.instance_variable_get(:@events).first
      expect(event.started_at).to be >= before
      expect(event.finished_at).to be <= after
      expect(event.duration).to be >= 10.0
    end
  end
end
