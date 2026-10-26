# frozen_string_literal: true

require "spec_helper"
require "profiler/cluster/token_cache"

RSpec.describe Profiler::Cluster::TokenCache do
  subject(:cache) { described_class.new }

  describe "#fetch" do
    it "returns nil for an unknown token" do
      expect(cache.fetch("unknown")).to be_nil
    end

    it "returns the slave name after store" do
      cache.store("tok1", "slave-a")
      expect(cache.fetch("tok1")).to eq("slave-a")
    end

    it "returns nil after the TTL has elapsed" do
      cache.store("tok2", "slave-b")
      entry = cache.instance_variable_get(:@cache)["tok2"]
      entry[:expires_at] = Time.now - 1
      expect(cache.fetch("tok2")).to be_nil
    end

    it "deletes expired entries when fetching" do
      cache.store("tok5", "slave-d")
      entry = cache.instance_variable_get(:@cache)["tok5"]
      entry[:expires_at] = Time.now - 1
      cache.fetch("tok5")
      expect(cache.instance_variable_get(:@cache)).not_to have_key("tok5")
    end
  end

  describe "#invalidate" do
    it "removes a cached entry" do
      cache.store("tok3", "slave-c")
      cache.invalidate("tok3")
      expect(cache.fetch("tok3")).to be_nil
    end
  end

  describe "#store" do
    it "overwrites an existing entry" do
      cache.store("tok4", "slave-a")
      cache.store("tok4", "slave-b")
      expect(cache.fetch("tok4")).to eq("slave-b")
    end

    it "cleans up expired entries when cache exceeds size limit" do
      # Store 1001 entries, with the first 1000 expired
      (0...1000).each do |i|
        cache.store("tok_#{i}", "slave")
        entry = cache.instance_variable_get(:@cache)["tok_#{i}"]
        entry[:expires_at] = Time.now - 1
      end
      cache.store("tok_fresh", "slave-fresh")
      # After storing the 1001st entry, expired entries should be cleaned
      # The fresh entry should still be there, and size should be much smaller
      expect(cache.fetch("tok_fresh")).to eq("slave-fresh")
      expect(cache.instance_variable_get(:@cache).size).to be < 100
    end
  end
end
