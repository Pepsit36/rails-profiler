# frozen_string_literal: true

require "spec_helper"
require "rack"
require "active_support/notifications"
require "profiler/collectors/database_collector"
require "profiler/collectors/flamegraph_collector"
require "profiler/collectors/http_collector"
require "profiler/collectors/log_collector"

# Where a streamed response is iterated, and by whom: a fiber-based server runs several
# requests on one thread, and the server, not the profiler, closes the application's body.
RSpec.describe Profiler::Middleware::ProfilerMiddleware, "execution context of a streamed response" do
  # A stream whose chunks run a query each, and that records whether it was closed.
  class ContextStreamBody
    attr_reader :closed

    def initialize(chunks)
      @chunks = chunks
      @closed = 0
    end

    def each
      @chunks.each do |chunk|
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT '#{chunk}'", name: "Load", binds: [])
        yield chunk
      end
    end

    def close
      @closed += 1
    end
  end

  let(:env) { Rack::MockRequest.env_for("http://localhost/stream", "REMOTE_ADDR" => "127.0.0.1") }

  def middleware(body)
    described_class.new(->(_env) { [200, Rack::Headers["content-type" => "text/plain"], body] })
  end

  def serve(body)
    parts = []
    begin
      body.each { |part| parts << part }
    ensure
      body.close if body.respond_to?(:close)
    end
    parts.join
  end

  def queries(token)
    Profiler.storage.load(token).collector_data("database")["queries"].map { |q| q["sql"] }
  end

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = [
        Profiler::Collectors::DatabaseCollector,
        Profiler::Collectors::FlameGraphCollector,
        Profiler::Collectors::HttpCollector,
        Profiler::Collectors::LogCollector,
        Profiler::Collectors::RequestCollector
      ]
      c.skip_paths = []
      c.track_memory = false
      c.track_http = false
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  after { Profiler::Middleware::StreamedProfile.release_all_pending }

  # Falcon: each request in its own fiber, all on one thread.
  describe "two requests in two fibers of one thread" do
    it "leaves the first stream alone while the second request runs" do
      first_body = ContextStreamBody.new(%w[a b c])
      first = Fiber.new do
        _status, headers, body = middleware(first_body).call(env)
        Fiber.yield headers["X-Profiler-Token"]
        serve(body)
      end
      token = first.resume

      second = Fiber.new { serve(middleware(["second"]).call(env)[2]) }
      second.resume

      expect(Profiler.storage.load(token)).to be_nil # still streaming
      first.resume
      expect(queries(token)).to eq(["SELECT 'a'", "SELECT 'b'", "SELECT 'c'"])
      expect(first_body.closed).to eq(1)
    end
  end

  describe "a stream whose profile was finished before the server closed it" do
    it "still closes the application's body, once, when the server does" do
      inner = ContextStreamBody.new(%w[a])
      _status, headers, body = middleware(inner).call(env)

      # The same fiber starts another request: the first stream is taken for abandoned.
      middleware(["next"]).call(env)
      expect(Profiler.storage.load(headers["X-Profiler-Token"])).not_to be_nil
      expect(inner.closed).to eq(0)

      body.close
      body.close
      expect(inner.closed).to eq(1)
    end
  end

  # What the server's fiber does while it iterates the body is the stream's: its logs, its
  # outbound HTTP calls, its measures. Lent for the iteration, then given back.
  describe "the collectors' thread-local slots while the body is iterated" do
    let(:streaming) do
      Class.new do
        attr_reader :http_collector

        def each
          Profiler::Collectors::LogCollector::CaptureLogger.new.add(1, "streamed line")
          Profiler.measure("streamed.measure") { :ok }
          @http_collector = Thread.current[:profiler_http_collector]
          yield "x"
        end

        def close; end
      end
    end

    it "records the logs, the measures and the outbound HTTP collector of the stream" do
      Profiler.configure { |c| c.track_http = true }
      stream = streaming.new
      _status, headers, body = middleware(stream).call(env)
      serve(body)

      profile = Profiler.storage.load(headers["X-Profiler-Token"])
      logs = profile.collector_data("logs")["logs"].map { |l| l["message"] }
      events = profile.collector_data("flamegraph")["root_events"].map { |e| e["name"] }
      expect(logs).to include("streamed line")
      expect(events).to include("streamed.measure")
      expect(stream.http_collector).to be_a(Profiler::Collectors::HttpCollector)
    end

    it "gives the iterating fiber back what its slots held" do
      _status, _headers, body = middleware(streaming.new).call(env)
      other_logs = []
      Thread.current[:profiler_logs] = other_logs
      begin
        serve(body)
        expect(Thread.current[:profiler_logs]).to equal(other_logs)
        expect(Thread.current[:profiler_http_collector]).to be_nil
        expect(Thread.current[:profiler_flamegraph_collector]).to be_nil
        expect(other_logs).to be_empty
      ensure
        Thread.current[:profiler_logs] = nil
      end
    end
  end

  describe "collectors released before the body was closed" do
    it "says so in the profile" do
      stub_const("Profiler::Middleware::StreamedProfile::MAX_SUBSCRIBED_SECONDS", 0)
      body = nil
      token = nil
      Thread.new do
        _status, headers, body = middleware(ContextStreamBody.new(%w[a])).call(env)
        token = headers["X-Profiler-Token"]
      end.join

      middleware(["next"]).call(env)
      serve(body)

      profile = Profiler.storage.load(token)
      expect(profile.collectors_released_after_seconds).to eq(0)
      expect(profile.collector_data("request")).to include("collectors_released_after_seconds" => 0)
      expect(profile.to_h[:collectors_released_after_seconds]).to eq(0)
    end
  end
end
