# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Profiler::Storage::FileStore do
  around(:each) do |example|
    Dir.mktmpdir do |tmpdir|
      @tmpdir = tmpdir
      example.run
    end
  end

  subject(:store) { described_class.new(path: @tmpdir) }

  let(:profile) { build_profile(path: "/test") }

  describe "#save and #load" do
    it "persists and retrieves a profile" do
      store.save(profile.token, profile)
      loaded = store.load(profile.token)
      expect(loaded).not_to be_nil
      expect(loaded.token).to eq(profile.token)
    end

    it "returns the token" do
      result = store.save(profile.token, profile)
      expect(result).to eq(profile.token)
    end

    it "creates a JSON file on disk" do
      store.save(profile.token, profile)
      expect(File.exist?(File.join(@tmpdir, "#{profile.token}.json"))).to be true
    end
  end

  describe "#load" do
    it "returns nil for unknown token" do
      expect(store.load("doesnotexist")).to be_nil
    end

    it "returns nil for corrupted JSON" do
      File.write(File.join(@tmpdir, "badtoken.json"), "not valid json {{{}}")
      expect(store.load("badtoken")).to be_nil
    end
  end

  describe "#list" do
    it "returns profiles sorted newest-first by mtime" do
      old_p = build_profile(path: "/old")
      new_p = build_profile(path: "/new")

      store.save(old_p.token, old_p)
      sleep(0.01)
      store.save(new_p.token, new_p)

      result = store.list
      expect(result.map(&:path)).to eq(["/new", "/old"])
    end

    it "respects limit and offset" do
      5.times { store.save(SecureRandom.hex(16), build_profile) }
      expect(store.list(limit: 2).size).to eq(2)
      expect(store.list(limit: 10, offset: 3).size).to eq(2)
    end
  end

  describe "#cleanup" do
    it "deletes files older than the cutoff" do
      store.save(profile.token, profile)
      file_path = File.join(@tmpdir, "#{profile.token}.json")

      # Make the file appear old
      old_time = Time.now - 7200
      File.utime(old_time, old_time, file_path)

      store.cleanup(older_than: 3600)

      expect(File.exist?(file_path)).to be false
    end

    it "keeps recent files" do
      store.save(profile.token, profile)
      file_path = File.join(@tmpdir, "#{profile.token}.json")

      store.cleanup(older_than: 3600)

      expect(File.exist?(file_path)).to be true
    end
  end

  describe "#find_by_parent" do
    it "returns profiles with matching parent_token" do
      parent_token = "par123"
      child = build_profile(parent_token: parent_token)
      other = build_profile(parent_token: "other")

      store.save(child.token, child)
      store.save(other.token, other)

      results = store.find_by_parent(parent_token)
      expect(results.size).to eq(1)
      expect(results.first.token).to eq(child.token)
    end
  end
end
