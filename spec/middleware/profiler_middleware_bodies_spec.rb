# frozen_string_literal: true

require "spec_helper"
require "rack"
require "stringio"

# How the profiler hands the response body back to the server: a streamed body leaves as a
# stream, its first chunk as soon as the application yields it, and whatever the body does
# (to_path, close, an error part way) still reaches the server.
RSpec.describe Profiler::Middleware::ProfilerMiddleware, "response bodies" do
  # A body the application produces lazily: no to_ary, one chunk every `delay` seconds.
  class SlowStreamBody
    attr_reader :closed

    def initialize(chunks, delay)
      @chunks = chunks
      @delay = delay
      @closed = 0
    end

    def each
      @chunks.each do |chunk|
        sleep @delay
        yield chunk
      end
    end

    def close
      @closed += 1
    end
  end

  # What Rack::Files and send_file return: the server may send the file by its path.
  class FileLikeBody
    attr_reader :closed

    def initialize(path)
      @path = path
      @closed = 0
    end

    def to_path
      @path
    end

    def each
      yield File.binread(@path)
    end

    def close
      @closed += 1
    end
  end

  class FailingBody
    def each
      yield "first"
      raise IOError, "the file went away"
    end

    def close; end
  end

  # A collector that only records whether it is still subscribed.
  class SubscriptionProbe
    class << self
      attr_accessor :subscribed
    end

    def initialize(_profile); end

    def subscribe
      self.class.subscribed = true
    end

    def unsubscribe
      self.class.subscribed = false
    end
  end

  let(:env) { Rack::MockRequest.env_for("http://localhost/stream", "REMOTE_ADDR" => "127.0.0.1") }

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = []
      c.skip_paths = []
      c.track_memory = false
      c.track_http = false
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def middleware(status: 200, headers: { "content-type" => "text/plain" }, body:)
    described_class.new(->(_env) { [status, Rack::Headers[headers], body] })
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # What a server does: iterate, then close whatever happened.
  def serve(body)
    parts = []
    begin
      body.each { |part| parts << part }
    ensure
      body.close if body.respond_to?(:close)
    end
    parts.join
  end

  describe "a streamed body (no to_ary)" do
    let(:inner_body) { SlowStreamBody.new(%w[a b c d e], 0.2) }

    it "returns to the server before the stream ends and lets the first chunk out at once" do
      started = monotonic
      _status, _headers, body = middleware(body: inner_body).call(env)
      returned_after = monotonic - started

      first_chunk_after = nil
      parts = []
      body.each do |part|
        first_chunk_after ||= monotonic - started
        parts << part
      end
      body.close if body.respond_to?(:close)

      warn format("returned after %.2fs, first chunk after %.2fs", returned_after, first_chunk_after) if ENV["PROFILER_TIMINGS"]
      expect(returned_after).to be < 0.15
      expect(first_chunk_after).to be < 0.35
      expect(parts).to eq(%w[a b c d e])
    end

    it "is not turned into an Array" do
      _status, _headers, body = middleware(body: inner_body).call(env)
      expect(body).not_to respond_to(:to_ary)
      serve(body)
    end

    it "closes the application body once when the server closes it" do
      _status, _headers, body = middleware(body: inner_body).call(env)
      serve(body)
      expect(inner_body.closed).to eq(1)
    end

    it "saves the profile when the body is closed, with the body captured on the way" do
      _status, headers, body = middleware(body: inner_body).call(env)
      token = headers["X-Profiler-Token"]
      serve(body)

      profile = Profiler.storage.load(token)
      expect(profile).not_to be_nil
      expect(profile.status).to eq(200)
      expect(profile.response_body).to eq("abcde")
    end

    it "saves the profile and releases the collectors when the client goes away part way" do
      Profiler.configure { |c| c.collectors = [SubscriptionProbe] }
      _status, headers, body = middleware(body: inner_body).call(env)

      expect do
        body.each { |_part| raise Errno::EPIPE }
      end.to raise_error(Errno::EPIPE)
      body.close if body.respond_to?(:close)

      expect(SubscriptionProbe.subscribed).to be(false)
      expect(Profiler.storage.load(headers["X-Profiler-Token"])).not_to be_nil
    end

    it "saves the profile once, even when the server closes the body twice" do
      _status, _headers, body = middleware(body: inner_body).call(env)
      allow(Profiler.storage).to receive(:save).and_call_original
      serve(body)
      body.close if body.respond_to?(:close)
      expect(Profiler.storage).to have_received(:save).once
    end
  end

  describe "a text/event-stream body" do
    it "is passed through as a stream even when it could be read as an Array" do
      events = ["data: 1\n\n", "data: 2\n\n"]
      _status, _headers, body = middleware(headers: { "content-type" => "text/event-stream" }, body: events).call(env)
      expect(body).not_to respond_to(:to_ary)
      expect(serve(body)).to eq(events.join)
    end
  end

  describe "a Rack::BodyProxy around a stream" do
    it "stays a stream and still runs the proxy's callback" do
      called = false
      proxy = Rack::BodyProxy.new(SlowStreamBody.new(%w[a b], 0.01)) { called = true }
      _status, _headers, body = middleware(body: proxy).call(env)

      expect(body).not_to respond_to(:to_ary)
      expect(serve(body)).to eq("ab")
      expect(called).to be(true)
    end
  end

  describe "a body served by its path (send_file)" do
    let(:file) do
      Tempfile.new(["download", ".bin"]).tap do |f|
        f.write("file contents")
        f.flush
      end
    end

    after { file.close! }

    it "still answers to_path, with the same path" do
      inner = FileLikeBody.new(file.path)
      _status, _headers, body = middleware(headers: { "content-type" => "application/octet-stream" }, body: inner).call(env)

      expect(body).to respond_to(:to_path)
      expect(body.to_path).to eq(file.path)
      body.close if body.respond_to?(:close)
      expect(inner.closed).to eq(1)
    end
  end

  describe "an error raised while the body is iterated" do
    it "reaches the server instead of becoming an empty 200" do
      status, _headers, body = middleware(body: FailingBody.new).call(env)

      expect(status).to eq(200)
      expect { serve(body) }.to raise_error(IOError, "the file went away")
    end

    it "still saves the profile once the server closes the body" do
      _status, headers, body = middleware(body: FailingBody.new).call(env)
      expect { serve(body) }.to raise_error(IOError)
      expect(Profiler.storage.load(headers["X-Profiler-Token"])).not_to be_nil
    end
  end

  describe "an HTML page that carries a Content-Length" do
    it "sends a Content-Length that matches the page with the toolbar injected" do
      page = "<html><body>hello</body></html>"
      headers = { "content-type" => "text/html", "content-length" => page.bytesize.to_s }
      _status, out_headers, body = middleware(headers: headers, body: [page]).call(env)
      sent = serve(body)

      expect(sent).to include("profiler-toolbar")
      expect(out_headers["content-length"]).to eq(sent.bytesize.to_s)
    end
  end

  # A server that never closes the body breaks the Rack contract; even then nothing the
  # collectors installed stays behind: they are read and released before the body leaves.
  describe "a streamed body the server never closes" do
    it "leaves no collector subscribed" do
      Profiler.configure { |c| c.collectors = [SubscriptionProbe] }
      middleware(body: SlowStreamBody.new(%w[a], 0)).call(env)

      expect(SubscriptionProbe.subscribed).to be(false)
    end

    it "leaves the thread clean for the next request" do
      Profiler.configure { |c| c.collectors = [Profiler::Collectors::DumpCollector] }
      first = described_class.new(lambda do |_env|
        Profiler.dump("from the first request")
        [200, Rack::Headers["content-type" => "text/plain"], SlowStreamBody.new(%w[a], 0)]
      end)
      first.call(env) # never iterated, never closed

      expect(Thread.current[:profiler_dumps]).to be_nil

      _status, headers, body = middleware(body: ["second"]).call(env)
      serve(body)
      dumps = Profiler.storage.load(headers["X-Profiler-Token"]).collector_data("dump")
      expect(dumps.to_s).not_to include("from the first request")
    end
  end

  # Responses that carry no body, or whose file the web server sends: left as they were.
  describe "responses without a body to profile" do
    def passes_unchanged(status:, headers:, body:, method: "GET")
      request_env = Rack::MockRequest.env_for("http://localhost/x", method: method, "REMOTE_ADDR" => "127.0.0.1")
      app = ->(_env) { [status, Rack::Headers[headers], body] }
      expected_status, expected_headers, expected_body = app.call(request_env.dup)
      expected = serve(expected_body)

      out_status, out_headers, out_body = described_class.new(app).call(request_env)
      expect(out_status).to eq(expected_status)
      expect(out_headers.to_h.except("x-profiler-token", "X-Profiler-Token")).to eq(expected_headers.to_h)
      expect(serve(out_body)).to eq(expected)
    end

    it "keeps a HEAD answer empty" do
      head = Rack::Head.new(->(_env) { [200, Rack::Headers["content-type" => "text/html", "content-length" => "31"], ["<html><body>hello</body></html>"]] })
      request_env = Rack::MockRequest.env_for("http://localhost/x", method: "HEAD", "REMOTE_ADDR" => "127.0.0.1")
      status, headers, body = described_class.new(head).call(request_env)

      expect(status).to eq(200)
      expect(headers["content-length"]).to eq("31")
      expect(serve(body)).to eq("")
    end

    it "keeps a 204 as it was" do
      passes_unchanged(status: 204, headers: {}, body: [])
    end

    it "keeps a 304 as it was" do
      passes_unchanged(status: 304, headers: { "etag" => '"v1"' }, body: [])
    end

    it "keeps the X-Sendfile answer of Rack::Sendfile as it was" do
      file = Tempfile.new(["sent", ".html"])
      file.write("<html><body>file</body></html>")
      file.flush
      sendfile = Rack::Sendfile.new(->(_env) { [200, Rack::Headers["content-type" => "text/html"], FileLikeBody.new(file.path)] },
                                    "X-Sendfile")
      request_env = Rack::MockRequest.env_for("http://localhost/x", "REMOTE_ADDR" => "127.0.0.1")
      status, headers, body = described_class.new(sendfile).call(request_env)

      expect(status).to eq(200)
      expect(headers["x-sendfile"]).to eq(file.path)
      expect(headers["content-length"]).to eq("0")
      expect(serve(body)).to eq("")
    ensure
      file&.close!
    end
  end

  # Rack 3 has header names in lower case, Rack 2 lets a plain Hash use any case, and
  # Rack::Headers (what Rails returns) answers either.
  describe "response headers in any case" do
    let(:page) { "<html><body>hello</body></html>" }

    {
      "a plain Hash in lower case" => -> (page) { { "content-type" => "text/html", "content-length" => page.bytesize.to_s } },
      "a plain Hash in mixed case" => -> (page) { { "Content-Type" => "text/html", "Content-Length" => page.bytesize.to_s } },
      "a plain Hash in odd case" => -> (page) { { "CONTENT-type" => "text/html", "Content-length" => page.bytesize.to_s } },
      "a Rack::Headers" => -> (page) { Rack::Headers["Content-Type" => "text/html", "content-length" => page.bytesize.to_s] }
    }.each do |label, build|
      it "injects the toolbar and corrects the length with #{label}" do
        headers = build.call(page)
        app = described_class.new(->(_env) { [200, headers, [page]] })
        _status, out_headers, body = app.call(env)
        sent = serve(body)

        lengths = out_headers.select { |name, _| name.to_s.casecmp?("content-length") }
        expect(sent).to include("profiler-toolbar")
        expect(lengths.values).to eq([sent.bytesize.to_s])
        expect(out_headers.keys.map(&:to_s).grep(/\Ax-profiler-token\z/i).size).to eq(1)
      end
    end

    it "keeps the name a Rack 2 application spelled" do
      app = described_class.new(->(_env) { [200, { "Content-Type" => "text/html", "Content-Length" => "31" }, [page]] })
      _status, out_headers, body = app.call(env)
      serve(body)
      expect(out_headers.keys).to include("Content-Length")
    end

    it "sees a lower case text/event-stream in a plain Hash as a stream" do
      app = described_class.new(->(_env) { [200, { "content-type" => "text/event-stream" }, ["data: 1\n\n"]] })
      _status, _headers, body = app.call(env)
      expect(body).not_to respond_to(:to_ary)
      serve(body)
    end
  end
end
