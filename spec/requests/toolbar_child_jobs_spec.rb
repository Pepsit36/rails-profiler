# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"
require "active_job"
require "profiler/instrumentation/active_job_instrumentation"
require "profiler/job_profiler"

# A job enqueued by a request runs after its response: the toolbar of that request, already on
# screen, has to see the job start and end. It asks GET /_profiler/api/events/:token whether its
# profile changed (profileUpdatePoller.ts), and reads GET /_profiler/api/toolbar/:token when it
# did. The jobs are enqueued on the test adapter and performed by a thread of the spec, the
# worker picking them up once the response has left, held at a gate inside perform.
RSpec.describe "Jobs of a request in its toolbar", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:writing) { local.merge("HTTP_X_PROFILER_REQUEST" => "1") }
  let(:storage) { Profiler::Storage::MemoryStore.new }
  let(:started) { Thread::Queue.new }
  let(:gate) { Thread::Queue.new }
  let(:workers) { [] }

  def app
    Rails.application
  end

  def json
    JSON.parse(last_response.body)
  end

  # The application's own request, through the profiler's middleware, enqueueing a job.
  def request_enqueueing(job_class, path: "/orders", headers: {})
    page = lambda do |_env|
      job_class.perform_later
      [200, { "content-type" => "text/html" }, ["<html><body>ok</body></html>"]]
    end
    response = Rack::MockRequest.new(Profiler::Middleware::ProfilerMiddleware.new(page))
                                .get(path, { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" }.merge(headers))
    response.headers["x-profiler-token"] || response.headers["X-Profiler-Token"]
  end

  def toolbar(token)
    get "/_profiler/api/toolbar/#{token}", {}, local
    expect(last_response.status).to eq(200)
    json
  end

  def updated_since?(token, cursor)
    get "/_profiler/api/events/#{token}", { since: cursor }, local
    json["updated"]
  end

  def wait_for(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until (value = yield)
      raise "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Thread.pass
      sleep 0.01
    end
    value
  end

  # A worker performing the jobs enqueued so far, as a queue backend would after the response.
  def perform_enqueued_jobs_in_background
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.dup
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    workers << Thread.new do
      jobs.each do |job|
        ActiveJob::Base.execute(job.transform_keys(&:to_s))
      rescue StandardError
        nil # the job's own failure, recorded on its profile
      end
    end
  end

  def job_status(token)
    wait_for { toolbar(token)["profile"]["child_jobs"].first }["status"]
  end

  def stub_job(name, &perform)
    stub_const(name, Class.new(ActiveJob::Base) do
      include Profiler::Instrumentation::ActiveJobInstrumentation
      define_method(:perform, &perform)
    end)
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.skip_paths = []
      config.track_jobs = true
      config.track_memory = false
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, storage)
    Profiler::SSE::EventBus.instance.reset!
    ActiveJob::Base.logger = Logger.new(nil)
    ActiveJob::Base.queue_adapter = :test

    started_queue = started
    gate_queue = gate
    stub_job("SlowReportJob") do
      started_queue << :started
      raise "the report failed" if gate_queue.pop == :fail
    end
  end

  after do
    gate << :go while gate.num_waiting.positive?
    workers.each { |worker| worker.join(5) }
    ActiveJob::Base.queue_adapter = :inline
  end

  it "shows a job of the page while it runs, then its end, each time the page's version moves" do
    page = request_enqueueing(SlowReportJob)
    answer = toolbar(page)
    expect(answer["profile"]["child_jobs"]).to eq([])
    cursor = answer["events_cursor"]
    perform_enqueued_jobs_in_background
    started.pop

    # The response has left, the job runs: the toolbar is told, and reads it running.
    wait_for { updated_since?(page, cursor) }
    answer = toolbar(page)
    expect(answer["profile"]["child_jobs"].map { |job| [job["job_class"], job["status"]] })
      .to eq([["SlowReportJob", "running"]])
    cursor = answer["events_cursor"]

    gate << :go

    wait_for { updated_since?(page, cursor) }
    expect(job_status(page)).to eq("completed")
    expect(toolbar(page)["profile"]["child_jobs"].first["duration"]).to be_a(Numeric)
  end

  it "shows a job that fails as failed, once it has" do
    page = request_enqueueing(SlowReportJob)
    perform_enqueued_jobs_in_background
    started.pop
    cursor = toolbar(page)["events_cursor"]

    gate << :fail

    wait_for { updated_since?(page, cursor) }
    wait_for { toolbar(page)["profile"]["child_jobs"].first&.dig("status") == "failed" }
  end

  it "gives a job enqueued by an AJAX request to that request, not to the page" do
    page = request_enqueueing(Class.new { def self.perform_later; end })
    ajax = request_enqueueing(SlowReportJob, path: "/orders/refresh",
                                             headers: { "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest" })
    post "/_profiler/api/ajax/link", { "parent_token" => page, "child_token" => ajax }, writing
    expect(last_response.status).to eq(200)
    perform_enqueued_jobs_in_background
    started.pop
    gate << :go

    expect(wait_for { toolbar(ajax)["profile"]["child_jobs"].find { |job| job["status"] == "completed" } })
      .to include("job_class" => "SlowReportJob")
    expect(storage.load(storage.find_by_parent(ajax).first.token).parent_token).to eq(ajax)
    expect(toolbar(page)["profile"]["child_jobs"]).to eq([])
  end
end
