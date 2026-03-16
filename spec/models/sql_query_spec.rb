# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Models::SqlQuery do
  let(:default_attrs) do
    { sql: "SELECT * FROM users WHERE id = 1", duration: 50.0 }
  end

  subject(:query) { described_class.new(**default_attrs) }

  describe "#slow?" do
    it "returns false when duration is below threshold" do
      q = described_class.new(sql: "SELECT 1", duration: 50.0)
      expect(q.slow?(100)).to be false
    end

    it "returns true when duration exceeds threshold" do
      q = described_class.new(sql: "SELECT 1", duration: 200.0)
      expect(q.slow?(100)).to be true
    end

    it "uses 100 as default threshold" do
      fast = described_class.new(sql: "SELECT 1", duration: 99.9)
      slow = described_class.new(sql: "SELECT 1", duration: 100.1)
      expect(fast.slow?).to be false
      expect(slow.slow?).to be true
    end
  end

  describe "#cached?" do
    it "returns true when name is CACHE" do
      q = described_class.new(sql: "SELECT 1", duration: 0.1, name: "CACHE")
      expect(q.cached?).to be true
    end

    it "returns false for other names" do
      q = described_class.new(sql: "SELECT 1", duration: 5.0, name: "User Load")
      expect(q.cached?).to be false
    end

    it "returns false when name is nil" do
      expect(query.cached?).to be false
    end
  end

  describe "#transaction?" do
    it "returns truthy for BEGIN" do
      q = described_class.new(sql: "BEGIN", duration: 0.1)
      expect(q.transaction?).to be_truthy
    end

    it "returns truthy for COMMIT" do
      q = described_class.new(sql: "COMMIT", duration: 0.1)
      expect(q.transaction?).to be_truthy
    end

    it "returns truthy for ROLLBACK" do
      q = described_class.new(sql: "ROLLBACK", duration: 0.1)
      expect(q.transaction?).to be_truthy
    end

    it "is case-insensitive" do
      q = described_class.new(sql: "begin", duration: 0.1)
      expect(q.transaction?).to be_truthy
    end

    it "returns nil for normal queries" do
      expect(query.transaction?).to be_nil
    end
  end

  describe "#to_h" do
    it "includes sql, duration, binds, name, connection" do
      q = described_class.new(sql: "SELECT 1", duration: 5.0, name: "User Load")
      hash = q.to_h
      expect(hash).to include(:sql, :duration, :binds, :name, :connection)
    end

    it "includes computed slow field" do
      q = described_class.new(sql: "SELECT 1", duration: 200.0)
      expect(q.to_h[:slow]).to be true
    end

    it "includes computed cached field" do
      q = described_class.new(sql: "SELECT 1", duration: 0.1, name: "CACHE")
      expect(q.to_h[:cached]).to be true
    end

    it "includes computed transaction field" do
      q = described_class.new(sql: "BEGIN", duration: 0.1)
      expect(q.to_h[:transaction]).to be_truthy
    end
  end

  describe "#to_json" do
    it "returns valid JSON" do
      expect { JSON.parse(query.to_json) }.not_to raise_error
    end
  end
end
