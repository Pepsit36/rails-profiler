# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "profiler/storage/sqlite_store"
require "profiler/mcp/file_cache"

# FAB-39 and BUG-05: tmp_path is shared by the file store, the SQLite store and its blobs, the
# env overrides and the MCP body cache. Each keeps to its own files.
RSpec.describe "Layout of tmp_path" do
  around do |example|
    Dir.mktmpdir do |root|
      @tmp_path = Pathname.new(root).join("profiler")
      Profiler.configure { |config| config.tmp_path = @tmp_path }
      example.run
    end
  ensure
    Profiler.instance_variable_set(:@env_override_store, nil)
  end

  let(:overrides_file) { @tmp_path.join("env_overrides.json") }

  def age(path, seconds)
    time = Time.now - seconds
    File.utime(time, time, path)
  end

  describe "the file store" do
    it "keeps its profiles in a directory of their own by default" do
      store = Profiler::Storage::FileStore.new
      profile = build_profile
      store.save(profile.token, profile)

      expect(File.exist?(@tmp_path.join("profiles", "#{profile.token}.json"))).to be true
    end

    it "neither lists nor clears the env overrides" do
      Profiler::EnvOverrideStore.new.set("PROFILER_SPEC_LAYOUT", "1")
      store = Profiler::Storage::FileStore.new

      expect(store.list).to be_empty
      store.clear
      expect(File.exist?(overrides_file)).to be true
    ensure
      ENV.delete("PROFILER_SPEC_LAYOUT")
    end

    it "takes only the files named after a token for profiles, even when its path is tmp_path" do
      Profiler::EnvOverrideStore.new.set("PROFILER_SPEC_LAYOUT", "1")
      store = Profiler::Storage::FileStore.new(path: @tmp_path.to_s)
      profile = build_profile
      store.save(profile.token, profile)

      expect(store.list.map(&:token)).to eq([profile.token])
      store.cleanup(older_than: -60)
      store.clear
      expect(File.exist?(overrides_file)).to be true
      expect(store.list).to be_empty
    ensure
      ENV.delete("PROFILER_SPEC_LAYOUT")
    end
  end

  describe "the MCP body cache" do
    let(:token) { SecureRandom.hex(16) }

    it "writes under a directory of its own" do
      path = Profiler::MCP::FileCache.save(token, "response_body", "body")
      expect(path).to eq(@tmp_path.join("mcp-cache", token, "response_body").to_s)
    end

    it "leaves the SQLite blobs alone when it cleans up" do
      store = Profiler::Storage::SqliteStore.new
      profile = build_profile(collectors_data: {
        "http" => { "requests" => [{ "url" => "http://x", "response_body" => "stored body" }] }
      })
      store.save(profile.token, profile)
      blobs = @tmp_path.join("blobs")
      expect(blobs.join(profile.token, "http_response_bodies.json")).to exist
      age(blobs, 7200)

      Profiler::MCP::FileCache.cleanup

      expect(blobs.join(profile.token, "http_response_bodies.json")).to exist
      body = store.load(profile.token).collector_data("http")["requests"].first["response_body"]
      expect(body).to eq("stored body")
    end

    it "removes only the old entries it wrote itself" do
      old_path = Profiler::MCP::FileCache.save(token, "response_body", "body")
      age(File.dirname(old_path), 7200)
      fresh = Profiler::MCP::FileCache.save(SecureRandom.hex(16), "response_body", "body")
      foreign = @tmp_path.join("mcp-cache", "notes")
      FileUtils.mkdir_p(foreign)
      age(foreign, 7200)

      Profiler::MCP::FileCache.cleanup

      expect(File.exist?(old_path)).to be false
      expect(File.exist?(fresh)).to be true
      expect(foreign).to exist
    end

    it "refuses a token or a name that would leave its directory" do
      expect(Profiler::MCP::FileCache.save("../outside", "response_body", "body")).to be_nil
      expect(Profiler::MCP::FileCache.save(token, "../../outside", "body")).to be_nil
      expect(@tmp_path.parent.join("outside")).not_to exist
    end
  end
end
