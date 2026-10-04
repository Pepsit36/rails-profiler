# frozen_string_literal: true

require "spec_helper"
require "stringio"
require_relative "../support/rails_app"

RSpec.describe "Profiler access control", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:remote) { { "REMOTE_ADDR" => "10.0.0.5", "HTTP_HOST" => "localhost" } }
  let(:profiler_header) { { "HTTP_X_PROFILER_REQUEST" => "1" } }

  def app
    Rails.application
  end

  def default_host
    "localhost"
  end

  def json
    JSON.parse(last_response.body)
  end

  let(:storage) { Profiler::Storage::MemoryStore.new }

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, storage)
    Profiler::LocalRequest.reset_warning!
  end

  def refuse_everything
    Profiler.configure do |config|
      config.authorization_mode = :allow_authorized
      config.authorize_with { |_request| false }
    end
  end

  describe "an unauthorized request" do
    before { refuse_everything }

    it "is refused on the UI" do
      get "/_profiler/", {}, local
      expect(last_response.status).to eq(403)
    end

    it "is refused on a profile page" do
      storage.save("tok", build_profile(token: "tok"))
      get "/_profiler/profiles/tok", {}, local
      expect(last_response.status).to eq(403)
    end

    it "is refused on the API listing, with a JSON error" do
      storage.save("tok", build_profile(token: "tok"))
      get "/_profiler/api/profiles", {}, local

      expect(last_response.status).to eq(403)
      expect(json["error"]).to match(/not authorized/i)
      expect(last_response.body).not_to include("tok")
    end

    it "is refused on profile deletion, even with the forgery header" do
      storage.save("tok", build_profile(token: "tok"))
      delete "/_profiler/api/profiles/clear", {}, local.merge(profiler_header)

      expect(last_response.status).to eq(403)
      expect(storage.load("tok")).not_to be_nil
    end

    it "is refused on an ENV write" do
      patch "/_profiler/api/env_vars", { key: "PROFILER_SPEC_VAR", value: "1" }, local.merge(profiler_header)

      expect(last_response.status).to eq(403)
      expect(ENV).not_to have_key("PROFILER_SPEC_VAR")
    end

    it "is refused on the SSE stream" do
      expect(Profiler::SSE).not_to receive(:current)
      get "/_profiler/api/events/tok", {}, local
      expect(last_response.status).to eq(403)
    end

    it "is refused on the test runner page and API" do
      get "/_profiler/test_runner", {}, local
      expect(last_response.status).to eq(403)

      get "/_profiler/api/test_runner/files", {}, local
      expect(last_response.status).to eq(403)

      expect(Profiler::TestRunner::Runner).not_to receive(:new) if defined?(Profiler::TestRunner::Runner)
      post "/_profiler/api/test_runner/runs", { files: ["spec/x_spec.rb"] }, local.merge(profiler_header)
      expect(last_response.status).to eq(403)
    end

    it "is refused on the toolbar" do
      storage.save("tok", build_profile(token: "tok"))
      get "/_profiler/api/toolbar/tok", {}, local
      expect(last_response.status).to eq(403)
    end

    it "still gets the gem's static assets" do
      path = Profiler::Engine.root.join("app", "assets", "builds", "profiler.css")
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(path).and_return("body {}")

      get "/_profiler/assets/profiler.css", {}, local
      expect(last_response.status).to eq(200)
    end

    # Walks every route of the engine, so that a controller added later without the
    # check, or one that skips it, fails here.
    it "is refused on every route of the engine except the static assets" do
      # Routes behind a configuration switch are walked too.
      Profiler.configure do |config|
        config.cluster_master = true
        config.mcp_enabled = true
        config.mcp_transport = :http
      end
      routes = Profiler::Engine.routes.routes.select { |route| route.defaults[:controller] }
      routes = routes.reject { |route| route.defaults[:controller] == "profiler/assets" }
      expect(routes.size).to be > 30

      allowed = routes.filter_map do |route|
        verb = route.verb.to_s.split("|").first
        verb = "GET" if verb.nil? || verb.empty?
        path = "/_profiler" + route.path.spec.to_s.sub("(.:format)", "").gsub(/[:*]\w+/, "x")

        custom_request(verb, path, {}, local.merge(profiler_header))
        "#{verb} #{path} -> #{last_response.status}" unless last_response.status == 403
      end

      expect(allowed).to be_empty
    end
  end

  describe "an authorized request" do
    it "is accepted under :allow_all, from any address" do
      Profiler.configuration.authorization_mode = :allow_all
      get "/_profiler/api/profiles", {}, remote
      expect(last_response.status).to eq(200)
    end

    it "is accepted under :allow_authorized when the block says so" do
      Profiler.configure do |config|
        config.authorization_mode = :allow_authorized
        config.authorize_with { |request| request.get_header("REMOTE_ADDR") == "10.0.0.5" }
      end
      get "/_profiler/api/profiles", {}, remote
      expect(last_response.status).to eq(200)
    end

    it "is refused under :allow_authorized without a block" do
      Profiler.configuration.authorization_mode = :allow_authorized
      get "/_profiler/api/profiles", {}, local
      expect(last_response.status).to eq(403)
    end

    it "is accepted under :allow_local from this machine" do
      Profiler.configuration.authorization_mode = :allow_local
      get "/_profiler/api/profiles", {}, local
      expect(last_response.status).to eq(200)
    end
  end

  describe "a disabled profiler" do
    before { Profiler.configuration.enabled = false }

    it "refuses the API listing, with a JSON error" do
      get "/_profiler/api/profiles", {}, local

      expect(last_response.status).to eq(403)
      expect(last_response.media_type).to eq("application/json")
      expect(json["error"]).to eq("Profiler is disabled")
    end

    it "refuses the UI, in plain text" do
      get "/_profiler/", {}, local

      expect(last_response.status).to eq(403)
      expect(last_response.media_type).to eq("text/plain")
      expect(last_response.body).to eq("Profiler is disabled")
    end

    it "refuses the toolbar, even for a profile left in storage" do
      storage.save("tok", build_profile(token: "tok", headers: { "Cookie" => "session=secret" }))
      get "/_profiler/api/toolbar/tok", {}, local

      expect(last_response.status).to eq(403)
      expect(last_response.body).not_to include("secret")
    end

    # Walks every route of the engine, the MCP mount and the routes behind a configuration
    # switch included, so that a controller or a Rack application added later without the
    # check, or one that skips it, fails here. Any other mount fails the example: a mounted
    # Rack application skips every controller filter and needs its own guard.
    it "refuses every route of the engine except the static assets" do
      Profiler.configure do |config|
        config.cluster_master = true
        config.mcp_enabled = true
        config.mcp_transport = :http
      end
      mounts, routes = Profiler::Engine.routes.routes.partition { |route| route.defaults[:controller].nil? }
      expect(mounts.map { |route| route.path.spec.to_s }).to eq(["/mcp"])

      routes = routes.reject { |route| route.defaults[:controller] == "profiler/assets" }
      expect(routes.size).to be > 30

      allowed = routes.filter_map do |route|
        verb = route.verb.to_s.split("|").first
        verb = "GET" if verb.nil? || verb.empty?
        path = "/_profiler" + route.path.spec.to_s.sub("(.:format)", "").gsub(/[:*]\w+/, "x")

        custom_request(verb, path, {}, local.merge(profiler_header))
        "#{verb} #{path} -> #{last_response.status}" unless last_response.status == 403
      end
      allowed += %w[GET HEAD POST PUT PATCH DELETE OPTIONS].filter_map do |verb|
        custom_request(verb, "/_profiler/mcp", "{}", local.merge(mcp_headers))
        "#{verb} /_profiler/mcp -> #{last_response.status}" unless last_response.status == 403
      end

      expect(allowed).to be_empty
    end

    it "does not route the MCP mount while its HTTP transport is off" do
      with_rendered_errors do
        post "/_profiler/mcp", "{}", local.merge(mcp_headers)
      end

      expect(last_response.status).to eq(404)
    end

    it "does not route the MCP mount when mcp_enabled is off, even with the HTTP transport" do
      Profiler.configure do |config|
        config.mcp_enabled = false
        config.mcp_transport = :http
      end
      with_rendered_errors do
        post "/_profiler/mcp", "{}", local.merge(mcp_headers)
      end

      expect(last_response.status).to eq(404)
    end

    it "does not route the MCP mount with the stdio transport" do
      Profiler.configure do |config|
        config.mcp_enabled = true
        config.mcp_transport = :stdio
      end
      with_rendered_errors do
        post "/_profiler/mcp", "{}", local.merge(mcp_headers)
      end

      expect(last_response.status).to eq(404)
    end
  end

  describe "the toolbar of an enabled profiler" do
    it "serves the profile to an authorized request" do
      storage.save("tok", build_profile(token: "tok"))
      get "/_profiler/api/toolbar/tok", {}, local

      expect(last_response.status).to eq(200)
      expect(json.dig("profile", "token")).to eq("tok")
    end
  end

  let(:mcp_headers) do
    { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream" }
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

  def rails_env(name)
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new(name))
  end

  describe "the default authorization mode" do
    # The test environment also accepts the reserved test hosts (see below).
    before { rails_env("development") }

    it "is :allow_local" do
      expect(Profiler.configuration.authorization_mode).to eq(:allow_local)
    end

    it "accepts a loopback IPv4 address" do
      get "/_profiler/api/profiles", {}, local.merge("REMOTE_ADDR" => "127.0.0.42")
      expect(last_response.status).to eq(200)
    end

    it "accepts a loopback IPv6 address" do
      get "/_profiler/api/profiles", {}, { "REMOTE_ADDR" => "::1", "HTTP_HOST" => "[::1]:3000" }
      expect(last_response.status).to eq(200)
    end

    it "accepts the UI from this machine" do
      get "/_profiler/", {}, local
      expect(last_response.status).to eq(200)
    end

    it "refuses a non-loopback address" do
      get "/_profiler/api/profiles", {}, remote
      expect(last_response.status).to eq(403)
    end

    it "refuses a Docker bridge address" do
      get "/_profiler/api/profiles", {}, remote.merge("REMOTE_ADDR" => "172.17.0.1")
      expect(last_response.status).to eq(403)
    end

    it "ignores an X-Forwarded-For that claims a loopback client" do
      get "/_profiler/api/profiles", {}, remote.merge("HTTP_X_FORWARDED_FOR" => "127.0.0.1")
      expect(last_response.status).to eq(403)
    end

    it "refuses a remote client relayed by a local proxy" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_X_FORWARDED_FOR" => "203.0.113.9, 127.0.0.1")
      expect(last_response.status).to eq(403)
    end

    it "refuses a remote client named in a Forwarded header" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_FORWARDED" => 'for="203.0.113.9:4711";proto=http')
      expect(last_response.status).to eq(403)
    end

    it "accepts a local client relayed by a local proxy" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_X_FORWARDED_FOR" => "127.0.0.1",
                                                     "HTTP_FORWARDED" => 'for="[::1]:4711"')
      expect(last_response.status).to eq(200)
    end

    it "refuses a DNS-rebound host" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_HOST" => "evil.example:3000")
      expect(last_response.status).to eq(403)
    end

    it "refuses a rebound host that sends a local X-Forwarded-Host" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_HOST" => "evil.example", "HTTP_X_FORWARDED_HOST" => "localhost")
      expect(last_response.status).to eq(403)
    end

    it "refuses a local host with a foreign X-Forwarded-Host" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_X_FORWARDED_HOST" => "evil.example")
      expect(last_response.status).to eq(403)
    end

    it "refuses a non-local host named in a Forwarded header" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_FORWARDED" => "for=127.0.0.1;host=evil.example")
      expect(last_response.status).to eq(403)
    end

    it "accepts a local host named in a Forwarded header" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_FORWARDED" => 'for=127.0.0.1;host="localhost:3000"')
      expect(last_response.status).to eq(200)
    end

    it "accepts a loopback X-Forwarded-For carrying a port" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_X_FORWARDED_FOR" => "127.0.0.1:5555, [::1]:5556")
      expect(last_response.status).to eq(200)
    end

    it "refuses a remote X-Forwarded-For carrying a port" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_X_FORWARDED_FOR" => "203.0.113.9:5555")
      expect(last_response.status).to eq(403)
    end

    it "accepts an IPv6 loopback Host without brackets" do
      get "/_profiler/api/profiles", {}, { "REMOTE_ADDR" => "::1", "HTTP_HOST" => "::1" }
      expect(last_response.status).to eq(200)
    end

    it "refuses the default test hosts outside the test environment" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_HOST" => "www.example.com")
      expect(last_response.status).to eq(403)
    end

    it "accepts a *.localhost name" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_HOST" => "myapp.localhost:3000")
      expect(last_response.status).to eq(200)
    end

    it "accepts a host the application lists in config.hosts" do
      hosts = Rails.application.config.hosts
      hosts << "myapp.test"
      get "/_profiler/api/profiles", {}, local.merge("HTTP_HOST" => "myapp.test")
      expect(last_response.status).to eq(200)
    ensure
      hosts.delete("myapp.test")
    end

    describe "the warning" do
      let(:log) { StringIO.new }

      around do |example|
        previous = Rails.logger
        Rails.logger = Logger.new(log)
        example.run
      ensure
        Rails.logger = previous
      end

      it "names the cause and both ways out, once per process" do
        get "/_profiler/api/profiles", {}, remote
        get "/_profiler/api/profiles", {}, remote.merge("REMOTE_ADDR" => "10.0.0.6")

        warnings = log.string.lines.grep(/allow_local/)
        expect(warnings.size).to eq(1)
        expect(warnings.first).to include("REMOTE_ADDR 10.0.0.5 is not a loopback address")
        expect(warnings.first).to include("refused or not profiled")
        expect(warnings.first).to include(":allow_authorized", "authorize_with", ":allow_all")
      end

      it "is logged when the middleware does not capture a non-local request" do
        get "/hello", {}, remote

        expect(last_response.status).to eq(200)
        expect(last_response.headers).not_to have_key("X-Profiler-Token")
        expect(storage.list).to be_empty
        expect(log.string).to include("REMOTE_ADDR 10.0.0.5 is not a loopback address")
      end

      it "names a forwarding header" do
        get "/_profiler/api/profiles", {}, local.merge("HTTP_X_FORWARDED_FOR" => "203.0.113.9")
        expect(log.string).to include("X-Forwarded-For header reports a non-local client (203.0.113.9)")
      end

      it "names a non-local Host" do
        get "/_profiler/api/profiles", {}, local.merge("HTTP_HOST" => "evil.example")
        expect(log.string).to include('the Host header "evil.example" is not a local name')
      end

      it "is not logged for a local request" do
        get "/hello", {}, local

        expect(last_response.headers).to have_key("X-Profiler-Token")
        expect(log.string).not_to include("allow_local")
      end
    end
  end

  describe ":allow_local in the test environment" do
    before { rails_env("test") }

    # The application's own request specs use the default hosts of rack-test and of Rails
    # integration tests, reserved names (RFC 2606) that no attacker can point at himself.
    it "accepts the default test hosts" do
      %w[www.example.com example.com example.org www.example.com:3000].each do |host|
        get "/_profiler/api/profiles", {}, local.merge("HTTP_HOST" => host)
        expect(last_response.status).to eq(200), host
      end
    end

    it "still refuses any other Host, a server run in the test environment being reachable" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_HOST" => "evil.com")
      expect(last_response.status).to eq(403)
    end

    it "still refuses a foreign X-Forwarded-Host" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_HOST" => "www.example.com",
                                                     "HTTP_X_FORWARDED_HOST" => "evil.com")
      expect(last_response.status).to eq(403)
    end

    it "still refuses a foreign host= in a Forwarded header" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_FORWARDED" => "for=127.0.0.1;host=evil.com")
      expect(last_response.status).to eq(403)
    end

    it "captures the application's request specs" do
      get "/hello", {}, local.merge("HTTP_HOST" => "www.example.com")
      expect(last_response.headers).to have_key("X-Profiler-Token")
    end

    it "still checks REMOTE_ADDR" do
      get "/_profiler/api/profiles", {}, remote.merge("HTTP_HOST" => "www.example.com")
      expect(last_response.status).to eq(403)
    end

    it "still checks forwarding headers" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_X_FORWARDED_FOR" => "203.0.113.9")
      expect(last_response.status).to eq(403)
    end
  end

  describe "CORS" do
    it "never answers Access-Control-Allow-Origin: * by default" do
      get "/_profiler/api/profiles", {}, local.merge("HTTP_ORIGIN" => "https://evil.example")
      expect(last_response.headers["Access-Control-Allow-Origin"]).to be_nil
    end

    it "is disabled by default" do
      expect(Profiler.configuration.extension_cors_enabled).to be(false)
      expect(Profiler.configuration.cors_allowed_origins).to eq([])
    end
  end

  describe "forgery protection" do
    before { storage.save("tok", build_profile(token: "tok")) }

    it "refuses a JSON mutation without the header" do
      delete "/_profiler/api/profiles/clear", {}, local.merge("CONTENT_TYPE" => "application/json")

      expect(last_response.status).to eq(403)
      expect(json["error"]).to include("X-Profiler-Request")
      expect(storage.load("tok")).not_to be_nil
    end

    it "refuses a form POST turned into a DELETE by _method" do
      post "/_profiler/api/profiles/clear", { "_method" => "delete" }, local

      expect(last_response.status).to eq(403)
      expect(storage.load("tok")).not_to be_nil
    end

    it "refuses a form POST turned into a PATCH of ENV by _method" do
      post "/_profiler/api/env_vars", { "_method" => "patch", "key" => "PROFILER_SPEC_VAR", "value" => "1" }, local

      expect(last_response.status).to eq(403)
      expect(ENV).not_to have_key("PROFILER_SPEC_VAR")
    end

    it "refuses a plain form POST" do
      post "/_profiler/api/ajax/link", { "parent_token" => "a", "child_token" => "tok" }, local

      expect(last_response.status).to eq(403)
      expect(storage.load("tok").parent_token).to be_nil
    end

    it "accepts a mutation carrying the header" do
      delete "/_profiler/api/profiles/clear", {}, local.merge(profiler_header)

      expect(last_response.status).to eq(204)
      expect(storage.load("tok")).to be_nil
    end

    it "accepts a mutation carrying the Rails CSRF token" do
      get "/_profiler/", {}, local
      token = last_response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
      expect(token).not_to be_nil

      delete "/_profiler/api/profiles/clear", {}, local.merge("HTTP_X_CSRF_TOKEN" => token)
      expect(last_response.status).to eq(204)
    end

    context "when the application turns forgery protection off" do
      # What the config/environments/test.rb generated by Rails does.
      around do |example|
        previous = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        example.run
      ensure
        ActionController::Base.allow_forgery_protection = previous
      end

      it "still refuses a mutation without the header" do
        post "/_profiler/api/profiles/clear", { "_method" => "delete" }, local

        expect(last_response.status).to eq(403)
        expect(storage.load("tok")).not_to be_nil
      end

      it "still accepts a mutation carrying the header" do
        delete "/_profiler/api/profiles/clear", {}, local.merge(profiler_header)
        expect(last_response.status).to eq(204)
      end
    end

    it "accepts a mutation without either when api_forgery_protection is off" do
      Profiler.configuration.api_forgery_protection = false
      post "/_profiler/api/profiles/clear", { "_method" => "delete" }, local

      expect(last_response.status).to eq(204)
    end
  end

  describe "framing" do
    it "only lets the profiler itself, the extension and DevTools frame it" do
      get "/_profiler/", {}, local

      expect(last_response.headers["Content-Security-Policy"]).to eq("frame-ancestors 'self' chrome-extension: devtools:")
      expect(last_response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
    end

    it "applies to the dashboard URL without a trailing slash" do
      get "/_profiler", {}, local

      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Security-Policy"]).to eq("frame-ancestors 'self' chrome-extension: devtools:")
      expect(last_response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
    end

    it "keeps the same policy on the embedded profile page" do
      storage.save("tok", build_profile(token: "tok"))
      get "/_profiler/profiles/tok", { embed: "true" }, local

      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Security-Policy"]).to eq("frame-ancestors 'self' chrome-extension: devtools:")
      expect(last_response.headers["X-Frame-Options"]).to eq("SAMEORIGIN")
    end

    it "keeps the policy on a refused request" do
      get "/_profiler/api/profiles", {}, remote

      expect(last_response.headers["Content-Security-Policy"]).to eq("frame-ancestors 'self' chrome-extension: devtools:")
    end
  end
end
