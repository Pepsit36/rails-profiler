# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "profiler/storage/sqlite_store"

RSpec.describe "Storage#find_by_replay_of" do
  let(:tmpdir) { Dir.mktmpdir("profiler_replay_of") }

  after { FileUtils.rm_rf(tmpdir) }

  stores = {
    memory: ->(_dir) { Profiler::Storage::MemoryStore.new },
    file: ->(dir) { Profiler::Storage::FileStore.new(path: dir) },
    sqlite: lambda { |dir|
      Profiler::Storage::SqliteStore.new(database: File.join(dir, "p.sqlite3"), blob_path: File.join(dir, "blobs"))
    }
  }

  stores.each do |name, factory|
    context "with the #{name} store" do
      let(:store) { factory.call(tmpdir) }

      it "finds the replays of a profile, oldest first, and keeps replay_of on load" do
        source = build_profile(started_at: Time.now - 10)
        first = build_profile(started_at: Time.now - 5).tap { |p| p.replay_of = source.token }
        second = build_profile(started_at: Time.now - 1).tap { |p| p.replay_of = source.token }
        other = build_profile.tap { |p| p.replay_of = SecureRandom.hex(16) }
        [source, second, first, other].each { |p| store.save(p.token, p) }

        expect(store.find_by_replay_of(source.token).map(&:token)).to eq([first.token, second.token])
        expect(store.load(first.token).replay_of).to eq(source.token)
        expect(store.find_by_replay_of(first.token)).to be_empty
        expect(store.find_by_replay_of("../bad")).to eq([])
      end

      it "does not turn replays into children of the original" do
        source = build_profile
        replay = build_profile.tap { |p| p.replay_of = source.token }
        [source, replay].each { |p| store.save(p.token, p) }

        expect(store.find_by_parent(source.token)).to be_empty
      end
    end
  end
end
