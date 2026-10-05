# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::LocalRequest do
  def request(env)
    Rack::Request.new(Rack::MockRequest.env_for("http://localhost/_profiler/", env))
  end

  describe ".loopback_address?" do
    it "accepts the IPv4 and IPv6 loopback ranges" do
      expect(described_class.loopback_address?("127.0.0.1")).to be(true)
      expect(described_class.loopback_address?("127.255.0.9")).to be(true)
      expect(described_class.loopback_address?("::1")).to be(true)
      expect(described_class.loopback_address?("[::1]")).to be(true)
      expect(described_class.loopback_address?("::ffff:127.0.0.1")).to be(true)
    end

    it "refuses everything else" do
      ["10.0.0.5", "172.17.0.1", "192.168.1.2", "::ffff:10.0.0.5", "fe80::1%eth0", "0.0.0.0",
       "unknown", "", nil].each do |address|
        expect(described_class.loopback_address?(address)).to be(false), address.inspect
      end
    end
  end

  describe ".denial_reason" do
    # The test environment, which the request specs load, also accepts the test hosts.
    before do
      if defined?(Rails) && Rails.respond_to?(:env)
        allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))
      end
    end

    it "works on a plain Rack::Request" do
      env = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost:3000" }
      expect(described_class.denial_reason(request(env))).to be_nil
    end

    it "lets REMOTE_ADDR decide alone when there is no Host header" do
      expect(described_class.denial_reason(request("REMOTE_ADDR" => "127.0.0.1"))).to be_nil
      expect(described_class.denial_reason(request("REMOTE_ADDR" => "10.0.0.5"))).to include("REMOTE_ADDR")
    end

    it "names a missing REMOTE_ADDR" do
      expect(described_class.denial_reason(request("REMOTE_ADDR" => "")))
        .to eq("REMOTE_ADDR (missing) is not a loopback address")
    end

    it "refuses an obfuscated Forwarded identifier" do
      env = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_FORWARDED" => "for=_hidden" }
      expect(described_class.denial_reason(request(env))).to include("Forwarded header")
    end

    it "refuses a non-local X-Real-IP" do
      env = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_X_REAL_IP" => "203.0.113.9" }
      expect(described_class.denial_reason(request(env))).to include("X-Real-IP header")
    end

    it "accepts a loopback Host with a port" do
      env = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "127.0.0.1:3000" }
      expect(described_class.denial_reason(request(env))).to be_nil
    end

    it "refuses a lookalike of localhost" do
      env = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost.evil.example" }
      expect(described_class.denial_reason(request(env))).to include("Host header")
    end

    it "accepts the reserved test hosts in the test environment only, with the address checks" do
      stub_const("Rails", double("Rails", env: ActiveSupport::EnvironmentInquirer.new("test"),
                                          application: nil))
      host = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "www.example.com" }
      remote = host.merge("REMOTE_ADDR" => "10.0.0.5")
      evil = host.merge("HTTP_HOST" => "evil.com")

      expect(described_class.denial_reason(request(host))).to be_nil
      expect(described_class.denial_reason(request(remote))).to include("REMOTE_ADDR")
      expect(described_class.denial_reason(request(evil))).to include("Host header")
    end

    # Only "host", "host:digits", "[ipv6]" and "[ipv6]:digits" lose their port; anything
    # else is taken as is, so it is refused unless it is itself local.
    it "refuses malformed forms with a port" do
      ["127.0.0.1:abc", "[::1]10.0.0.5", "[::1]evil.com", "127.0.0.1:", "[::1"].each do |value|
        env = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_X_FORWARDED_FOR" => value }
        expect(described_class.denial_reason(request(env))).to include("X-Forwarded-For"), value
      end

      ["localhost:evil.com", "[::1]evil.com", "localhost:3000:80", "127.0.0.1%evil.com"].each do |value|
        env = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => value }
        expect(described_class.denial_reason(request(env))).to include("Host header"), value
      end
    end

    it "accepts well-formed forms with a port" do
      ["127.0.0.1:5555", "[::1]:5556", "::1", "[::1]", "127.0.0.1"].each do |value|
        env = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_X_FORWARDED_FOR" => value }
        expect(described_class.denial_reason(request(env))).to be_nil, value
      end

      ["localhost:3000", "[::1]:3000", "::1", "127.0.0.1:3000"].each do |value|
        env = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => value }
        expect(described_class.denial_reason(request(env))).to be_nil, value
      end
    end
  end

  describe ".warn_once" do
    before { described_class.reset_warning! }

    it "warns a single time" do
      allow(Profiler).to receive(:log_warn)
      allow(Rails).to receive(:logger).and_return(nil) if defined?(Rails)

      described_class.warn_once("first")
      described_class.warn_once("second")

      expect(Profiler).to have_received(:log_warn).once.with(/first/)
    end
  end
end
