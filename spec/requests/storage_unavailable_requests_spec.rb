# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/rails_app"
require "profiler/mcp/server"
require "profiler/mcp/tools/query_profiles"

# C6 and R-d: with a store that cannot be created, the profiler's routes answer 503 with the cause
# in one line (no path), the MCP tools answer an error with it, and no page gets a toolbar for a
# profile that was never saved.
RSpec.describe "Profiler routes while the store cannot be created", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:token) { SecureRandom.hex(16) }

  def app
    Rails.application
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  before do
    path = File.join(@dir, "profiles")
    FileUtils.mkdir_p(path)
    File.symlink(File.join(@dir, "elsewhere"), File.join(path, Profiler::Storage::FileStore::LOCK_FILE))
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
      config.storage = :file
      config.storage_options = { path: path }
    end
    Profiler.instance_variable_set(:@storage, nil)
    Profiler::Storage::Unavailable.reset!
    allow(Profiler).to receive(:log_warn)
  end

  after do
    Profiler.configure do |config|
      config.storage = :memory
      config.storage_options = {}
    end
    Profiler.instance_variable_set(:@storage, nil)
  end

  def expect_cause(text)
    expect(text).to include("storage is unavailable")
    expect(text).to include("symbolic link")
    expect(text).not_to include(@dir)
    expect(text.lines.size).to eq(1)
  end

  %w[/_profiler/api/profiles /_profiler/api/jobs].each do |path|
    it "answers 503 with the cause on #{path}" do
      get path, {}, local
      expect(last_response.status).to eq(503)
      expect_cause(JSON.parse(last_response.body)["error"])
    end
  end

  it "answers 503 with the cause to the toolbar" do
    get "/_profiler/api/toolbar/#{token}", {}, local
    expect(last_response.status).to eq(503)
    expect_cause(JSON.parse(last_response.body)["error"])
  end

  it "answers a plain 503 page with the cause on the HTML pages" do
    get "/_profiler/profiles/#{token}", {}, local
    expect(last_response.status).to eq(503)
    expect(last_response.content_type).to start_with("text/plain")
    expect_cause(last_response.body)
  end

  it "answers an MCP error with the cause" do
    tool = Profiler::MCP::Server.allocate.send(:define_tool, name: "query_profiles", description: "spec",
                                               input_schema: { properties: {} },
                                               handler: Profiler::MCP::Tools::QueryProfiles)
    response = tool.call(server_context: nil)

    expect(response.error?).to be true
    expect_cause(response.content.map { |part| part[:text] }.join)
  end

  it "injects no toolbar into a page whose profile was not saved" do
    Profiler.configuration.track_http = true
    get "/hello", {}, local

    expect(last_response.status).to eq(200)
    expect(last_response.body).not_to include("profiler-toolbar")
    expect(last_response.headers["X-Profiler-Token"]).to be_nil
  end
end
