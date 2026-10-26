# frozen_string_literal: true

require "spec_helper"
require "profiler/redaction"

# The peer token is masked by value wherever the profiler captures it, in addition to the
# masking by name: it may travel under a name no filter knows.
RSpec.describe "Peer token redaction" do
  let(:token) { "peer-shared-value-0123456789abcdef" }
  let(:mask) { Profiler::Redaction::MASK }

  before do
    Profiler.configure { |config| config.peer_token = token }
    Profiler::Peers.reset!
  end

  after { Profiler.configure { |config| config.peer_token = nil } }

  it "masks params holding it, whole or embedded" do
    filtered = Profiler::Redaction.filter_hash("peer_auth" => token, "nested" => { "list" => ["x #{token} y"] })

    expect(filtered).to eq("peer_auth" => mask, "nested" => { "list" => ["x #{mask} y"] })
  end

  it "masks incoming and outbound headers under any name" do
    headers = { "X-Peer-Token" => token, "Referer" => "http://h/?token=#{token}", "Accept" => "*/*" }

    expect(Profiler::Redaction.filter_headers(headers))
      .to eq("X-Peer-Token" => mask, "Referer" => "http://h/?token=#{mask}", "Accept" => "*/*")
  end

  it "masks it in URLs and query strings" do
    expect(Profiler::Redaction.filter_url("https://h/p?token=#{token}")).to eq("https://h/p?token=#{mask}")
    expect(Profiler::Redaction.filter_query("token=#{token}")).to eq("token=#{mask}")
  end

  it "leaves values alone when no token is configured" do
    Profiler.configure { |config| config.peer_token = nil }
    Profiler::Peers.reset!
    expect(Profiler::Redaction.filter_hash("peer_auth" => token)).to eq("peer_auth" => token)
  end

  it "masks nothing for a token the peers module ignores, shorter than 32 characters" do
    Profiler.configure { |config| config.peer_token = "short" }
    Profiler::Peers.reset!

    expect(Profiler::Redaction.filter_hash("a" => "short", "b" => "xshortx")).to eq("a" => "short", "b" => "xshortx")
  end
end
