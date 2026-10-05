# frozen_string_literal: true

require "spec_helper"
require "profiler/collectors/database_collector"
require "profiler/collectors/view_collector"
require "profiler/collectors/cache_collector"
require "profiler/collectors/exception_collector"
require "profiler/collectors/flamegraph_collector"
require "profiler/collectors/mailer_collector"

# A collector profiles one request, so it records the events of the thread that runs that request
# only. On a server with several threads, another request's SQL, which may belong to another user,
# must never show in this one's profile.
RSpec.describe "Collectors scoped to the request thread" do
  let(:profile) { Profiler::Models::Profile.new }

  # Stands for another request: a thread that already existed before this request began, as a
  # server's thread pool does, and that runs whatever it is handed.
  class OtherRequestThread
    def initialize
      @jobs = Queue.new
      @done = Queue.new
      @thread = Thread.new do
        while (job = @jobs.pop)
          begin
            job.call
          ensure
            @done << true
          end
        end
      end
    end

    def run(&block)
      @jobs << block
      @done.pop
    end

    def stop
      @jobs << nil
      @thread.join
    end
  end

  let!(:other_request) { OtherRequestThread.new }

  after { other_request.stop }

  def sql(text = "SELECT * FROM users WHERE id = 1")
    ActiveSupport::Notifications.instrument("sql.active_record", sql: text, name: "User Load", binds: [])
  end

  def collected(collector)
    collector.collect
    profile.collector_data(collector.name)
  end

  {
    Profiler::Collectors::DatabaseCollector => {
      emit: -> { ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1", name: "User Load", binds: []) },
      count: ->(data) { data[:total_queries] }
    },
    Profiler::Collectors::ViewCollector => {
      emit: lambda {
        ActiveSupport::Notifications.instrument("render_template.action_view", identifier: "users/show.html.erb")
        ActiveSupport::Notifications.instrument("render_partial.action_view", identifier: "users/_row.html.erb")
      },
      count: ->(data) { data[:total_views] + data[:total_partials] }
    },
    Profiler::Collectors::CacheCollector => {
      emit: lambda {
        ActiveSupport::Notifications.instrument("cache_read.active_support", key: "k", hit: true)
        ActiveSupport::Notifications.instrument("cache_write.active_support", key: "k")
        ActiveSupport::Notifications.instrument("cache_delete.active_support", key: "k")
      },
      count: ->(data) { data[:total_reads] + data[:total_writes] + data[:total_deletes] }
    },
    Profiler::Collectors::FlameGraphCollector => {
      emit: lambda {
        ActiveSupport::Notifications.instrument("process_action.action_controller", controller: "UsersController", action: "show")
        ActiveSupport::Notifications.instrument("render_template.action_view", identifier: "users/show.html.erb")
        ActiveSupport::Notifications.instrument("render_partial.action_view", identifier: "users/_row.html.erb")
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1", name: "User Load")
        ActiveSupport::Notifications.instrument("cache_read.active_support", key: "k", hit: true)
      },
      count: ->(data) { data[:total_events] }
    },
    Profiler::Collectors::ExceptionCollector => {
      emit: lambda {
        ActiveSupport::Notifications.instrument("process_action.action_controller",
                                                exception_object: RuntimeError.new("someone else's error"))
      },
      count: ->(data) { data.empty? ? 0 : 1 }
    }
  }.each do |klass, spec|
    describe klass.name.split("::").last do
      let(:collector) { klass.new(profile) }

      it "ignores the events another request's thread emits" do
        collector.subscribe
        other_request.run { spec[:emit].call }

        expect(spec[:count].call(collected(collector))).to eq(0)
      end

      it "records the events of its own thread" do
        collector.subscribe
        spec[:emit].call

        expect(spec[:count].call(collected(collector))).to be > 0
      end
    end
  end

  describe "events the request emits outside its own thread" do
    let(:collector) { Profiler::Collectors::DatabaseCollector.new(profile) }

    before { collector.subscribe }

    it "records a thread the request starts, as it already does for HTTP calls and the timeline" do
      Thread.new { sql }.join

      expect(collected(collector)[:total_queries]).to eq(1)
    end

    it "records a fiber of the request's thread, such as an external Enumerator" do
      Enumerator.new { |y| sql; y << 1 }.next

      expect(collected(collector)[:total_queries]).to eq(1)
    end

    it "records the thread that ActionController::Live hands the action to, which shares the request's state" do
      request_thread = Thread.current
      other_request.run do
        ActiveSupport::IsolatedExecutionState.share_with(request_thread) { sql }
      end

      expect(collected(collector)[:total_queries]).to eq(1)
    end
  end

  # A streamed response: the application returns, then the server iterates the body, and the
  # collectors are released when the server closes it, possibly from another thread.
  describe "a streamed response, between the end of call and the release" do
    let(:collector) { Profiler::Collectors::DatabaseCollector.new(profile) }
    let(:token) { profile.token }

    before do
      Profiler::CurrentContext.token = token
      collector.subscribe
      Profiler::CurrentContext.clear # the application has returned
    end

    after { Profiler::CurrentContext.clear }

    it "records what the request's thread emits while it iterates the body" do
      sql("SELECT 'streamed'")
      collector.unsubscribe
      sql("SELECT 'after close'")

      expect(collected(collector)[:queries].map { |q| q[:sql] }).to eq(["SELECT 'streamed'"])
    end

    it "records what a server thread carrying the profile's token emits, and nothing from one without it" do
      other_request.run do
        Profiler::CurrentContext.token = token
        sql("SELECT 'body iterated by another server thread'")
      ensure
        Profiler::CurrentContext.clear
      end
      other_request.run { sql("SELECT 'another request'") }

      expect(collected(collector)[:queries].map { |q| q[:sql] }).to eq(["SELECT 'body iterated by another server thread'"])
    end

    it "records what the ActionController::Live thread emits" do
      request_thread = Thread.current
      other_request.run { ActiveSupport::IsolatedExecutionState.share_with(request_thread) { sql } }

      expect(collected(collector)[:total_queries]).to eq(1)
    end

    it "is released from the thread that closes the body, and the next request of the thread starts afresh" do
      baseline = ActiveSupport::Notifications.notifier.listeners_for("sql.active_record").size - 1
      other_request.run { collector.unsubscribe }

      expect(ActiveSupport::Notifications.notifier.listeners_for("sql.active_record").size).to eq(baseline)
      expect(Profiler::Collectors::ScopedNotifications.current).to be_nil

      next_profile = Profiler::Models::Profile.new
      next_request = Profiler::Collectors::DatabaseCollector.new(next_profile)
      next_request.subscribe
      other_request.run do
        Profiler::CurrentContext.token = token # the old token, still held somewhere
        sql("SELECT 'stale token'")
      ensure
        Profiler::CurrentContext.clear
      end
      sql("SELECT 'next request'")
      next_request.collect

      expect(next_profile.collector_data("database")[:queries].map { |q| q[:sql] }).to eq(["SELECT 'next request'"])
    end
  end

  # The server may iterate a streamed body in another fiber than the one that ran the request:
  # it lends that fiber the profile's token (StreamedProfile#enter), which is fiber-local.
  describe "a body iterated by another fiber" do
    def in_fiber(token: nil, &block)
      Fiber.new do
        Profiler::CurrentContext.token = token
        block.call
      ensure
        Profiler::CurrentContext.clear
      end.resume
    end

    context "with the default isolation level, :thread" do
      it "records the fiber that carries the profile's token" do
        Profiler::CurrentContext.token = profile.token
        collector = Profiler::Collectors::DatabaseCollector.new(profile)
        collector.subscribe
        Profiler::CurrentContext.clear

        in_fiber(token: profile.token) { sql("SELECT 'streamed'") }

        expect(collected(collector)[:total_queries]).to eq(1)
      ensure
        Profiler::CurrentContext.clear
      end
    end

    # Falcon runs each request in its own fiber, and Rails then wants isolation_level = :fiber.
    context "with isolation_level = :fiber, as under Falcon" do
      around do |example|
        previous = ActiveSupport::IsolatedExecutionState.isolation_level
        ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
        example.run
      ensure
        ActiveSupport::IsolatedExecutionState.isolation_level = previous
      end

      # render stream: true renders the layout in a Fiber it creates during the request
      # (ActionView::StreamingTemplateRenderer): what that fiber queries is the request's.
      it "records a fiber the request creates, and nothing from a fiber of another request" do
        collector = nil
        request_profile = Profiler::Models::Profile.new
        in_fiber do
          collector = Profiler::Collectors::DatabaseCollector.new(request_profile)
          collector.subscribe
          Fiber.new { sql("SELECT 'streamed layout'") }.resume
        end
        in_fiber { Fiber.new { sql("SELECT 'another request'") }.resume }
        collector.collect

        expect(request_profile.collector_data("database")[:queries].map { |q| q[:sql] })
          .to eq(["SELECT 'streamed layout'"])
      end

      it "records nothing more in a fiber that outlives the request" do
        collector = nil
        request_profile = Profiler::Models::Profile.new
        lingering = nil
        in_fiber do
          collector = Profiler::Collectors::DatabaseCollector.new(request_profile)
          collector.subscribe
          lingering = Fiber.new { Fiber.yield sql("SELECT 'during'"); sql("SELECT 'after the request'") }
          lingering.resume
          collector.collect
        end
        next_profile = Profiler::Models::Profile.new
        next_request = Profiler::Collectors::DatabaseCollector.new(next_profile)
        in_fiber do
          next_request.subscribe
          lingering.resume
          next_request.collect
        end

        expect(request_profile.collector_data("database")[:queries].map { |q| q[:sql] }).to eq(["SELECT 'during'"])
        expect(next_profile.collector_data("database")[:queries]).to eq([])
      end

      it "keeps the requests of one thread apart, and records the fiber iterating the body" do
        collector = nil
        request_profile = Profiler::Models::Profile.new
        in_fiber(token: request_profile.token) do
          collector = Profiler::Collectors::DatabaseCollector.new(request_profile)
          collector.subscribe
          sql("SELECT 'in the request'")
        end

        in_fiber { sql("SELECT 'another request on the same thread'") }
        in_fiber(token: request_profile.token) { sql("SELECT 'streamed body'") }
        collector.collect

        expect(request_profile.collector_data("database")[:queries].map { |q| q[:sql] })
          .to eq(["SELECT 'in the request'", "SELECT 'streamed body'"])
      end
    end
  end

  describe "a job performed inline during the request" do
    it "records the job's queries in both profiles, and the request's own after the job, as before" do
      request = Profiler::Collectors::DatabaseCollector.new(profile)
      job_profile = Profiler::Models::Profile.new
      job = Profiler::Collectors::DatabaseCollector.new(job_profile)

      request.subscribe
      sql("SELECT 'before the job'")
      job.subscribe
      sql("SELECT 'in the job'")
      job.collect
      sql("SELECT 'after the job'")

      expect(collected(request)[:queries].map { |q| q[:sql] })
        .to eq(["SELECT 'before the job'", "SELECT 'in the job'", "SELECT 'after the job'"])
      expect(job_profile.collector_data("database")[:queries].map { |q| q[:sql] }).to eq(["SELECT 'in the job'"])
    end
  end

  describe "releasing" do
    it "is idempotent, and leaves the subscriber of the requests still profiled in place" do
      baseline = ActiveSupport::Notifications.notifier.listeners_for("sql.active_record").size
      first = Profiler::Collectors::DatabaseCollector.new(profile)
      second_profile = Profiler::Models::Profile.new
      second = Profiler::Collectors::DatabaseCollector.new(second_profile)
      first.subscribe
      second.subscribe

      handle = first.instance_variable_get(:@subscriptions).first
      2.times { Profiler::Collectors::ScopedNotifications.unsubscribe(handle) }
      sql("SELECT 'still recorded'")
      second.collect

      expect(second_profile.collector_data("database")[:total_queries]).to eq(1)
      expect(ActiveSupport::Notifications.notifier.listeners_for("sql.active_record").size).to eq(baseline)
    end

    it "keeps a failing collector from stopping the others or the application's query" do
      failing = Profiler::Collectors::ScopedNotifications.subscribe("sql.active_record") { raise "collector bug" }
      collector = Profiler::Collectors::DatabaseCollector.new(profile)
      collector.subscribe

      expect { sql }.to output(/collector bug/).to_stderr
      expect(collected(collector)[:total_queries]).to eq(1)
    ensure
      Profiler::Collectors::ScopedNotifications.unsubscribe(failing)
    end
  end

  describe "the cost of concurrent requests" do
    it "keeps one subscriber per event for the process, however many requests are profiled at once" do
      baseline = ActiveSupport::Notifications.notifier.listeners_for("sql.active_record").size
      ready = Queue.new
      release = Queue.new
      threads = Array.new(5) do
        Thread.new do
          collector = Profiler::Collectors::DatabaseCollector.new(Profiler::Models::Profile.new)
          collector.subscribe
          ready << true
          release.pop
          collector.collect
        end
      end
      5.times { ready.pop }

      during = ActiveSupport::Notifications.notifier.listeners_for("sql.active_record").size
      5.times { release << true }
      threads.each(&:join)

      expect(during - baseline).to eq(1)
      expect(ActiveSupport::Notifications.notifier.listeners_for("sql.active_record").size).to eq(baseline)
    end
  end
end
