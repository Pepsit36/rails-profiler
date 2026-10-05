# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "profiler/storage/sqlite_store"
require "profiler/storage/blob_store"

# SEC-13: a token is turned into a file name, a directory name or a key by every backend. Each
# backend checks it against the format the gem issues (SecureRandom.hex(16)) before any access,
# whoever calls it: the controllers, the cluster proxy or the MCP tools.
RSpec.describe "Profile token validation in the storage backends" do
  INVALID_TOKENS = [
    "../victim", "../../config/important", "/etc/passwd", "abc", "tok", "A" * 32, "g" * 32,
    "#{"a" * 32}\n", "#{"a" * 32}/../victim", "a" * 31, "a" * 33, "", nil, 42
  ].freeze

  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      example.run
    end
  end

  let(:valid_token) { SecureRandom.hex(16) }

  describe Profiler::Storage::FileStore do
    subject(:store) { described_class.new(path: File.join(@root, "store")) }

    let(:victim) { File.join(@root, "victim.json") }

    before { File.write(victim, JSON.generate("token" => "x", "path" => "/secret")) }

    it "finds no profile for a traversing token, and leaves the file alone" do
      expect(store.load("../victim")).to be_nil
      expect(store.exists?("../victim")).to be false
      store.delete("../victim")
      expect(File.exist?(victim)).to be true
    end

    it "refuses to save under a traversing token" do
      expect { store.save("../victim", build_profile) }.to raise_error(ArgumentError, /token/)
      expect(JSON.parse(File.read(victim))).to eq("token" => "x", "path" => "/secret")
    end

    it "answers not found for every malformed token, never an exception" do
      INVALID_TOKENS.each do |token|
        expect(store.load(token)).to be_nil, "load(#{token.inspect})"
        expect { store.delete(token) }.not_to raise_error
      end
    end

    it "still keeps a profile under a token the gem issues" do
      profile = build_profile(token: valid_token)
      store.save(valid_token, profile)
      expect(store.load(valid_token).token).to eq(valid_token)
    end
  end

  describe Profiler::Storage::MemoryStore do
    subject(:store) { described_class.new }

    it "refuses to save under a malformed token" do
      INVALID_TOKENS.each do |token|
        expect { store.save(token, build_profile) }.to raise_error(ArgumentError, /token/), "save(#{token.inspect})"
      end
      expect(store.list).to be_empty
    end

    it "answers not found for a malformed token" do
      INVALID_TOKENS.each { |token| expect(store.load(token)).to be_nil }
    end
  end

  describe Profiler::Storage::RedisStore do
    let(:redis) { instance_double("Redis") }
    subject(:store) { described_class.new(redis: redis) }

    it "never sends a malformed token to Redis" do
      INVALID_TOKENS.each do |token|
        expect(store.load(token)).to be_nil
        expect { store.delete(token) }.not_to raise_error
        expect { store.save(token, build_profile) }.to raise_error(ArgumentError, /token/)
      end
    end
  end

  describe Profiler::Storage::SqliteStore do
    subject(:store) do
      described_class.new(database: File.join(@root, "db", "profiler.db"), blob_path: File.join(@root, "blobs"))
    end

    let(:victim_dir) { File.join(@root, "victim_dir") }

    before do
      FileUtils.mkdir_p(victim_dir)
      File.write(File.join(victim_dir, "keep.txt"), "keep")
    end

    it "leaves a directory outside the blob store alone on a traversing delete" do
      store.delete("../victim_dir")
      expect(File.exist?(File.join(victim_dir, "keep.txt"))).to be true
    end

    it "answers not found for a malformed token and refuses to save under one" do
      INVALID_TOKENS.each do |token|
        expect(store.load(token)).to be_nil
        expect { store.save(token, build_profile) }.to raise_error(ArgumentError, /token/)
      end
    end
  end

  describe Profiler::Storage::BlobStore do
    subject(:blobs) { described_class.new(File.join(@root, "blobs")) }

    let(:victim_dir) { File.join(@root, "victim_dir") }

    before do
      FileUtils.mkdir_p(victim_dir)
      File.write(File.join(victim_dir, "http_response_bodies.json"), "[]")
    end

    it "neither reads, writes nor deletes outside its directory" do
      expect(blobs.read("../victim_dir", "http_response_bodies")).to be_nil
      expect(blobs.exists?("../victim_dir", "http_response_bodies")).to be false
      expect { blobs.write("../victim_dir", "http_response_bodies", [1]) }.to raise_error(ArgumentError, /token/)
      expect { blobs.write(valid_token, "../../victim", [1]) }.to raise_error(ArgumentError, /name/)
      blobs.delete("../victim_dir")
      expect(File.read(File.join(victim_dir, "http_response_bodies.json"))).to eq("[]")
    end
  end
end
