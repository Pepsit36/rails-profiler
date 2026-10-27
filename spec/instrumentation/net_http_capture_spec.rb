# frozen_string_literal: true

require "spec_helper"
require "socket"
require "stringio"
require "zlib"
require "profiler/instrumentation/net_http_instrumentation"

# Outgoing Net::HTTP calls: which hosts are left out, and how much of their bodies a profile keeps.
RSpec.describe Profiler::Instrumentation::NetHttpInstrumentation, "capture" do
  let(:collector) { Profiler::Collectors::HttpCollector.new(build_profile) }

  # A server on 127.0.0.1 that reads each request whole and answers +response_body+.
  def start_server(response_body: "ok", headers: {})
    server = TCPServer.new("127.0.0.1", 0)
    received = []
    thread = Thread.new do
      loop do
        client = server.accept
        head = +""
        head << client.readline until head.end_with?("\r\n\r\n")
        if head.match?(/transfer-encoding: *chunked/i)
          body = +""
          while (size = client.readline.to_i(16)).positive?
            body << client.read(size)
            client.readline
          end
          client.readline
          received << body
        else
          received << client.read(head[/content-length: *(\d+)/i, 1].to_i)
        end
        content_type = headers.fetch("Content-Type", "text/plain; charset=utf-8")
        extra = headers.except("Content-Type").map { |name, value| "#{name}: #{value}\r\n" }.join
        client.write("HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\n#{extra}" \
                     "Content-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n")
        client.write(response_body)
        client.close
      rescue IOError, Errno::EBADF
        break
      end
    end
    [server, thread, received]
  end

  around do |example|
    Profiler.configure do |c|
      c.enabled = true
      c.track_http = true
    end
    @server, @thread, @received = start_server(**(example.metadata[:server] || {}))
    @port = @server.addr[1]
    collector.subscribe
    example.run
  ensure
    collector.unsubscribe
    @server&.close
    @thread&.kill
  end

  def entries
    collector.collect
    collector.panel_content[:requests]
  end

  describe "hosts left out" do
    it "records calls to a service on the same machine by default" do
      Net::HTTP.get(URI("http://127.0.0.1:#{@port}/neighbour"))

      expect(entries.map { |e| e["url"] }).to include("http://127.0.0.1:#{@port}/neighbour")
    end

    it "leaves out the hosts listed in http_skip_hosts" do
      Profiler.configuration.http_skip_hosts = ["127.0.0.1"]
      Net::HTTP.get(URI("http://127.0.0.1:#{@port}/neighbour"))

      expect(entries).to be_empty
    end

    it "matches a String as the whole host name, not as a pattern" do
      Profiler.configuration.http_skip_hosts = ["example.com"]

      expect(described_class.skip_host?("example.com")).to be(true)
      expect(described_class.skip_host?("EXAMPLE.com")).to be(true)
      expect(described_class.skip_host?("notexample.com")).to be(false)
      expect(described_class.skip_host?("exampleXcom")).to be(false)
      expect(described_class.skip_host?("example.com.attacker.net")).to be(false)
      expect(described_class.skip_host?("api.example.com")).to be(false)
    end

    it "matches a String starting with a dot as a domain, against its subdomains only" do
      Profiler.configuration.http_skip_hosts = [".internal"]

      expect(described_class.skip_host?("api.internal")).to be(true)
      expect(described_class.skip_host?("a.b.Internal")).to be(true)
      expect(described_class.skip_host?("internal")).to be(false)
      expect(described_class.skip_host?("notinternal")).to be(false)
      expect(described_class.skip_host?("api.internal.attacker.net")).to be(false)
    end

    it "still matches a Regexp as a pattern" do
      Profiler.configuration.http_skip_hosts = [/\.example\.com\z/]

      expect(described_class.skip_host?("api.example.com")).to be(true)
      expect(described_class.skip_host?("example.com.attacker.net")).to be(false)
    end

    # A list changed in place (<<) is never validated: a String that is not a valid Regexp left
    # every call of a profiled request failing with a RegexpError.
    it "records the calls of a request whose list holds a wildcard String added in place" do
      Profiler.configuration.http_skip_hosts << "*.internal"

      expect { Net::HTTP.get(URI("http://127.0.0.1:#{@port}/neighbour")) }.not_to raise_error
      expect(entries.map { |e| e["url"] }).to eq(["http://127.0.0.1:#{@port}/neighbour"])
    end

    it "brings the former list back with LOCAL_HTTP_HOSTS" do
      Profiler.configuration.http_skip_hosts = Profiler::Configuration::LOCAL_HTTP_HOSTS
      Net::HTTP.get(URI("http://127.0.0.1:#{@port}/neighbour"))

      expect(entries).to be_empty
      expect(described_class.skip_host?("localhost")).to be(true)
      expect(described_class.skip_host?("::1")).to be(true)
      expect(described_class.skip_host?("127.0.0.10")).to be(false)
    end

    it "always leaves out the cluster's master, so that the cluster's own calls are not profiled" do
      Profiler.configuration.master_url = "http://127.0.0.1:#{@port}"
      Net::HTTP.get(URI("http://127.0.0.1:#{@port}/_profiler/api/cluster/heartbeat"))

      expect(entries).to be_empty
    end

    it "records another port of the master's host" do
      Profiler.configuration.master_url = "http://127.0.0.1:#{@port + 1}"
      Net::HTTP.get(URI("http://127.0.0.1:#{@port}/neighbour"))

      expect(entries.size).to eq(1)
    end
  end

  describe "SKIP_HOSTS" do
    it "stays, deprecated, as the former list" do
      skip_hosts = described_class.const_get(:SKIP_HOSTS)
      expect(skip_hosts).to eq(%w[127.0.0.1 localhost ::1])
      expect(skip_hosts).to include("localhost")
      expect(skip_hosts.include?("127.0.0.1")).to be(true)
      expect(skip_hosts).to be_frozen
    end
  end

  describe "the profiler's own calls" do
    before do
      Profiler.configure do |c|
        c.cluster_master = true
        c.cluster_secret = "s" * 40
        c.cluster_allow_insecure_http = true
        c.cluster_allowed_slave_urls = :any
      end
      Profiler.instance_variable_set(:@slave_registry, nil)
    end

    after { Profiler.instance_variable_set(:@slave_registry, nil) }

    it "does not record a master's request to a slave on 127.0.0.1" do
      require "profiler/cluster/slave_proxy"
      Profiler.slave_registry.register(name: "local-slave", url: "http://127.0.0.1:#{@port}")
      Profiler::Cluster::SlaveProxy.new("local-slave").get_json("/_profiler/api/profiles")

      expect(@received.size).to eq(1)
      expect(entries).to be_empty
    end

    it "does not record a slave's registration and heartbeats, on any port of the master" do
      require "profiler/cluster/master_client"
      Profiler.configure do |c|
        c.master_url = "http://127.0.0.1:#{@port}"
        c.self_url = "http://127.0.0.1:1"
      end
      client = Profiler::Cluster::MasterClient.new
      client.send(:register!)
      client.send(:heartbeat!)

      expect(@received.size).to eq(2)
      expect(entries).to be_empty
    end

    it "records the application's calls made around them" do
      Profiler.untracked_http { Net::HTTP.get(URI("http://127.0.0.1:#{@port}/own")) }
      Net::HTTP.get(URI("http://127.0.0.1:#{@port}/app"))

      expect(entries.map { |e| e["url"] }).to eq(["http://127.0.0.1:#{@port}/app"])
    end
  end

  describe "bodies" do
    before do
      Profiler.configuration.max_captured_body_bytes = 1024
      Profiler.configuration.http_skip_hosts = []
      # Earlier versions left out 127.0.0.1 whatever the configuration said.
      allow(described_class).to receive(:skip_host?).and_return(false)
    end

    it "keeps only the first max_captured_body_bytes of a large request body, says so, and sends all of it" do
      payload = "a" * 10_000
      http = Net::HTTP.new("127.0.0.1", @port)
      http.post("/upload", payload, "Content-Type" => "text/plain")

      entry = entries.first
      expect(@received.first).to eq(payload)
      expect(entry["request_body"].bytesize).to eq(1024)
      expect(entry["request_body_truncated"]).to be(true)
      expect(entry["request_size"]).to eq(10_000)
    end

    it "reads at most max_captured_body_bytes of a rewindable body_stream, and sends all of it" do
      payload = "b" * 10_000
      stream = StringIO.new(payload)
      allow(stream).to receive(:read).and_call_original
      req = Net::HTTP::Post.new("/upload")
      req["Content-Type"] = "text/plain"
      req["Content-Length"] = payload.bytesize.to_s
      req.body_stream = stream
      Net::HTTP.new("127.0.0.1", @port).request(req)

      entry = entries.first
      expect(@received.first).to eq(payload)
      expect(stream).not_to have_received(:read).with(no_args)
      expect(entry["request_body"].bytesize).to eq(1024)
      expect(entry["request_body_truncated"]).to be(true)
      expect(entry["request_size"]).to eq(10_000)
    end

    it "never reads a body_stream that cannot be rewound, and leaves it to Net::HTTP" do
      payload = "c" * 5_000
      reader, writer = IO.pipe
      writer.write(payload)
      writer.close
      req = Net::HTTP::Post.new("/upload")
      req["Content-Type"] = "text/plain"
      req["Content-Length"] = payload.bytesize.to_s
      req.body_stream = reader
      # Earlier versions read the pipe whole, then sent nothing: the server waited for the body.
      http = Net::HTTP.new("127.0.0.1", @port)
      http.read_timeout = 3
      http.request(req)

      entry = entries.first
      expect(req.body_stream).to equal(reader)
      expect(@received.first).to eq(payload)
      expect(entry["request_body"]).to be_nil
      expect(entry["request_body_not_captured"]).to be(true)
    end

    it "keeps only the first max_captured_body_bytes of a large response, and says so", server: { response_body: "r" * 50_000 } do
      response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/big"))

      entry = entries.first
      expect(response.body.bytesize).to eq(50_000)
      expect(entry["response_body"].bytesize).to eq(1024)
      expect(entry["response_body_truncated"]).to be(true)
      expect(entry["response_size"]).to eq(50_000)
    end

    it "stops inflating a compressed response at the cap",
       server: { response_body: Zlib.gzip("z" * 5_000_000), headers: { "Content-Encoding" => "gzip" } } do
      http = Net::HTTP.new("127.0.0.1", @port)
      req = Net::HTTP::Get.new("/zip")
      req["Accept-Encoding"] = "gzip" # Net::HTTP leaves the body compressed when the caller asks for it
      http.request(req)

      entry = entries.first
      expect(entry["response_body"].bytesize).to eq(1024)
      expect(entry["response_body_truncated"]).to be(true)
    end

    it "keeps the text of a body_stream in UTF-8" do
      req = Net::HTTP::Post.new("/upload")
      req["Content-Type"] = "text/plain; charset=utf-8"
      req["Content-Length"] = "héllo".bytesize.to_s
      req.body_stream = StringIO.new("héllo")
      Net::HTTP.new("127.0.0.1", @port).request(req)

      expect(entries.first["request_body"]).to eq("héllo")
    end

    it "keeps the text of a gzip response in UTF-8",
       server: { response_body: Zlib.gzip("héllo"), headers: { "Content-Encoding" => "gzip" } } do
      req = Net::HTTP::Get.new("/zip")
      req["Accept-Encoding"] = "gzip"
      Net::HTTP.new("127.0.0.1", @port).request(req)

      expect(entries.first["response_body"]).to eq("héllo")
    end

    it "gives the whole size of a chunked body_stream whose size the stream knows" do
      payload = "k" * 10_000
      req = Net::HTTP::Post.new("/upload")
      req["Content-Type"] = "text/plain"
      req["Transfer-Encoding"] = "chunked"
      req.body_stream = StringIO.new(payload)
      Net::HTTP.new("127.0.0.1", @port).request(req)

      entry = entries.first
      expect(@received.first).to eq(payload)
      expect(entry["request_size"]).to eq(10_000)
      expect(entry["request_size_is_minimum"]).to be(false)
      expect(entry["request_body_truncated"]).to be(true)
    end

    it "says the size is only a minimum when neither the stream nor a Content-Length gives it" do
      payload = "m" * 10_000
      stream = StringIO.new(payload)
      stream.singleton_class.send(:undef_method, :size)
      stream.singleton_class.send(:undef_method, :length)
      req = Net::HTTP::Post.new("/upload")
      req["Content-Type"] = "text/plain"
      req["Transfer-Encoding"] = "chunked"
      req.body_stream = stream
      Net::HTTP.new("127.0.0.1", @port).request(req)

      entry = entries.first
      expect(@received.first).to eq(payload)
      expect(entry["request_size"]).to eq(1025)
      expect(entry["request_size_is_minimum"]).to be(true)
      expect(entry["request_body"].bytesize).to eq(1024)
    end

    it "reads no more of a body_stream than its Content-Length announces" do
      stream = StringIO.new("d" * 10_000)
      allow(stream).to receive(:read).and_call_original
      req = Net::HTTP::Post.new("/upload")
      req["Content-Type"] = "text/plain"
      req["Content-Length"] = "100"
      req.body_stream = stream
      http = Net::HTTP.new("127.0.0.1", @port)
      http.read_timeout = 3
      begin
        http.request(req)
      rescue Net::ReadTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE
        nil # the server reads 100 bytes; what Net::HTTP does with the rest is not the point
      end

      expect(stream).to have_received(:read).with(100)
      expect(stream).not_to have_received(:read).with(1025)
    end

    it "inflates a deflate answer no further than the cap, give or take one inflater buffer" do
      bomb = Zlib::Deflate.deflate("z" * 20_000_000)
      inflated = described_class.decompress_body(bomb, "deflate", 1024)

      expect(inflated.bytesize).to be > 1024
      expect(inflated.bytesize).to be <= 1024 + 16 * 1024
    end

    it "inflates a gzip answer no further than the cap, give or take one inflater buffer" do
      bomb = Zlib.gzip("z" * 20_000_000)
      inflated = described_class.decompress_body(bomb, "gzip", 1024)

      expect(inflated.bytesize).to be <= 1024 + 16 * 1024
    end

    it "keeps whole bodies when max_captured_body_bytes is nil", server: { response_body: "w" * 5_000 } do
      Profiler.configuration.max_captured_body_bytes = nil
      Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/whole"))

      entry = entries.first
      expect(entry["response_body"].bytesize).to eq(5_000)
      expect(entry["response_body_truncated"]).to be(false)
    end
  end

  describe "a JSON body longer than max_captured_body_bytes" do
    let(:mask) { Profiler::Redaction::MASK }
    big_json = %({"token":"first-secret-value","items":[#{(1..40_000).map { |i| %({"id":#{i}}) }.join(",")}],"nested":{"token":"last-secret-value"}})

    before do
      Profiler.configuration.max_captured_body_bytes = 256 * 1024
      Profiler.configuration.http_skip_hosts = []
      allow(described_class).to receive(:skip_host?).and_return(false)
    end

    it "keeps the beginning, readable, with its sensitive values masked",
       server: { response_body: big_json, headers: { "Content-Type" => "application/json" } } do
      Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/big"))

      entry = entries.first
      expect(big_json.bytesize).to be > 300_000
      expect(entry["response_body_truncated"]).to be(true)
      expect(entry["response_body"].bytesize).to be_between(256 * 1024 - 8, 256 * 1024)
      expect(entry["response_body"]).to start_with(%({"token":"#{mask}","items":[{"id":1}))
      expect(entry["response_body"]).not_to include("unparseable")
      expect(entry["response_body"]).not_to include("secret-value")
      expect(entry["response_size"]).to eq(big_json.bytesize)
    end

    it "masks a sensitive value that sits in the visible part of a request body" do
      Net::HTTP.new("127.0.0.1", @port).post("/upload", big_json, "Content-Type" => "application/json")

      entry = entries.first
      expect(entry["request_body_truncated"]).to be(true)
      expect(entry["request_body"]).to start_with(%({"token":"#{mask}","items":[{"id":1}))
      expect(entry["request_body"]).not_to include("secret-value")
    end

    it "keeps a form body readable and masked past the limit" do
      form = "token=form-secret&#{(1..30_000).map { |i| "k#{i}=v#{i}" }.join("&")}"
      Net::HTTP.new("127.0.0.1", @port).post("/upload", form, "Content-Type" => "application/x-www-form-urlencoded")

      entry = entries.first
      expect(entry["request_body"]).to start_with("token=#{mask}&k1=v1")
      expect(entry["request_body"].bytesize).to be <= 256 * 1024
    end

    it "masks an invalid JSON with the unparseable label, not the truncated one" do
      Net::HTTP.new("127.0.0.1", @port).post("/upload", %({"token": "t", "a": #{"x" * 300_000}), "Content-Type" => "application/json")

      expect(entries.first["request_body"]).to match(/\A\[FILTERED: unparseable application\/json body, \d+ bytes\]\z/)
    end

    it "says the body is truncated, not unparseable, when only its beginning is known",
       server: { response_body: Zlib.gzip(%({"token":"first-secret-value","pad":"#{"p" * 400_000}"})), headers: { "Content-Type" => "application/json", "Content-Encoding" => "gzip" } } do
      req = Net::HTTP::Get.new("/zip")
      req["Accept-Encoding"] = "gzip"
      Net::HTTP.new("127.0.0.1", @port).request(req)

      body = entries.first["response_body"]
      expect(body).to eq("[FILTERED: truncated application/json body, kept #{256 * 1024} of more than #{256 * 1024} bytes, " \
                         "only its beginning is known, it cannot be redacted]")
    end

    it "masks a body over the redaction ceiling with a clear label instead of passing it through" do
      stub_const("Profiler::Redaction::MAX_REDACTABLE_BODY_BYTES", 300_000)
      Net::HTTP.new("127.0.0.1", @port).post("/upload", %({"token":"first-secret-value","pad":"#{"p" * 400_000}"}), "Content-Type" => "application/json")

      body = entries.first["request_body"]
      expect(body).to start_with("[FILTERED: truncated application/json body, kept #{256 * 1024} of 4")
      expect(body).to end_with("bytes, too large to redact]")
      expect(body).not_to include("first-secret-value")
    end

    it "leaves a JSON body under the limit as it was", server: { response_body: %({"token":"abc","id":7}), headers: { "Content-Type" => "application/json" } } do
      Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/small"))

      entry = entries.first
      expect(entry["response_body"]).to eq(%({"token":"#{mask}","id":7}))
      expect(entry["response_body_truncated"]).to be(false)
    end
  end

  describe "a binary body declared as text" do
    let(:png_like) { "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR".b + (0..255).map(&:chr).join.b }

    it "keeps a response served as text/plain as base64, byte for byte", server: { response_body: "\x89PNG\r\n\x1a\n\x00\x01\xFF\xFE".b } do
      Net::HTTP.get(URI("http://127.0.0.1:#{@port}/blob"))

      entry = entries.first
      expect(entry["response_body_encoding"]).to eq("base64")
      expect(Base64.strict_decode64(entry["response_body"])).to eq("\x89PNG\r\n\x1a\n\x00\x01\xFF\xFE".b)
    end

    it "keeps a font, a protobuf and a gzip answer as base64 whatever their bytes" do
      %w[font/woff2 application/x-protobuf application/gzip].each do |type|
        expect(described_class.process_body("abc", type)[:encoding]).to eq("base64"), type
      end
    end

    it "keeps real text as text, accents included" do
      expect(described_class.process_body("café \u00e9t\u00e9".b, "text/plain")).to eq(body: "café été", encoding: "text")
    end
  end

  describe "a response read as a stream" do
    it "records no body rather than the inspect of the adapter", server: { response_body: "streamed payload" } do
      chunks = []
      Net::HTTP.start("127.0.0.1", @port) do |http|
        http.request(Net::HTTP::Get.new("/stream")) { |response| response.read_body { |chunk| chunks << chunk } }
      end

      entry = entries.first
      expect(chunks.join).to eq("streamed payload")
      expect(entry["response_body"]).to be_nil
      expect(entry["response_body_not_captured"]).to be(true)
      expect(entry["response_size"]).to eq("streamed payload".bytesize)
    end
  end
end
