# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"
require "profiler/mcp/tools/get_profile_detail"
require "profiler/console_profiler"
require "profiler/test_profiler"

class ProfilerSpecWidgetsController < ActionController::Base
  def show
    head :ok
  end
end

# The route table and ENV are the same for every request of a process. A profile keeps the route
# the request matched; the Routes and Env tabs, and the MCP tools, get the table and the variables
# from the process when the profile is displayed.
RSpec.describe "Routes and Env tabs", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:storage) { Profiler::Storage::MemoryStore.new }

  def app
    Rails.application
  end

  before(:all) do
    Rails.application.routes.append do
      get "/spec_widgets/:id", to: "profiler_spec_widgets#show", as: :spec_widget
      post "/spec_widgets", to: "profiler_spec_widgets#create"
    end
    Rails.application.reload_routes!
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, storage)
    ENV["PROFILER_SPEC_API_TOKEN"] = "s3cr3t-value"
  end

  after { ENV.delete("PROFILER_SPEC_API_TOKEN") }

  # A profile as the middleware leaves it: collected, then saved.
  def capture(path:, method: "GET")
    profile = build_profile(path: path, method: method)
    [Profiler::Collectors::RoutesCollector, Profiler::Collectors::EnvCollector].each do |klass|
      collector = klass.new(profile)
      collector.collect
      profile.add_collector_metadata(collector)
    end
    storage.save(profile.token, profile)
    profile.token
  end

  def shown(token)
    get "/_profiler/api/profiles/#{token}", {}, local
    expect(last_response.status).to eq(200)
    JSON.parse(last_response.body)["collectors_data"]
  end

  describe "what a profile stores" do
    it "keeps the matched route and the size of the table, not the table" do
      routes = storage.load(capture(path: "/spec_widgets/7")).collector_data("routes")

      expect(routes).not_to have_key("routes")
      expect(routes["matched"]).to include("pattern" => "/spec_widgets/:id", "verb" => "GET",
                                           "name" => "spec_widget",
                                           "controller_action" => "ProfilerSpecWidgetsController#show")
      expect(routes["total"]).to eq(2)
    end

    it "keeps no ENV variable" do
      env = storage.load(capture(path: "/spec_widgets/7")).collector_data("env")

      expect(env).not_to have_key("variables")
      expect(env.to_json).not_to include("PROFILER_SPEC_API_TOKEN")
    end

    it "is smaller by the size of the route table and of ENV" do
      token = capture(path: "/spec_widgets/7")
      stored = storage.load(token).collectors_data.slice("routes", "env").to_json.bytesize
      displayed = shown(token).slice("routes", "env").to_json.bytesize

      expect(stored).to be < 400
      expect(displayed).to be > stored + ENV.size * 10
    end
  end

  describe "what the Routes tab shows" do
    it "lists the process's routes and marks the one the request matched" do
      routes = shown(capture(path: "/spec_widgets/7"))["routes"]

      expect(routes["total"]).to eq(2)
      expect(routes["routes"].map { |r| [r["verb"], r["pattern"], r["matched"]] })
        .to contain_exactly(["GET", "/spec_widgets/:id", true], ["POST", "/spec_widgets", false])
      expect(routes["matched"]["pattern"]).to eq("/spec_widgets/:id")
    end

    it "marks no route when the request matched none" do
      routes = shown(capture(path: "/nowhere"))["routes"]

      expect(routes["matched"]).to be_nil
      expect(routes["routes"].map { |r| r["matched"] }).to all(be(false))
    end

    it "follows the routes when they are reloaded, as in development" do
      token = capture(path: "/spec_widgets/7")
      appended = Rails.application.routes.instance_variable_get(:@append)
      Rails.application.routes.append { delete "/spec_widgets/:id", to: "profiler_spec_widgets#destroy" }
      Rails.application.reload_routes!

      begin
        routes = shown(token)["routes"]

        expect(routes["routes"].map { |r| r["verb"] }).to contain_exactly("GET", "POST", "DELETE")
        expect(routes["total"]).to eq(3)
      ensure
        appended.pop
        Rails.application.reload_routes!
      end

      expect(shown(token)["routes"]["routes"].map { |r| r["verb"] }).to contain_exactly("GET", "POST")
    end

    it "shows a profile saved by an earlier version, with its own table, as it was" do
      old = build_profile(collectors_data: {
        "routes" => {
          "total" => 1,
          "matched" => { "name" => "legacy", "pattern" => "/legacy", "verb" => "GET",
                         "controller_action" => "LegacyController#index", "matched" => true },
          "routes" => [{ "name" => "legacy", "pattern" => "/legacy", "verb" => "GET",
                         "controller_action" => "LegacyController#index", "matched" => true }]
        },
        "env" => { "variables" => { "LEGACY" => "kept" }, "total" => 1 }
      })
      storage.save(old.token, old)

      data = shown(old.token)

      expect(data["routes"]["routes"].map { |r| r["pattern"] }).to eq(["/legacy"])
      expect(data["env"]).to eq("variables" => { "LEGACY" => "kept" }, "total" => 1)
    end
  end

  describe "what the Env tab shows" do
    it "lists the process's variables, masked as before" do
      env = shown(capture(path: "/spec_widgets/7"))["env"]

      expect(env["variables"]["PROFILER_SPEC_API_TOKEN"]).to eq(Profiler::Redaction::MASK)
      expect(env["variables"]["RAILS_ENV"]).to eq(ENV["RAILS_ENV"])
      expect(env["total"]).to eq(env["variables"].size)
    end
  end

  describe "what no path lets out, as the stored profile did not" do
    let(:secret) { "cluster-secret-#{"s" * 32}" }

    before do
      Profiler.configure do |config|
        config.cluster_secret = secret
        config.env_allowlist += ["PROFILER_SPEC_VISIBLE"]
      end
      ENV["PROFILER_SPEC_VISIBLE"] = "prefix #{secret}"
    end

    after { ENV.delete("PROFILER_SPEC_VISIBLE") }

    it "masks the profiler's own credential inside a variable shown in clear, in the API" do
      env = shown(capture(path: "/spec_widgets/7"))["env"]

      expect(env["variables"]["PROFILER_SPEC_VISIBLE"]).to start_with("prefix ")
      expect(env.to_json).not_to include(secret)
      expect(env.to_json).not_to include("s3cr3t-value")
    end

    it "masks them in the MCP profile detail too" do
      text = Profiler::MCP::Tools::GetProfileDetail.format_profile_detail(
        storage.load(capture(path: "/spec_widgets/7")), { "sections" => ["env"], "env_filter" => "PROFILER_SPEC" }
      )

      expect(text).to include("PROFILER_SPEC_VISIBLE")
      expect(text).not_to include(secret)
      expect(text).not_to include("s3cr3t-value")
    end

    it "never lends this process's ENV to a slave's profile in the MCP" do
      text = Profiler::MCP::Tools::GetProfileDetail.format_profile_detail(
        storage.load(capture(path: "/spec_widgets/7")), { "sections" => ["env"], "env_filter" => "PROFILER_SPEC", "slave" => "api" }
      )

      expect(text).not_to include("PROFILER_SPEC_VISIBLE")
    end
  end

  # A job, a console expression or a test runs in another process than the one that serves the
  # dashboard (Sidekiq, the console, rspec): its profile keeps that process's ENV, masked, and the
  # dashboard never shows its own in its place.
  describe "profiles of jobs, console expressions and tests" do
    before do
      Profiler.configure do |config|
        config.track_jobs = true
        config.track_console = true
        config.track_tests = true
        config.env_allowlist += ["PROFILER_SPEC_WORKER"]
      end
      ENV["PROFILER_SPEC_WORKER"] = "the worker's value"
    end

    after { ENV.delete("PROFILER_SPEC_WORKER") }

    {
      "job" => -> { Profiler::JobProfiler.profile(job_class: "W", job_id: "1", queue: "q", arguments: [], executions: 0) { :ok } },
      "console" => -> { Profiler::ConsoleProfiler.profile(expression: "1 + 1") { 2 } },
      "test" => lambda {
        Profiler::TestProfiler.profile(test_name: "t", test_file: "spec/t_spec.rb", test_line: 1, framework: "rspec") { :ok }
      }
    }.each do |type, run|
      endpoint = { "job" => "jobs", "console" => "console", "test" => "tests" }[type]

      it "keeps the #{type}'s own ENV, masked, through its API endpoint and the profile page" do
        run.call
        token = storage.list(limit: 100).find { |p| p.profile_type == type }.token
        ENV["PROFILER_SPEC_WORKER"] = "the web process's value"

        get "/_profiler/api/#{endpoint}/#{token}", {}, local
        env = JSON.parse(last_response.body)["collectors_data"]["env"]
        expect(env["variables"]["PROFILER_SPEC_WORKER"]).to eq("the worker's value")
        expect(env["variables"]["PROFILER_SPEC_API_TOKEN"]).to eq(Profiler::Redaction::MASK)
        expect(env["total"]).to eq(env["variables"].size)

        get "/_profiler/api/profiles/#{token}", {}, local
        shown = JSON.parse(last_response.body)["collectors_data"]["env"]
        expect(shown["variables"]["PROFILER_SPEC_WORKER"]).to eq("the worker's value")
      end
    end
  end

  describe "the toolbar" do
    it "gets the same table and variables" do
      token = capture(path: "/spec_widgets/7")
      get "/_profiler/api/toolbar/#{token}", {}, local

      data = JSON.parse(last_response.body)["profile"]["collectors_data"]
      expect(data["routes"]["routes"].size).to eq(2)
      expect(data["env"]["variables"]).to have_key("PROFILER_SPEC_API_TOKEN")
    end
  end

  describe "the profile page" do
    it "embeds the table and the variables" do
      get "/_profiler/profiles/#{capture(path: "/spec_widgets/7")}", {}, local

      script = last_response.body[%r{<script type="application/json" id="profiler-show-data">(.*?)</script>}m, 1]
      data = JSON.parse(script)
      collectors = data["collectors_data"] || data.dig("profile", "collectors_data")
      expect(collectors["routes"]["routes"].size).to eq(2)
      expect(collectors["env"]["variables"]).to have_key("PROFILER_SPEC_API_TOKEN")
    end
  end

  describe "the MCP profile detail" do
    it "filters the process's variables" do
      text = Profiler::MCP::Tools::GetProfileDetail.format_profile_detail(
        storage.load(capture(path: "/spec_widgets/7")), { "sections" => ["env"], "env_filter" => "PROFILER_SPEC" }
      )

      expect(text).to include("`PROFILER_SPEC_API_TOKEN` = `#{Profiler::Redaction::MASK}`")
    end

    it "gives the matched route" do
      text = Profiler::MCP::Tools::GetProfileDetail.format_profile_detail(
        storage.load(capture(path: "/spec_widgets/7")), { "sections" => ["routes"] }
      )

      expect(text).to include("**Matched:** `GET /spec_widgets/:id`")
    end
  end
end
