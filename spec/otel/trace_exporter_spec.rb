# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "opentelemetry/sdk"
require "profiler/otel/trace_exporter"

RSpec.describe Profiler::Otel::TraceExporter do
  include Rack::Test::Methods

  let(:memory) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:provider) do
    OpenTelemetry::SDK::Trace::TracerProvider.new.tap do |p|
      p.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(memory))
    end
  end
  let(:trace_id) { "0af7651916cd43dd8448eb211c80319c" }
  let(:parent_id) { "b7ad6b7169203331" }

  def hex(bytes)
    bytes.unpack1("H*")
  end

  def default_host
    "localhost"
  end

  def app
    Profiler::Middleware::ProfilerMiddleware.new(
      lambda do |_env|
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1", name: "Load", binds: [])
        ActiveSupport::Notifications.instrument("render_template.action_view", identifier: "app/views/x.erb")
        ActiveSupport::Notifications.instrument("cache_read.active_support", key: "k", hit: true)
        [200, { "Content-Type" => "text/plain" }, ["ok"]]
      end
    )
  end

  before do
    Profiler::Otel::Sdk.reset!
    Profiler.configure do |c|
      c.enabled = true
      c.skip_paths = []
      c.track_memory = false
      c.collectors = [Profiler::Collectors::DatabaseCollector, Profiler::Collectors::ViewCollector,
                      Profiler::Collectors::CacheCollector, Profiler::Collectors::HttpCollector]
      c.otel_enabled = true
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
    allow(OpenTelemetry).to receive(:tracer_provider).and_return(provider)
  end

  after { Profiler::Otel::Sdk.reset! }

  def saved_profile
    Profiler.storage.load(last_response.headers["X-Profiler-Token"] || last_response.headers["x-profiler-token"])
  end

  it "exports the root span with the profile's own trace_id and span_id, and its children under it" do
    get "/"

    profile = saved_profile
    spans = memory.finished_spans
    root = spans.find { |s| s.kind == :server }
    expect(hex(root.trace_id)).to eq(profile.trace_id)
    expect(hex(root.span_id)).to eq(profile.span_id)
    expect(root.hex_parent_span_id).to eq("0" * 16)

    children = spans - [root]
    expect(children.map(&:name)).to include("SELECT", "render_template app/views/x.erb", "cache read")
    children.each do |child|
      expect(hex(child.trace_id)).to eq(profile.trace_id)
      expect(hex(child.parent_span_id)).to eq(profile.span_id)
    end
  end

  it "makes the root a child of the caller's span when a traceparent came in" do
    get "/", {}, "HTTP_TRACEPARENT" => "00-#{trace_id}-#{parent_id}-01"

    profile = saved_profile
    root = memory.finished_spans.find { |s| s.kind == :server }
    expect(hex(root.trace_id)).to eq(trace_id)
    expect(hex(root.span_id)).to eq(profile.span_id)
    expect(root.hex_parent_span_id).to eq(parent_id)
  end

  it "exports an outbound HTTP call as a child span, without the query string" do
    profile = Profiler::Models::Profile.new
    profile.trace_id = trace_id
    profile.span_id = "1122334455667788"
    profile.method = "GET"
    profile.path = "/x"
    profile.finish(200)
    profile.collectors_data["http"] = {
      "requests" => [{ "method" => "GET", "url" => "https://api.example.com/v1?token=secret", "status" => 200,
                       "duration" => 12.5, "in_flight" => false, "started_at" => Time.now.iso8601(3) }]
    }

    expect(described_class.export(profile)).to be(true)

    http = memory.finished_spans.find { |s| s.name == "HTTP GET" }
    expect(http.kind).to eq(:client)
    expect(hex(http.parent_span_id)).to eq("1122334455667788")
    expect(http.attributes["url.full"]).to eq("https://api.example.com/v1")
    expect(http.attributes["http.response.status_code"]).to eq(200)
    expect(memory.finished_spans.find { |s| s.kind == :server }.hex_span_id).to eq("1122334455667788")
  end

  it "reuses the application's provider instead of building one" do
    expect(OpenTelemetry::SDK::Trace::TracerProvider).not_to receive(:new)
    get "/"
    expect(memory.finished_spans).not_to be_empty
  end

  it "keeps the provider's own ids for spans the application starts itself" do
    get "/"
    own = provider.tracer("app").start_root_span("own")
    own.finish
    expect(own.context.trace_id).not_to eq([saved_profile.trace_id].pack("H*"))
  end

  it "never raises into the request when the export fails" do
    allow(provider).to receive(:tracer).and_raise("boom")
    allow(Profiler).to receive(:log_error_once)
    get "/"
    expect(last_response.status).to eq(200)
    expect(Profiler).to have_received(:log_error_once)
  end

  it "builds its own http/protobuf OTLP exporter when the application has no SDK" do
    allow(OpenTelemetry).to receive(:tracer_provider).and_call_original
    require "opentelemetry/exporter/otlp"
    Profiler.configuration.otel_otlp_endpoint = "http://collector.test:4318/v1/traces"
    Profiler.configuration.otel_service_name = "svc"
    expect(OpenTelemetry::Exporter::OTLP::Exporter).to receive(:new)
      .with(endpoint: "http://collector.test:4318/v1/traces").and_call_original

    own = Profiler::Otel::Sdk.tracer_provider

    expect(own).to be_a(OpenTelemetry::SDK::Trace::TracerProvider)
    expect(own.resource.attribute_enumerator.to_h["service.name"]).to eq("svc")
    own.shutdown
  end

  it "warns and exports nothing when it has to build its own exporter but has no endpoint" do
    allow(OpenTelemetry).to receive(:tracer_provider).and_call_original
    stub_const("ENV", ENV.to_h.reject { |k, _| k.start_with?("OTEL_") })
    expect(Profiler).to receive(:log_error).with(/otel_otlp_endpoint is not set/)
    expect(Profiler::Otel::Sdk.tracer_provider).to be_nil
  end
end
