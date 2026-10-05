# frozen_string_literal: true

require "spec_helper"
require "concurrent"
require "profiler/collectors/database_collector"
require "profiler/collectors/http_collector"

# A request's work handed to a thread pool belongs to that request. The pool's threads outlive it
# and serve other requests: the request's context (notification scope, HTTP and timeline
# collectors) has to travel with the task, not with the thread the pool happened to create while
# the request was running.
RSpec.describe "Request context and thread pools" do
  # A request, run in its own thread as a server does, kept open until told to finish.
  class PooledRequest
    attr_reader :profile, :http_collector

    def initialize
      @profile = Profiler::Models::Profile.new
      @jobs = Queue.new
      @done = Queue.new
      @thread = Thread.new do
        @collector = Profiler::Collectors::DatabaseCollector.new(@profile)
        @collector.subscribe
        @http_collector = Profiler::Collectors::HttpCollector.new(@profile)
        Thread.current[:profiler_http_collector] = @http_collector
        @done << :ready
        while (job = @jobs.pop)
          begin
            @done << [:ok, job.call]
          rescue Exception => e # rubocop:disable Lint/RescueException
            @done << [:error, e]
          end
        end
        @collector.collect
        Thread.current[:profiler_http_collector] = nil
      end
      @done.pop
    end

    def run(&block)
      @jobs << block
      kind, value = @done.pop
      raise value if kind == :error

      value
    end

    def finish
      @jobs << nil
      @thread.join
      @profile.collector_data("database")[:queries].map { |q| q[:sql] }
    end
  end

  def sql(text)
    ActiveSupport::Notifications.instrument("sql.active_record", sql: text, name: "Load", binds: [])
  end

  let(:pool) { Concurrent::CachedThreadPool.new }

  after do
    pool.shutdown
    pool.wait_for_termination(5)
  end

  describe "a CachedThreadPool shared by two requests" do
    it "records each task in the request that posted it, while both run and after the first one ended" do
      a = PooledRequest.new
      b = PooledRequest.new

      # The pool creates its worker while serving A.
      a.run { pool.post { sql("SELECT 'a1'") }; sleep 0.05 }
      b.run { done = Concurrent::Event.new; pool.post { sql("SELECT 'b1'"); done.set }; done.wait(2) }
      a_queries = a.finish

      c = PooledRequest.new
      c.run { done = Concurrent::Event.new; pool.post { sql("SELECT 'c1'"); done.set }; done.wait(2) }

      expect(a_queries).to eq(["SELECT 'a1'"])
      expect(b.finish).to eq(["SELECT 'b1'"])
      expect(c.finish).to eq(["SELECT 'c1'"])
    end

    it "does not hand the creating request's context to the worker thread outside of a task" do
      a = PooledRequest.new
      a.run { pool.post { sleep 0.01 }; sleep 0.05 }
      worker_context = Concurrent::Promises.future_on(pool) do
        [Profiler::Collectors::ScopedNotifications.current, Thread.current[:profiler_http_collector]]
      end
      expect(worker_context.value!(2)).to eq([nil, nil])
      a.finish
    end
  end

  describe "Concurrent::Promises.future" do
    it "records the future's queries in the request that created it, on the global executor" do
      a = PooledRequest.new
      b = PooledRequest.new
      a.run { Concurrent::Promises.future { sql("SELECT 'a future'") }.value!(2) }
      b.run { Concurrent::Promises.future { sql("SELECT 'b future'") }.value!(2) }

      expect(a.finish).to eq(["SELECT 'a future'"])
      expect(b.finish).to eq(["SELECT 'b future'"])
    end

    it "records them on a pool shared with another request" do
      a = PooledRequest.new
      b = PooledRequest.new
      a.run { Concurrent::Promises.future_on(pool) { sql("SELECT 'a'") }.value!(2) }
      b.run { Concurrent::Promises.future_on(pool) { sql("SELECT 'b'") }.value!(2) }

      expect(a.finish).to eq(["SELECT 'a'"])
      expect(b.finish).to eq(["SELECT 'b'"])
    end

    it "gives an outgoing HTTP call in a future to the request that created it" do
      a = PooledRequest.new
      b = PooledRequest.new
      a.run { Concurrent::Promises.future_on(pool) { sleep 0.01 }.value!(2) }
      seen = b.run { Concurrent::Promises.future_on(pool) { Thread.current[:profiler_http_collector] }.value!(2) }

      expect(seen).to equal(b.http_collector)
      a.finish
      b.finish
    end
  end

  describe "ActiveJob with the :async adapter" do
    before(:all) do
      require "active_job"
      class ProfilerSpecAsyncJob < ActiveJob::Base
        def perform(text)
          ActiveSupport::Notifications.instrument("sql.active_record", sql: text, name: "Load", binds: [])
        end
      end
    end

    let(:adapter) { ActiveJob::QueueAdapters::AsyncAdapter.new(min_threads: 1, max_threads: 2) }

    before do
      ActiveJob::Base.logger = Logger.new(nil)
      ProfilerSpecAsyncJob.queue_adapter = adapter
    end

    after { adapter.shutdown(wait: true) }

    it "records each job in the request that enqueued it" do
      a = PooledRequest.new
      b = PooledRequest.new
      wait = ->(text) { sleep 0.01 until $profiler_spec_async_done.include?(text) }
      $profiler_spec_async_done = Concurrent::Array.new
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| $profiler_spec_async_done << p[:sql] }

      a.run { ProfilerSpecAsyncJob.perform_later("SELECT 'a job'"); wait.call("SELECT 'a job'") }
      b.run { ProfilerSpecAsyncJob.perform_later("SELECT 'b job'"); wait.call("SELECT 'b job'") }

      expect(a.finish).to eq(["SELECT 'a job'"])
      expect(b.finish).to eq(["SELECT 'b job'"])
    ensure
      ActiveSupport::Notifications.unsubscribe(sub) if sub
    end
  end

  # Puma creates a thread from the request's own thread when the request marks itself as IO
  # bound (env["puma.mark_as_io_bound"]) and work is waiting: that thread then serves other
  # requests.
  describe "a Puma thread created while a request runs" do
    it "does not inherit the request's context" do
      require "puma"
      require "puma/thread_pool"
      seen = Queue.new
      puma_pool = Puma::ThreadPool.new("spec", { min_threads: 0, max_threads: 2 }) do |*args|
        seen << [args.last, Profiler::Collectors::ScopedNotifications.current, Thread.current[:profiler_http_collector]]
      end
      a = PooledRequest.new

      a.run { puma_pool << :another_request }

      expect(seen.pop).to eq([:another_request, nil, nil])
      a.finish
    ensure
      puma_pool&.shutdown(1)
    end
  end

  describe "a thread the application starts with Thread.new" do
    it "still inherits the request's context, for the life of its block" do
      a = PooledRequest.new
      queries = a.run { Thread.new { sql("SELECT 'child'") }.join; :ok }

      expect(queries).to eq(:ok)
      expect(a.finish).to eq(["SELECT 'child'"])
    end
  end
end
