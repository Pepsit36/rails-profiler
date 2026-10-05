# frozen_string_literal: true

require "spec_helper"

# Profiler.storage is created on first use: the first requests of a threaded server reach it at
# the same time, and each must get the one store, or the profiles saved in the others are lost.
RSpec.describe "Profiler.storage created by concurrent requests" do
  before do
    Profiler.configure { |config| config.storage = :memory }
    Profiler.instance_variable_set(:@storage, nil)
    # A backend that takes a moment to build, as a file or SQLite store does on its first use.
    allow(Profiler::Storage::MemoryStore).to receive(:new).and_wrap_original do |original, *args|
      sleep 0.02
      original.call(*args)
    end
  end

  after { Profiler.instance_variable_set(:@storage, nil) }

  it "builds one store, which keeps every profile saved" do
    gate = Queue.new
    profiles = Array.new(16) { build_profile }
    threads = profiles.map do |profile|
      Thread.new do
        gate.pop
        Profiler.storage.save(profile.token, profile)
        Profiler.storage
      end
    end
    16.times { gate << :go }
    stores = threads.map(&:value)

    expect(stores.uniq.size).to eq(1)
    expect(profiles.count { |p| Profiler.storage.load(p.token) }).to eq(16)
    expect(Profiler::Storage::MemoryStore).to have_received(:new).once
  end
end
