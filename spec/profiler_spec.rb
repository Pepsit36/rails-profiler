# frozen_string_literal: true

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
end
