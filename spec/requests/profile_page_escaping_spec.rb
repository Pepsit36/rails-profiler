# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"

# The profile page embeds the profile as JSON in a <script> element. Captured values come
# from the profiled application (params, headers, bodies, SQL), so the page must never let
# one of them close the element, whatever the application sets for
# ActiveSupport.escape_html_entities_in_json.
RSpec.describe "Profile page escaping", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:storage) { Profiler::Storage::MemoryStore.new }
  let(:payload) { "</script><script>alert(document.domain)</script><!-- &    > <" }

  def app
    Rails.application
  end

  def default_host
    "localhost"
  end

  # What the front end does: JSON.parse of the element's text.
  def embedded_profile
    script = last_response.body[%r{<script type="application/json" id="profiler-show-data">(.*?)</script>}m, 1]
    expect(script).not_to be_nil
    JSON.parse(script)
  end

  before do
    @escape_html_entities_in_json = ActiveSupport.escape_html_entities_in_json
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, storage)
    storage.save("5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", build_profile(token: "5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", params: { "q" => payload }, headers: { "X-Note" => payload }))
  end

  after do
    ActiveSupport.escape_html_entities_in_json = @escape_html_entities_in_json
  end

  [true, false].each do |setting|
    context "with escape_html_entities_in_json = #{setting}" do
      before { ActiveSupport.escape_html_entities_in_json = setting }

      it "never lets a captured value close the script element" do
        get "/_profiler/profiles/5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", {}, local

        expect(last_response.status).to eq(200)
        expect(last_response.body).not_to include("</script><script>")
        expect(last_response.body).not_to include("<!--")
        expect(last_response.body.scan("</script>").size).to eq(last_response.body.scan("<script").size)
        expect(last_response.body).not_to include(" ")
        expect(last_response.body).not_to include(" ")
      end

      it "still hands the front end valid JSON with the original values" do
        get "/_profiler/profiles/5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", {}, local

        profile = embedded_profile
        expect(profile["params"]).to eq("q" => payload)
        expect(profile["headers"]).to eq("X-Note" => payload)
        expect(profile["token"]).to eq("5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d")
      end

      it "escapes the embedded page too" do
        get "/_profiler/profiles/5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", { embed: "true" }, local

        expect(last_response.body).not_to include("</script><script>")
        expect(embedded_profile["params"]).to eq("q" => payload)
      end
    end
  end
end
