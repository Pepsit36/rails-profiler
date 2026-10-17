# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"

# A host application with style-src 'nonce-...' and no 'unsafe-inline' blocks every inline
# <style> and <script> that carries no nonce. The embedded layout and the injected toolbar
# must carry the request's nonce, and add none when the application has no CSP.
RSpec.describe "CSP nonce on inline styles", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:storage) { Profiler::Storage::MemoryStore.new }
  let(:token) { "5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d" }
  # Rails merges its own env_config (the generator is nil without a CSP) over the request env.
  def configure_nonce_generator
    generator = ->(_request) { "abc123nonce" }
    allow(Rails.application).to receive(:env_config).and_wrap_original do |original|
      original.call.merge("action_dispatch.content_security_policy_nonce_generator" => generator)
    end
  end

  def app
    Rails.application
  end

  def default_host
    "localhost"
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, storage)
    storage.save(token, build_profile(token: token))
  end

  describe "the embedded layout" do
    it "puts the nonce on its inline style and script" do
      configure_nonce_generator
      get "/_profiler/profiles/#{token}?embed=true", {}, local

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include(%(<style nonce="abc123nonce">))
      expect(last_response.body).to include(%(<script nonce="abc123nonce">))
      expect(last_response.body).not_to match(/<style>|<script>/)
    end

    it "still starts with the doctype" do
      get "/_profiler/profiles/#{token}?embed=true", {}, local

      expect(last_response.body).to start_with("<!DOCTYPE html>")
    end

    it "adds no nonce when the application has no CSP" do
      get "/_profiler/profiles/#{token}?embed=true", {}, local

      expect(last_response.body).to include("<style>")
      expect(last_response.body).not_to include("nonce=")
    end
  end

  describe "the toolbar style" do
    let(:html) { "<html><body>hi</body></html>" }

    it "carries the nonce" do
      content = Profiler::Middleware::ToolbarInjector.new([html], token, "abc123nonce").inject.join

      expect(content).to include(%(<style nonce="abc123nonce">))
    end

    it "carries none without a nonce" do
      content = Profiler::Middleware::ToolbarInjector.new([html], token).inject.join

      expect(content).to include("<style>")
      expect(content).not_to include("nonce")
    end
  end
end
