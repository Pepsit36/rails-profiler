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
    # C3: the list of an earlier version is never pruned, expired tokens included.
    it "prunes the expired tokens and reads the others in batches" do
      now = Time.now.to_f
      2_000.times do |i|
        p = build_profile
        if i.even?
          redis.zadd("test_profiler:list", now - 7200 - i, p.token) # past the TTL of an hour: expired
        else
          redis.setex("test_profiler:#{p.token}", 3600, p.to_json)
          redis.zadd("test_profiler:list", now - i, p.token)
        end
      end
      uncapped = described_class.new(redis: redis, ttl: 3600, key_prefix: "test_profiler", max_profiles: nil)
      before = redis.round_trips

      expect(uncapped.list(limit: 5).size).to eq(5)

      expect(redis.round_trips - before).to be < 100
      expect(redis.zcard("test_profiler:list")).to eq(1_000)
      expect(uncapped.list(limit: 2_000, type: "http").size).to eq(1_000)
    end

    # C3 bis: the backlog past the cap is evicted by batches, not one token at a time.
    it "evicts the backlog past the cap in batches" do
      capped = described_class.new(redis: redis, ttl: 3600, key_prefix: "test_profiler", max_profiles: 100)
      2_000.times do |i|
        p = build_profile(started_at: Time.now - 2_000 + i)
        redis.setex("test_profiler:#{p.token}", 3600, p.to_json)
        redis.zadd("test_profiler:list", p.started_at.to_f, p.token)
      end
      before = redis.round_trips
      profile = build_profile
      capped.save(profile.token, profile)

      expect(redis.round_trips - before).to be < 150
      expect(redis.zcard("test_profiler:saved")).to be <= 100
      expect(redis.zcard("test_profiler:list")).to be <= 100
      expect(capped.load(profile.token)).not_to be_nil
    end

    it "evicts a bounded batch only while another process evicts the backlog" do
      described_class.new(redis: redis, ttl: 3600, key_prefix: "test_profiler", max_profiles: nil).tap do |uncapped|
        1_000.times { |i| build_profile(started_at: Time.now - 1_000 + i).tap { |p| uncapped.save(p.token, p) } }
      end
      redis.set("test_profiler:evict_lock", "another process", nx: true, ex: 60)
      capped = described_class.new(redis: redis, ttl: 3600, key_prefix: "test_profiler", max_profiles: 100)
      before = redis.round_trips
      profile = build_profile
      capped.save(profile.token, profile)

      expect(redis.round_trips - before).to be < 30
      evicted = 1_001 - redis.zcard("test_profiler:saved")
      expect(evicted).to be_between(1, described_class::EVICT_BATCH)
      expect(capped.load(profile.token)).not_to be_nil
    end

    # R-b: a lock that expired and was taken by another process is not this one's to release.
    it "releases the indexing lock only while it still holds it" do
      old = build_profile
      redis.setex("test_profiler:#{old.token}", 3600, old.to_json)
      redis.zadd("test_profiler:list", old.started_at.to_f, old.token)
      allow(redis).to receive(:mget).and_wrap_original do |original, *args|
        redis.set("test_profiler:index_lock", "another process")
        original.call(*args)
      end

      store.list(limit: 5)

      expect(redis.get("test_profiler:index_lock")).to eq("another process")
    end

    it "lets one process index them, the others going on meanwhile" do
      old = build_profile
      redis.setex("test_profiler:#{old.token}", 3600, old.to_json)
      redis.zadd("test_profiler:list", old.started_at.to_f, old.token)
      redis.set("test_profiler:index_lock", "another process", nx: true, ex: 60)

      expect(store.list(limit: 5).map(&:token)).to eq([old.token])
      expect(redis.get("test_profiler:summary:#{old.token}")).to be_nil

      redis.del("test_profiler:index_lock")
      expect(store.list(limit: 5, type: "http").map(&:token)).to eq([old.token])
    end

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
