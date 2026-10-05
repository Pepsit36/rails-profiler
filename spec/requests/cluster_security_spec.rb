# frozen_string_literal: true

require "spec_helper"
require "webmock"
require "webmock/rspec/matchers"
require_relative "../support/rails_app"
require "profiler/cluster/slave_registry"
require "profiler/cluster/master_client"
require "profiler/cluster/slave_proxy"

RSpec.describe "Cluster endpoints", type: :request do
  include Rack::Test::Methods
  include WebMock::API
  include WebMock::Matchers

  let(:secret) { "s3cret-shared-by-the-cluster-0123456789" }
  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:remote) { { "REMOTE_ADDR" => "10.0.0.5", "HTTP_HOST" => "master.internal" } }
  let(:json_headers) { { "CONTENT_TYPE" => "application/json" } }
  let(:profiler_header) { { "HTTP_X_PROFILER_REQUEST" => "1" } }
  let(:secret_header) { { "HTTP_X_PROFILER_CLUSTER_SECRET" => secret } }

  def app
    Rails.application
  end

  # The spec application raises routing errors; render them as an application does, so that
  # a route that is not there answers 404.
  def with_rendered_errors
    env_config = Rails.application.env_config
    previous = env_config["action_dispatch.show_exceptions"]
    env_config["action_dispatch.show_exceptions"] = :all
    yield
  ensure
    env_config["action_dispatch.show_exceptions"] = previous
  end

  def default_host
    "localhost"
  end

  def json
    JSON.parse(last_response.body)
  end

  def register(name:, url:, env:)
    post "/_profiler/api/cluster/register", { name: name, url: url }.to_json, json_headers.merge(env)
  end

  def configure_master(**options)
    Profiler.configure do |config|
      config.cluster_master = true
      config.cluster_secret = secret
      config.cluster_allowed_slave_urls = ["https://payment.internal", "http://localhost:3001"]
      options.each { |key, value| config.public_send("#{key}=", value) }
    end
  end

  before do
    WebMock.enable!
    WebMock.disable_net_connect!
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
    Profiler.instance_variable_set(:@slave_registry, Profiler::Cluster::SlaveRegistry.new)
    Profiler::LocalRequest.reset_warning!
  end

  after do
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
    Profiler.instance_variable_set(:@slave_registry, nil)
  end

  context "when the cluster is not configured" do
    around { |example| with_rendered_errors { example.run } }

    it "does not route register, even for a local client with the forgery header" do
      register(name: "evil", url: "http://169.254.169.254", env: local.merge(profiler_header).merge(secret_header))

      expect(last_response.status).to eq(404)
      expect(Profiler.slave_registry.all).to be_empty
    end

    it "does not route heartbeat, slaves or the slave proxy" do
      Profiler.slave_registry.register(name: "payment", url: "https://payment.internal")

      post "/_profiler/api/cluster/heartbeat", { name: "payment" }.to_json, json_headers.merge(local).merge(profiler_header)
      expect(last_response.status).to eq(404)

      get "/_profiler/api/cluster/slaves", {}, local
      expect(last_response.status).to eq(404)

      get "/_profiler/api/slaves/payment/profiles", {}, local
      expect(last_response.status).to eq(404)
      expect(a_request(:any, /payment\.internal/)).not_to have_been_made
    end

    it "still serves the rest of the API" do
      get "/_profiler/api/profiles", {}, local
      expect(last_response.status).to eq(200)
    end
  end

  context "when this node is a cluster master" do
    before { configure_master }

    describe "register" do
      it "accepts a slave with the shared secret and an allowed URL, from another host" do
        register(name: "payment", url: "https://payment.internal", env: remote.merge(secret_header))

        expect(last_response.status).to eq(200)
        expect(Profiler.slave_registry.all.map { |s| s[:name] }).to eq(["payment"])
      end

      it "refuses a request without the secret, even from a local client with the forgery header" do
        register(name: "payment", url: "https://payment.internal", env: local.merge(profiler_header))

        expect(last_response.status).to eq(403)
        expect(Profiler.slave_registry.all).to be_empty
      end

      it "refuses a wrong secret" do
        register(name: "payment", url: "https://payment.internal",
                 env: local.merge("HTTP_X_PROFILER_CLUSTER_SECRET" => "#{secret}x"))

        expect(last_response.status).to eq(403)
        expect(Profiler.slave_registry.all).to be_empty
      end

      it "compares the secret in constant time" do
        expect(ActiveSupport::SecurityUtils).to receive(:secure_compare).at_least(:once).and_call_original
        register(name: "payment", url: "https://payment.internal", env: remote.merge(secret_header))

        expect(last_response.status).to eq(200)
      end

      it "refuses everything when no secret is configured" do
        Profiler.configuration.cluster_secret = nil
        register(name: "payment", url: "https://payment.internal", env: local.merge(profiler_header).merge("HTTP_X_PROFILER_CLUSTER_SECRET" => ""))

        expect(last_response.status).to eq(403)
        expect(json["error"]).to match(/cluster_secret/)
      end

      it "treats a secret shorter than 32 characters as missing, and says so" do
        Profiler.configuration.cluster_secret = "a" * 31
        register(name: "payment", url: "https://payment.internal",
                 env: remote.merge("HTTP_X_PROFILER_CLUSTER_SECRET" => "a" * 31))

        expect(last_response.status).to eq(403)
        expect(json["error"]).to match(/32 characters/)
        expect(Profiler.slave_registry.all).to be_empty
      end

      it "treats a blank secret as missing" do
        Profiler.configuration.cluster_secret = " " * 40
        register(name: "payment", url: "https://payment.internal",
                 env: remote.merge("HTTP_X_PROFILER_CLUSTER_SECRET" => " " * 40))

        expect(last_response.status).to eq(403)
        expect(json["error"]).to match(/cluster_secret/)
      end

      it "stores the normalized URL" do
        register(name: "payment", url: " HTTPS://Payment.Internal:443/ ", env: remote.merge(secret_header))

        expect(last_response.status).to eq(200)
        expect(Profiler.slave_registry.all.first[:url]).to eq("https://payment.internal")
      end

      it "refuses a URL outside the allow list" do
        register(name: "evil", url: "https://169.254.169.254", env: remote.merge(secret_header))

        expect(last_response.status).to eq(422)
        expect(json["error"]).to match(/not allowed/)
        expect(Profiler.slave_registry.all).to be_empty
      end

      it "refuses a host that only starts like an allowed one" do
        register(name: "evil", url: "https://payment.internal.evil.example", env: remote.merge(secret_header))
        expect(last_response.status).to eq(422)
      end

      it "refuses plain HTTP to a host that is not a loopback address" do
        Profiler.configuration.cluster_allowed_slave_urls = ["http://payment.internal"]
        register(name: "payment", url: "http://payment.internal", env: remote.merge(secret_header))

        expect(last_response.status).to eq(422)
        expect(json["error"]).to match(/HTTPS/)
      end

      it "accepts plain HTTP to a remote host with cluster_allow_insecure_http" do
        Profiler.configure do |config|
          config.cluster_allowed_slave_urls = ["http://payment.internal"]
          config.cluster_allow_insecure_http = true
        end
        register(name: "payment", url: "http://payment.internal", env: remote.merge(secret_header))

        expect(last_response.status).to eq(200)
      end

      it "accepts any URL with cluster_allowed_slave_urls = :any" do
        Profiler.configuration.cluster_allowed_slave_urls = :any
        register(name: "anything", url: "https://anything.example", env: remote.merge(secret_header))

        expect(last_response.status).to eq(200)
      end
    end

    describe "heartbeat" do
      before { Profiler.slave_registry.register(name: "payment", url: "https://payment.internal") }

      it "accepts the shared secret" do
        post "/_profiler/api/cluster/heartbeat", { name: "payment" }.to_json, json_headers.merge(remote).merge(secret_header)
        expect(last_response.status).to eq(200)
      end

      it "refuses a request without the secret" do
        post "/_profiler/api/cluster/heartbeat", { name: "payment" }.to_json, json_headers.merge(local).merge(profiler_header)
        expect(last_response.status).to eq(403)
      end
    end

    describe "the slave proxy" do
      it "forwards to an allowed slave, with the shared secret" do
        Profiler.slave_registry.register(name: "payment", url: "https://payment.internal")
        stub = stub_request(:get, "https://payment.internal/_profiler/api/profiles")
               .with(headers: { "X-Profiler-Cluster-Secret" => secret })
               .to_return(status: 200, body: { profiles: [] }.to_json)

        get "/_profiler/api/slaves/payment/profiles", {}, local

        expect(last_response.status).to eq(200)
        expect(stub).to have_been_requested
      end

      it "refuses a slave whose URL is no longer allowed, without any request" do
        Profiler.slave_registry.register(name: "evil", url: "https://169.254.169.254")

        get "/_profiler/api/slaves/evil/latest/meta-data", {}, local

        expect(last_response.status).to eq(502)
        expect(json["error"]).to match(/not allowed/)
        expect(a_request(:any, /169\.254\.169\.254/)).not_to have_been_made
      end

      it "refuses to proxy when no secret is configured" do
        Profiler.slave_registry.register(name: "payment", url: "https://payment.internal")
        Profiler.configuration.cluster_secret = nil

        get "/_profiler/api/slaves/payment/profiles", {}, local

        expect(last_response.status).to eq(502)
        expect(a_request(:any, /payment\.internal/)).not_to have_been_made
      end

      it "does not follow a redirect, and does not return its body" do
        Profiler.slave_registry.register(name: "payment", url: "https://payment.internal")
        stub_request(:get, "https://payment.internal/_profiler/api/profiles")
          .to_return(status: 302, headers: { "Location" => "http://169.254.169.254/latest/" }, body: "moved")

        get "/_profiler/api/slaves/payment/profiles", {}, local

        expect(last_response.status).to eq(502)
        expect(last_response.body).not_to include("moved")
        expect(a_request(:any, /169\.254\.169\.254/)).not_to have_been_made
      end

      it "still requires an authorized browser" do
        Profiler.slave_registry.register(name: "payment", url: "https://payment.internal")
        get "/_profiler/api/slaves/payment/profiles", {}, remote.merge(secret_header)

        expect(last_response.status).to eq(403)
      end
    end

    # Every request the master sends to a slave has to stay under the slave's /_profiler/api/:
    # it carries the secret. Requests are captured as Net::HTTP builds them, before any
    # normalization, so that a ".." or an injected query shows as it would on the wire.
    describe "paths sent to a slave" do
      let(:sent) { [] }

      before do
        Profiler.slave_registry.register(name: "payment", url: "https://payment.internal/app")
        ok = instance_double(Net::HTTPResponse, code: "200", body: "{}")
        http = double("http")
        allow(http).to receive(:request) { |req| sent << req.path; ok }
        allow(Net::HTTP).to receive(:start).and_yield(http)
        Profiler.configuration.cluster_allowed_slave_urls = ["https://payment.internal/app"]
      end

      def escaped_prefix?(path)
        path.start_with?("/app/_profiler/api/") &&
          path.split("?").first.split("/").none? { |segment| %w[. ..].include?(URI.decode_www_form_component(segment)) }
      end

      it "refuses a dot segment in the proxied path" do
        get "/_profiler/api/slaves/payment/%2E%2E/%2E%2E/admin", {}, local

        expect(last_response.status).to eq(502)
        expect(sent).to be_empty
      end

      it "does not let an encoded question mark in the proxied path become a query" do
        get "/_profiler/api/slaves/payment/profiles/x%3Fall_types=1", {}, local

        expect(sent.size).to eq(1)
        expect(sent.first).to eq("/app/_profiler/api/profiles/x%3Fall_types%3D1")
      end

      it "keeps the query of the proxied request as a query" do
        get "/_profiler/api/slaves/payment/profiles", { limit: "5" }, local
        expect(sent).to eq(["/app/_profiler/api/profiles?limit=5"])
      end

      it "sends no malformed token in the fan-out of a profile page" do
        get "/_profiler/profiles/%2E%2E%2F%2E%2E%2Fadmin%3Fx=1", {}, local
        get "/_profiler/profiles/abc%3Fall_types=1", {}, local

        expect(sent).to be_empty
      end

      it "keeps the fan-out of a profile page under the API prefix" do
        token = SecureRandom.hex(16)
        get "/_profiler/profiles/#{token}", {}, local

        expect(sent).not_to be_empty
        expect(sent).to all(satisfy { |path| escaped_prefix?(path) && !path.include?("?") })
      end

      it "sends no malformed token in an MCP lookup, and keeps a valid one under the API prefix" do
        require "profiler/mcp/slave_support"
        storage = Profiler::MCP::SlaveSupport.resolve_storage("slave" => "payment")

        expect(storage.load("../../admin")).to be_nil
        expect(storage.load("x?all_types=1#frag")).to be_nil
        expect(sent).to be_empty

        token = SecureRandom.hex(16)
        storage.load(token)
        expect(sent).to eq(["/app/_profiler/api/profiles/#{token}"])
      end
    end

    describe "the old behaviour, restored by cluster_require_secret = false" do
      before do
        Profiler.configure do |config|
          config.cluster_secret = nil
          config.cluster_require_secret = false
        end
      end

      it "registers a local client without a secret" do
        register(name: "payment", url: "https://payment.internal", env: local.merge(profiler_header))
        expect(last_response.status).to eq(200)
      end

      it "still applies the access guard of 0.30.6 to a remote client" do
        register(name: "payment", url: "https://payment.internal", env: remote.merge(profiler_header))
        expect(last_response.status).to eq(403)
      end
    end
  end

  describe "a slave node" do
    let(:slave_env) { { "REMOTE_ADDR" => "10.0.0.9", "HTTP_HOST" => "slave.internal" } }

    before do
      Profiler.configure do |config|
        config.master_url = "https://master.internal"
        config.cluster_secret = secret
      end
    end

    it "accepts its master's proxied API calls, authenticated by the secret" do
      delete "/_profiler/api/profiles/clear", {}, slave_env.merge(secret_header)
      expect(last_response.status).to eq(204).or eq(200)
    end

    it "refuses the same call with a wrong secret" do
      delete "/_profiler/api/profiles/clear", {}, slave_env.merge("HTTP_X_PROFILER_CLUSTER_SECRET" => "nope")
      expect(last_response.status).to eq(403)
    end

    it "refuses the same call without the secret" do
      delete "/_profiler/api/profiles/clear", {}, slave_env.merge(profiler_header)
      expect(last_response.status).to eq(403)
    end

    it "does not count the secret as a forgery proof for a local browser without it" do
      delete "/_profiler/api/profiles/clear", {}, local
      expect(last_response.status).to eq(403)
      expect(json["error"]).to match(/X-Profiler-Request/)
    end

    it "accepts no secret at all when none is configured" do
      Profiler.configuration.cluster_secret = nil
      delete "/_profiler/api/profiles/clear", {}, slave_env.merge("HTTP_X_PROFILER_CLUSTER_SECRET" => "")
      expect(last_response.status).to eq(403)
    end

    it "gives the secret no power on a node that is not a slave" do
      Profiler.configuration.master_url = nil
      delete "/_profiler/api/profiles/clear", {}, slave_env.merge(secret_header)
      expect(last_response.status).to eq(403)
    end

    it "does not serve the master-side cluster routes" do
      with_rendered_errors { register(name: "x", url: "https://payment.internal", env: local.merge(secret_header)) }
      expect(last_response.status).to eq(404)
    end
  end

  # One process plays both roles, as two local Rails servers would with the README setup;
  # WebMock hands the HTTP calls between them back to the same Rack application.
  describe "a local master and slave, configured as documented" do
    before do
      Profiler.configure do |config|
        config.name = "payment"
        config.cluster_master = true
        config.cluster_secret = secret
        config.cluster_allowed_slave_urls = ["http://localhost:3001"]
        config.master_url = "http://localhost:3000"
        config.self_url = "http://localhost:3001"
      end
      # WebMock hands the application a session Hash that Rails cannot load: drop it, and give
      # the call the loopback address it would come from.
      relay = lambda do |env|
        env.delete("rack.session")
        env.delete("rack.session.options")
        Rails.application.call(env.merge("REMOTE_ADDR" => "127.0.0.1"))
      end
      stub_request(:any, %r{\Ahttp://localhost:300[01]/}).to_rack(relay)
    end

    it "registers the slave, proxies to it, and keeps the heartbeat going" do
      client = Profiler::Cluster::MasterClient.new
      client.send(:register!)
      expect(Profiler.slave_registry.all.map { |s| s[:name] }).to eq(["payment"])

      Profiler.storage.save("5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d", build_profile(token: "5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d"))
      get "/_profiler/api/slaves/payment/profiles", {}, local
      expect(last_response.status).to eq(200)
      expect(json["profiles"].map { |p| p["token"] }).to include("5f2b8c0d9e4a4f1b8c3d2e1f0a9b8c7d")

      expect { client.send(:heartbeat!) }.not_to raise_error
    end
  end

  # The secret opens every slave from the network: it must not be readable in a profile, on
  # any node, whatever name it travels under. Names the filter knows (PROFILER_CLUSTER_SECRET,
  # X-Profiler-Cluster-Secret) are masked by name; the others only by value.
  describe "the cluster secret in captured data" do
    let(:env_names) { %w[PROFILER_CLUSTER_SECRET CLUSTER_PSK] }

    around do |example|
      saved = env_names.to_h { |name| [name, ENV[name]] }
      env_names.each { |name| ENV[name] = secret }
      example.run
    ensure
      saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    end

    before do
      require "profiler/collectors/request_collector"
      require "profiler/collectors/env_collector"
      Profiler.configure do |config|
        config.name = "payment"
        config.collectors = [Profiler::Collectors::RequestCollector, Profiler::Collectors::EnvCollector]
        config.env_allowlist = :all
        config.cluster_master = true
        config.cluster_secret = ENV.fetch("PROFILER_CLUSTER_SECRET")
        config.cluster_allowed_slave_urls = ["http://localhost:3001"]
        config.master_url = "http://localhost:3000"
        config.self_url = "http://localhost:3001"
      end
      relay = lambda do |env|
        env.delete("rack.session")
        env.delete("rack.session.options")
        Rails.application.call(env.merge("REMOTE_ADDR" => "127.0.0.1"))
      end
      stub_request(:any, %r{\Ahttp://localhost:300[01]/}).to_rack(relay)
      Profiler::Cluster::MasterClient.new.send(:register!)
    end

    it "appears nowhere in a profile stored on the slave and read through the master" do
      get "/hello", { q: secret, note: "auth=#{secret}" },
          local.merge("HTTP_REFERER" => "http://localhost/?auth=#{secret}", "HTTP_X_PROFILER_CLUSTER_SECRET" => secret)
      token = last_response.headers["X-Profiler-Token"]
      expect(token).not_to be_nil

      expect(Profiler.storage.load(token).to_h.to_json).not_to include(secret)

      get "/_profiler/api/slaves/payment/profiles/#{token}", {}, local
      expect(last_response.status).to eq(200)
      body = last_response.body
      expect(body).to include("CLUSTER_PSK", "Referer")
      expect(body).not_to include(secret)

      get "/_profiler/api/slaves/payment/env_vars", {}, local
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("CLUSTER_PSK")
      expect(last_response.body).not_to include(secret)
    end
  end
end
