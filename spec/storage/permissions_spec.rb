# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "profiler/storage/sqlite_store"
require "profiler/storage/blob_store"
require "profiler/mcp/file_cache"

# SEC-16: the profiles hold cookies, tokens and environment values. What the profiler creates is
# readable by its own user only, whatever the umask of the process.
RSpec.describe "Permissions of the profiler files" do
  around do |example|
    previous = File.umask(0o022)
    Dir.mktmpdir do |root|
      @root = root
      example.run
    end
  ensure
    File.umask(previous)
    Profiler.instance_variable_set(:@env_override_store, nil)
  end

  def mode(path)
    File.stat(path).mode & 0o777
  end

  let(:tmp_path) { Pathname.new(File.join(@root, "app", "tmp", "rails-profiler")) }

  before { Profiler.configure { |config| config.tmp_path = tmp_path } }

  it "creates the file store directory 0700 and its profiles 0600" do
    store = Profiler::Storage::FileStore.new(path: File.join(@root, "profiles"))
    profile = build_profile
    store.save(profile.token, profile)

    expect(mode(File.join(@root, "profiles"))).to eq(0o700)
    expect(mode(File.join(@root, "profiles", "#{profile.token}.json"))).to eq(0o600)
  end

  it "makes a profile file written over an older one 0600" do
    dir = File.join(@root, "profiles")
    FileUtils.mkdir_p(dir)
    profile = build_profile
    file = File.join(dir, "#{profile.token}.json")
    File.write(file, "{}")
    File.chmod(0o644, file)

    Profiler::Storage::FileStore.new(path: dir).save(profile.token, profile)
    expect(mode(file)).to eq(0o600)
  end

  it "restricts tmp_path it creates, and not the application directories above it" do
    Profiler::Storage::FileStore.new

    expect(mode(tmp_path)).to eq(0o700)
    expect(mode(File.join(@root, "app", "tmp"))).to eq(0o755)
  end

  it "leaves the mode of a directory that already exists as it is" do
    FileUtils.mkdir_p(tmp_path)
    File.chmod(0o755, tmp_path)

    Profiler::Storage::FileStore.new
    expect(mode(tmp_path)).to eq(0o755)
  end

  it "creates the blob directories 0700 and the blobs 0600" do
    token = SecureRandom.hex(16)
    blobs = Profiler::Storage::BlobStore.new(File.join(@root, "blobs"))
    blobs.write(token, "http_response_bodies", [{ "response_body" => "secret" }])

    expect(mode(File.join(@root, "blobs"))).to eq(0o700)
    expect(mode(File.join(@root, "blobs", token))).to eq(0o700)
    expect(mode(File.join(@root, "blobs", token, "http_response_bodies.json"))).to eq(0o600)
  end

  it "creates the SQLite database and its -wal and -shm files 0600" do
    db = File.join(@root, "db", "profiler.db")
    store = Profiler::Storage::SqliteStore.new(database: db, blob_path: File.join(@root, "blobs"))
    profile = build_profile
    store.save(profile.token, profile)

    expect(mode(File.join(@root, "db"))).to eq(0o700)
    expect(mode(db)).to eq(0o600)
    %w[-wal -shm].each do |suffix|
      expect(File.exist?("#{db}#{suffix}")).to be(true), "#{suffix} missing"
      expect(mode("#{db}#{suffix}")).to eq(0o600)
    end
  end

  it "creates the env overrides file and its lock 0600" do
    store = Profiler::EnvOverrideStore.new
    observed = nil
    allow(File).to receive(:rename).and_wrap_original do |original, from, to|
      observed = mode(from)
      original.call(from, to)
    end
    store.set("PROFILER_SPEC_PERMISSIONS", "1")

    expect(mode(tmp_path)).to eq(0o700)
    expect(mode(tmp_path.join("env_overrides.json"))).to eq(0o600)
    expect(mode(tmp_path.join("env_overrides.json.lock"))).to eq(0o600)
    expect(observed).to eq(0o600)
  end

  it "creates the MCP body cache 0700 and its files 0600" do
    token = SecureRandom.hex(16)
    path = Profiler::MCP::FileCache.save(token, "response_body", "secret")

    expect(path).not_to be_nil
    expect(mode(File.dirname(File.dirname(path)))).to eq(0o700)
    expect(mode(File.dirname(path))).to eq(0o700)
    expect(mode(path)).to eq(0o600)
  end

  context "with config.restrict_storage_permissions = false" do
    before { Profiler.configuration.restrict_storage_permissions = false }

    it "lets the umask decide, as before" do
      store = Profiler::Storage::FileStore.new(path: File.join(@root, "profiles"))
      profile = build_profile
      store.save(profile.token, profile)

      expect(mode(File.join(@root, "profiles"))).to eq(0o755)
      expect(mode(File.join(@root, "profiles", "#{profile.token}.json"))).to eq(0o644)
    end
  end
end
