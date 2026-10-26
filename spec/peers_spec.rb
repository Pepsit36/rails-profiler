# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Peers do
  let(:token) { "peer-token-0123456789abcdefghijklmnopqr" }

  def configure(peers:, token: self.token, insecure: false)
    Profiler.configure do |c|
      c.peers = peers
      c.peer_token = token
      c.peer_allow_insecure_http = insecure
    end
  end

  it "has no peers by default, so nothing is ever called" do
    expect(Profiler::Configuration.new.peers).to eq([])
    expect(described_class.all).to eq([])
    expect(described_class.names).to eq([])
  end

  describe ".find!" do
    it "returns the configured peer, with a normalized URL" do
      configure(peers: [{ name: "staging", url: "https://Staging.example.com:443/" }])
      peer = described_class.find!("staging")
      expect(peer.url).to eq("https://staging.example.com")
    end

    it "raises a clear error for a node that is not in config.peers" do
      configure(peers: [{ name: "staging", url: "https://staging.example.com" }])
      expect { described_class.find!("prod") }
        .to raise_error(Profiler::Error, /Unknown node "prod".*not in config.peers.*known nodes: staging/)
    end

    it "never turns a URL into a peer" do
      configure(peers: [{ name: "staging", url: "https://staging.example.com" }])
      expect { described_class.find!("https://evil.example.com") }.to raise_error(Profiler::Error, /Unknown node/)
    end

    it "says config.peers is empty when it is" do
      expect { described_class.find!("staging") }.to raise_error(Profiler::Error, /config.peers is empty/)
    end
  end

  describe "validation of the list" do
    it "refuses plain HTTP to a non-loopback host" do
      configure(peers: [{ name: "p", url: "http://staging.internal" }])
      expect { described_class.all }.to raise_error(Profiler::Error, /HTTPS is required/)
    end

    it "accepts plain HTTP when explicitly allowed, and for loopback" do
      configure(peers: [{ name: "p", url: "http://staging.internal" }], insecure: true)
      expect(described_class.names).to eq(["p"])
      configure(peers: [{ name: "l", url: "http://127.0.0.1:3001" }])
      expect(described_class.names).to eq(["l"])
    end

    it "refuses user info, a query and a non-http scheme" do
      ["https://user:pw@x.example.com", "https://x.example.com/?a=1", "file:///etc/passwd", "not a url"].each do |url|
        configure(peers: [{ name: "p", url: url }])
        expect { described_class.all }.to raise_error(Profiler::Error, /not a valid http\(s\) URL/)
      end
    end

    it "refuses reserved, malformed and duplicate names" do
      configure(peers: [{ name: "local", url: "https://a.example.com" }])
      expect { described_class.all }.to raise_error(Profiler::Error, /name/)
      configure(peers: [{ name: "a b", url: "https://a.example.com" }])
      expect { described_class.all }.to raise_error(Profiler::Error, /name/)
      configure(peers: [{ name: "a", url: "https://a.example.com" }, { name: "a", url: "https://b.example.com" }])
      expect { described_class.all }.to raise_error(Profiler::Error, /used twice/)
    end

    it "refuses entries that are not hashes" do
      configure(peers: ["https://a.example.com"])
      expect { described_class.all }.to raise_error(Profiler::Error, /must be a Hash/)
    end
  end

  describe "the token" do
    it "is a problem when absent or too short" do
      configure(peers: [], token: nil)
      expect(described_class.token_problem).to match(/No config.peer_token/)
      configure(peers: [], token: "short")
      expect(described_class.token_problem).to match(/shorter than 32/)
      configure(peers: [])
      expect(described_class.token_problem).to be_nil
    end

    it "is a problem when surrounded by spaces or newlines" do
      configure(peers: [], token: " #{"k" * 32} ")
      expect(described_class.configured_token?).to be(false)
      expect(described_class.token_problem).to match(/surrounded by spaces or newlines/)

      configure(peers: [], token: "\n#{"k" * 32}\n")
      expect(described_class.configured_token?).to be(false)
      expect(described_class.token_problem).to match(/surrounded by spaces or newlines/)
    end

    it "is compared in constant time and never accepted when unconfigured" do
      configure(peers: [])
      expect(described_class.valid_token?(token)).to be true
      expect(described_class.valid_token?("wrong")).to be false
      expect(described_class.valid_token?(nil)).to be false
      configure(peers: [], token: nil)
      expect(described_class.valid_token?("")).to be false
      expect(described_class.valid_token?(nil)).to be false
    end

    it "is warned about once peers are configured without it" do
      configure(peers: [{ name: "p", url: "https://a.example.com" }], token: nil)
      expect(Profiler).to receive(:log_warn).with(/Peers: No config.peer_token/, anything)
      described_class.warn_about_configuration(nil)
    end

    it "is not warned about without peers" do
      configure(peers: [], token: nil)
      expect(Profiler).not_to receive(:log_warn)
      described_class.warn_about_configuration(nil)
    end
  end
end
