# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Storage::RedisStore do
  let(:redis) { instance_double("Redis") }
  subject(:store) { described_class.new(redis: redis, ttl: 3600, key_prefix: "test_profiler") }

  let(:profile) { build_profile(path: "/redis-test") }

  describe "#save" do
    it "calls setex with the profile JSON" do
      expect(redis).to receive(:setex).with(
        "test_profiler:#{profile.token}",
        3600,
        profile.to_json
      )
      expect(redis).to receive(:zadd).with(
        "test_profiler:list",
        anything,
        profile.token
      )

      store.save(profile.token, profile)
    end

    it "returns the token" do
      allow(redis).to receive(:setex)
      allow(redis).to receive(:zadd)

      result = store.save(profile.token, profile)
      expect(result).to eq(profile.token)
    end
  end

  describe "#load" do
    it "calls get and deserializes the profile" do
      allow(redis).to receive(:get).with("test_profiler:#{profile.token}").and_return(profile.to_json)

      loaded = store.load(profile.token)
      expect(loaded.token).to eq(profile.token)
      expect(loaded.path).to eq("/redis-test")
    end

    it "returns nil when Redis returns nil" do
      allow(redis).to receive(:get).and_return(nil)
      expect(store.load("nonexistent")).to be_nil
    end
  end

  describe "#list" do
    it "calls zrevrange and loads each token" do
      tokens = [profile.token]
      allow(redis).to receive(:zrevrange).with("test_profiler:list", 0, 49).and_return(tokens)
      allow(redis).to receive(:get).with("test_profiler:#{profile.token}").and_return(profile.to_json)

      result = store.list(limit: 50, offset: 0)
      expect(result.size).to eq(1)
      expect(result.first.token).to eq(profile.token)
    end

    it "compacts nil results (expired profiles)" do
      allow(redis).to receive(:zrevrange).and_return(["dead_token"])
      allow(redis).to receive(:get).and_return(nil)

      expect(store.list).to be_empty
    end
  end

  describe "#cleanup" do
    it "calls zremrangebyscore with cutoff score" do
      expect(redis).to receive(:zremrangebyscore).with("test_profiler:list", "-inf", anything)
      store.cleanup(older_than: 3600)
    end
  end

  describe "#find_by_parent" do
    it "loads all profiles and filters by parent_token" do
      parent_token = SecureRandom.hex(16)
      child = build_profile(parent_token: parent_token)
      other = build_profile(parent_token: SecureRandom.hex(16))

      allow(redis).to receive(:zrange).with("test_profiler:list", 0, -1)
                                      .and_return([child.token, other.token])
      allow(redis).to receive(:get).with("test_profiler:#{child.token}").and_return(child.to_json)
      allow(redis).to receive(:get).with("test_profiler:#{other.token}").and_return(other.to_json)

      results = store.find_by_parent(parent_token)
      expect(results.size).to eq(1)
      expect(results.first.token).to eq(child.token)
    end
  end
end
