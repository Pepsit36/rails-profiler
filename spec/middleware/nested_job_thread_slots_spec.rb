# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "logger"
require "active_support/logger"
require "profiler/job_profiler"
require "profiler/collectors/log_collector"
require "profiler/collectors/dump_collector"
require "profiler/collectors/flamegraph_collector"
require "profiler/collectors/mailer_collector"

# A job performed inline during a request (perform_now, or the :inline adapter) runs its own
# collectors on the request's thread. Each collector's thread-local slot follows a stack: the
# job's collectors take it over and hand it back, so the request keeps what it recorded before
# and after the job, and the job's profile gets only what the job did.
RSpec.describe Profiler::Middleware::ProfilerMiddleware, "with a job performed inline" do
  include Rack::Test::Methods

  let(:broadcaster) { ActiveSupport::BroadcastLogger.new(Logger.new(nil)) }

  def record_http(url)
    Thread.current[:profiler_http_collector]&.register_pending(id: url, url: url, method: "GET")
  end

  def step(label)
    Rails.logger.info(label)
    Profiler.dump(label, label)
    record_http("http://example.test/#{label.tr(" ", "-")}")
    Profiler.measure(label) { nil }
  end

  let(:inner_app) do
    lambda do |_env|
      step("outer before job")
      Profiler::JobProfiler.profile(job_class: "InlineJob", job_id: "j1", queue: "default",
                                    arguments: [], executions: 0) { step("in job") }
      step("outer after job")
      [200, { "Content-Type" => "text/plain" }, ["ok"]]
    end
  end

  def app
    described_class.new(inner_app)
  end

  def default_host
    "localhost"
  end

  before do
    stub_const("Rails", Module.new)
    logger = broadcaster
    Rails.define_singleton_method(:logger) { logger }
    Profiler.configure do |c|
      c.enabled = true
      c.track_jobs = true
      c.track_http = true
      c.track_memory = false
      c.skip_paths = []
      c.collectors = [
        Profiler::Collectors::LogCollector,
        Profiler::Collectors::DumpCollector,
        Profiler::Collectors::HttpCollector,
        Profiler::Collectors::FlameGraphCollector,
        Profiler::Collectors::MailerCollector
      ]
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def recorded(profile)
    data = profile.collectors_data.transform_keys(&:to_s)
    logs = data["logs"].transform_keys(&:to_s)["logs"].map { |l| l.transform_keys(&:to_s)["message"] }
    dumps = data["dump"].transform_keys(&:to_s)["dumps"].map { |d| d.transform_keys(&:to_s)["label"] }
    http = data["http"].transform_keys(&:to_s)["requests"].map { |r| r.transform_keys(&:to_s)["url"] }
    events = data["flamegraph"].transform_keys(&:to_s)["root_events"].map { |e| e.transform_keys(&:to_s)["name"] }
    { logs: logs, dumps: dumps, http: http, events: events }
  end

  it "keeps the request's records around the job, and gives the job its own" do
    get "/with-job"
    expect(last_response.status).to eq(200)

    request_profile = Profiler.storage.load(last_response.headers["X-Profiler-Token"])
    job_summary = Profiler.storage.list.find { |p| p.method == "JOB" }
    job_profile = Profiler.storage.load(job_summary.token)

    expect(recorded(request_profile)).to eq(
      logs: ["outer before job", "outer after job"],
      dumps: ["outer before job", "outer after job"],
      http: ["http://example.test/outer-before-job", "http://example.test/outer-after-job"],
      events: ["outer before job", "outer after job"]
    )
    expect(recorded(job_profile)).to eq(
      logs: ["in job"], dumps: ["in job"], http: ["http://example.test/in-job"], events: ["in job"]
    )
    expect(Thread.current[:profiler_logs]).to be_nil
    expect(Thread.current[:profiler_http_collector]).to be_nil
    expect(Thread.current[:profiler_flamegraph_collector]).to be_nil
    expect(Thread.current[:profiler_pending_processes]).to be_nil
  end
end
