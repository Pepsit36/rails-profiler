# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "opentelemetry/sdk"
require "opentelemetry-metrics-sdk"
require "profiler/otel/metrics_exporter"

RSpec.describe Profiler::Otel::MetricsExporter do
  include Rack::Test::Methods

  let(:reader) { OpenTelemetry::SDK::Metrics::Export::InMemoryMetricPullExporter.new }
  let(:provider) do
    OpenTelemetry::SDK::Metrics::MeterProvider.new.tap { |p| p.add_metric_reader(reader) }
  end

  def default_host
    "localhost"
  end

  before do
    Profiler::Otel::Sdk.reset!
    Profiler.configure do |c|
      c.enabled = true
      c.skip_paths = []
      c.track_memory = false
      c.otel_enabled = true
    end
    allow(OpenTelemetry).to receive(:meter_provider).and_return(provider)
  end

  after { Profiler::Otel::Sdk.reset! }

  def snapshots
    reader.reset
    reader.pull
    reader.metric_snapshots.group_by(&:name)
  end

  def points(name)
    Array(snapshots[name]).flat_map(&:data_points)
  end

  def build_profile(queries: [], allocated: 1234)
    profile = Profiler::Models::Profile.new
    profile.method = "GET"
    profile.path = "/users/42?secret=abc"
    profile.finish(200)
    profile.duration = 80.0
    profile.allocated_objects = allocated
    profile.collectors_data["request"] = { "controller_action" => "UsersController#show" }
    profile.collectors_data["database"] = { "queries" => queries }
    profile.collectors_data["view"] = { "views" => [{ "identifier" => "app/views/users/show.erb", "duration" => 7.5 }],
                                        "partials" => [{ "identifier" => "app/views/users/_card.erb", "duration" => 2.5 }] }
    profile.collectors_data["cache"] = { "reads" => [{ "key" => "user/42", "hit" => true, "duration" => 1.5 }],
                                         "writes" => [{ "key" => "user/42", "duration" => 3.0 }] }
    profile.collectors_data["http"] = {
      "requests" => [{ "method" => "GET", "url" => "https://api.example.com/v1?token=s3cr3t", "status" => 200,
                       "duration" => 40.0, "in_flight" => false },
                     { "method" => "GET", "url" => "https://slow.example.com/", "duration" => 5.0, "in_flight" => true }]
    }
    profile
  end

  def query(sql, duration)
    { "sql" => sql, "duration" => duration }
  end

  it "records the duration histograms with the values the collectors hold" do
    profile = build_profile(queries: [query("SELECT * FROM users WHERE id = 42", 4.0),
                                      query("UPDATE users SET name = 'x'", 6.0),
                                      { "sql" => "BEGIN", "duration" => 0.1, "transaction" => true }])

    expect(described_class.export(profile)).to be(true)

    expect(points("profiler.request.duration").map(&:sum)).to eq([80.0])
    expect(points("profiler.db.query.duration").map(&:sum)).to contain_exactly(4.0, 6.0)
    expect(points("profiler.db.query.duration").map { |p| p.attributes["db.operation.name"] }).to contain_exactly("SELECT", "UPDATE")
    expect(points("profiler.view.render.duration").map(&:sum)).to eq([10.0])
    expect(points("profiler.view.render.duration").map(&:count)).to eq([2])
    expect(points("profiler.cache.operation.duration").map { |p| [p.attributes["cache.operation"], p.sum] })
      .to contain_exactly(["read", 1.5], ["write", 3.0])
    expect(points("profiler.http.client.request.duration").map { |p| [p.count, p.sum] }).to eq([[1, 40.0]])
  end

  it "counts the allocated objects" do
    described_class.export(build_profile(allocated: 1234))
    expect(points("profiler.request.allocations").map(&:value)).to eq([1234])
  end

  it "records no allocations, and does not fail, when track_memory left them nil" do
    expect(described_class.export(build_profile(allocated: nil))).to be(true)
    expect(snapshots).not_to have_key("profiler.request.allocations")
    expect(snapshots).to have_key("profiler.request.duration")
  end

  it "counts a request with an N+1 once, however many groups repeat" do
    repeated = [query("SELECT * FROM posts WHERE user_id = 1", 1.0), query("SELECT * FROM posts WHERE user_id = 2", 1.0),
                query("SELECT * FROM posts WHERE user_id = 3", 1.0), query("SELECT * FROM tags WHERE id = 1", 1.0),
                query("SELECT * FROM tags WHERE id = 2", 1.0)]
    described_class.export(build_profile(queries: repeated))
    expect(points("profiler.request.n_plus_one").map(&:value)).to eq([1])
  end

  it "does not count a request whose queries are all different" do
    distinct = [query("SELECT * FROM posts WHERE user_id = 1", 1.0), query("SELECT * FROM tags WHERE id = 1", 1.0),
                { "sql" => "COMMIT", "duration" => 0.1, "transaction" => true },
                { "sql" => "COMMIT", "duration" => 0.1, "transaction" => true }]
    described_class.export(build_profile(queries: distinct))
    expect(snapshots).not_to have_key("profiler.request.n_plus_one")
  end

  it "emits only low-cardinality attributes: no token, path, URL, SQL text or cache key" do
    profile = build_profile(queries: [query("SELECT * FROM users WHERE email = 'a@b.c'", 1.0),
                                      query("SELECT * FROM users WHERE email = 'd@e.f'", 1.0)])
    described_class.export(profile)

    attributes = snapshots.values.flatten.flat_map(&:data_points).map(&:attributes)
    expect(attributes).not_to be_empty
    rendered = attributes.map(&:to_a).flatten.map(&:to_s).join(" ")
    [profile.token.to_s, "/users", "secret", "api.example.com", "s3cr3t", "https://", "SELECT *", "email", "a@b.c", "user/42"].each do |leak|
      expect(rendered).not_to include(leak) unless leak.empty?
    end
    expect(attributes.flat_map(&:keys).uniq).to match_array(
      %w[profiler.controller_action http.request.method http.response.status_code db.operation.name cache.operation]
    )
    expect(attributes.map { |a| a["profiler.controller_action"] }.uniq).to eq(["UsersController#show"])
  end

  it "falls back to a fixed value for an unknown route and an unusual method" do
    profile = build_profile
    profile.collectors_data.delete("request")
    profile.method = "PURGE-#{SecureRandom.hex(4)}"
    described_class.export(profile)
    attributes = points("profiler.request.duration").map(&:attributes)
    expect(attributes).to eq([{ "profiler.controller_action" => "unknown", "http.request.method" => "_OTHER",
                                "http.response.status_code" => 200 }])
  end

  context "through the middleware" do
    def app
      Profiler::Middleware::ProfilerMiddleware.new(
        lambda do |_env|
          3.times { |i| ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM posts WHERE id = #{i}", name: "Load", binds: []) }
          [200, { "Content-Type" => "text/plain" }, ["ok"]]
        end
      )
    end

    before do
      Profiler.configuration.collectors = [Profiler::Collectors::DatabaseCollector]
      Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
    end

    it "records the metrics of a profiled request, with the N+1 it ran" do
      get "/posts/7"
      expect(points("profiler.request.duration").size).to eq(1)
      expect(points("profiler.db.query.duration").sum(&:count)).to eq(3)
      expect(points("profiler.request.n_plus_one").map(&:value)).to eq([1])
    end
  end

  it "reuses the application's meter provider instead of building one" do
    expect(OpenTelemetry::SDK::Metrics::MeterProvider).not_to receive(:new)
    described_class.export(build_profile)
    expect(snapshots).not_to be_empty
  end

  it "never raises into the request when the export fails" do
    allow(provider).to receive(:meter).and_raise("boom")
    allow(Profiler).to receive(:log_error_once)
    expect(described_class.export(build_profile)).to be(false)
    expect(Profiler).to have_received(:log_error_once)
  end

  it "builds its own http/protobuf OTLP metrics exporter, not installed globally, when the application has none" do
    allow(OpenTelemetry).to receive(:meter_provider).and_call_original
    require "opentelemetry/exporter/otlp_metrics"
    Profiler.configuration.otel_otlp_endpoint = "http://collector.test:4318/v1/traces"
    Profiler.configuration.otel_service_name = "svc"
    expect(OpenTelemetry::Exporter::OTLP::Metrics::MetricsExporter).to receive(:new)
      .with(endpoint: "http://collector.test:4318/v1/metrics").and_call_original

    own = Profiler::Otel::Sdk.meter_provider

    expect(own).to be_a(OpenTelemetry::SDK::Metrics::MeterProvider)
    expect(own.resource.attribute_enumerator.to_h["service.name"]).to eq("svc")
    expect(OpenTelemetry.meter_provider).not_to equal(own)
    own.shutdown
  end

  it "warns and exports nothing when it has to build its own exporter but has no endpoint" do
    allow(OpenTelemetry).to receive(:meter_provider).and_call_original
    stub_const("ENV", ENV.to_h.reject { |k, _| k.start_with?("OTEL_") })
    expect(Profiler).to receive(:log_error).with(/otel_otlp_endpoint is not set/)
    expect(Profiler::Otel::Sdk.meter_provider).to be_nil
  end
end
