# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"

# The front end compares this meta with the gem_version of each profile. The API reports
# Profiler.version, which differs from the raw VERSION constant when the gem is mounted
# from a git checkout, so the layouts have to use it too.
RSpec.describe "Layout profiler-version meta", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:token) { "5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d" }
  let(:derived) { "0.34.2-3-gabc1234" }

  def app
    Rails.application
  end

  def default_host
    "localhost"
  end

  def meta_version
    last_response.body[/<meta name="profiler-version" content="([^"]*)"/, 1]
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
    end
    storage = Profiler::Storage::MemoryStore.new
    Profiler.instance_variable_set(:@storage, storage)
    storage.save(token, build_profile(token: token))
    allow(Profiler).to receive(:version).and_return(derived)
  end

  it "reports Profiler.version, not the raw constant, in the application layout" do
    get "/_profiler/profiles/#{token}", {}, local

    expect(Profiler::VERSION).not_to eq(derived)
    expect(meta_version).to eq(derived)
  end

  it "reports Profiler.version, not the raw constant, in the embedded layout" do
    get "/_profiler/profiles/#{token}", { embed: "true" }, local

    expect(meta_version).to eq(derived)
  end
end
