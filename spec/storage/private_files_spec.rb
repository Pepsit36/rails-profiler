# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "profiler/storage/sqlite_store"

# Files placed in advance under tmp_path: the profiler neither follows a symbolic link where it
# expects its own file, nor stays silent about a tmp_path that other users can write to.
RSpec.describe Profiler::Storage::PrivateFiles do
  around do |example|
    previous = File.umask(0o022)
    Dir.mktmpdir do |root|
      @root = root
      @tmp_path = Pathname.new(root).join("profiler")
      Profiler.configure { |config| config.tmp_path = @tmp_path }
      described_class.reset_warnings!
      example.run
    end
  ensure
    File.umask(previous)
    Profiler.instance_variable_set(:@env_override_store, nil)
  end

  def mode(path)
    File.stat(path).mode & 0o777
  end

  let(:target) { File.join(@root, "target") }

  before do
    File.write(target, "keep")
    File.chmod(0o644, target)
  end

  describe "a symbolic link in place of the env overrides lock" do
    before do
      FileUtils.mkdir_p(@tmp_path)
      File.chmod(0o700, @tmp_path)
      File.symlink(target, @tmp_path.join("env_overrides.json.lock"))
    end

    it "is not followed" do
      expect { Profiler::EnvOverrideStore.new.set("PROFILER_SPEC_LINK", "1") }
        .to raise_error(Profiler::EnvOverrideStore::Error)
      expect(File.read(target)).to eq("keep")
      expect(mode(target)).to eq(0o644)
    ensure
      ENV.delete("PROFILER_SPEC_LINK")
    end
  end

  describe "a symbolic link in place of the SQLite database" do
    %w[profiler.db profiler.db-wal profiler.db-shm].each do |name|
      it "is refused for #{name}, and its target left alone" do
        FileUtils.mkdir_p(@tmp_path)
        File.chmod(0o700, @tmp_path)
        File.write(@tmp_path.join("profiler.db"), "") unless name == "profiler.db"
        File.symlink(target, @tmp_path.join(name))

        expect { Profiler::Storage::SqliteStore.new }.to raise_error(Profiler::Error, /symbolic link/)
        expect(mode(target)).to eq(0o644)
        expect(File.read(target)).to eq("keep")
      end
    end
  end

  context "with restrict_storage_permissions = false" do
    before { Profiler.configuration.restrict_storage_permissions = false }

    it "follows a symbolic link in place of the SQLite database, as before" do
      FileUtils.mkdir_p(@tmp_path)
      elsewhere = File.join(@root, "elsewhere.db")
      File.symlink(elsewhere, @tmp_path.join("profiler.db"))

      store = Profiler::Storage::SqliteStore.new
      profile = build_profile
      store.save(profile.token, profile)

      expect(store.load(profile.token).token).to eq(profile.token)
      expect(File.size(elsewhere)).to be > 0
      expect(File.symlink?(@tmp_path.join("profiler.db"))).to be true
    end

    it "follows a symbolic link in place of the env overrides lock, as before" do
      FileUtils.mkdir_p(@tmp_path)
      File.symlink(File.join(@root, "elsewhere.lock"), @tmp_path.join("env_overrides.json.lock"))

      Profiler::EnvOverrideStore.new.set("PROFILER_SPEC_LINK", "1")
      expect(Profiler::EnvOverrideStore.new.all_overrides).to have_key("PROFILER_SPEC_LINK")
    ensure
      ENV.delete("PROFILER_SPEC_LINK")
    end
  end

  describe "an existing tmp_path that other users can write to" do
    before do
      FileUtils.mkdir_p(@tmp_path)
      File.chmod(0o777, @tmp_path)
    end

    it "is warned about once" do
      expect(capture_profiler_log { 2.times { Profiler::Storage::FileStore.new } })
        .to match(/\A[^\n]*\[Profiler\].*tmp_path.*#{Regexp.escape(@tmp_path.to_s)}.*writable[^\n]*\n\z/)
      expect(capture_profiler_log { Profiler::Storage::FileStore.new }).to be_empty
    end

    it "is not warned about with restrict_storage_permissions = false" do
      Profiler.configuration.restrict_storage_permissions = false
      expect(capture_profiler_log { Profiler::Storage::FileStore.new }).to be_empty
    end
  end

  it "says nothing about a tmp_path of its own" do
    expect(capture_profiler_log { Profiler::Storage::FileStore.new }).to be_empty
  end
end
