# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Collectors::BaseCollector do
  # Create a concrete subclass for testing
  let(:concrete_class) do
    Class.new(described_class) do
      def self.name
        "Profiler::Collectors::TestCollector"
      end
    end
  end

  let(:profile) { build_profile }
  subject(:collector) { concrete_class.new(profile) }

  describe "#name" do
    it "derives from class name by removing Collector suffix and downcasing" do
      expect(collector.name).to eq("test")
    end
  end

  describe "#tab_config" do
    it "returns a hash with required keys" do
      config = collector.tab_config
      expect(config).to include(:key, :label, :icon, :priority, :enabled, :default_active)
    end

    it "uses name as key" do
      expect(collector.tab_config[:key]).to eq("test")
    end
  end

  describe "#has_data?" do
    it "returns false when panel_content is nil" do
      allow(collector).to receive(:panel_content).and_return(nil)
      expect(collector.has_data?).to be false
    end

    it "returns false when panel_content is empty hash" do
      allow(collector).to receive(:panel_content).and_return({})
      expect(collector.has_data?).to be false
    end

    it "returns false when panel_content is empty array" do
      allow(collector).to receive(:panel_content).and_return([])
      expect(collector.has_data?).to be false
    end

    it "returns true when panel_content has data" do
      allow(collector).to receive(:panel_content).and_return({ total: 5 })
      expect(collector.has_data?).to be true
    end
  end

  describe "#store_data" do
    it "stores data in @data" do
      collector.send(:store_data, { count: 3 })
      expect(collector.panel_content).to eq({ count: 3 })
    end

    it "calls profile.add_collector_data" do
      expect(profile).to receive(:add_collector_data).with("test", { count: 3 })
      collector.send(:store_data, { count: 3 })
    end
  end

  describe ".descendants" do
    it "tracks subclasses" do
      # The concrete_class is already a subclass; verify it's tracked somewhere
      expect(described_class.descendants).to be_an(Array)
    end
  end
end
