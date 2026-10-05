# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "profiler/collectors/request_collector"
require_relative "../support/rails_app"

# PERF-05 through the real controller stack: the bodies are stored gzip+base64, and every response
# that showed them as text still does; the toolbar, which shows none, gets them as stored.
RSpec.describe "Compressed bodies through the profiler API", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:body) { "<html><body>#{(1..600).map { |i| "<p>shown-body-marker row #{i}</p>" }.join}</body></html>" }

  def app
    Rails.application
  end

  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      example.run
    end
  ensure
    Profiler.instance_variable_set(:@storage, nil)
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
      config.tmp_path = Pathname.new(File.join(@root, "profiler"))
    end
    Profiler.instance_variable_set(:@storage, store)
  end

  let(:store) { Profiler::Storage::FileStore.new(path: File.join(@root, "profiles")) }

  let!(:profile) do
    profile = Profiler::Models::Profile.new
    profile.path = "/page"
    profile.method = "POST"
    profile.set_bodies(request_body: body, response_body: body, req_content_type: "text/plain", resp_content_type: "text/html")
    profile.finish(200, { "Content-Type" => "text/html" })
    Profiler::Collectors::RequestCollector.new(profile).collect
    store.save(profile.token, profile)
    profile
  end

  def json
    JSON.parse(last_response.body)
  end

  it "stores the bodies compressed" do
    expect(File.read(File.join(@root, "profiles", "#{profile.token}.json"))).not_to include("shown-body-marker")
  end

  it "gives the bodies as text in the profile detail" do
    get "/_profiler/api/profiles/#{profile.token}", {}, local

    expect(last_response.status).to eq(200)
    expect(json.values_at("request_body", "request_body_encoding")).to eq([body, "text"])
    expect(json.values_at("response_body", "response_body_encoding")).to eq([body, "text"])
  end

  # The cluster proxy reads a slave's whole profiles from this list.
  it "gives the bodies as text in the list of whole profiles (all_types)" do
    get "/_profiler/api/profiles", { all_types: 1 }, local

    listed = json["profiles"].find { |p| p["token"] == profile.token }
    expect(listed.values_at("response_body", "response_body_encoding")).to eq([body, "text"])
  end

  it "embeds the bodies as text in the profile page" do
    get "/_profiler/profiles/#{profile.token}", {}, local

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("shown-body-marker row 600")
  end

  it "gives the toolbar the bodies as stored, which it does not show" do
    get "/_profiler/api/toolbar/#{profile.token}", {}, local

    expect(last_response.status).to eq(200)
    expect(json["profile"]["response_body_encoding"]).to eq("gzip+base64")
    expect(last_response.body).not_to include("shown-body-marker")
    expect(last_response.body.bytesize).to be < body.bytesize
  end

  it "answers with a damaged compressed body as it is, without an error" do
    broken = build_profile(path: "/broken")
    broken.response_body = "AAAA"
    broken.response_body_encoding = "gzip+base64"
    store.save(broken.token, broken)

    get "/_profiler/api/profiles/#{broken.token}", {}, local

    expect(last_response.status).to eq(200)
    expect(json.values_at("response_body", "response_body_encoding")).to eq(%w[AAAA gzip+base64])
  end
end
