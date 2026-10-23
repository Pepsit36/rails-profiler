# frozen_string_literal: true

require "spec_helper"
require "webmock"
require "webmock/rspec/matchers"
require "rack/mock"
require "action_dispatch"
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
                custom: env["HTTP_X_CUSTOM"], content_type: env["CONTENT_TYPE"] }
      [200, { "Content-Type" => "text/plain" }, ["ok"]]
    end
  end
  let(:app) { Profiler::Middleware::ProfilerMiddleware.new(inner_app) }
  let(:source) do
    build_profile(path: "/orders", method: "POST", params: { "a" => "1" },
                  headers: { "Host" => "localhost:3000", "Content-Type" => "application/x-www-form-urlencoded",
                             "Cookie" => "[FILTERED]" },
                  server_port: 3000, url_scheme: "http").tap do |profile|
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

    it "keeps whitespace and control characters out of the request line, query included" do
      ["/a?x=1\tHost: evil", "/a?x=1 HTTP/1.1", "/a?x=1\r\nHost: evil", "/a?x=\x00"].each do |path|
        expect { replay(path: path) }.to raise_error(described_class::Invalid, /query string/)
      end
      replay(query: "x=1\tb=2\x00 \r\nHost:evil")
      expect(seen.last).to include(query: "x=1b=2Host:evil", host: "localhost:3000")
    end

    it "refuses a profile whose captured Host is neither loopback nor a literal config.hosts entry" do
      forged = build_profile(headers: { "Host" => "evil.example" }, server_port: 3000, url_scheme: "http")
      storage.save(forged.token, forged)
      expect { replay({}, forged.token) }.to raise_error(described_class::Invalid, /neither a loopback name/)
      expect(a_request(:any, /evil/)).not_to have_been_made
    end

    describe "host check independent of Rails' permissive config.hosts" do
      def with_rails_hosts(hosts)
        stub_const("Rails", double(application: double(config: double(hosts: hosts)), env: double(test?: false)))
      end

      def stored_host(host)
        profile = build_profile(headers: { "Host" => host }, server_port: 3000, url_scheme: "http")
        storage.save(profile.token, profile)
        profile.token
      end

      # What Rails sets in development: every IPv4 and IPv6 address, plus .localhost and the like.
      let(:development_hosts) { [IPAddr.new("0.0.0.0/0"), IPAddr.new("::/0"), ".localhost", "localhost"] }

      ["10.0.0.5", "169.254.169.254", "169.254.169.254:80", "[fd00::1]", "192.168.1.10"].each do |host|
        it "refuses Host #{host} although config.hosts holds 0.0.0.0/0 and ::/0" do
          with_rails_hosts(development_hosts)
          expect { replay({}, stored_host(host)) }.to raise_error(described_class::Invalid, /neither a loopback name/)
          expect(a_request(:any, /./)).not_to have_been_made
        end
      end

      it "refuses a host that only a wildcard, a CIDR range, a Regexp or a Proc of config.hosts matches" do
        with_rails_hosts([".example.test", IPAddr.new("10.0.0.0/8"), /\Aregexp\.test\z/, ->(_h) { true }])
        ["app.example.test", "example.test", "10.0.0.5", "regexp.test"].each do |host|
          expect { replay({}, stored_host(host)) }.to raise_error(described_class::Invalid, /neither a loopback name/), host
        end
      end

      it "refuses a name that merely ends in .localhost" do
        with_rails_hosts(development_hosts)
        expect { replay({}, stored_host("evil.localhost")) }.to raise_error(described_class::Invalid)
      end

      it "accepts the loopback names whatever config.hosts says" do
        with_rails_hosts([])
        stub_request(:any, /127\.0\.0\.1|\[::1\]|localhost/).to_return(status: 200)
        ["localhost", "LOCALHOST:3000", "127.0.0.1", "[::1]:3000"].each do |host|
          expect { replay({}, stored_host(host)) }.not_to raise_error, host
        end
      end

      it "accepts a literal config.hosts entry, with or without a port, and an IP written literally" do
        with_rails_hosts(["app.example.test", "api.example.test:3000", "10.0.0.5"])
        stub_request(:any, /example\.test|10\.0\.0\.5/).to_return(status: 200)
        ["app.example.test", "API.example.test", "10.0.0.5"].each do |host|
          expect { replay({}, stored_host(host)) }.not_to raise_error, host
        end
      end
    end

    it "refuses a Host header that is not a bare host name" do
      forged = build_profile(headers: { "Host" => "localhost@evil.example/x" }, server_port: 3000, url_scheme: "http")
      storage.save(forged.token, forged)
      expect { replay({}, forged.token) }.to raise_error(described_class::Invalid)
    end

    it "refuses a profile with no Host" do
      bare = build_profile(headers: {})
      storage.save(bare.token, bare)
      expect { replay({}, bare.token) }.to raise_error(described_class::Invalid, /no Host/)
    end

    it "uses https only when the captured X-Forwarded-Proto says so, on the captured host" do
      secure = build_profile(headers: { "Host" => "localhost:8443" }, server_port: 8443, url_scheme: "https")
      storage.save(secure.token, secure)
      stub_request(:any, "https://localhost:8443/test").to_return(status: 200)
      result = replay({}, secure.token)
      expect(result.target).to eq("https://localhost:8443")
      expect(a_request(:get, "https://localhost:8443/test")).to have_been_made
    end

    it "ignores a forged X-Forwarded-Proto: the scheme is the one the server saw" do
      forged = build_profile(headers: { "Host" => "localhost:3000", "X-Forwarded-Proto" => "https" },
                             server_port: 3000, url_scheme: "http")
      storage.save(forged.token, forged)
      expect(replay({}, forged.token).target).to eq("http://localhost:3000")
    end

    describe "port lock" do
      def stored(host, **attrs)
        profile = build_profile(headers: { "Host" => host }, server_port: 3000, url_scheme: "http", **attrs)
        storage.save(profile.token, profile)
        profile
      end

      ["localhost:6379", "127.0.0.1:5432", "[::1]:11211", "localhost:80", "localhost:1"].each do |host|
        it "sends a replay of Host #{host} to the captured server port, never to the Host port" do
          forged_port = host[/(\d+)\z/, 1]
          stub_request(:any, /127\.0\.0\.1|::1|localhost/).to_return(status: 200)
          result = replay({}, stored(host).token)

          expect(result.target).to end_with(":3000")
          expect(a_request(:any, /:#{forged_port}\//)).not_to have_been_made
          expect(a_request(:any, /:3000\//)).to have_been_made.once
        end
      end

      it "does not let a host listed in config.hosts choose the port" do
        stub_const("Rails", double(application: double(config: double(hosts: ["app.example.test"])), env: double(test?: false)))
        stub_request(:any, /app\.example\.test/).to_return(status: 200)
        result = replay({}, stored("app.example.test:6379").token)

        expect(result.target).to eq("http://app.example.test:3000")
        expect(a_request(:any, /:6379/)).not_to have_been_made
      end

      it "refuses a profile that recorded no server port, instead of falling back to the Host port" do
        old = build_profile(headers: { "Host" => "localhost:6379" })
        storage.save(old.token, old)
        expect { replay({}, old.token) }.to raise_error(described_class::Invalid, /port the application listens on is unknown/)
        expect(a_request(:any, /./)).not_to have_been_made
      end

      it "refuses an out-of-range server port or an unknown scheme" do
        [[0, "http"], [70_000, "http"], [3000, "ftp"], [3000, nil]].each do |port, scheme|
          bad = build_profile(headers: { "Host" => "localhost" }, server_port: port, url_scheme: scheme)
          storage.save(bad.token, bad)
          expect { replay({}, bad.token) }.to raise_error(described_class::Invalid, /port the application listens on is unknown/)
        end
      end

      it "survives the stores: the server port is kept by the SQLite store and by to_h / from_json" do
        profile = stored("localhost:6379")
        expect(Profiler::Models::Profile.from_json(profile.to_json).server_port).to eq(3000)
      end

      it "captures the port of the Puma socket, never SERVER_PORT, the Host or a forwarded header" do
        socket = TCPServer.new("127.0.0.1", 0)
        env = Rack::MockRequest.env_for("http://localhost:6379/x", "SERVER_PORT" => "6379", "puma.socket" => socket,
                                                                   "HTTP_X_FORWARDED_PORT" => "6379",
                                                                   "HTTP_X_FORWARDED_PROTO" => "https")
        profile = Profiler::Models::Profile.new(Rack::Request.new(env))
        expect([profile.server_port, profile.url_scheme]).to eq([socket.local_address.ip_port, "http"])
      ensure
        socket&.close
      end

      it "captures no port without a socket to read it from, whatever SERVER_PORT says" do
        env = Rack::MockRequest.env_for("http://localhost:6379/x", "SERVER_PORT" => "3000")
        profile = Profiler::Models::Profile.new(Rack::Request.new(env))
        expect([profile.server_port, profile.url_scheme]).to eq([nil, nil])
      end

      it "captures no port from a Unix socket" do
        path = File.join(Dir.mktmpdir, "s.sock")
        socket = UNIXServer.new(path)
        env = Rack::MockRequest.env_for("http://localhost/x", "puma.socket" => socket)
        expect(Profiler::Models::Profile.new(Rack::Request.new(env)).server_port).to be_nil
      ensure
        socket&.close
      end
    end

    describe "config.replay_port" do
      def stored_with(port, scheme, host = "localhost:6379")
        profile = build_profile(headers: { "Host" => host }, server_port: port, url_scheme: scheme)
        storage.save(profile.token, profile)
        profile
      end

      it "always wins over the captured port" do
        Profiler.configuration.replay_port = 4000
        stub_request(:any, /localhost:4000/).to_return(status: 200)
        result = replay({}, stored_with(3000, "http").token)
        expect(result.target).to eq("http://localhost:4000")
        expect(a_request(:any, /:3000|:6379/)).not_to have_been_made
      end

      it "replays a profile that captured no port (a server other than Puma)" do
        Profiler.configuration.replay_port = 4000
        stub_request(:any, /localhost:4000/).to_return(status: 200)
        expect(replay({}, stored_with(nil, nil).token).target).to eq("http://localhost:4000")
      end

      it "still refuses a host that config.hosts does not allow" do
        Profiler.configuration.replay_port = 4000
        expect { replay({}, stored_with(nil, nil, "evil.example:4000").token) }
          .to raise_error(described_class::Invalid, /neither a loopback name/)
      end

      it "validates the value" do
        config = Profiler::Configuration.new
        config.replay_port = "4000"
        expect(config.replay_port).to eq(4000)
        config.replay_port = nil
        expect(config.replay_port).to be_nil
        ["x", 0, 70_000, "80 "].each { |bad| expect { config.replay_port = bad }.to raise_error(ArgumentError, /replay_port/) }
      end
    end

    describe "without a captured port nor config.replay_port" do
      it "refuses with an explicit message that names config.replay_port, and sends nothing" do
        Profiler.configuration.replay_port = nil
        profile = build_profile(headers: { "Host" => "localhost:6379" }, server_port: nil, url_scheme: nil)
        storage.save(profile.token, profile)
        expect { replay({}, profile.token) }
          .to raise_error(described_class::Invalid, /config\.replay_port.*rather than using the Host header or SERVER_PORT/m)
        expect(a_request(:any, /./)).not_to have_been_made
      end
    end

    describe "against a real Puma" do
      require "socket"
      require "puma"
      require "puma/server"

      def start_puma(app)
        server = Puma::Server.new(app)
        server.add_tcp_listener("127.0.0.1", 0)
        server.run
        [server, server.connected_ports.first]
      end

      def get(port, host, extra = "")
        TCPSocket.open("127.0.0.1", port) do |c|
          c.write("GET /orders HTTP/1.1\r\nHost: #{host}\r\n#{extra}Connection: close\r\n\r\n")
          c.read
        end
      end

      it "replays to the port of the socket, not to the forged Host port nor the SERVER_PORT derived from it" do
        WebMock.allow_net_connect!
        WebMock.disable!
        decoy = TCPServer.new("127.0.0.1", 0)
        decoy_port = decoy.addr[1]
        decoy_hits = 0
        decoy_thread = Thread.new do
          loop do
            decoy.accept.close
            decoy_hits += 1
          rescue IOError
            break
          end
        end
        server_ports = []
        real_hits = []
        rack_app = lambda do |env|
          server_ports << env["SERVER_PORT"]
          real_hits << env["HTTP_HOST"]
          [200, { "Content-Type" => "text/plain" }, ["ok"]]
        end
        server, port = start_puma(Profiler::Middleware::ProfilerMiddleware.new(rack_app))

        get(port, "localhost:#{decoy_port}", "X-Forwarded-Proto: https\r\n")
        expect(server_ports).to eq([decoy_port.to_s]) # Puma derives SERVER_PORT from the Host header
        token = storage.list(limit: 10).find { |p| p.path == "/orders" }.token
        profile = storage.load(token)
        expect([profile.server_port, profile.url_scheme]).to eq([port, "http"])

        result = replay({}, token)

        expect(result.target).to eq("http://localhost:#{port}")
        expect(result.replays.first[:status]).to eq(200)
        expect(real_hits.size).to eq(2)
        expect(decoy_hits).to eq(0)
      ensure
        server&.stop(true)
        decoy&.close
        decoy_thread&.join
      end

      it "lets config.replay_port win over the Puma socket" do
        WebMock.allow_net_connect!
        WebMock.disable!
        rack_app = ->(_env) { [200, {}, ["ok"]] }
        server, port = start_puma(Profiler::Middleware::ProfilerMiddleware.new(rack_app))
        other, other_port = start_puma(rack_app)
        get(port, "localhost:1")
        token = storage.list(limit: 10).find { |p| p.path == "/orders" }.token
        Profiler.configuration.replay_port = other_port

        expect(replay({}, token).target).to eq("http://localhost:#{other_port}")
      ensure
        server&.stop(true)
        other&.stop(true)
      end
    end

    describe "against a real TCP server" do
      require "socket"

      it "never reaches a decoy listening on the port the Host header names" do
        WebMock.allow_net_connect!
        WebMock.disable!
        decoy = TCPServer.new("127.0.0.1", 0)
        real = TCPServer.new("127.0.0.1", 0)
        hits = { decoy: 0, real: 0 }
        threads = { decoy: decoy, real: real }.map do |name, server|
          Thread.new do
            loop do
              client = server.accept
              hits[name] += 1
              client.gets
              client.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
              client.close
            rescue IOError
              break
            end
          end
        end
        profile = build_profile(headers: { "Host" => "127.0.0.1:#{decoy.addr[1]}" },
                                server_port: real.addr[1], url_scheme: "http")
        storage.save(profile.token, profile)

        result = replay({ count: 2 }, profile.token)

        expect(result.replays.map { |r| r[:status] }).to eq([200, 200])
        expect(hits).to eq(decoy: 0, real: 2)
      ensure
        [decoy, real].compact.each(&:close)
        threads&.each(&:join)
      end
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

  describe "issue #64 fixes" do
    describe "case 1: Content-Type header from captured request" do
      it "includes Content-Type header when replaying JSON request" do
        json_source = build_profile(path: "/api/data", method: "POST",
                                    headers: { "Host" => "localhost:3000", "Content-Type" => "application/json" },
                                    server_port: 3000, url_scheme: "http")
        json_source.request_body = '{"key":"value"}'
        json_source.request_body_encoding = "text"
        storage.save(json_source.token, json_source)

        replay({}, json_source.token)
        expect(seen.last[:body]).to eq('{"key":"value"}')
      end

      it "replaces a captured multipart Content-Type when the stored body is dropped and params are given" do
        multipart_source = build_profile(path: "/upload", method: "POST",
                                         headers: { "Host" => "localhost:3000",
                                                    "Content-Type" => "multipart/form-data; boundary=----abc" },
                                         server_port: 3000, url_scheme: "http")
        multipart_source.request_body = "[FILTERED: multipart/form-data body, 1234 bytes]"
        multipart_source.request_body_encoding = "text"
        storage.save(multipart_source.token, multipart_source)

        replay({ params: { "a" => "1" } }, multipart_source.token)

        expect(seen.last[:body]).to eq("a=1")
        expect(seen.last[:content_type]).to eq("application/x-www-form-urlencoded")
      end
    end

    describe "case 2: Reject masked/redacted bodies" do
      it "does not send body containing [FILTERED] mask and notes it" do
        masked_source = build_profile(path: "/orders", method: "POST",
                                      headers: { "Host" => "localhost:3000" },
                                      server_port: 3000, url_scheme: "http")
        masked_source.request_body = "{\"password\":\"[FILTERED]\"}"
        masked_source.request_body_encoding = "text"
        storage.save(masked_source.token, masked_source)

        result = replay({}, masked_source.token)
        # Net::HTTP sends no body, so the stub builds an empty rack.input, not a nil one.
        expect(seen.last[:body]).to be_empty
        expect(result.notes.join).to match(/masked values/)
      end

      it "does not send body containing [FILTERED: multipart marker and notes it" do
        multipart_source = build_profile(path: "/upload", method: "POST",
                                         headers: { "Host" => "localhost:3000" },
                                         server_port: 3000, url_scheme: "http")
        multipart_source.request_body = "[FILTERED: multipart/form-data body, 1234 bytes]"
        multipart_source.request_body_encoding = "text"
        storage.save(multipart_source.token, multipart_source)

        result = replay({}, multipart_source.token)
        expect(seen.last[:body]).to be_empty
        expect(result.notes.join).to match(/masked values/)
      end
    end

    describe "case 3: Validate headers parameter type" do
      it "raises Invalid when headers is a string" do
        expect { replay(headers: "invalid") }.to raise_error(described_class::Invalid, /headers must be a Hash/)
        expect(seen).to be_empty
      end

      it "raises Invalid when headers is a number" do
        expect { replay(headers: 123) }.to raise_error(described_class::Invalid, /headers must be a Hash/)
        expect(seen).to be_empty
      end

      it "accepts headers as nil" do
        expect { replay(headers: nil) }.not_to raise_error
      end

      it "accepts headers as an empty hash" do
        expect { replay(headers: {}) }.not_to raise_error
      end
    end

    describe "validates params and body parameter types the same way as headers" do
      it "raises Invalid when params is a string" do
        expect { replay(params: "invalid") }.to raise_error(described_class::Invalid, /params must be a Hash/)
        expect(seen).to be_empty
      end

      it "raises Invalid when body is a hash" do
        expect { replay(body: { "a" => "1" }) }.to raise_error(described_class::Invalid, /body must be a String/)
        expect(seen).to be_empty
      end

      it "accepts params and body as nil" do
        expect { replay(params: nil, body: nil) }.not_to raise_error
      end
    end
  end
end
