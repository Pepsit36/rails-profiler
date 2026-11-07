# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"

RSpec.describe "GET /_profiler/api/stream", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:storage) { Profiler::Storage::MemoryStore.new }
  let(:profile) { Profiler::Models::Profile.new.tap { |p| p.finish(200) } }

  def app
    Rails.application
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.live_events = true
      config.live_events_max_streams = 2
    end
    Profiler.instance_variable_set(:@storage, storage)
    storage.save(profile.token, profile)
    Profiler::Live::Streams.reset!
    stub_const("Profiler::Live::EventStream::LIFETIME", 0.2)
    stub_const("Profiler::Live::EventStream::TICK", 0.02)
  end

  after { Profiler::Live::Streams.reset! }

  def stream(params = { tokens: profile.token }, env = {})
    get "/_profiler/api/stream", params, local.merge(env)
  end

  it "streams the update of a profile it was asked about" do
    stream

    expect(last_response.status).to eq(200)
    expect(last_response.headers["Content-Type"]).to start_with("text/event-stream")
    expect(last_response.headers["Cache-Control"]).to include("no-cache")
    expect(last_response.body).to include("event: update").and include(profile.token).and include("event: end")
    expect(Profiler::Live::Streams.open_count).to eq(0)
  end

  it "answers 503 with Retry-After when live events are off" do
    Profiler.configure { |config| config.live_events = false }
    stream

    expect(last_response.status).to eq(503)
    expect(last_response.headers["Retry-After"]).to eq("30")
  end

  it "answers 400 without a valid token" do
    stream({ tokens: "not-a-token" })

    expect(last_response.status).to eq(400)
  end

  it "answers 503 when the cap of open streams is reached" do
    2.times { Profiler::Live::Streams.acquire(2) }
    stream

    expect(last_response.status).to eq(503)
    expect(last_response.body).to include("too many open streams")
  end

  it "refuses a Puma that has too few threads to spare one" do
    config = Struct.new(:options).new({ max_threads: 2 })
    stream({ tokens: profile.token }, "puma.config" => config)

    expect(last_response.status).to eq(503)
    expect(last_response.body).to include("too few threads")
  end

  it "keeps threads for the application: the cap drops with Puma's thread count" do
    config = Struct.new(:options).new({ max_threads: 3 })
    Profiler::Live::Streams.acquire(1)
    stream({ tokens: profile.token }, "puma.config" => config)

    expect(last_response.status).to eq(503)
  end

  it "does not announce a profile whose cursor is the one it already holds" do
    cursor = Profiler::Live::Signature.of(storage, profile.token)
    stream({ tokens: profile.token, since: "#{profile.token}:#{cursor}" })

    expect(last_response.body).not_to include("event: update")
  end

  it "adds the live cursor to the toolbar answer, only while live events are on" do
    get "/_profiler/api/toolbar/#{profile.token}", {}, local
    expect(JSON.parse(last_response.body)["live_cursor"]).to eq(Profiler::Live::Signature.of(storage, profile.token))

    Profiler.configure { |config| config.live_events = false }
    get "/_profiler/api/toolbar/#{profile.token}", {}, local
    expect(JSON.parse(last_response.body)["live_cursor"]).to be_nil
  end
end
