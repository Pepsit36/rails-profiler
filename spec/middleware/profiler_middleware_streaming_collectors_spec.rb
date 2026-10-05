# frozen_string_literal: true

require "spec_helper"
require "rack"
require "active_support/notifications"
require "profiler/collectors/database_collector"
require "profiler/collectors/view_collector"
require "profiler/collectors/flamegraph_collector"
require "profiler/collectors/dump_collector"

# What a streamed response records while it streams: the notifications the collectors listen
# to stay subscribed until the server closes the body, while what they hold in the request's
# thread is given back when the application returns.
RSpec.describe Profiler::Middleware::ProfilerMiddleware, "collectors of a streamed response" do
  # A body that runs queries and renders while it is iterated, as `render stream: true` does.
  class QueryingStreamBody
    def initialize(chunks = %w[a b])
      @chunks = chunks
    end

    def each
      @chunks.each do |chunk|
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT '#{chunk}'", name: "Load", binds: [])
        ActiveSupport::Notifications.instrument("render_template.action_view", identifier: "/app/views/#{chunk}.html.erb")
        yield chunk
      end
    end

    def close; end
  end

  let(:env) { Rack::MockRequest.env_for("http://localhost/stream", "REMOTE_ADDR" => "127.0.0.1") }

  def sql_listeners
    ActiveSupport::Notifications.notifier.listeners_for("sql.active_record").size
  end

  # The collectors of a request listen through its notification scope; the process holds one
  # subscriber per event for all of them.
  def sql_handlers
    Profiler::Collectors::ScopedNotifications.current&.handlers_for("sql.active_record")&.size.to_i
  end

  def serve(body)
    parts = []
    begin
      body.each { |part| parts << part }
    ensure
      body.close
    end
    parts.join
  end

  def middleware(body)
    described_class.new(->(_env) { [200, Rack::Headers["content-type" => "text/plain"], body] })
  end

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = [
        Profiler::Collectors::DatabaseCollector,
        Profiler::Collectors::ViewCollector,
        Profiler::Collectors::FlameGraphCollector,
        Profiler::Collectors::DumpCollector
      ]
      c.skip_paths = []
      c.track_memory = true
      c.track_http = false
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  after { Profiler::Middleware::StreamedProfile.release_all_pending if defined?(Profiler::Middleware::StreamedProfile) }

  it "records the queries and the views of the stream" do
    _status, headers, body = middleware(QueryingStreamBody.new).call(env)
    serve(body)

    profile = Profiler.storage.load(headers["X-Profiler-Token"])
    sql = profile.collector_data("database")["queries"].map { |q| q["sql"] }
    expect(sql).to include("SELECT 'a'", "SELECT 'b'")
    expect(profile.collector_data("view")["total_views"]).to eq(2)
  end

  it "counts the objects allocated while streaming" do
    allocating = Class.new do
      def each
        20_000.times { Object.new }
        yield "done"
      end

      def close; end
    end
    _status, headers, body = middleware(allocating.new).call(env)
    serve(body)

    expect(Profiler.storage.load(headers["X-Profiler-Token"]).allocated_objects).to be >= 20_000
  end

  it "gives the request's thread back its slots when the application returns, and the notifications when the body is closed" do
    before_listeners = sql_listeners
    _status, _headers, body = middleware(QueryingStreamBody.new).call(env)

    expect(Thread.current[:profiler_flamegraph_collector]).to be_nil
    expect(Thread.current[:profiler_dumps]).to be_nil
    expect(sql_handlers).to eq(2) # database and flame graph
    expect(sql_listeners).to eq(before_listeners + 1)

    serve(body)
    expect(sql_handlers).to eq(0)
    expect(sql_listeners).to eq(before_listeners)
  end

  it "lets the thread that iterates the body carry the profile's token, for a filter by request" do
    seen = nil
    probe = Class.new do
      define_method(:each) do |&block|
        seen = Profiler::CurrentContext.token
        block.call("x")
      end
      define_method(:close) {}
    end
    _status, headers, body = middleware(probe.new).call(env)
    serve(body)

    expect(seen).to eq(headers["X-Profiler-Token"])
    expect(Profiler::CurrentContext.token).to be_nil
  end

  # A server that never closes the body breaks the Rack contract: the subscriptions it would
  # leave are taken back at the next request the same thread serves, and after a while from
  # any other thread.
  describe "a body never closed" do
    it "is finished and released at the next request on the same thread" do
      before_listeners = sql_listeners
      _status, first_headers, _body = middleware(QueryingStreamBody.new).call(env)

      middleware(["second"]).call(env)

      expect(sql_listeners).to eq(before_listeners)
      expect(Profiler.storage.load(first_headers["X-Profiler-Token"])).not_to be_nil
    end

    it "is released, from another thread, once older than the limit" do
      stub_const("Profiler::Middleware::StreamedProfile::MAX_SUBSCRIBED_SECONDS", 0)
      before_listeners = sql_listeners
      Thread.new { middleware(QueryingStreamBody.new).call(env) }.join

      _status, _headers, body = middleware(["next"]).call(env)
      body.close if body.respond_to?(:close)

      expect(sql_listeners).to eq(before_listeners)
    end
  end
end
