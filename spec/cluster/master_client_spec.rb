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

    it "keeps running when the master is unreachable at startup, and registers once it answers" do
      stub_request(:post, register_url).to_raise(Errno::ECONNREFUSED).then.to_return(status: 201)
      stub_request(:post, heartbeat_url).to_return(status: 200)

      start_client
      wait_until { requests_to(heartbeat_url) >= 1 }

      expect(log.string).to include("Cluster: could not register with master at startup, will retry in the heartbeat loop")
      expect(log.string).to include("Errno::ECONNREFUSED")
      expect(log.string).to include("Cluster: Re-registered with master after previous failure")
      expect(a_request(:post, register_url)).to have_been_made.twice
    end

    it "treats a timeout like any network error, and retries on the next interval" do
      stub_request(:post, register_url).to_timeout.then.to_return(status: 201)
      stub_request(:post, heartbeat_url).to_return(status: 200)

      start_client
      wait_until { requests_to(heartbeat_url) >= 1 }

      expect(log.string).to match(/could not register with master at startup.*Net::OpenTimeout/m)
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

      expect(log.string).to include("Master returned 403: #{"x" * 200}")
      expect(log.string).not_to include("x" * 201)
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

  describe "after fork" do
    before { skip "Process.fork is not available on this platform" unless Process.respond_to?(:fork) }

    # A thread does not survive fork: a forked worker inherits the client object but not its
    # heartbeat loop, so the parent alone keeps the master informed, and the child sends nothing.
    it "keeps the heartbeat in the parent, and leaves none running in the child" do
      stub_request(:post, register_url).to_return(status: 201)
      stub_request(:post, heartbeat_url).to_return(status: 200)
      start_client
      wait_until { requests_to(heartbeat_url) >= 1 }

      reader, writer = IO.pipe
      pid = fork do
        reader.close
        sent_before = requests_to(heartbeat_url)
        sleep 0.1
        writer.write([@heartbeat_thread.alive?, requests_to(heartbeat_url) - sent_before].join(","))
        writer.close
        exit!(0)
      end
      writer.close
      child_report = reader.read
      Process.wait(pid)

      expect(child_report).to eq("false,0")
      expect(@heartbeat_thread).to be_alive
      sent = requests_to(heartbeat_url)
      wait_until { requests_to(heartbeat_url) > sent }
    end
  end
end
