# frozen_string_literal: true

require "spec_helper"
require "profiler/sse/event_bus"

RSpec.describe Profiler::SSE::EventBus do
  subject(:bus) { described_class.instance }

  # Reset the singleton state between examples
  before { bus.instance_variable_set(:@subscriptions, Concurrent::Hash.new) }

  describe "subscribe / unsubscribe lifecycle" do
    it "returns a unique string id" do
      id = bus.subscribe("tok", [])
      expect(id).to be_a(String)
      expect(id).not_to be_empty
    end

    it "removes the subscription on unsubscribe" do
      id = bus.subscribe("tok", [])
      bus.unsubscribe(id)
      expect(bus.instance_variable_get(:@subscriptions)).not_to have_key(id)
    end
  end

  describe "#broadcast routing by token" do
    it "delivers the event to a matching subscriber" do
      id = bus.subscribe("tok-a", [])
      bus.broadcast("tok-a", ["db"])
      event = bus.wait_for_event(id, timeout: 1)
      expect(event).not_to be_nil
      expect(event[:token]).to eq("tok-a")
    end

    it "does not deliver to a subscriber on a different token" do
      id = bus.subscribe("tok-b", [])
      bus.broadcast("tok-a", ["db"])
      event = bus.wait_for_event(id, timeout: 0.1)
      expect(event).to be_nil
    end
  end

  describe "#broadcast collector filtering" do
    it "delivers when the collector intersection is non-empty" do
      id = bus.subscribe("tok", ["db", "cache"])
      bus.broadcast("tok", ["db"])
      event = bus.wait_for_event(id, timeout: 1)
      expect(event).not_to be_nil
    end

    it "does not deliver when the collector intersection is empty" do
      id = bus.subscribe("tok", ["cache"])
      bus.broadcast("tok", ["db"])
      event = bus.wait_for_event(id, timeout: 0.1)
      expect(event).to be_nil
    end

    it "delivers to a match-all subscriber (empty collector set) regardless of changed collectors" do
      id = bus.subscribe("tok", [])
      bus.broadcast("tok", ["db"])
      event = bus.wait_for_event(id, timeout: 1)
      expect(event).not_to be_nil
    end
  end

  describe "#wait_for_event timeout" do
    it "returns nil when no event arrives within the timeout" do
      id = bus.subscribe("tok", [])
      result = bus.wait_for_event(id, timeout: 0.05)
      expect(result).to be_nil
    end

    it "returns nil for an unknown subscription id" do
      result = bus.wait_for_event("does-not-exist", timeout: 0.05)
      expect(result).to be_nil
    end
  end

  describe "multiple concurrent subscribers" do
    it "each subscriber receives the event independently" do
      id_a = bus.subscribe("tok", [])
      id_b = bus.subscribe("tok", [])
      bus.broadcast("tok", ["views"])
      event_a = bus.wait_for_event(id_a, timeout: 1)
      event_b = bus.wait_for_event(id_b, timeout: 1)
      expect(event_a).not_to be_nil
      expect(event_b).not_to be_nil
      expect(event_a[:collectors]).to eq(event_b[:collectors])
    end
  end
end
