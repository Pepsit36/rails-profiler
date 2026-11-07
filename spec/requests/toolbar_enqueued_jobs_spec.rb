# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"
require "active_job"
require "profiler/instrumentation/active_job_instrumentation"
require "profiler/job_profiler"

# A job has no profile until it starts. The toolbar of the request that enqueued it lists it as
# enqueued from the request's own profile, then as a child job once it runs, and sees the jobs of
# a job (the whole chain) through the version of the request.
RSpec.describe "Enqueued jobs in the toolbar of a request", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:storage) { Profiler::Storage::MemoryStore.new }

  def app
    Rails.application
  end

  def json
    JSON.parse(last_response.body)
  end

  def toolbar(token)
    get "/_profiler/api/toolbar/#{token}", {}, local
    expect(last_response.status).to eq(200)
    json
  end

  def request_enqueueing(*job_classes)
    page = lambda do |_env|
      job_classes.each(&:perform_later)
      [200, { "content-type" => "text/html" }, ["<html><body>ok</body></html>"]]
    end
    response = Rack::MockRequest.new(Profiler::Middleware::ProfilerMiddleware.new(page)).get("/orders", local)
    response.headers["x-profiler-token"] || response.headers["X-Profiler-Token"]
  end

  # What a queue worker does once the response has left, for the jobs enqueued so far.
  def perform_enqueued_jobs
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.dup
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    jobs.each { |job| ActiveJob::Base.execute(job.transform_keys(&:to_s)) }
  end

  def stub_job(name, &perform)
    stub_const(name, Class.new(ActiveJob::Base) do
      include Profiler::Instrumentation::ActiveJobInstrumentation
      queue_as :reports
      define_method(:perform, &perform)
    end)
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = [Profiler::Collectors::EnqueuedJobsCollector]
      config.skip_paths = []
      config.track_jobs = true
      config.track_memory = false
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, storage)
    Profiler::SSE::EventBus.instance.reset!
    ActiveJob::Base.logger = Logger.new(nil)
    ActiveJob::Base.queue_adapter = :test
    stub_job("ReportJob") { nil }
    stub_job("ChildJob") { nil }
    stub_job("ParentJob") { ChildJob.perform_later }
  end

  after { ActiveJob::Base.queue_adapter = :inline }

  it "lists a job that has not started as enqueued, with its class, queue and id" do
    answer = toolbar(request_enqueueing(ReportJob))

    expect(answer["profile"]["child_jobs"]).to eq([])
    expect(answer["profile"]["enqueued_jobs"].size).to eq(1)
    job = answer["profile"]["enqueued_jobs"].first
    expect(job).to include("job_class" => "ReportJob", "queue" => "reports")
    expect(job["job_id"]).to match(/\A\h{8}-/)
    expect(job["enqueued_at"]).to match(/\A\d{4}-\d\d-\d\dT/)
    expect(job["scheduled_at"]).to be_nil
  end

  it "moves the job from enqueued to child jobs once it started, matched by its id" do
    page = request_enqueueing(ReportJob)
    job_id = toolbar(page)["profile"]["enqueued_jobs"].first["job_id"]

    perform_enqueued_jobs

    answer = toolbar(page)
    expect(answer["profile"]["enqueued_jobs"]).to eq([])
    expect(answer["profile"]["child_jobs"].map { |j| [j["job_id"], j["status"]] }).to eq([[job_id, "completed"]])
  end

  it "keeps the jobs not started yet next to those that did" do
    page = request_enqueueing(ReportJob, ChildJob)
    ActiveJob::Base.queue_adapter.enqueued_jobs.first.then do |first|
      ActiveJob::Base.queue_adapter.enqueued_jobs.delete(first)
      ActiveJob::Base.execute(first.transform_keys(&:to_s))
    end

    answer = toolbar(page)
    expect(answer["profile"]["child_jobs"].map { |j| j["job_class"] }).to eq(["ReportJob"])
    expect(answer["profile"]["enqueued_jobs"].map { |j| j["job_class"] }).to eq(["ChildJob"])
  end

  it "gives a scheduled job its time" do
    stub_job("LaterJob") { nil }
    page = lambda do |_env|
      LaterJob.set(wait: 3600).perform_later
      [200, { "content-type" => "text/html" }, ["<html><body>ok</body></html>"]]
    end
    response = Rack::MockRequest.new(Profiler::Middleware::ProfilerMiddleware.new(page)).get("/orders", local)
    token = response.headers["x-profiler-token"] || response.headers["X-Profiler-Token"]

    expect(toolbar(token)["profile"]["enqueued_jobs"].first["scheduled_at"]).to match(/\A\d{4}-\d\d-\d\dT/)
  end

  it "lists the jobs of a job on that job, and moves the version of the request when they run" do
    page = request_enqueueing(ParentJob)
    cursor = toolbar(page)["events_cursor"]

    perform_enqueued_jobs # ParentJob runs, and enqueues ChildJob
    parent_token = toolbar(page)["profile"]["child_jobs"].first["token"]
    parent = toolbar(parent_token)
    expect(parent["profile"]["enqueued_jobs"].map { |j| j["job_class"] }).to eq(["ChildJob"])
    expect(parent["profile"]["child_jobs"]).to eq([])

    after_parent = toolbar(page)["events_cursor"]
    expect(after_parent.to_i).to be > cursor.to_i

    perform_enqueued_jobs # ChildJob runs: two levels below the request
    expect(toolbar(parent_token)["profile"]["child_jobs"].map { |j| j["job_class"] }).to eq(["ChildJob"])
    get "/_profiler/api/events/#{page}", { since: after_parent }, local
    expect(json["updated"]).to be(true)
  end

  it "records nothing when track_jobs is off" do
    Profiler.configure { |config| config.track_jobs = false }
    answer = toolbar(request_enqueueing(ReportJob))

    expect(answer["profile"]["enqueued_jobs"]).to eq([])
  end
end
