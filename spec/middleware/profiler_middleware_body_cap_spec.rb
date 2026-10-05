# frozen_string_literal: true

require "spec_helper"
require "rack"
require "stringio"

# The bodies kept in a profile are capped by max_captured_body_bytes; the application still
# reads and sends every byte.
RSpec.describe Profiler::Middleware::ProfilerMiddleware, "captured body size" do
  let(:cap) { 1024 }

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = [Profiler::Collectors::RequestCollector]
      c.skip_paths = []
      c.track_memory = false
      c.track_http = false
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def post_env(body)
    Rack::MockRequest.env_for("http://localhost/upload", method: "POST", input: body,
                              "CONTENT_TYPE" => "text/plain", "REMOTE_ADDR" => "127.0.0.1")
  end

  def serve(body)
    parts = []
    body.each { |part| parts << part }
    body.close if body.respond_to?(:close)
    parts.join
  end

  it "defaults to a few hundred kilobytes" do
    expect(Profiler::Configuration.new.max_captured_body_bytes).to eq(256 * 1024)
  end

  context "with a cap" do
    before { Profiler.configure { |c| c.max_captured_body_bytes = cap } }

    it "keeps only the first bytes of a large request body, says so, and gives the application all of it" do
      upload = "x" * (cap * 10)
      seen_by_app = nil
      app = lambda do |env|
        seen_by_app = env["rack.input"].read
        [200, Rack::Headers["content-type" => "text/plain"], ["ok"]]
      end

      _status, headers, body = described_class.new(app).call(post_env(upload))
      serve(body)

      expect(seen_by_app).to eq(upload)
      profile = Profiler.storage.load(headers["X-Profiler-Token"])
      expect(profile.request_body.bytesize).to eq(cap)
      request = profile.collector_data("request")
      expect(request["request_body_truncated"]).to be(true)
      expect(request["request_body_size"]).to eq(upload.bytesize)
    end

    it "reads no more of rack.input than the cap before the application runs" do
      input = StringIO.new("y" * (cap * 10))
      allow(input).to receive(:read).and_call_original
      app = ->(_env) { [200, Rack::Headers["content-type" => "text/plain"], ["ok"]] }

      env = post_env("")
      env["rack.input"] = input
      described_class.new(app).call(env)

      expect(input).to have_received(:read).with(cap + 1)
      expect(input).not_to have_received(:read).with(no_args)
    end

    it "keeps only the first bytes of a large response body, says so, and sends all of it" do
      page = "z" * (cap * 10)
      app = ->(_env) { [200, Rack::Headers["content-type" => "text/plain"], [page]] }

      _status, headers, body = described_class.new(app).call(post_env(""))
      expect(serve(body)).to eq(page)

      profile = Profiler.storage.load(headers["X-Profiler-Token"])
      expect(profile.response_body.bytesize).to eq(cap)
      response = profile.collector_data("request")
      expect(response["response_body_truncated"]).to be(true)
      expect(response["response_body_size"]).to eq(page.bytesize)
    end

    it "leaves out a cluster secret cut in two by the cap, in both bodies" do
      secret = "s" * 40
      Profiler.configure { |c| c.cluster_secret = secret }
      text = ("a" * (cap - 10)) + secret + ("b" * cap)
      app = ->(_env) { [200, Rack::Headers["content-type" => "text/plain"], [text]] }

      _status, headers, body = described_class.new(app).call(post_env(text))
      serve(body)

      profile = Profiler.storage.load(headers["X-Profiler-Token"])
      expect(profile.request_body).to eq("a" * (cap - 10))
      expect(profile.response_body).to eq("a" * (cap - 10))
    ensure
      Profiler.configure { |c| c.cluster_secret = nil }
    end

    it "does not flag a body under the cap" do
      app = ->(_env) { [200, Rack::Headers["content-type" => "text/plain"], ["small"]] }
      _status, headers, body = described_class.new(app).call(post_env("tiny"))
      serve(body)

      request = Profiler.storage.load(headers["X-Profiler-Token"]).collector_data("request")
      expect(request["request_body_truncated"]).to be(false)
      expect(request["response_body_truncated"]).to be(false)
    end
  end

  context "when set to nil" do
    before { Profiler.configure { |c| c.max_captured_body_bytes = nil } }

    it "keeps the whole bodies, as before" do
      upload = "x" * (300 * 1024)
      app = ->(_env) { [200, Rack::Headers["content-type" => "text/plain"], [upload]] }
      _status, headers, body = described_class.new(app).call(post_env(upload))
      serve(body)

      profile = Profiler.storage.load(headers["X-Profiler-Token"])
      expect(profile.request_body.bytesize).to eq(upload.bytesize)
      expect(profile.collector_data("request")["response_body_truncated"]).to be(false)
    end
  end
end
