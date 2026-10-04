# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stackprof"
require "active_support/logger"
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

# BaseCollector#unsubscribe releases what subscribe installed. It runs after collect and on
# every path where collect never runs, so it must be idempotent and safe after a partial or
# missing subscribe.
RSpec.describe "Collector release (unsubscribe)" do
  NOTIFICATION_NAMES = %w[
    sql.active_record render_template.action_view render_partial.action_view
    cache_read.active_support cache_write.active_support cache_delete.active_support
    process_action.action_controller process.action_mailer deliver.action_mailer
  ].freeze

  RELEASED_THREAD_KEYS = %i[
    profiler_flamegraph_collector profiler_http_collector profiler_i18n_collector
    profiler_pending_processes profiler_logs profiler_dumps
    fn_profiler_mode fn_profiler_clock fn_profiler_wall_start fn_profiler_cpu_start
    fn_profiler_stack fn_profiler_roots fn_profiler_count fn_profiler_depth
  ].freeze

  COLLECTOR_CLASSES = [
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

  let(:profile) { Profiler::Models::Profile.new }
  let(:broadcaster) { ActiveSupport::BroadcastLogger.new(Logger.new(nil)) }

  def installed
    {
      subscribers: NOTIFICATION_NAMES.sum { |n| ActiveSupport::Notifications.notifier.listeners_for(n).size },
      thread_keys: RELEASED_THREAD_KEYS.reject { |k| v = Thread.current[k]; v.nil? || (v.respond_to?(:empty?) && v.empty?) },
      stackprof: StackProf.running?,
      tracepoints: ObjectSpace.each_object(TracePoint).count(&:enabled?),
      log_sinks: broadcaster.broadcasts.size
    }
  end

  around do |example|
    previous = [Profiler.function_profiling_enabled, Profiler.function_profiling_mode]
    example.run
  ensure
    Profiler.function_profiling_enabled, Profiler.function_profiling_mode = previous
    StackProf.stop if StackProf.running?
  end

  before do
    RELEASED_THREAD_KEYS.each { |key| Thread.current[key] = nil }
    stub_const("Rails", Module.new)
    logger = broadcaster
    Rails.define_singleton_method(:logger) { logger }
    Profiler.configure do |c|
      c.track_http = true
      c.track_mailers = true
    end
    Profiler.function_profiling_enabled = true
  end

  %w[lite full].each do |mode|
    context "with function profiling in #{mode} mode" do
      before { Profiler.function_profiling_mode = mode }

      COLLECTOR_CLASSES.each do |klass|
        describe klass.name.split("::").last do
          it "releases everything subscribe installed, without collect" do
            baseline = installed
            collector = klass.new(profile)
            collector.subscribe
            collector.unsubscribe
            expect(installed).to eq(baseline)
          end

          it "is idempotent, after collect" do
            baseline = installed
            collector = klass.new(profile)
            collector.subscribe
            collector.collect
            collector.unsubscribe
            collector.unsubscribe
            expect(installed).to eq(baseline)
          end

          it "is safe when subscribe never ran" do
            baseline = installed
            expect { klass.new(profile).unsubscribe }.not_to raise_error
            expect(installed).to eq(baseline)
          end
        end
      end
    end
  end

  describe "after a subscribe that failed part way" do
    [
      Profiler::Collectors::ViewCollector,
      Profiler::Collectors::CacheCollector,
      Profiler::Collectors::FlameGraphCollector,
      Profiler::Collectors::MailerCollector
    ].each do |klass|
      it "releases the subscriptions #{klass.name.split("::").last} made before the failure" do
        baseline = installed
        calls = 0
        original = ActiveSupport::Notifications.method(:monotonic_subscribe)
        allow(ActiveSupport::Notifications).to receive(:monotonic_subscribe) do |*args, &block|
          calls += 1
          raise "notifier failure" if calls == 2

          original.call(*args, &block)
        end

        collector = klass.new(profile)
        expect { collector.subscribe }.to raise_error("notifier failure")
        expect(installed[:subscribers]).to eq(baseline[:subscribers] + 1)

        collector.unsubscribe
        expect(installed).to eq(baseline)
      end
    end
  end

  describe "a thread-local slot taken over by a nested profile" do
    it "is left to the nested collector" do
      outer = Profiler::Collectors::FlameGraphCollector.new(profile)
      inner = Profiler::Collectors::FlameGraphCollector.new(profile)
      outer.subscribe
      inner.subscribe
      outer.unsubscribe
      expect(Thread.current[:profiler_flamegraph_collector]).to be(inner)
      inner.unsubscribe
      expect(Thread.current[:profiler_flamegraph_collector]).to be_nil
    end
  end

  describe Profiler::Collectors::FunctionProfilerCollector do
    before { Profiler.function_profiling_mode = "lite" }

    it "leaves a StackProf run it did not start" do
      StackProf.start(mode: :wall, interval: 1000, raw: true)
      collector = described_class.new(profile)
      collector.subscribe
      collector.unsubscribe
      expect(StackProf.running?).to be(true)
    end
  end

  describe Profiler::Collectors::LogCollector do
    it "records the lines logged while subscribed, and none after release" do
      collector = described_class.new(profile)
      collector.subscribe
      Rails.logger.info("during the request")
      collector.unsubscribe
      Rails.logger.info("after the request")
      collector.collect
      expect(collector.panel_content[:logs].map { |l| l[:message] }).to eq([])

      collector = described_class.new(profile)
      collector.subscribe
      Rails.logger.info("during the request")
      collector.collect
      expect(collector.panel_content[:logs].map { |l| l[:message] }).to eq(["during the request"])
    end

    context "on Rails 7.0, whose broadcast extends the logger with a module" do
      let(:legacy_logger) { Logger.new(nil) }

      before do
        logger = legacy_logger
        Rails.define_singleton_method(:logger) { logger }
        stub_const("ActiveSupport::Logger", Class.new(::Logger) do
          def self.broadcast(target)
            Module.new do
              define_method(:add) do |*args, &block|
                target.add(*args, &block)
                super(*args, &block)
              end
            end
          end
        end)
      end

      it "extends the logger once, whatever the number of requests, and captures per request" do
        modules_before = legacy_logger.singleton_class.ancestors.size

        messages = 3.times.map do |i|
          collector = described_class.new(profile)
          collector.subscribe
          legacy_logger.info("request #{i}")
          collector.collect
          collector.unsubscribe
          collector.panel_content[:logs].map { |l| l[:message] }
        end
        legacy_logger.info("outside any request")

        expect(legacy_logger.singleton_class.ancestors.size).to eq(modules_before + 1)
        expect(messages).to eq([["request 0"], ["request 1"], ["request 2"]])
        expect(Thread.current[:profiler_logs]).to be_nil
      end
    end
  end
end
