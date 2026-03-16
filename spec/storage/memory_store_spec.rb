# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Storage::MemoryStore do
  subject(:store) { described_class.new(max_profiles: 10) }

  let(:profile) { build_profile(path: "/test") }

  describe "#save and #load" do
    it "stores and retrieves a profile by token" do
      store.save(profile.token, profile)
      loaded = store.load(profile.token)
      expect(loaded).not_to be_nil
      expect(loaded.token).to eq(profile.token)
    end

    it "returns the token from save" do
      result = store.save(profile.token, profile)
      expect(result).to eq(profile.token)
    end
  end

  describe "#load" do
    it "returns nil for unknown token" do
      expect(store.load("nonexistent")).to be_nil
    end
  end

  describe "#list" do
    it "returns profiles sorted newest-first" do
      older = build_profile(started_at: Time.now - 100)
      newer = build_profile(started_at: Time.now)

      store.save(older.token, older)
      store.save(newer.token, newer)

      result = store.list
      expect(result.first.token).to eq(newer.token)
    end

    it "respects limit" do
      5.times { |i| store.save("token#{i}", build_profile(path: "/p#{i}")) }
      expect(store.list(limit: 2).size).to eq(2)
    end

    it "respects offset" do
      3.times { |i| store.save("token#{i}", build_profile(path: "/p#{i}")) }
      full = store.list
      offset_result = store.list(offset: 1)
      expect(offset_result.size).to eq(full.size - 1)
    end
  end

  describe "#cleanup" do
    it "removes profiles older than cutoff" do
      old_profile = build_profile(started_at: Time.now - 3600)
      new_profile = build_profile(started_at: Time.now)

      store.save(old_profile.token, old_profile)
      store.save(new_profile.token, new_profile)

      store.cleanup(older_than: 1800) # 30 min cutoff

      expect(store.load(old_profile.token)).to be_nil
      expect(store.load(new_profile.token)).not_to be_nil
    end
  end

  describe "#find_by_parent" do
    it "returns profiles with matching parent_token sorted by started_at" do
      parent_token = "parent123"
      child1 = build_profile(parent_token: parent_token, started_at: Time.now - 10)
      child2 = build_profile(parent_token: parent_token, started_at: Time.now)
      other = build_profile(parent_token: "other")

      store.save(child1.token, child1)
      store.save(child2.token, child2)
      store.save(other.token, other)

      results = store.find_by_parent(parent_token)
      expect(results.size).to eq(2)
      expect(results.map(&:token)).to eq([child1.token, child2.token])
    end

    it "returns empty array when no children found" do
      expect(store.find_by_parent("none")).to be_empty
    end
  end

  describe "#exists?" do
    it "returns true when profile exists" do
      store.save(profile.token, profile)
      expect(store.exists?(profile.token)).to be true
    end

    it "returns false when profile does not exist" do
      expect(store.exists?("nonexistent")).to be false
    end
  end

  describe "capacity management" do
    it "removes oldest profiles when max_profiles is exceeded" do
      store = described_class.new(max_profiles: 5)
      tokens = []
      5.times do |i|
        p = build_profile(started_at: Time.now - (50 - i))
        store.save(p.token, p)
        tokens << p.token
      end

      # Saving one more should trigger cleanup
      extra = build_profile(started_at: Time.now)
      store.save(extra.token, extra)

      # The oldest profiles should have been removed
      expect(store.load(tokens.first)).to be_nil
    end
  end
end
