# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"

# GET /_profiler/api/config: the settings of the file:line links, read by the dashboard and by
# the browser extension. The URLs themselves are built by the client (source-links.ts); what the
# server guarantees is that a scheme outside the allow list is never handed out.
RSpec.describe "Editor settings API", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }

  def app
    Rails.application
  end

  before { Profiler.configure { |config| config.enabled = true } }

  def read
    get "/_profiler/api/config", {}, local
    expect(last_response.status).to eq(200)
    JSON.parse(last_response.body)
  end

  it "answers vscode and an empty map by default" do
    expect(read).to eq("editor_url_scheme" => "vscode", "editor_path_map" => {})
  end

  %w[vscode idea cursor].each do |scheme|
    it "exposes the #{scheme} scheme" do
      Profiler.configuration.editor_url_scheme = scheme.to_sym

      expect(read["editor_url_scheme"]).to eq(scheme)
    end
  end

  ["javascript", "data", "vscode://evil", "VSCODE", "", :file, 42].each do |value|
    it "exposes no scheme for #{value.inspect}" do
      Profiler.configuration.editor_url_scheme = value

      expect(read["editor_url_scheme"]).to be_nil
    end
  end

  it "exposes no scheme when links are turned off with nil" do
    Profiler.configuration.editor_url_scheme = nil

    expect(read["editor_url_scheme"]).to be_nil
  end

  it "exposes the path map as strings" do
    Profiler.configuration.editor_path_map = { :"/app" => "/home/me/projet", "/gems" => Pathname.new("/opt/gems") }

    expect(read["editor_path_map"]).to eq("/app" => "/home/me/projet", "/gems" => "/opt/gems")
  end

  it "refuses an access that is not authorized" do
    get "/_profiler/api/config", {}, { "REMOTE_ADDR" => "203.0.113.9", "HTTP_HOST" => "example.com" }

    expect(last_response.status).to eq(403)
  end
end
