# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/rails_app"

# Turbo Frame and Turbo Stream requests go through the page's fetch(), which the AJAX interceptor
# wraps: they are profiled by the middleware like any request, linked to the page by the
# interceptor, and named in the page's AJAX data. The requests below carry what Turbo sends
# (the Turbo-Frame header, the turbo-stream Accept) and get what turbo-rails answers.
RSpec.describe "Turbo sub-requests of a page", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:writing) { local.merge("HTTP_X_PROFILER_REQUEST" => "1") }
  let(:turbo_stream_accept) { "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" }
  let(:store) { Profiler::Storage::MemoryStore.new }

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

  def json
    JSON.parse(last_response.body)
  end

  # The request, then what the interceptor does with its X-Profiler-Token.
  def request_and_link(parent_token, verb, path, env)
    send(verb, path, {}, local.merge(env))
    token = last_response.headers["X-Profiler-Token"]
    expect(token).to match(/\A\h{32}\z/)

    post "/_profiler/api/ajax/link", { parent_token: parent_token, child_token: token }, writing
    expect(last_response.status).to eq(200)
    token
  end

  it "lists the frame, the stream and a plain fetch in the page's toolbar, each with its kind" do
    get "/hello", {}, local
    page = last_response.headers["X-Profiler-Token"]

    frame = request_and_link(page, :get, "/turbo/frame",
                             "HTTP_TURBO_FRAME" => "customer_card",
                             "HTTP_ACCEPT" => "text/html, application/xhtml+xml")
    stream = request_and_link(page, :post, "/turbo/stream", "HTTP_ACCEPT" => turbo_stream_accept)
    plain = request_and_link(page, :get, "/hello", "HTTP_ACCEPT" => "application/json")

    get "/_profiler/api/toolbar/#{page}", {}, local

    ajax = json["profile"]["collectors_data"]["ajax"]
    expect(ajax["total_requests"]).to eq(3)
    expect(ajax["requests"].map { |r| r.values_at("token", "method", "path", "turbo") }).to contain_exactly(
      [frame, "GET", "/turbo/frame", "frame"],
      [stream, "POST", "/turbo/stream", "stream"],
      [plain, "GET", "/hello", nil]
    )
    expect(store.load(frame)).to have_attributes(parent_token: page, is_ajax: true)
  end

  it "keeps the Turbo-Frame header in the frame request's profile" do
    get "/turbo/frame", {}, local.merge("HTTP_TURBO_FRAME" => "customer_card")

    get "/_profiler/api/profiles/#{last_response.headers['X-Profiler-Token']}", {}, local

    expect(json["headers"]).to include("Turbo-Frame" => "customer_card")
  end

  it "shows the kinds in the page's AJAX tab of the dashboard" do
    get "/hello", {}, local
    page = last_response.headers["X-Profiler-Token"]
    request_and_link(page, :post, "/turbo/stream", "HTTP_ACCEPT" => turbo_stream_accept)

    get "/_profiler/api/profiles/#{page}", {}, local

    expect(json["collectors_data"]["ajax"]["requests"].map { |r| r["turbo"] }).to eq(["stream"])
  end
end
