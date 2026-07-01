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
  end
end
