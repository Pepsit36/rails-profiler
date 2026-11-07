# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "profiler/storage/file_store"
require "profiler/storage/memory_store"

RSpec.describe Profiler::Live::EventStream do
  let(:storage) { Profiler::Storage::MemoryStore.new }

  def save(profile)
    storage.save(profile.token, profile)
    profile
  end

  def page
    save(Profiler::Models::Profile.new.tap { |p| p.finish(200) })
  end

  def job_of(parent, status: "running")
    job = Profiler::Models::Profile.new
    job.profile_type = "job"
    job.parent_token = parent.token
    job.add_collector_data("job", { "status" => status, "job_id" => SecureRandom.uuid })
    job.finish(200)
    save(job)
  end

  def stream(tokens, cursors: {}, lifetime: 0.3)
    described_class.new(storage: storage, tokens: tokens, cursors: cursors, lifetime: lifetime, tick: 0.02)
  end

  def frames(body, max: 20)
    list = []
    body.each do |frame|
      list << frame
      break if list.size >= max
    end
    list
  end

  def updates(list)
    list.grep(/\Aevent: update/).map { |f| JSON.parse(f[/data: (.*)\n/, 1]) }
  end

  before { Profiler::Live::Streams.reset! }

  it "announces a profile it holds no cursor for, once, and ends with an end event" do
    profile = page
    list = frames(stream([profile.token]))

    expect(list.first).to start_with("retry:")
    expect(updates(list).map { |u| u["token"] }).to eq([profile.token])
    expect(list.last).to eq("event: end\ndata: {}\n\n")
  end

  it "announces nothing when the cursor is the current one" do
    profile = page
    cursor = Profiler::Live::Signature.of(storage, profile.token)

    expect(updates(frames(stream([profile.token], cursors: { profile.token => cursor })))).to eq([])
  end

  it "announces a job that starts, then ends, under the profile it follows" do
    profile = page
    cursor = Profiler::Live::Signature.of(storage, profile.token)
    body = stream([profile.token], cursors: { profile.token => cursor }, lifetime: 1.5)
    seen = []
    worker = Thread.new do
      sleep 0.15
      job = job_of(profile)
      sleep 0.3
      job.add_collector_data("job", { "status" => "completed", "job_id" => "x" })
      save(job)
    end
    body.each do |frame|
      seen << frame
      break if updates(seen).size >= 2
    end
    worker.join

    expect(updates(seen).map { |u| u["token"] }).to eq([profile.token, profile.token])
    expect(updates(seen).map { |u| u["cursor"] }.uniq.size).to eq(2)
  end

  it "announces a profile that is gone" do
    list = frames(stream([SecureRandom.hex(16)], cursors: {}))

    expect(updates(list).first["cursor"]).to eq("gone")
  end

  it "gives its slot back when it ends, and once only when closed as well" do
    Profiler::Live::Streams.acquire(2)
    body = stream([page.token])
    frames(body)
    body.close

    expect(Profiler::Live::Streams.open_count).to eq(0)
  end

  it "gives its slot back when the client goes away" do
    Profiler::Live::Streams.acquire(2)
    body = stream([page.token])
    writer = proc { raise Errno::EPIPE }
    expect { body.each(&writer) }.not_to raise_error

    expect(Profiler::Live::Streams.open_count).to eq(0)
  end

  it "sees a save made by another process through the file index" do
    Dir.mktmpdir do |dir|
      mine = Profiler::Storage::FileStore.new(path: dir)
      theirs = Profiler::Storage::FileStore.new(path: dir)
      parent = Profiler::Models::Profile.new.tap { |p| p.finish(200) }
      mine.save(parent.token, parent)
      cursor = Profiler::Live::Signature.of(mine, parent.token)
      body = described_class.new(storage: mine, tokens: [parent.token], cursors: { parent.token => cursor },
                                 lifetime: 2, tick: 0.02)
      worker = Thread.new do
        sleep 0.2
        job = Profiler::Models::Profile.new
        job.profile_type = "job"
        job.parent_token = parent.token
        job.add_collector_data("job", { "status" => "running", "job_id" => "j1" })
        job.finish(200)
        theirs.save(job.token, job)
      end
      seen = []
      body.each do |frame|
        seen << frame
        break if updates(seen).any?
      end
      worker.join

      expect(updates(seen).map { |u| u["token"] }).to eq([parent.token])
    end
  end
end
