# frozen_string_literal: true

require "spec_helper"
require "webmock"
require "webmock/rspec/matchers"

RSpec.describe Profiler::Peers::PeerProxy do
  include WebMock::API
  include WebMock::Matchers

  let(:token) { "peer-token-0123456789abcdefghijklmnopqr" }
  let(:profile_token) { "a" * 32 }

  before do
    WebMock.enable!
    WebMock.disable_net_connect!
    Profiler.configure do |c|
      c.peers = [{ name: "staging", url: "https://staging.example.com" }]
      c.peer_token = token
    end
  end

  after do
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  it "refuses a node that is not in config.peers, without any HTTP call" do
    expect { described_class.new("prod") }.to raise_error(Profiler::Error, /Unknown node "prod"/)
    expect(WebMock).not_to have_requested(:any, /.*/)
  end

  it "refuses to be built when peers are configured but peer_token is not" do
    Profiler.configuration.peer_token = nil
    expect { described_class.new("staging") }.to raise_error(Profiler::Error, /No config.peer_token.*refused/)
    expect(WebMock).not_to have_requested(:any, /.*/)
  end

  it "refuses a too short peer_token" do
    Profiler.configuration.peer_token = "short"
    expect { described_class.new("staging") }.to raise_error(Profiler::Error, /shorter than 32/)
  end

  it "has short timeouts" do
    expect(described_class::OPEN_TIMEOUT).to eq(5)
    expect(described_class::READ_TIMEOUT).to eq(10)
  end

  describe "#load" do
    subject(:proxy) { described_class.new("staging") }

    it "reads the profile from the configured URL, with the peer token header" do
      body = build_profile(token: profile_token, path: "/x").to_h.to_json
      stub = stub_request(:get, "https://staging.example.com/_profiler/api/profiles/#{profile_token}")
             .with(headers: { "X-Profiler-Peer-Token" => token, "X-Profiler-Request" => "1" })
             .to_return(status: 200, body: body)

      profile = proxy.load(profile_token)
      expect(profile.path).to eq("/x")
      expect(stub).to have_been_requested
    end

    it "does not ask a peer for a token the gem could not have issued" do
      expect(proxy.load("../../etc/passwd")).to be_nil
      expect(WebMock).not_to have_requested(:any, /.*/)
    end

    it "returns nil on a 404" do
      stub_request(:get, %r{staging.example.com}).to_return(status: 404, body: "{}")
      expect(proxy.load(profile_token)).to be_nil
    end

    it "explains a refusal by the peer" do
      stub_request(:get, %r{staging.example.com}).to_return(status: 403, body: "{}")
      expect { proxy.load(profile_token) }.to raise_error(Profiler::Error, /refused the request \(403\).*peer_token/)
    end

    it "does not follow a redirect" do
      stub_request(:get, %r{staging.example.com}).to_return(status: 302, headers: { "Location" => "https://evil.example.com" })
      expect { proxy.load(profile_token) }.to raise_error(Profiler::Error, /redirect not followed/)
      expect(WebMock).not_to have_requested(:get, /evil/)
    end

    it "reports an unreachable peer clearly" do
      stub_request(:get, %r{staging.example.com}).to_timeout
      expect { proxy.load(profile_token) }.to raise_error(Profiler::Error, /Peer "staging" is unreachable/)
      stub_request(:get, %r{staging.example.com}).to_raise(Errno::ECONNREFUSED)
      expect { proxy.load(profile_token) }.to raise_error(Profiler::Error, /unreachable/)
    end

    it "rejects an answer that is not a profile" do
      stub_request(:get, %r{staging.example.com}).to_return(status: 200, body: "<html>")
      expect { proxy.load(profile_token) }.to raise_error(Profiler::Error, /not JSON/)
      stub_request(:get, %r{staging.example.com}).to_return(status: 200, body: "{}")
      expect { proxy.load(profile_token) }.to raise_error(Profiler::Error, /unexpected answer/)
    end
  end
end
