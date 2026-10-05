# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"
require "profiler/test_runner/run_store"

# The endpoints the profiler's pages ask again and again: each answers what there is now and
# ends, the page comes back later (see server_threads_spec.rb for what that leaves free).
RSpec.describe "Profiler update endpoints", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:storage) { Profiler::Storage::MemoryStore.new }

  def app
    Rails.application
  end

  def json
    JSON.parse(last_response.body)
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, storage)
    Profiler::SSE::EventBus.instance.reset!
  end

  describe "GET /_profiler/api/events/:token" do
    it "answers version 0 and no update for a profile never saved" do
      get "/_profiler/api/events/5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", {}, local

      expect(last_response.status).to eq(200)
      expect(json).to eq("cursor" => 0, "updated" => false)
    end

    it "tells a toolbar holding an older version that the profile was saved again" do
      storage.save("5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", build_profile(token: "5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d"))
      seen = Profiler::SSE.current.version("5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d")
      storage.save("5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", build_profile(token: "5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d"))

      get "/_profiler/api/events/5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", { since: seen }, local

      expect(json["updated"]).to be(true)
      expect(json["cursor"]).to be > seen
    end

    it "tells a toolbar holding the current version that nothing changed" do
      storage.save("5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", build_profile(token: "5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d"))
      seen = Profiler::SSE.current.version("5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d")

      get "/_profiler/api/events/5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", { since: seen }, local

      expect(json).to eq("cursor" => seen, "updated" => false)
    end

    it "keeps the version a toolbar holds when this process knows an older one" do
      # Without Redis, each worker only knows its own saves: the toolbar keeps the newest.
      get "/_profiler/api/events/5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", { since: 42 }, local

      expect(json).to eq("cursor" => 42, "updated" => false)
    end

    # A client that sends anything else than a version (NaN, nothing) holds no version: telling
    # it "updated" would reload its toolbar on every check, for nothing.
    ["NaN", "", "abc", "12abc", "-1", nil].each do |since|
      it "gives the current version without an update for since=#{since.inspect}" do
        storage.save("5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", build_profile(token: "5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d"))
        params = since.nil? ? {} : { since: since }

        get "/_profiler/api/events/5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", params, local

        expect(last_response.status).to eq(200)
        expect(json).to eq("cursor" => Profiler::SSE.current.version("5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d"), "updated" => false)
      end
    end

    it "only tells the profile whose token was saved" do
      storage.save("0e1d2c3b4a5f6e7d8c9b0a1f2e3d4c5b", build_profile(token: "0e1d2c3b4a5f6e7d8c9b0a1f2e3d4c5b"))

      get "/_profiler/api/events/5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", { since: 0 }, local

      expect(json["updated"]).to be(false)
    end
  end

  describe "GET /_profiler/api/toolbar/:token" do
    it "gives the version the toolbar data reflects" do
      storage.save("5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", build_profile(token: "5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d"))

      get "/_profiler/api/toolbar/5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", {}, local

      expect(last_response.status).to eq(200)
      expect(json["events_cursor"]).to eq(Profiler::SSE.current.version("5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d"))
      expect(json["events_cursor"]).to be > 0
    end
  end

  describe "GET /_profiler/api/test_runner/runs/:id/stream" do
    let(:run_store) { Profiler::TestRunner::RunStore.new }
    let(:run) { run_store.create(files: [], framework: "rspec") }

    before { Profiler::TestRunner.instance_variable_set(:@run_store, run_store) }
    after { Profiler::TestRunner.instance_variable_set(:@run_store, nil) }

    def events
      last_response.body.split("\n\n").map do |block|
        block.lines.to_h { |line| line.chomp.split(": ", 2) }
      end
    end

    it "answers 404 for an unknown run" do
      get "/_profiler/api/test_runner/runs/nope/stream", {}, local

      expect(last_response.status).to eq(404)
    end

    it "answers at once with the output there is, each piece numbered by the position after it" do
      run_store.update(run.id, status: "running")
      run_store.append_output(run.id, "one\n")
      run_store.append_output(run.id, "two\n")

      get "/_profiler/api/test_runner/runs/#{run.id}/stream", {}, local

      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include("text/event-stream")
      expect(events.first).to eq("retry" => "1000")
      outputs = events.select { |event| event["event"] == "output" }
      expect(outputs.map { |event| event["id"] }).to eq(%w[1 2])
      expect(outputs.map { |event| JSON.parse(event["data"])["chunk"] }).to eq(["one\n", "two\n"])
      expect(events.map { |event| event["event"] }).not_to include("done")
    end

    it "sends only what came after the position in Last-Event-ID" do
      run_store.update(run.id, status: "running")
      run_store.append_output(run.id, "one\n")
      run_store.append_output(run.id, "two\n")

      get "/_profiler/api/test_runner/runs/#{run.id}/stream", {}, local.merge("HTTP_LAST_EVENT_ID" => "1")

      outputs = events.select { |event| event["event"] == "output" }
      expect(outputs.map { |event| JSON.parse(event["data"])["chunk"] }).to eq(["two\n"])
      expect(outputs.map { |event| event["id"] }).to eq(%w[2])
    end

    it "answers with only the retry delay while the run prints nothing" do
      run_store.update(run.id, status: "running")

      get "/_profiler/api/test_runner/runs/#{run.id}/stream", {}, local.merge("HTTP_LAST_EVENT_ID" => "0")

      expect(events).to eq([{ "retry" => "1000" }])
    end

    it "streams a character cut between two pieces of output whole, and the run's JSON too" do
      run_store.update(run.id, status: "running")
      run_store.append_output(run.id, "caf\xC3".b)
      run_store.append_output(run.id, "\xA9\n".b)

      get "/_profiler/api/test_runner/runs/#{run.id}/stream", {}, local

      expect(last_response.status).to eq(200)
      chunks = events.select { |event| event["event"] == "output" }.map { |event| JSON.parse(event["data"])["chunk"] }
      expect(chunks.join).to eq("caf\u00e9\n")

      get "/_profiler/api/test_runner/runs/#{run.id}", {}, local

      expect(last_response.status).to eq(200)
      expect(json["output"]).to eq("caf\u00e9\n")
    end

    it "ends with done once the run is over" do
      run_store.append_output(run.id, "1 example, 0 failures\n")
      run_store.finish_output(run.id)
      run_store.update(run.id, status: "passed", exit_code: 0)

      get "/_profiler/api/test_runner/runs/#{run.id}/stream", {}, local

      done = events.find { |event| event["event"] == "done" }
      expect(JSON.parse(done["data"])).to eq("status" => "passed", "exit_code" => 0)
    end
  end
end
