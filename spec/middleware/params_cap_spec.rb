# frozen_string_literal: true

require "spec_helper"
require "json"
require "action_dispatch"

# The params a profile keeps are capped by max_captured_body_bytes, as the bodies are: a large
# JSON POST no longer stores its whole content twice more in the profile. The application still
# gets every param.
RSpec.describe Profiler::Middleware::ProfilerMiddleware, "params cap" do
  let(:cap) { 1024 }

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = [Profiler::Collectors::RequestCollector]
      c.skip_paths = []
      c.track_memory = false
      c.track_http = false
      c.max_captured_body_bytes = cap
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def post_json(payload)
    body = JSON.generate(payload)
    seen = nil
    app = lambda do |env|
      seen = ActionDispatch::Request.new(env).params.except("controller", "action")
      [200, Rack::Headers["content-type" => "text/plain"], ["ok"]]
    end
    env = Rack::MockRequest.env_for("http://localhost/items", method: "POST", input: body,
                                    "CONTENT_TYPE" => "application/json", "REMOTE_ADDR" => "127.0.0.1")
    _status, headers, = described_class.new(app).call(env)
    [Profiler.storage.load(headers["X-Profiler-Token"]), seen]
  end

  it "keeps at most max_captured_body_bytes of params, says so, and leaves the application's params whole" do
    payload = { "title" => "t", "items" => Array.new(5_000) { |i| { "id" => i, "name" => "item #{i} #{"n" * 50}" } } }
    profile, seen = post_json(payload)

    expect(seen).to eq(payload)
    expect(JSON.generate(profile.params).bytesize).to be <= cap + 200
    expect(profile.params["title"]).to eq("t")
    expect(profile.params_truncated).to be(true)
    request = profile.collector_data("request")
    expect(JSON.generate(request["params"]).bytesize).to be <= cap + 200
    expect(request["params_truncated"]).to be(true)
  end

  it "cuts one very long value" do
    profile, seen = post_json("data" => "d" * 100_000)

    expect(seen["data"].bytesize).to eq(100_000)
    expect(profile.params["data"].bytesize).to be < cap
    expect(profile.params_truncated).to be(true)
  end

  it "keeps small params as they are" do
    profile, = post_json("a" => "1", "b" => { "c" => [1, 2] })

    expect(profile.params).to eq("a" => "1", "b" => { "c" => [1, 2] })
    expect(profile.params_truncated).to be(false)
  end

  it "keeps whole params when max_captured_body_bytes is nil" do
    Profiler.configuration.max_captured_body_bytes = nil
    profile, = post_json("data" => "d" * 100_000)

    expect(profile.params["data"].bytesize).to eq(100_000)
  end
end
