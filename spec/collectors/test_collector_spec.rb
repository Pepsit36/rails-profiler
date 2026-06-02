# frozen_string_literal: true

require "spec_helper"
require "profiler/collectors/test_collector"

RSpec.describe Profiler::Collectors::TestCollector do
  let(:profile) { build_profile }
  subject(:collector) do
    described_class.new(
      profile,
      test_name: "MySpec#does something",
      test_file: "spec/models/my_spec.rb",
      test_line: 42,
      framework: :rspec
    )
  end

  describe "#collect" do
    it "stores test metadata in the profile" do
      collector.collect
      data = profile.collector_data("test")
      expect(data[:test_name]).to eq("MySpec#does something")
      expect(data[:test_file]).to eq("spec/models/my_spec.rb")
      expect(data[:test_line]).to eq(42)
      expect(data[:framework]).to eq("rspec")
    end

    it "stores default status as 'running' before any update" do
      collector.collect
      expect(profile.collector_data("test")[:status]).to eq("running")
    end
  end

  describe "#update_status" do
    it "updates status to passed" do
      collector.update_status("passed")
      collector.collect
      expect(profile.collector_data("test")[:status]).to eq("passed")
    end

    it "updates status to failed with exception message" do
      collector.update_status("failed", "expected 1 but got 2")
      collector.collect
      data = profile.collector_data("test")
      expect(data[:status]).to eq("failed")
      expect(data[:exception_message]).to eq("expected 1 but got 2")
    end
  end

  describe "#update_extra" do
    it "stores assertions count" do
      collector.update_extra(assertions: 5)
      collector.collect
      expect(profile.collector_data("test")[:assertions]).to eq(5)
    end

    it "stores skip_reason" do
      collector.update_extra(skip_reason: "not implemented yet")
      collector.collect
      expect(profile.collector_data("test")[:skip_reason]).to eq("not implemented yet")
    end
  end

  describe "#toolbar_summary" do
    it "returns green for passed" do
      collector.update_status("passed")
      expect(collector.toolbar_summary[:color]).to eq("green")
    end

    it "returns red for failed" do
      collector.update_status("failed")
      expect(collector.toolbar_summary[:color]).to eq("red")
    end

    it "returns orange for pending" do
      collector.update_status("pending")
      expect(collector.toolbar_summary[:color]).to eq("orange")
    end

    it "returns gray for running" do
      expect(collector.toolbar_summary[:color]).to eq("gray")
    end

    it "includes the status as text" do
      collector.update_status("passed")
      expect(collector.toolbar_summary[:text]).to eq("passed")
    end
  end

  describe "#tab_config" do
    it "uses 'test' as key" do
      expect(collector.tab_config[:key]).to eq("test")
    end

    it "is default_active" do
      expect(collector.tab_config[:default_active]).to be true
    end

    it "includes required keys" do
      expect(collector.tab_config).to include(:key, :label, :icon, :priority, :enabled, :default_active)
    end
  end

  describe "#has_data?" do
    it "always returns true" do
      expect(collector.has_data?).to be true
    end
  end
end
