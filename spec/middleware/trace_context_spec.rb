# frozen_string_literal: true

require "spec_helper"
require "rack/test"

RSpec.describe Profiler::Middleware::ProfilerMiddleware, "trace context" do
  include Rack::Test::Methods

  let(:seen) { {} }
  let(:inner_app) do
    lambda do |_env|
      seen[:trace_id] = Profiler::CurrentContext.trace_id
      [200, { "Content-Type" => "text/plain" }, ["ok"]]
    end
  end
  let(:trace_id) { "0af7651916cd43dd8448eb211c80319c" }
  let(:parent_id) { "b7ad6b7169203331" }

  def app
    described_class.new(inner_app)
  end

  def default_host
    "localhost"
  end

  def saved_profile
    Profiler.storage.load(last_response.headers["X-Profiler-Token"] || last_response.headers["x-profiler-token"])
  end

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = []
      c.skip_paths = []
      c.track_memory = false
      c.track_http = false
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  it "continues the trace of a valid traceparent and keeps its parent-id" do
    get "/", {}, "HTTP_TRACEPARENT" => "00-#{trace_id}-#{parent_id}-01"

    profile = saved_profile
    expect(profile.trace_id).to eq(trace_id)
    expect(profile.parent_span_id).to eq(parent_id)
    expect(profile.span_id).to match(/\A\h{16}\z/)
    expect(profile.span_id).not_to eq(parent_id)
    expect(seen[:trace_id]).to eq(trace_id)
  end

  it "starts a new trace when there is no traceparent" do
    get "/"

    profile = saved_profile
    expect(profile.trace_id).to match(/\A\h{32}\z/)
    expect(profile.parent_span_id).to be_nil
    expect(profile.span_id).to match(/\A\h{16}\z/)
  end

  it "starts a new trace when the traceparent is invalid" do
    get "/", {}, "HTTP_TRACEPARENT" => "00-not-a-trace-id-01"

    profile = saved_profile
    expect(profile.trace_id).to match(/\A\h{32}\z/)
    expect(profile.trace_id).not_to eq(trace_id)
    expect(profile.parent_span_id).to be_nil
  end

  it "gives each request its own span and clears the context afterwards" do
    get "/"
    first = saved_profile
    get "/"

    expect(saved_profile.span_id).not_to eq(first.span_id)
    expect(Profiler::CurrentContext.trace_id).to be_nil
  end
end
