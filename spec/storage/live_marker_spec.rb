# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "profiler/storage/file_store"
require "profiler/storage/memory_store"

RSpec.describe "Storage#live_marker" do
  def profile
    Profiler::Models::Profile.new.tap { |p| p.finish(200) }
  end

  it "moves when the memory store saves" do
    store = Profiler::Storage::MemoryStore.new
    before = store.live_marker
    store.save(*[profile].flat_map { |p| [p.token, p] })

    expect(store.live_marker).not_to eq(before)
  end

  it "moves for the file store when another instance sharing the directory saves" do
    Dir.mktmpdir do |dir|
      mine = Profiler::Storage::FileStore.new(path: dir)
      theirs = Profiler::Storage::FileStore.new(path: dir)
      before = mine.live_marker
      other = profile
      theirs.save(other.token, other)

      expect(mine.live_marker).not_to eq(before)
    end
  end

  it "does not move while nothing is saved" do
    Dir.mktmpdir do |dir|
      store = Profiler::Storage::FileStore.new(path: dir)

      expect(store.live_marker).to eq(store.live_marker)
    end
  end
end
