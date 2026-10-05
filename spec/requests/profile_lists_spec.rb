# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/rails_app"

# PERF-03, PERF-04 and FAB-17 through the real controller stack: the dashboard lists are paged by
# the store, past the thousandth profile included; a profile page reads its children once; the
# AJAX tab shows the sub-requests of a page with the default collector list.
RSpec.describe "Profile lists and children through the profiler API", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:base_time) { Time.at(Time.now.to_i - 7200) }

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
      # The default list of the railtie, which has no AjaxCollector.
      config.collectors = []
      config.track_http = false
      config.tmp_path = Pathname.new(File.join(@root, "profiler"))
    end
    Profiler.instance_variable_set(:@storage, store)
  end

  let(:store) { Profiler::Storage::MemoryStore.new(max_profiles: 5000) }

  def save(index, **attrs)
    build_profile(started_at: base_time + index, path: "/p#{index}", **attrs).tap { |p| store.save(p.token, p) }
  end

  def json
    JSON.parse(last_response.body)
  end

  describe "GET /api/profiles" do
    it "pages past the thousandth profile, with has_more right" do
      (0...1030).each { |i| save(i) }

      get "/_profiler/api/profiles", { limit: 25, offset: 1000 }, local

      expect(last_response.status).to eq(200)
      expect(json["profiles"].map { |p| p["path"] }).to eq((5...30).map { |i| "/p#{i}" }.reverse)
      expect(json["has_more"]).to be true

      get "/_profiler/api/profiles", { limit: 25, offset: 1025 }, local
      expect(json["profiles"].size).to eq(5)
      expect(json["has_more"]).to be false
    end

    it "finds the http profiles behind a thousand newer profiles of other types" do
      older = (0...3).map { |i| save(i) }
      (3...1010).each { |i| save(i, profile_type: "job") }

      get "/_profiler/api/profiles", { limit: 50 }, local

      expect(json["profiles"].map { |p| p["token"] }).to eq(older.reverse.map(&:token))
    end

    it "lists summaries, without the bodies" do
      profile = build_profile(started_at: base_time + 1, path: "/p1",
                              collectors_data: { "database" => { "total_queries" => 4, "queries" => [{ "sql" => "SELECT 1" }] } })
      profile.allocated_objects = 321
      store.save(profile.token, profile)

      get "/_profiler/api/profiles", { limit: 50 }, local

      listed = json["profiles"].first
      expect(listed["token"]).to eq(profile.token)
      expect(listed["collectors_data"]["database"]).to eq("total_queries" => 4)
      expect(listed["allocated_objects"]).to eq(321)
    end

    it "keeps the full profiles of every type for the cluster proxy" do
      job = save(1, profile_type: "job", collectors_data: { "job" => { "queue" => "q", "arguments" => [1] } })

      get "/_profiler/api/profiles", { limit: 50, all_types: 1 }, local

      expect(json["profiles"].map { |p| p["token"] }).to eq([job.token])
      expect(json["profiles"].first["collectors_data"]["job"]["arguments"]).to eq([1])
    end
  end

  %w[jobs console tests].each do |kind|
    type = { "jobs" => "job", "console" => "console", "tests" => "test" }.fetch(kind)

    describe "GET /api/#{kind}" do
      it "finds the #{type} profiles behind a thousand newer http profiles" do
        older = (0...2).map { |i| save(i, profile_type: type) }
        (2...1010).each { |i| save(i) }

        get "/_profiler/api/#{kind}", { limit: 50 }, local

        expect(json["profiles"].map { |p| p["token"] }).to eq(older.reverse.map(&:token))
        expect(json["has_more"]).to be false
      end
    end
  end

  describe "a page with AJAX sub-requests, under the default collectors" do
    let!(:parent) { save(0) }
    let!(:children) { (1..2).map { |i| save(i, parent_token: parent.token, is_ajax: true, method: "POST") } }
    let!(:job) { save(3, parent_token: parent.token, profile_type: "job") }

    it "shows the AJAX tab with the sub-requests in the API" do
      get "/_profiler/api/profiles/#{parent.token}", {}, local

      ajax = json["collectors_data"]["ajax"]
      expect(ajax["total_requests"]).to eq(2)
      expect(ajax["requests"].map { |r| r["token"] }).to eq(children.map(&:token))
      expect(json["tabs"].find { |t| t["key"] == "ajax" }).to include("has_data" => true)
      expect(json["child_jobs"].map { |j| j["token"] }).to eq([job.token])
    end

    it "shows them in the toolbar" do
      get "/_profiler/api/toolbar/#{parent.token}", {}, local

      expect(json["profile"]["collectors_data"]["ajax"]["total_requests"]).to eq(2)
      expect(json["profile"]["tabs"].find { |t| t["key"] == "ajax" }).to include("has_data" => true)
    end

    it "shows them on the profile page" do
      get "/_profiler/profiles/#{parent.token}", {}, local

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include(children.first.token)
    end

    it "reads the children once per page, with the AJAX collector configured or not" do
      [[], [Profiler::Collectors::AjaxCollector]].each do |collectors|
        Profiler.configuration.collectors = collectors
        calls = 0
        allow(store).to receive(:find_by_parent).and_wrap_original { |original, *args| calls += 1; original.call(*args) }

        get "/_profiler/api/profiles/#{parent.token}", {}, local
        get "/_profiler/api/toolbar/#{parent.token}", {}, local

        expect(calls).to eq(2)
      end
    end
  end

  describe "a page without sub-requests" do
    it "gets no AJAX tab" do
      parent = save(0)

      get "/_profiler/api/profiles/#{parent.token}", {}, local

      expect(json["tabs"].map { |t| t["key"] }).not_to include("ajax")
    end
  end
end
