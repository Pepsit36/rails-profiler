# frozen_string_literal: true

require "spec_helper"
require "profiler/cluster/slave_registry"

RSpec.describe Profiler::Cluster::SlaveRegistry do
  subject(:registry) { described_class.new }

  describe "#register" do
    it "adds a new slave as online" do
      registry.register(name: "payment", url: "http://localhost:3001")
      entry = registry.all.first
      expect(entry[:name]).to eq("payment")
      expect(entry[:url]).to eq("http://localhost:3001")
      expect(entry[:status]).to eq("online")
    end

    it "upserts an existing slave (updates url, keeps a single entry)" do
      registry.register(name: "payment", url: "http://old:3001")
      registry.register(name: "payment", url: "http://new:3001")
      expect(registry.all.size).to eq(1)
      expect(registry.all.first[:url]).to eq("http://new:3001")
    end

    it "serializes timestamps as ISO8601 strings" do
      registry.register(name: "payment", url: "http://localhost:3001")
      entry = registry.all.first
      expect(entry[:registered_at]).to match(/\d{4}-\d{2}-\d{2}T/)
      expect(entry[:last_heartbeat_at]).to match(/\d{4}-\d{2}-\d{2}T/)
    end
  end

  describe "#heartbeat" do
    it "refreshes the heartbeat and returns the entry" do
      registry.register(name: "payment", url: "http://localhost:3001")
      expect(registry.heartbeat("payment")).not_to be_nil
    end

    it "returns nil for an unknown slave" do
      expect(registry.heartbeat("ghost")).to be_nil
    end
  end

  describe "#find!" do
    it "returns the entry for a known slave" do
      registry.register(name: "payment", url: "http://localhost:3001")
      expect(registry.find!("payment").name).to eq("payment")
    end

    it "raises Profiler::Error for an unknown slave" do
      expect { registry.find!("ghost") }.to raise_error(Profiler::Error, /Unknown slave/)
    end
  end

  describe "status" do
    it "is offline when the last heartbeat is older than the threshold" do
      Profiler.configure { |c| c.cluster_offline_threshold = 60 }
      entry = registry.register(name: "payment", url: "http://localhost:3001")
      entry.last_heartbeat_at = Time.now - 120
      expect(registry.all.first[:status]).to eq("offline")
    end
  end
end
