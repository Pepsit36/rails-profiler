# frozen_string_literal: true

require "spec_helper"
require_relative "../support/fake_redis"

RSpec.describe Profiler::Storage::RedisStore do
  let(:redis) { FakeRedis.new }
  subject(:store) { described_class.new(redis: redis, ttl: 3600, key_prefix: "test_profiler") }

  let(:profile) { build_profile(path: "/redis-test") }

  describe "#save" do
    it "stores the profile JSON with the TTL and lists the token" do
      store.save(profile.token, profile)

      expect(redis.get("test_profiler:#{profile.token}")).to eq(profile.to_json)
      expect(redis.ttls["test_profiler:#{profile.token}"]).to eq(3600)
      expect(redis.zrange("test_profiler:list", 0, -1)).to eq([profile.token])
    end

    it "returns the token" do
      result = store.save(profile.token, profile)
      expect(result).to eq(profile.token)
    end
  end

  describe "#load" do
    it "gets and deserializes the profile" do
      redis.set("test_profiler:#{profile.token}", profile.to_json)

      loaded = store.load(profile.token)
      expect(loaded.token).to eq(profile.token)
      expect(loaded.path).to eq("/redis-test")
    end

    it "returns nil when Redis returns nil" do
      expect(store.load("nonexistent")).to be_nil
    end
  end

  describe "#list" do
    it "loads the tokens of the list, newest first" do
      store.save(profile.token, profile)

      result = store.list(limit: 50, offset: 0)
      expect(result.size).to eq(1)
      expect(result.first.token).to eq(profile.token)
    end

    it "compacts nil results (expired profiles)" do
      store.save(profile.token, profile)
      redis.del("test_profiler:#{profile.token}", "test_profiler:summary:#{profile.token}")

      expect(store.list).to be_empty
      expect(store.list(summary: true)).to be_empty
    end
  end

  describe "#cleanup" do
    it "removes the profiles started before the cutoff, and keeps the others" do
      old = build_profile(started_at: Time.now - 7200)
      store.save(old.token, old)
      store.save(profile.token, profile)

      store.cleanup(older_than: 3600)

      expect(redis.zrange("test_profiler:list", 0, -1)).to eq([profile.token])
      expect(store.load(old.token)).to be_nil
    end
  end

  describe "#find_by_parent" do
    it "returns the children of the parent only" do
      parent_token = SecureRandom.hex(16)
      child = build_profile(parent_token: parent_token)
      other = build_profile(parent_token: SecureRandom.hex(16))
      store.save(child.token, child)
      store.save(other.token, other)

      results = store.find_by_parent(parent_token)
      expect(results.size).to eq(1)
      expect(results.first.token).to eq(child.token)
    end
  end

  describe "profiles saved by a version without the indexes" do
    it "indexes them once, on first use" do
      parent = build_profile(started_at: Time.now - 10)
      child = build_profile(parent_token: parent.token, profile_type: "job")
      [parent, child].each do |p|
        redis.setex("test_profiler:#{p.token}", 3600, p.to_json)
        redis.zadd("test_profiler:list", p.started_at.to_f, p.token)
      end

      expect(store.find_by_parent(parent.token).map(&:token)).to eq([child.token])
      expect(store.list(type: "job").map(&:token)).to eq([child.token])
      expect(store.list(summary: true).map(&:token)).to eq([child.token, parent.token])
    end
  end
end
