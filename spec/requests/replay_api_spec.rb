# frozen_string_literal: true

require "spec_helper"
require "webmock"
require "webmock/rspec/matchers"
require_relative "../support/rails_app"

RSpec.describe "POST /_profiler/api/profiles/:id/replay", type: :request do
  include Rack::Test::Methods
  include WebMock::API
  include WebMock::Matchers

  let(:storage) { Profiler::Storage::MemoryStore.new }
  let(:source) { build_profile(method: "DELETE", path: "/things/1", headers: { "Host" => "localhost:3000" },
                                 server_port: 3000, url_scheme: "http") }
  let(:headers) { { "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "localhost" } }

  def app
    Rails.application
  end

  def replay(body = {}, token = source.token)
    post "/_profiler/api/profiles/#{token}/replay", body.to_json, headers.merge("HTTP_X_PROFILER_REQUEST" => "1")
  end

  before do
    WebMock.enable!
    WebMock.disable_net_connect!
    stub_request(:any, "http://localhost:3000/things/1").to_return(status: 204, headers: { "X-Profiler-Token" => "a" * 32 })
    Profiler.configure do |config|
      config.enabled = true
      config.authorization_mode = :allow_all
      config.replay_enabled = true
    end
    Profiler.instance_variable_set(:@storage, storage)
    storage.save(source.token, source)
    Rails.application.reload_routes!
  end

  after do
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
  end

  it "replays a DELETE to the original host and answers the new profile token" do
    replay

    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["target"]).to eq("http://localhost:3000")
    expect(body["replays"].first).to include("status" => 204, "token" => "a" * 32)
    expect(a_request(:delete, "http://localhost:3000/things/1").with(headers: { "X-Profiler-Replay-Of" => source.token })).to have_been_made
  end

  it "answers 403 with a clear message when replays are disabled" do
    Profiler.configuration.replay_enabled = false
    replay

    expect(last_response.status).to eq(403)
    expect(JSON.parse(last_response.body)["error"]).to match(/replay_enabled/)
    expect(a_request(:any, /./)).not_to have_been_made
  end

  it "answers 422 to an attempt to change the target" do
    replay({ "host" => "evil.example" })

    expect(last_response.status).to eq(422)
    expect(a_request(:any, /./)).not_to have_been_made
  end

  it "answers 404 for an unknown profile" do
    replay({}, "f" * 32)

    expect(last_response.status).to eq(404)
  end
end
