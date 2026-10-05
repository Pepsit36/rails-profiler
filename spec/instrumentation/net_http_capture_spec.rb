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
        length = head[/content-length: *(\d+)/i, 1].to_i
        received << client.read(length)
        extra = headers.map { |name, value| "#{name}: #{value}\r\n" }.join
        client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n#{extra}" \
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

    it "keeps whole bodies when max_captured_body_bytes is nil", server: { response_body: "w" * 5_000 } do
      Profiler.configuration.max_captured_body_bytes = nil
      Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/whole"))

      entry = entries.first
      expect(entry["response_body"].bytesize).to eq(5_000)
      expect(entry["response_body_truncated"]).to be(false)
    end
  end
end
