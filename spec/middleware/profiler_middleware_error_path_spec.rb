# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "stackprof"
require "timeout"
require "profiler/collectors/database_collector"
require "profiler/collectors/view_collector"
require "profiler/collectors/cache_collector"
require "profiler/collectors/exception_collector"
require "profiler/collectors/flamegraph_collector"
require "profiler/collectors/mailer_collector"
require "profiler/collectors/log_collector"
require "profiler/collectors/i18n_collector"
require "profiler/collectors/dump_collector"
require "profiler/collectors/function_profiler_collector"

# What happens when the application below the profiler raises: the exception has to reach
# the server once, the application must not run a second time, and nothing the collectors
# installed may outlive the request.
RSpec.describe Profiler::Middleware::ProfilerMiddleware, "on the error path" do
  include Rack::Test::Methods

  ERROR_PATH_NOTIFICATIONS = %w[
    sql.active_record
    render_template.action_view
    render_partial.action_view
    cache_read.active_support
    cache_write.active_support
    cache_delete.active_support
    process_action.action_controller
    process.action_mailer
    deliver.action_mailer
  ].freeze

  ERROR_PATH_COLLECTORS = [
    Profiler::Collectors::DatabaseCollector,
    Profiler::Collectors::ViewCollector,
    Profiler::Collectors::CacheCollector,
    Profiler::Collectors::ExceptionCollector,
    Profiler::Collectors::FlameGraphCollector,
    Profiler::Collectors::MailerCollector,
    Profiler::Collectors::LogCollector,
    Profiler::Collectors::HttpCollector,
    Profiler::Collectors::I18nCollector,
    Profiler::Collectors::DumpCollector,
    Profiler::Collectors::FunctionProfilerCollector
  ].freeze

  ERROR_PATH_THREAD_KEYS = %i[
    profiler_flamegraph_collector profiler_http_collector profiler_i18n_collector
    profiler_pending_processes profiler_logs profiler_dumps profiler_token
    fn_profiler_mode fn_profiler_clock fn_profiler_wall_start fn_profiler_cpu_start
    fn_profiler_stack fn_profiler_roots fn_profiler_count fn_profiler_depth
  ].freeze

  let(:calls) { [] }
  let(:inner_app) do
    calls = self.calls
    lambda do |_env|
      calls << :called
      raise ArgumentError, "the application failed"
    end
  end

  def app
    described_class.new(inner_app)
  end

  def default_host
    "localhost"
  end

  def subscriber_counts
    ERROR_PATH_NOTIFICATIONS.to_h { |name| [name, ActiveSupport::Notifications.notifier.listeners_for(name).size] }
  end

  def enabled_tracepoints
    ObjectSpace.each_object(TracePoint).count(&:enabled?)
  end

  def leftover_thread_keys
    ERROR_PATH_THREAD_KEYS.select { |key| v = Thread.current[key]; !(v.nil? || (v.respond_to?(:empty?) && v.empty?)) }
  end

  def get_raising(path = "/boom")
    get path
  rescue ArgumentError
    nil
  end

  around do |example|
    previous = [Profiler.function_profiling_enabled, Profiler.function_profiling_mode]
    example.run
  ensure
    Profiler.function_profiling_enabled, Profiler.function_profiling_mode = previous
    StackProf.stop if StackProf.running?
  end

  before do
    ERROR_PATH_THREAD_KEYS.each { |key| Thread.current[key] = nil }
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = ERROR_PATH_COLLECTORS
      c.skip_paths = []
      c.track_memory = false
      c.track_http = true
      c.track_mailers = true
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
    Profiler.function_profiling_enabled = true
    Profiler.function_profiling_mode = "lite"
  end

  describe "when the application raises" do
    it "propagates the exception unchanged" do
      expect { get "/boom" }.to raise_error(ArgumentError, "the application failed")
    end

    it "calls the application exactly once" do
      get_raising
      expect(calls).to eq([:called])
    end

    it "leaves no ActiveSupport::Notifications subscriber behind" do
      before_counts = subscriber_counts
      5.times { get_raising }
      expect(subscriber_counts).to eq(before_counts)
    end

    it "stops StackProf in lite mode" do
      get_raising
      expect(StackProf.running?).to be(false)
    end

    it "disables the TracePoint in full mode" do
      Profiler.function_profiling_mode = "full"
      before_count = enabled_tracepoints
      3.times { get_raising }
      expect(enabled_tracepoints).to eq(before_count)
    end

    it "clears every thread-local slot the collectors and the request context used" do
      get_raising
      expect(leftover_thread_keys).to eq([])
    end

    it "keeps the profile, with status 500 and the exception" do
      get_raising
      profiles = Profiler.storage.list
      expect(profiles.size).to eq(1)
      profile = Profiler.storage.load(profiles.first.token)
      expect(profile.status).to eq(500)
      expect(profile.collectors_data["exception"]).to include("exception_class" => "ArgumentError",
                                                              "message" => "the application failed")
    end
  end

  describe "when the application raises an exception outside StandardError" do
    let(:inner_app) do
      calls = self.calls
      ->(_env) { calls << :called; raise Interrupt }
    end

    it "propagates it, calls the application once and releases the collectors" do
      before_counts = subscriber_counts
      expect { get "/boom" }.to raise_error(Interrupt)
      expect(calls).to eq([:called])
      expect(subscriber_counts).to eq(before_counts)
      expect(StackProf.running?).to be(false)
    end
  end

  describe "when a collector fails in its own subscribe" do
    let(:failing_collector) do
      Class.new(Profiler::Collectors::BaseCollector) do
        def subscribe
          raise "subscribe failed"
        end
      end
    end
    let(:inner_app) do
      calls = self.calls
      ->(_env) { calls << :called; [200, { "Content-Type" => "text/plain" }, ["ok"]] }
    end

    it "serves the request once, unprofiled, and releases the collectors already subscribed" do
      Profiler.configure { |c| c.collectors = ERROR_PATH_COLLECTORS + [failing_collector] }
      before_counts = subscriber_counts

      get "/ok"

      expect(last_response.status).to eq(200)
      expect(calls).to eq([:called])
      expect(subscriber_counts).to eq(before_counts)
      expect(StackProf.running?).to be(false)
    end
  end

  describe "when a collector's subscribe is interrupted by an exception outside StandardError" do
    [Interrupt, Timeout::ExitException].each do |exception_class|
      it "propagates #{exception_class}, never calls the application and releases everything" do
        interrupting = Class.new(Profiler::Collectors::BaseCollector) do
          define_method(:subscribe) { raise exception_class }
        end
        Profiler.configure { |c| c.collectors = ERROR_PATH_COLLECTORS + [interrupting] }
        before_counts = subscriber_counts

        expect { get "/ok" }.to raise_error(exception_class)

        expect(calls).to eq([])
        expect(subscriber_counts).to eq(before_counts)
        expect(StackProf.running?).to be(false)
        expect(leftover_thread_keys).to eq([])
      end
    end
  end

  describe "when the request is cut short by an exception outside StandardError" do
    let(:raised) { Timeout::ExitException }
    let(:inner_app) do
      calls = self.calls
      raised = self.raised
      ->(_env) { calls << :called; raise raised, "request timed out" }
    end

    it "keeps the profile of a timed-out request, with status 500 and the exception" do
      expect { get "/slow" }.to raise_error(Timeout::ExitException)
      profiles = Profiler.storage.list
      expect(profiles.map(&:status)).to eq([500])
      exception = Profiler.storage.load(profiles.first.token).collectors_data["exception"]
      expect(exception).to include("exception_class" => "Timeout::ExitException")
    end

    [Interrupt, SignalException.new("TERM"), SystemExit].each do |signal|
      context "by #{signal.is_a?(Exception) ? signal.class : signal}" do
        let(:raised) { signal }
        let(:inner_app) do
          calls = self.calls
          raised = self.raised
          ->(_env) { calls << :called; raise raised }
        end

        it "keeps no profile, and still releases everything" do
          before_counts = subscriber_counts
          expect { get "/stopped" }.to raise_error(signal.is_a?(Exception) ? signal.class : signal)
          expect(Profiler.storage.list).to eq([])
          expect(calls).to eq([:called])
          expect(subscriber_counts).to eq(before_counts)
          expect(StackProf.running?).to be(false)
        end
      end
    end
  end

  describe "when another request already runs the StackProf sampler" do
    let(:inner_app) do
      calls = self.calls
      ->(_env) { calls << :called; [200, { "Content-Type" => "text/plain" }, ["ok"]] }
    end

    it "leaves that sampler running and marks the profile as sampler busy" do
      Profiler.configure { |c| c.collectors = [Profiler::Collectors::FunctionProfilerCollector] }
      StackProf.start(mode: :wall, interval: 1000, raw: true)

      get "/concurrent"

      expect(StackProf.running?).to be(true)
      data = Profiler.storage.load(last_response.headers["X-Profiler-Token"]).collectors_data["function_profile"]
      expect(data).to include("enabled" => true, "sampler_busy" => true)
    end
  end

  describe "when a request succeeds" do
    let(:inner_app) do
      calls = self.calls
      ->(_env) { calls << :called; [200, { "Content-Type" => "text/html" }, ["<html><body>hi</body></html>"]] }
    end

    it "behaves as before and releases everything" do
      before_counts = subscriber_counts
      get "/ok"

      expect(last_response.status).to eq(200)
      expect(last_response.headers["X-Profiler-Token"]).not_to be_nil
      expect(last_response.body).to include("profiler-toolbar")
      expect(calls).to eq([:called])
      expect(subscriber_counts).to eq(before_counts)
      expect(StackProf.running?).to be(false)
      expect(leftover_thread_keys).to eq([])
    end
  end
end
