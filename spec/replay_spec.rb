# frozen_string_literal: true

require "spec_helper"
require "webmock"
require "webmock/rspec/matchers"
require "rack/mock"
require "profiler/replay"
require "profiler/mcp/tools/replay_request"

RSpec.describe Profiler::Replay do
  include WebMock::API
  include WebMock::Matchers

  let(:storage) { Profiler::Storage::MemoryStore.new }
  let(:seen) { [] }
  # The application: answers 200 and remembers what reached it.
  let(:inner_app) do
    lambda do |env|
      seen << { method: env["REQUEST_METHOD"], path: env["PATH_INFO"], query: env["QUERY_STRING"],
                host: env["HTTP_HOST"], body: env["rack.input"]&.read, cookie: env["HTTP_COOKIE"],
                custom: env["HTTP_X_CUSTOM"] }
      [200, { "Content-Type" => "text/plain" }, ["ok"]]
    end
  end
  let(:app) { Profiler::Middleware::ProfilerMiddleware.new(inner_app) }
  let(:source) do
    build_profile(path: "/orders", method: "POST", params: { "a" => "1" },
                  headers: { "Host" => "localhost:3000", "Content-Type" => "application/x-www-form-urlencoded",
                             "Cookie" => "[FILTERED]" }).tap do |profile|
      profile.request_body = "a=1"
      profile.request_body_encoding = "text"
    end
  end

  before do
    WebMock.enable!
    WebMock.disable_net_connect!
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = []
      c.skip_paths = []
      c.track_memory = false
      c.track_http = false
      c.authorization_mode = :allow_all
      c.replay_enabled = true
    end
    Profiler.instance_variable_set(:@storage, storage)
    storage.save(source.token, source)
    # WebMock hands the outgoing request to the application, through the middleware.
    stub_request(:any, /localhost|example/).to_return do |request|
      uri = URI(request.uri.to_s)
      env = Rack::MockRequest.env_for(request.uri.to_s, method: request.method.to_s.upcase,
                                                        input: request.body.to_s)
      request.headers.each { |name, value| env["HTTP_#{name.upcase.tr("-", "_")}"] = value }
      env["CONTENT_TYPE"] = request.headers["Content-Type"] if request.headers["Content-Type"]
      env["HTTP_HOST"] = "#{uri.host}:#{uri.port}"
      status, headers, body = app.call(env)
      { status: status, headers: headers.transform_keys(&:to_s), body: body.each.to_a.join }
    end
  end

  after do
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
  end

  def replay(options = {}, token = source.token)
    described_class.call(token, options, storage: storage)
  end

  it "is off by default" do
    expect(Profiler::Configuration.new.replay_enabled).to be(false)
  end

  describe "linking" do
    it "creates a profile whose replay_of is the original, found through find_by_replay_of" do
      result = replay
      new_token = result.replays.first[:token]

      expect(new_token).to match(/\A\h{32}\z/)
      expect(new_token).not_to eq(source.token)
      expect(storage.load(new_token).replay_of).to eq(source.token)
      expect(storage.find_by_replay_of(source.token).map(&:token)).to eq([new_token])
      expect(storage.find_by_parent(source.token)).to be_empty
    end

    it "replays the captured method, path, body and Content-Type to the original host" do
      replay
      expect(seen.last).to include(method: "POST", path: "/orders", host: "localhost:3000", body: "a=1")
    end

    it "makes N replays, each a new profile linked to the original" do
      result = replay(count: 3)
      tokens = result.replays.map { |r| r[:token] }

      expect(tokens.compact.uniq.size).to eq(3)
      expect(storage.find_by_replay_of(source.token).map(&:token)).to match_array(tokens)
      expect(seen.size).to eq(3)
    end

    it "does not link a profile made without the replay header" do
      env = Rack::MockRequest.env_for("http://localhost:3000/x")
      _status, headers, = app.call(env)
      expect(storage.load(headers["x-profiler-token"] || headers["X-Profiler-Token"]).replay_of).to be_nil
    end

    it "ignores the replay header when replays are disabled" do
      Profiler.configuration.replay_enabled = false
      env = Rack::MockRequest.env_for("http://localhost:3000/x", "HTTP_X_PROFILER_REPLAY_OF" => source.token)
      _status, headers, = app.call(env)
      expect(storage.load(headers["x-profiler-token"] || headers["X-Profiler-Token"]).replay_of).to be_nil
    end
  end

  describe "limits" do
    it "refuses more replays than config.replay_max_count" do
      expect { replay(count: 11) }.to raise_error(described_class::Invalid, /1 to 10/)
      expect(seen).to be_empty
    end

    it "refuses a count below 1 or not a number" do
      expect { replay(count: 0) }.to raise_error(described_class::Invalid)
      expect { replay(count: "many") }.to raise_error(described_class::Invalid)
    end

    it "honours a lower configured maximum" do
      Profiler.configuration.replay_max_count = 2
      expect { replay(count: 3) }.to raise_error(described_class::Invalid)
    end
  end

  describe "when disabled" do
    before { Profiler.configuration.replay_enabled = false }

    it "refuses cleanly and sends nothing" do
      expect { replay }.to raise_error(described_class::Disabled, /replay_enabled/)
      expect(seen).to be_empty
      expect(a_request(:any, /localhost/)).not_to have_been_made
    end

    it "answers the MCP tool with an error response, not an exception" do
      response = Profiler::MCP::Tools::ReplayRequest.call("token" => source.token)
      expect(response).to be_error
      expect(response.content.first[:text]).to match(/disabled/)
    end
  end

  describe "target lock" do
    it "refuses every option that names a host, port, scheme or URL" do
      %w[host port scheme url base_url origin hostname uri target].each do |key|
        expect { replay(key => "evil.example") }.to raise_error(described_class::Invalid, /original request/)
      end
      expect(a_request(:any, /./)).not_to have_been_made
    end

    it "ignores Host and forwarding headers given as header overrides" do
      result = replay(headers: { "Host" => "evil.example", "X-Forwarded-Host" => "evil.example",
                                 "x-forwarded-proto" => "https", "X-Custom" => "yes" })

      expect(a_request(:any, "http://localhost:3000/orders")).to have_been_made.once
      expect(a_request(:any, /evil/)).not_to have_been_made
      expect(seen.last).to include(host: "localhost:3000", custom: "yes")
      expect(result.notes.join).to match(/Ignored headers/)
    end

    it "keeps a path override on the application: no other authority can be smuggled in" do
      ["//evil.example/x", "http://evil.example/x", "evil.example/x", "/a b", "/a\r\nHost: evil"].each do |path|
        expect { replay(path: path) }.to raise_error(described_class::Invalid)
      end
      replay(path: "/other?x=1")
      expect(seen.last).to include(path: "/other", query: "x=1", host: "localhost:3000")
    end

    it "refuses a profile whose captured Host is neither local nor allowed" do
      forged = build_profile(headers: { "Host" => "evil.example" })
      storage.save(forged.token, forged)
      expect { replay({}, forged.token) }.to raise_error(described_class::Invalid, /neither local nor allowed/)
      expect(a_request(:any, /evil/)).not_to have_been_made
    end

    it "refuses a Host header that is not a bare host name" do
      forged = build_profile(headers: { "Host" => "localhost@evil.example/x" })
      storage.save(forged.token, forged)
      expect { replay({}, forged.token) }.to raise_error(described_class::Invalid)
    end

    it "refuses a profile with no Host" do
      bare = build_profile(headers: {})
      storage.save(bare.token, bare)
      expect { replay({}, bare.token) }.to raise_error(described_class::Invalid, /no Host/)
    end

    it "uses https only when the captured X-Forwarded-Proto says so, on the captured host" do
      secure = build_profile(headers: { "Host" => "localhost:8443", "X-Forwarded-Proto" => "https" })
      storage.save(secure.token, secure)
      stub_request(:any, "https://localhost:8443/test").to_return(status: 200)
      result = replay({}, secure.token)
      expect(result.target).to eq("https://localhost:8443")
      expect(a_request(:get, "https://localhost:8443/test")).to have_been_made
    end

    it "does not follow a redirect to another host" do
      stub_request(:any, "http://localhost:3000/orders").to_return(status: 302, headers: { "Location" => "http://evil.example/" })
      result = replay
      expect(result.replays.first[:status]).to eq(302)
      expect(a_request(:any, /evil/)).not_to have_been_made
    end
  end

  describe "variations" do
    it "overrides method, path, params, headers and cookies" do
      replay(method: "delete", path: "/orders/1", params: { "x" => "2" }, cookies: { "sid" => "abc" })
      expect(seen.last).to include(method: "DELETE", path: "/orders/1", query: "x=2", cookie: "sid=abc")
    end

    it "sends a body override as it is" do
      replay(body: "raw=1", headers: { "Content-Type" => "text/plain" })
      expect(seen.last[:body]).to eq("raw=1")
    end

    it "does not send the masked headers" do
      result = replay
      expect(seen.last[:cookie]).to be_nil
      expect(result.notes.join).to match(/Cookie/)
    end

    it "refuses an unknown method and unknown options" do
      expect { replay(method: "TRACE") }.to raise_error(described_class::Invalid, /Unsupported/)
      expect { replay(bogus: 1) }.to raise_error(described_class::Invalid, /Unknown/)
    end

    it "reports an unknown profile" do
      expect { replay({}, "f" * 32) }.to raise_error(described_class::NotFound)
      expect { replay({}, "../etc") }.to raise_error(described_class::NotFound)
    end
  end

  describe "self-profiling" do
    it "makes the call inside Profiler.untracked_http" do
      flag = nil
      allow_any_instance_of(Net::HTTP).to receive(:start).and_wrap_original do |original, *args, &block|
        flag = Thread.current[:profiler_http_untracked]
        original.call(*args, &block)
      end
      replay
      expect(flag).to be(true)
      expect(Thread.current[:profiler_http_untracked]).to be_falsey
    end
  end

  describe "MCP tool" do
    it "replays and lists the new profiles" do
      response = Profiler::MCP::Tools::ReplayRequest.call("token" => source.token, "count" => 2)
      text = response.first[:text]
      expect(text).to include("localhost:3000")
      expect(storage.find_by_replay_of(source.token).size).to eq(2)
    end

    it "refuses a host argument" do
      response = Profiler::MCP::Tools::ReplayRequest.call("token" => source.token, "host" => "evil.example")
      expect(response).to be_error
      expect(a_request(:any, /evil/)).not_to have_been_made
    end
  end
end
