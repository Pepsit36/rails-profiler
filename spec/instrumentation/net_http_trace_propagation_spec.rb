# frozen_string_literal: true

require "spec_helper"
require "socket"
require "profiler/instrumentation/net_http_instrumentation"
require "profiler/cluster/slave_registry"
require "profiler/cluster/slave_proxy"

# The traceparent header on outgoing calls, made while a profiled request runs on the thread.
RSpec.describe Profiler::Instrumentation::NetHttpInstrumentation, "trace propagation" do
  let(:trace_id) { "0af7651916cd43dd8448eb211c80319c" }

  # Answers every request with 200 and keeps the head of each.
  around do |example|
    @heads = []
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new do
      loop do
        client = @server.accept
        head = +""
        head << client.readline until head.end_with?("\r\n\r\n")
        @heads << head
        client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        client.close
      rescue IOError, Errno::EBADF
        break
      end
    end
    @port = @server.addr[1]
    Profiler.configure { |c| c.enabled = true }
    example.run
  ensure
    Profiler::CurrentContext.clear
    @server&.close
    @thread&.kill
  end

  def header(name)
    @heads.last[/^#{name}: *(.+?)\r$/i, 1]
  end

  it "sends the trace id of the request in progress with a span id of its own" do
    Profiler::CurrentContext.trace_id = trace_id
    Net::HTTP.get(URI("http://127.0.0.1:#{@port}/x"))

    expect(header("traceparent")).to match(/\A00-#{trace_id}-\h{16}-01\z/)
  end

  it "reuses the span id from CurrentContext" do
    span_id = "c9c7ff12d331cce1"
    Profiler::CurrentContext.trace_id = trace_id
    Profiler::CurrentContext.span_id = span_id
    Net::HTTP.get(URI("http://127.0.0.1:#{@port}/x"))

    expect(header("traceparent")).to eq("00-#{trace_id}-#{span_id}-01")
  end

  it "uses a new span id for each call when span_id is not set" do
    Profiler::CurrentContext.trace_id = trace_id
    2.times { Net::HTTP.get(URI("http://127.0.0.1:#{@port}/x")) }

    spans = @heads.map { |h| h[/^traceparent: *\S+-(\h{16})-01/i, 1] }
    expect(spans.uniq.size).to eq(2)
  end

  it "propagates incoming trace flags" do
    span_id = "c9c7ff12d331cce1"
    Profiler::CurrentContext.trace_id = trace_id
    Profiler::CurrentContext.span_id = span_id
    Profiler::CurrentContext.trace_flags = "00"
    Net::HTTP.get(URI("http://127.0.0.1:#{@port}/x"))

    expect(header("traceparent")).to eq("00-#{trace_id}-#{span_id}-00")
  end

  it "defaults to sampling flag 01 when no trace_flags are set" do
    span_id = "c9c7ff12d331cce1"
    Profiler::CurrentContext.trace_id = trace_id
    Profiler::CurrentContext.span_id = span_id
    Profiler::CurrentContext.trace_flags = nil
    Net::HTTP.get(URI("http://127.0.0.1:#{@port}/x"))

    expect(header("traceparent")).to eq("00-#{trace_id}-#{span_id}-01")
  end

  it "never overwrites a traceparent the application set" do
    Profiler::CurrentContext.trace_id = trace_id
    own = "00-#{'a' * 32}-#{'b' * 16}-00"
    request = Net::HTTP::Get.new("/x", "traceparent" => own)
    Net::HTTP.start("127.0.0.1", @port) { |http| http.request(request) }

    expect(header("traceparent")).to eq(own)
  end

  it "sends none outside a profiled request" do
    Net::HTTP.get(URI("http://127.0.0.1:#{@port}/x"))

    expect(header("traceparent")).to be_nil
  end

  it "sends none to a host excluded from the instrumentation" do
    Profiler.configuration.http_skip_hosts = ["127.0.0.1"]
    Profiler::CurrentContext.trace_id = trace_id
    Net::HTTP.get(URI("http://127.0.0.1:#{@port}/x"))

    expect(header("traceparent")).to be_nil
  end

  it "reaches the master's calls to a slave, which are untracked" do
    Profiler.configure do |config|
      config.cluster_secret = "spec-secret-0123456789abcdefghijklmnop"
      config.cluster_allowed_slave_urls = ["http://127.0.0.1:#{@port}"]
      config.cluster_allow_insecure_http = true
    end
    Profiler.instance_variable_set(:@slave_registry, Profiler::Cluster::SlaveRegistry.new)
    Profiler.slave_registry.register(name: "payment", url: "http://127.0.0.1:#{@port}")
    Profiler::CurrentContext.trace_id = trace_id

    Profiler::Cluster::SlaveProxy.new("payment").get_json("/_profiler/api/profiles")

    expect(header("traceparent")).to match(/\A00-#{trace_id}-\h{16}-01\z/)
  end
end
