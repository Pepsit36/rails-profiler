# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "profiler/storage/file_store"

# PERF-02 for the file store: the work done by a save does not grow with the number of profiles
# on disk, several processes share one directory, and the profiles written before the index
# existed (or with the index lost or damaged) are still found.
RSpec.describe Profiler::Storage::FileStore do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:path) { File.join(@dir, "profiles") }
  let(:base_time) { Time.at(Time.now.to_i - 3600) }

  def profile_at(index, **attrs)
    build_profile(started_at: base_time + index, finished_at: base_time + index + 0.01, path: "/p#{index}", **attrs)
  end

  def profile_files
    Dir.children(path).grep(/\A\h{32}\.json\z/)
  end

  # Writes profiles the way 0.31.1 did: one <token>.json file each, nothing else.
  def write_legacy_profiles(count, **attrs)
    FileUtils.mkdir_p(path)
    (0...count).map do |i|
      profile = profile_at(i, **attrs)
      File.write(File.join(path, "#{profile.token}.json"), profile.to_json)
      profile
    end
  end

  # The file system calls a save makes per profile already stored: stat, size and mtime of a file,
  # and the directory listings.
  def file_system_calls_for(saves, store)
    calls = 0
    %i[size mtime stat lstat exist?].each do |name|
      allow(File).to receive(name).and_wrap_original { |original, *args| calls += 1; original.call(*args) }
    end
    %i[glob children entries each_child].each do |name|
      allow(Dir).to receive(name).and_wrap_original { |original, *args, &block| calls += 1; original.call(*args, &block) }
    end
    saves.each { |p| store.save(p.token, p) }
    calls
  ensure
    RSpec::Mocks.space.proxy_for(File).reset
    RSpec::Mocks.space.proxy_for(Dir).reset
  end

  describe "the cost of a save" do
    it "does not grow with the number of profiles already stored" do
      calls = [50, 400].map do |stored|
        dir = File.join(@dir, "store-#{stored}")
        store = described_class.new(path: dir, max_profiles: nil)
        (0...stored).each { |i| profile_at(i).tap { |p| store.save(p.token, p) } }
        file_system_calls_for((0...20).map { |i| profile_at(10_000 + i) }, store)
      end

      expect(calls.last).to be <= calls.first + 5
      expect(calls.last).to be < 400
    end
  end

  describe "several processes writing to the same directory", skip: !Process.respond_to?(:fork) && "needs fork" do
    it "keeps the count cap and sees every other process's profiles" do
      described_class.new(path: path, max_profiles: 30) # creates the directory once
      pids = 3.times.map do |worker|
        fork do
          store = described_class.new(path: path, max_profiles: 30)
          40.times { |i| profile_at(worker * 100 + i).tap { |p| store.save(p.token, p) } }
          exit!(0)
        end
      end
      statuses = pids.map { |pid| Process.wait2(pid).last }

      expect(statuses).to all(be_success)
      expect(profile_files.size).to be <= 30
      fresh = described_class.new(path: path, max_profiles: 30)
      expect(fresh.list(limit: 1000).map(&:token)).to match_array(profile_files.map { |f| f.delete_suffix(".json") })
    end

    # Three writers past the cap, so that they compact again and again, and a reader listing and
    # reading children meanwhile: no live profile missing from the index, no line consumed half
    # written (the reader would have found the index damaged and rebuilt it).
    it "loses no live profile and reads no partial line while the writers compact" do
      parent = profile_at(100_000)
      seed = described_class.new(path: path, max_profiles: 50)
      seed.save(parent.token, parent)
      done = File.join(@dir, "writers-done")
      damaged = File.join(@dir, "damaged")
      track_damage = Module.new do
        define_method(:compact) do |&block|
          File.write(damaged, "x", mode: "a") if @damaged
          super(&block)
        end
      end

      reader = fork do
        store = described_class.new(path: path, max_profiles: 50)
        store.singleton_class.prepend(track_damage)
        until File.exist?(done)
          store.list(limit: 100, summary: true)
          store.find_by_parent(parent.token)
        end
        exit!(0)
      end
      writers = 3.times.map do |worker|
        fork do
          store = described_class.new(path: path, max_profiles: 50)
          store.singleton_class.prepend(track_damage)
          80.times do |i|
            attrs = i.even? ? { parent_token: parent.token } : {}
            profile_at(worker * 1000 + i, **attrs).tap { |p| store.save(p.token, p) }
          end
          exit!(0)
        end
      end
      writer_statuses = writers.map { |pid| Process.wait2(pid).last }
      File.write(done, "")
      reader_status = Process.wait2(reader).last

      expect(writer_statuses + [reader_status]).to all(be_success)
      expect(File.exist?(damaged)).to be false
      on_disk = profile_files.map { |f| f.delete_suffix(".json") }
      expect(on_disk.size).to be <= 50
      indexed = described_class.new(path: path, max_profiles: 50).list(limit: 1000, summary: true).map(&:token)
      expect(indexed).to match_array(on_disk)
      children_on_disk = on_disk.select { |t| JSON.parse(File.read(File.join(path, "#{t}.json")))["parent_token"] == parent.token }
      expect(described_class.new(path: path, max_profiles: 50).find_by_parent(parent.token).map(&:token))
        .to match_array(children_on_disk)
    end

    it "lists a profile saved by another process" do
      reader = described_class.new(path: path, max_profiles: 100)
      expect(reader.list(limit: 10)).to be_empty

      pid = fork do
        writer = described_class.new(path: path, max_profiles: 100)
        profile_at(1, token: "a" * 32).tap { |p| writer.save(p.token, p) }
        exit!(0)
      end
      Process.wait(pid)

      expect(reader.list(limit: 10).map(&:token)).to eq(["a" * 32])
    end
  end

  describe "compatibility with the profiles written by 0.31.1" do
    it "finds them without any migration, and indexes their parents" do
      parent = write_legacy_profiles(1).first
      children = write_legacy_profiles(3, parent_token: parent.token)

      store = described_class.new(path: path, max_profiles: 100)

      expect(store.list(limit: 10).size).to eq(4)
      expect(store.find_by_parent(parent.token).map(&:token)).to match_array(children.map(&:token))
    end

    it "rebuilds an index that was deleted" do
      store = described_class.new(path: path, max_profiles: 100)
      saved = (0...3).map { |i| profile_at(i).tap { |p| store.save(p.token, p) } }
      Dir.children(path).reject { |f| f.match?(/\A\h{32}\.json\z/) }.each { |f| File.delete(File.join(path, f)) }

      expect(described_class.new(path: path, max_profiles: 100).list(limit: 10).map(&:token))
        .to match_array(saved.map(&:token))
    end

    it "rebuilds an index that was damaged" do
      store = described_class.new(path: path, max_profiles: 100)
      saved = (0...3).map { |i| profile_at(i).tap { |p| store.save(p.token, p) } }
      Dir.children(path).reject { |f| f.match?(/\A\h{32}\.json\z/) }.each do |f|
        File.write(File.join(path, f), "\x00garbage{{{\n") if File.file?(File.join(path, f))
      end

      expect(described_class.new(path: path, max_profiles: 100).list(limit: 10).map(&:token))
        .to match_array(saved.map(&:token))
    end
  end

  describe "the index file" do
    let(:index) { File.join(path, described_class::INDEX_FILE) }

    it "lives in the profiles directory, 0600, and is not taken for a profile" do
      store = described_class.new(path: path, max_profiles: 100)
      profile = profile_at(1).tap { |p| store.save(p.token, p) }

      expect(File.stat(index).mode & 0o777).to eq(0o600)
      expect(File.stat(File.join(path, described_class::LOCK_FILE)).mode & 0o777).to eq(0o600)
      expect(store.list(limit: 10).map(&:token)).to eq([profile.token])
    end

    it "is not followed when it is a symbolic link, while the modes are restricted", skip: !File::NOFOLLOW && "no O_NOFOLLOW" do
      store = described_class.new(path: path, max_profiles: 100)
      profile_at(1).tap { |p| store.save(p.token, p) }
      victim = File.join(@dir, "victim")
      File.write(victim, "untouched")
      File.delete(index)
      File.symlink(victim, index)

      expect { profile_at(2).tap { |p| described_class.new(path: path).save(p.token, p) } }.to raise_error(Errno::ELOOP)
      expect(File.read(victim)).to eq("untouched")
    end

    it "skips a line whose token is not one the gem issues, and never makes a path of it" do
      store = described_class.new(path: path, max_profiles: 100)
      profile = profile_at(1).tap { |p| store.save(p.token, p) }
      File.write(File.join(@dir, "outside.json"), profile.to_json)
      File.write(index, "#{JSON.generate("op" => "put", "token" => "../outside", "at" => 1.0, "bytes" => 1)}\n", mode: "a")

      fresh = described_class.new(path: path, max_profiles: 100)
      expect(fresh.list(limit: 10).map(&:token)).to eq([profile.token])
      fresh.clear
      expect(File.exist?(File.join(@dir, "outside.json"))).to be true
    end
  end

  describe "files changed behind the store's back" do
    it "skips a profile whose file was removed" do
      store = described_class.new(path: path, max_profiles: 100)
      kept = profile_at(1).tap { |p| store.save(p.token, p) }
      removed = profile_at(2, parent_token: kept.token).tap { |p| store.save(p.token, p) }
      File.delete(File.join(path, "#{removed.token}.json"))

      expect(store.list(limit: 10).map(&:token)).to eq([kept.token])
      expect(store.find_by_parent(kept.token)).to be_empty
    end

    it "purges a temporary file left by a killed writer during the cleanup" do
      store = described_class.new(path: path, max_profiles: 3)
      orphan = File.join(path, ".#{"b" * 32}.json.4242.deadbeef.tmp")
      File.write(orphan, "{")
      old = Time.now - 3600
      File.utime(old, old, orphan)

      (0...6).each { |i| profile_at(i).tap { |p| store.save(p.token, p) } }

      expect(File.exist?(orphan)).to be false
    end
  end
end
