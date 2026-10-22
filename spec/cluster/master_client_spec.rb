# frozen_string_literal: true

require "spec_helper"
require "webmock"
require "webmock/rspec/matchers"
require "profiler/cluster/master_client"

RSpec.describe Profiler::Cluster::MasterClient do
  include WebMock::API
  include WebMock::Matchers

  let(:register_url) { "http://127.0.0.1:3000/_profiler/api/cluster/register" }
  let(:heartbeat_url) { "http://127.0.0.1:3000/_profiler/api/cluster/heartbeat" }
  let(:secret) { "spec-secret-0123456789abcdefghijklmnop" }
  let(:client) { described_class.new }
  let(:log) { StringIO.new }

  before do
    WebMock.enable!
    WebMock.disable_net_connect!
    Profiler.configure do |config|
      config.master_url = "http://127.0.0.1:3000"
      config.self_url = "http://127.0.0.1:3001"
      config.name = "worker-1"
      config.cluster_secret = secret
      config.cluster_heartbeat_interval = 0.01
      config.logger = Logger.new(log)
    end
  end

  after do
    @heartbeat_thread&.kill
    @heartbeat_thread&.join(1)
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
  end

  # Starts the client and keeps its heartbeat thread, for the after block to stop it.
  def start_client
    allow(client).to receive(:start_heartbeat_thread).and_wrap_original do |original|
      @heartbeat_thread = original.call
    end
    client.start
  end

  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
  end

  def requests_to(url)
    WebMock::RequestRegistry.instance.times_executed(WebMock::RequestPattern.new(:post, url))
  end

  describe "#start" do
    it "sets write_timeout along with open_timeout and read_timeout" do
      http = instance_double(Net::HTTP, post: instance_double(Net::HTTPResponse, code: "201", body: ""))
      allow(Net::HTTP).to receive(:start).and_yield(http)

      client.send(:register!)

      expect(Net::HTTP).to have_received(:start)
        .with("127.0.0.1", 3000, hash_including(open_timeout: 3, read_timeout: 5, write_timeout: 5))
    end

    it "registers with the master, then sends a heartbeat on each interval" do
      stub_request(:post, register_url).to_return(status: 201)
      stub_request(:post, heartbeat_url).to_return(status: 200)

      start_client
      wait_until { requests_to(heartbeat_url) >= 2 }

      expect(a_request(:post, register_url).with(
        body: { name: "worker-1", url: "http://127.0.0.1:3001" }.to_json,
        headers: { "Content-Type" => "application/json", Profiler::FORGERY_PROTECTION_HEADER => "1",
                   "X-Profiler-Cluster-Secret" => secret }
      )).to have_been_made.once
      expect(a_request(:post, heartbeat_url).with(body: { name: "worker-1" }.to_json)).to have_been_made.at_least_twice
      expect(log.string).to include("Cluster: Registered with master at http://127.0.0.1:3000 as 'worker-1'")
    end

    it "returns before any request is made, the registration belongs to the heartbeat thread" do
      stub_request(:post, register_url).to_return(status: 201)
      stub_request(:post, heartbeat_url).to_return(status: 200)
      allow(client).to receive(:start_heartbeat_thread)

      client.start

      expect(a_request(:post, register_url)).not_to have_been_made
    end

    it "does not wait for a master that never answers" do
      gate = Queue.new
      stub_request(:post, register_url).to_return { gate.pop && { status: 201 } }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      start_client
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      gate << true

      expect(elapsed).to be < 1
    end

    it "gives the master short timeouts" do
      http = instance_double(Net::HTTP, post: instance_double(Net::HTTPResponse, code: "201", body: ""))
      allow(Net::HTTP).to receive(:start).and_yield(http)

      client.send(:register!)
      client.send(:heartbeat!)

      expect(Net::HTTP).to have_received(:start)
        .with("127.0.0.1", 3000, hash_including(open_timeout: 3, read_timeout: 5, use_ssl: false)).twice
    end

    it "keeps running when the master is unreachable at startup, and registers once it answers" do
      stub_request(:post, register_url).to_raise(Errno::ECONNREFUSED).then.to_return(status: 201)
      stub_request(:post, heartbeat_url).to_return(status: 200)

      start_client
      wait_until { requests_to(heartbeat_url) >= 1 }

      expect(log.string).to include("Cluster: communication with the master failed, will retry")
      expect(log.string).to include("Errno::ECONNREFUSED")
      expect(log.string).to include("Cluster: Re-registered with master after previous failure")
      expect(a_request(:post, register_url)).to have_been_made.twice
    end

    it "treats a timeout like any network error, and retries on the next interval" do
      stub_request(:post, register_url).to_timeout.then.to_return(status: 201)
      stub_request(:post, heartbeat_url).to_return(status: 200)

      start_client
      wait_until { requests_to(heartbeat_url) >= 1 }

      expect(log.string).to match(/communication with the master failed.*Net::OpenTimeout/m)
      expect(log.string).to include("Re-registered with master after previous failure")
    end

    it "registers again after a rejected heartbeat" do
      stub_request(:post, register_url).to_return(status: 201)
      stub_request(:post, heartbeat_url).to_return(status: 404).then.to_return(status: 200)

      start_client
      wait_until { requests_to(register_url) >= 2 && requests_to(heartbeat_url) >= 2 }

      expect(log.string).to include("Cluster: communication with the master failed, will retry")
      expect(log.string).to include("Heartbeat rejected 404")
      expect(log.string).to include("Re-registered with master after previous failure")
    end

    it "reports a refused registration with the start of the master's answer" do
      stub_request(:post, register_url).to_return(status: 403, body: "x" * 300)

      start_client
      wait_until { log.string.include?("Master returned 403") }

      expect(log.string).to include("Master returned 403: #{"x" * 200}")
      expect(log.string).not_to include("x" * 201)
    end

    it "logs configuration errors via log_error_once, appearing only once despite repeated heartbeat cycles" do
      Profiler.configuration.cluster_secret = nil
      Profiler.configuration.cluster_require_secret = true
      Profiler.configuration.cluster_heartbeat_interval = 0.01

      start_client
      wait_until { log.string.include?("failed due to configuration") }

      sleep 0.1  # Allow multiple heartbeat cycles (interval is 0.01s)

      config_error_count = log.string.scan(/failed due to configuration/).count
      expect(config_error_count).to eq(1)
      expect(log.string).not_to include("will retry")
    end

    it "logs transient network errors on each cycle with log_warn, unlike configuration errors" do
      stub_request(:post, register_url).to_raise(Errno::ECONNREFUSED).times(4).then.to_return(status: 201)
      stub_request(:post, heartbeat_url).to_return(status: 200)

      start_client
      wait_until { requests_to(register_url) >= 3 }

      network_error_count = log.string.scan(/Errno::ECONNREFUSED/).count
      expect(network_error_count).to be >= 2
      expect(log.string).to include("will retry")
    end
  end

  describe "requests the client refuses to send" do
    it "sends nothing to a remote master over plain HTTP" do
      Profiler.configuration.master_url = "http://master.example:3000"

      expect { client.send(:register!) }.to raise_error(/uses plain HTTP to a host that is not a loopback address/)
      expect { client.send(:heartbeat!) }.to raise_error(/uses plain HTTP/)
      expect(a_request(:any, /master\.example/)).not_to have_been_made
    end

    it "sends nothing when the master requires a secret and none is configured" do
      Profiler.configuration.cluster_secret = nil
      Profiler.configuration.cluster_require_secret = true

      expect { client.send(:register!) }
        .to raise_error("No config.cluster_secret is configured: the master refuses registration without a secret")
      expect(a_request(:any, /127\.0\.0\.1/)).not_to have_been_made
    end
  end

  # A heartbeat thread started from a request thread (a fork taken mid-request) would run the
  # request's context wrapper for the life of the process: it would hold the request's collectors
  # and record the cluster's own HTTP calls into them.
  describe "a heartbeat thread started while a request is profiled" do
    let(:collector) { Object.new }

    after { Thread.current[:profiler_http_collector] = nil }

    it "does not carry the request's collectors" do
      stub_request(:post, register_url).to_return(status: 201)
      stub_request(:post, heartbeat_url).to_return(status: 200)
      seen = Queue.new
      allow(client).to receive(:heartbeat!) { seen << Thread.current[:profiler_http_collector] }

      Thread.current[:profiler_http_collector] = collector
      start_client
      Thread.current[:profiler_http_collector] = nil

      expect(seen.pop).to be_nil
    end
  end

  describe "after fork" do
    before { skip "Process.fork is not available on this platform" unless Process.respond_to?(:fork) }

    # A thread does not survive fork: a forked worker inherits the client object but not its
    # heartbeat loop. The Process._fork hook starts one in the child, which registers again, while
    # the parent keeps its own.
    it "keeps the heartbeat in the parent, and starts one in the child that registers again" do
      stub_request(:post, register_url).to_return(status: 201)
      stub_request(:post, heartbeat_url).to_return(status: 200)
      start_client
      wait_until { requests_to(heartbeat_url) >= 1 }

      reader, writer = IO.pipe
      pid = fork do
        reader.close
        registered_before = requests_to(register_url)
        wait_until { requests_to(register_url) > registered_before }
        writer.write([@heartbeat_thread.alive?, requests_to(register_url) - registered_before].join(","))
        writer.close
        exit!(0)
      end
      writer.close
      child_report = reader.read
      Process.wait(pid)

      expect(child_report).to eq("true,1")
      expect(@heartbeat_thread).to be_alive
      sent = requests_to(heartbeat_url)
      wait_until { requests_to(heartbeat_url) > sent }
    end
  end

  describe "a fork" do
    before do
      Profiler.configuration.cluster_heartbeat_interval = 3600
      stub_request(:post, register_url).to_return(status: 201)
    end

    after { described_class.current = nil }

    # Runs the block in a forked child and returns what it wrote, as a String.
    def in_forked_child
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        writer.write(yield.to_s)
        writer.close
        exit!(0)
      end
      writer.close
      result = reader.read
      Process.wait(pid)
      result
    end

    it "gets a heartbeat thread of its own in the child, which registers again" do
      start_client
      parent_thread = client.instance_variable_get(:@thread)

      result = in_forked_child do
        child_thread = client.instance_variable_get(:@thread)
        [child_thread.equal?(parent_thread), child_thread.alive?, client.instance_variable_get(:@registered)].inspect
      end

      expect(result).to eq("[false, true, false]")
      expect(parent_thread).to be_alive
    end

    it "does not start a second thread while one is alive" do
      start_client
      thread = client.instance_variable_get(:@thread)

      client.restart_after_fork

      expect(client.instance_variable_get(:@thread)).to equal(thread)
    end

    it "does nothing in the child of a process that never started the client" do
      expect { described_class.restart_after_fork }.not_to raise_error
      expect(described_class.current).to be_nil
    end

    it "warns when a cluster_master forks and restarts the heartbeat" do
      Profiler.configuration.cluster_master = true
      start_client

      result = in_forked_child do
        client.restart_after_fork
        log.string
      end

      expect(result).to include("Cluster: master process forked: each worker maintains a separate slave registry")
    end

    it "warns when a pure master (not a slave) forks" do
      Profiler.configuration.cluster_master = true
      Profiler.configuration.master_url = nil
      described_class.install_pure_master_fork_hook!

      result = in_forked_child do
        log.string
      end

      expect(result).to include("Cluster: master process forked: each worker maintains a separate slave registry")
      expect(described_class.current).to be_nil
    end
  end
end
