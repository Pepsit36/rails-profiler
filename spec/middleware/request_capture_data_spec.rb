# frozen_string_literal: true

require "spec_helper"
require "rack"
require "action_controller"

# What a profile keeps of a request is what the controller saw: the params after the routing
# (route segments, param_encoding), and text bodies with their accents.
RSpec.describe Profiler::Middleware::ProfilerMiddleware, "request capture data" do
  before do
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = [Profiler::Collectors::RequestCollector]
      c.skip_paths = []
      c.track_memory = false
      c.track_http = false
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def profile_of(app, env)
    _status, headers, = described_class.new(app).call(env)
    Profiler.storage.load(headers["X-Profiler-Token"])
  end

  describe "params" do
    before do
      stub_const("ItemsController", Class.new(ActionController::Base) do
        param_encoding :index, "name", Encoding::ISO_8859_1
      end)
    end

    it "keeps the route parameters, which only exist once the router has run" do
      app = lambda do |env|
        env["action_dispatch.request.path_parameters"] = { controller: "items", action: "show", id: "42" }
        [200, Rack::Headers["content-type" => "text/plain"], ["ok"]]
      end
      env = Rack::MockRequest.env_for("http://localhost/items/42?q=1", "REMOTE_ADDR" => "127.0.0.1")

      expect(profile_of(app, env).params).to include("id" => "42", "q" => "1")
    end

    it "keeps the params the encoding declared by the route gives them" do
      app = lambda do |env|
        env["action_dispatch.request.path_parameters"] = { controller: "items", action: "index" }
        [200, Rack::Headers["content-type" => "text/plain"], ["ok"]]
      end
      env = Rack::MockRequest.env_for("http://localhost/items?name=caf%E9", "REMOTE_ADDR" => "127.0.0.1")

      expect(profile_of(app, env).params["name"]).to eq("café".encode("ISO-8859-1").force_encoding("ISO-8859-1").encode("UTF-8"))
    end
  end

  describe "text bodies" do
    {
      "application/xml" => "<nom>Éléonore à Noël, crème brûlée</nom>",
      "text/csv" => "nom;ville\nÉléonore;Orléans\n",
      "text/plain" => "Crème brûlée à l'été, œuf"
    }.each do |type, text|
      it "keeps the accents of a #{type} request and response" do
        app = lambda do |env|
          env["rack.input"].read
          [200, Rack::Headers["content-type" => type], [text.b]]
        end
        env = Rack::MockRequest.env_for("http://localhost/doc", method: "POST", input: text.b,
                                        "CONTENT_TYPE" => type, "REMOTE_ADDR" => "127.0.0.1")
        profile = profile_of(app, env)

        expect(profile.request_body).to eq(text)
        expect(profile.response_body).to eq(text)
      end
    end

    it "converts a body to UTF-8 from the charset it declares" do
      latin1 = "Crème brûlée".encode("ISO-8859-1")
      app = ->(_env) { [200, Rack::Headers["content-type" => "text/plain; charset=ISO-8859-1"], [latin1.b]] }
      env = Rack::MockRequest.env_for("http://localhost/doc", "REMOTE_ADDR" => "127.0.0.1")

      expect(profile_of(app, env).response_body).to eq("Crème brûlée")
    end

    %w[utf-7 internal].each do |charset|
      it "keeps a profile, with replacement characters, for charset=#{charset}" do
        app = ->(_env) { [200, Rack::Headers["content-type" => "text/plain; charset=#{charset}"], ["ok \xFF caf\xC3\xA9".b]] }
        env = Rack::MockRequest.env_for("http://localhost/doc", "REMOTE_ADDR" => "127.0.0.1")
        body = profile_of(app, env).response_body

        expect(body).to start_with("ok ")
        expect(body).to be_valid_encoding
        expect(body).to include("\uFFFD")
      end
    end

    it "replaces invalid sequences instead of failing" do
      app = ->(_env) { [200, Rack::Headers["content-type" => "text/plain"], ["ok \xFF\xFE".b]] }
      env = Rack::MockRequest.env_for("http://localhost/doc", "REMOTE_ADDR" => "127.0.0.1")
      body = profile_of(app, env).response_body

      expect(body).to start_with("ok ")
      expect(body).to be_valid_encoding
    end
  end
end
