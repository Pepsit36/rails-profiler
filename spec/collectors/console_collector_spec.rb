# frozen_string_literal: true

require "spec_helper"
require "profiler/collectors/console_collector"

RSpec.describe Profiler::Collectors::ConsoleCollector do
  let(:profile) { build_profile }
  let(:expression) { "User.where(active: true).count" }

  subject(:collector) { described_class.new(profile, expression: expression) }

  describe "#set_return_value" do
    it "inspects the value and stores it" do
      collector.set_return_value(42)
      expect(collector.instance_variable_get(:@return_value)).to eq("42")
    end

    it "truncates values longer than 10_000 chars" do
      long_value = "x" * 20_000
      collector.set_return_value(long_value)
      expect(collector.instance_variable_get(:@return_value).length).to eq(10_000)
    end

    it "handles objects that raise on inspect" do
      bad_obj = Object.new
      bad_obj.define_singleton_method(:inspect) { raise "cannot inspect" }
      collector.set_return_value(bad_obj)
      expect(collector.instance_variable_get(:@return_value)).to eq("(uninspectable)")
    end

    it "marks return_value_captured as true" do
      collector.set_return_value(nil)
      expect(collector.instance_variable_get(:@return_value_captured)).to be true
    end
  end

  describe "#collect" do
    it "stores the expression in the profile" do
      collector.collect
      data = profile.collector_data("console")
      expect(data).not_to be_nil
      expect(data[:expression]).to eq(expression)
    end

    it "does not include return_value when not captured" do
      collector.collect
      data = profile.collector_data("console")
      expect(data).not_to have_key(:return_value)
    end

    it "includes return_value when captured" do
      collector.set_return_value(42)
      collector.collect
      data = profile.collector_data("console")
      expect(data[:return_value]).to eq("42")
    end
  end

  describe "#has_data?" do
    it "returns true when expression is present" do
      expect(collector.has_data?).to be true
    end

    it "returns false when expression is empty" do
      empty_collector = described_class.new(profile, expression: "")
      expect(empty_collector.has_data?).to be false
    end
  end

  describe "#tab_config" do
    it "has key 'console'" do
      expect(collector.tab_config[:key]).to eq("console")
    end

    it "has label 'Console'" do
      expect(collector.tab_config[:label]).to eq("Console")
    end

    it "is enabled by default" do
      expect(collector.tab_config[:enabled]).to be true
    end

    it "is default_active" do
      expect(collector.tab_config[:default_active]).to be true
    end

    it "has a lower priority number than other collectors (shown first)" do
      expect(collector.tab_config[:priority]).to be < 20
    end
  end

  describe "#toolbar_summary" do
    it "returns the first 30 chars of the expression in text" do
      long_expr = "a" * 50
      c = described_class.new(profile, expression: long_expr)
      expect(c.toolbar_summary[:text].length).to eq(30)
    end

    it "returns the full expression if shorter than 30 chars" do
      c = described_class.new(profile, expression: "2 + 2")
      expect(c.toolbar_summary[:text]).to eq("2 + 2")
    end

    it "returns blue color" do
      expect(collector.toolbar_summary[:color]).to eq("blue")
    end
  end
end
