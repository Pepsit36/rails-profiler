# frozen_string_literal: true

require "spec_helper"
require "profiler/mcp/slave_support"
require "profiler/cluster/slave_registry"

RSpec.describe Profiler::MCP::SlaveSupport do
  before do
    Profiler.configure { |c| c.storage = :memory }
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
    Profiler.instance_variable_set(:@slave_registry, Profiler::Cluster::SlaveRegistry.new)
    Profiler.slave_registry.register(name: "payment", url: "http://payment:3001")
  end

  describe ".resolve_storage" do
    it "returns the local storage when no slave is requested" do
      expect(described_class.resolve_storage({})).to eq(Profiler.storage)
    end

    it "returns a SlaveProxy when a slave is requested" do
      expect(described_class.resolve_storage("slave" => "payment"))
        .to be_a(Profiler::Cluster::SlaveProxy)
    end

    it "raises for an unknown slave" do
      expect { described_class.resolve_storage("slave" => "ghost") }
        .to raise_error(Profiler::Error, /Unknown slave/)
    end
  end

  describe ".with_slave_proxy" do
    it "returns nil when no slave is requested" do
      expect(described_class.with_slave_proxy({})).to be_nil
    end

    it "returns a SlaveProxy when a slave is requested" do
      expect(described_class.with_slave_proxy("slave" => "payment"))
        .to be_a(Profiler::Cluster::SlaveProxy)
    end
  end
end
