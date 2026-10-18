# frozen_string_literal: true

require "spec_helper"
require "socket"
require "stringio"
require "zlib"
require "profiler/instrumentation/net_http_instrumentation"

# The failure paths of the Net::HTTP patch: a call that raises is recorded as failed and still
# raises for the caller, and every helper that reads something it does not control falls back
# instead of raising into the application.
RSpec.describe Profiler::Instrumentation::NetHttpInstrumentation, "failure paths" do
  let(:collector) { Profiler::Collectors::HttpCollector.new(build_profile) }

  around do |example|
    Profiler.configure do |c|
      c.enabled = true
      c.track_http = true
    end
    collector.subscribe
    example.run
  ensure
    collector.unsubscribe
  end

  def entries
    collector.collect
    collector.panel_content[:requests]
  end

  def closed_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  describe "a call that raises" do
    # The patch wraps Net::HTTP#request: a connection refused in #start never reaches it, so
    # there is nothing in flight to fail, and nothing is left half recorded.
    it "raises a refused connection without leaving a request in flight" do
      port = closed_port

      expect { Net::HTTP.get(URI("http://127.0.0.1:#{port}/down")) }.to raise_error(SystemCallError)

      expect(entries.reject { |e| e["status"] == 0 && e["in_flight"] == false }).to be_empty
      expect(entries.none? { |e| e["in_flight"] }).to be(true)
    end

    it "raises on a timeout and records it as failed" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      http = Net::HTTP.new("127.0.0.1", port)
      http.read_timeout = 0.2

      begin
        expect { http.get("/slow") }.to raise_error(Net::ReadTimeout)
      ensure
        server.close
      end

      expect(entries.last).to include("status" => 0, "in_flight" => false)
      expect(entries.last["error"]).not_to be_nil
    end

    it "clears the recording flag, so that the next call on the thread is recorded" do
      port = closed_port
      expect { Net::HTTP.get(URI("http://127.0.0.1:#{port}/")) }.to raise_error(SystemCallError)

      expect(Thread.current[:profiler_http_recording]).to be(false)
    end
  end

  describe ".skip_host_pattern?" do
    it "matches nothing for a pattern that is neither a String nor a Regexp" do
      expect(described_class.skip_host_pattern?(nil, "example.com")).to be(false)
      expect(described_class.skip_host_pattern?(42, "example.com")).to be(false)
    end
  end

  describe ".master_address" do
    it "is nil for an empty or missing URL" do
      expect(described_class.master_address(nil)).to be_nil
      expect(described_class.master_address("")).to be_nil
    end

    it "is nil for a URL that cannot be parsed" do
      expect(described_class.master_address("http://bad host/")).to be_nil
    end

    it "is nil for a URL without a host" do
      expect(described_class.master_address("not-a-url")).to be_nil
    end

    it "gives the host without the brackets of an IPv6 literal, and the port" do
      expect(described_class.master_address("http://[::1]:4000/")).to eq(["::1", 4000])
    end
  end

  describe ".capture_request_body" do
    def request(stream, headers = {})
      req = Net::HTTP::Post.new("/upload", headers)
      req.body_stream = stream
      req
    end

    it "does not raise when the stream fails while being read, and says it was not captured" do
      stream = StringIO.new("payload")
      allow(stream).to receive(:read).and_raise(IOError, "closed stream")
      req = request(stream, "Content-Length" => "7")

      result = described_class.capture_request_body(req, nil, 1024)

      expect(result).to include(content: nil, size: 7, not_captured: true, truncated: false)
    end

    it "puts the stream back where it was even though the read failed" do
      stream = StringIO.new("payload")
      stream.pos = 3
      allow(stream).to receive(:read).and_raise(IOError, "boom")

      described_class.capture_request_body(request(stream), nil, 1024)

      expect(stream.pos).to eq(3)
    end

    it "reports no size when the stream fails and no Content-Length was declared" do
      stream = StringIO.new("payload")
      allow(stream).to receive(:read).and_raise(Errno::EIO)

      result = described_class.capture_request_body(request(stream), nil, 1024)

      expect(result).to include(content: nil, size: nil, not_captured: true)
    end
  end

  describe ".remaining_size" do
    it "is nil for a stream that does not know its size" do
      expect(described_class.remaining_size(Object.new, 0)).to be_nil
    end

    it "is nil when asking for the size raises" do
      stream = instance_double(StringIO)
      allow(stream).to receive(:respond_to?).with(:size).and_return(true)
      allow(stream).to receive(:size).and_raise(IOError, "closed")

      expect(described_class.remaining_size(stream, 0)).to be_nil
    end

    it "never goes below zero" do
      expect(described_class.remaining_size(StringIO.new("abc"), 10)).to eq(0)
    end
  end

  describe ".rewindable?" do
    it "is false when the stream refuses to say what it is" do
      stream = StringIO.new("abc")
      allow(stream).to receive(:stat).and_raise(IOError, "closed")

      expect(described_class.rewindable?(stream)).to be(false)
    end

    it "is false for an object that cannot seek" do
      expect(described_class.rewindable?(Object.new)).to be(false)
    end
  end

  describe ".decompress_body" do
    it "gives a corrupt gzip body back untouched" do
      expect(described_class.decompress_body("not gzip at all", "gzip", 1024)).to eq("not gzip at all")
    end

    it "gives a corrupt deflate body back untouched, with no limit" do
      expect(described_class.decompress_body("garbage", "deflate")).to eq("garbage")
    end

    it "leaves an unknown content encoding alone" do
      expect(described_class.decompress_body("abc", "br", 1024)).to eq("abc")
    end

    it "leaves an empty or nil body alone" do
      expect(described_class.decompress_body("", "gzip", 1024)).to eq("")
      expect(described_class.decompress_body(nil, "gzip", 1024)).to be_nil
    end

    it "inflates a whole gzip body when there is no limit" do
      expect(described_class.decompress_body(Zlib.gzip("hello"), "x-gzip")).to eq("hello")
    end
  end
end
