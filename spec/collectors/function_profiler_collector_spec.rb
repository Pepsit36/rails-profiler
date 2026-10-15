# frozen_string_literal: true

require "spec_helper"
require "stackprof"
require "tmpdir"
require "profiler/collectors/function_profiler_collector"

# The function profiler samples with StackProf, which is not a runtime dependency of the gem.
# Without it, the collector used to fall back on a TracePoint hooked on every thread of the
# process, which called GC.stat four times per method: the most expensive part of the profiler,
# for a tab that is not shown.
RSpec.describe Profiler::Collectors::FunctionProfilerCollector do
  let(:profile) { Profiler::Models::Profile.new }
  subject(:collector) { described_class.new(profile) }

  around do |example|
    saved = %i[function_profiling_enabled function_profiling_mode function_profiling_clock
               function_profiling_max_frames]
            .to_h { |name| [name, Profiler.public_send(name)] }
    saved_fallback = Profiler.function_profiling_tracepoint_fallback if Profiler.respond_to?(:function_profiling_tracepoint_fallback)
    example.run
  ensure
    collector.unsubscribe
    saved.each { |name, value| Profiler.public_send("#{name}=", value) }
    Profiler.function_profiling_tracepoint_fallback = saved_fallback if Profiler.respond_to?(:function_profiling_tracepoint_fallback=)
  end

  context "without stackprof, with the default settings" do
    before { hide_const("StackProf") }

    it "installs no TracePoint" do
      expect(TracePoint).not_to receive(:new)

      collector.subscribe
      collector.collect
    end

    it "says why there is no data" do
      collector.subscribe
      collector.collect

      expect(profile.collector_data("function_profile")).to include(enabled: false, reason: "stackprof_missing")
    end

    it "leaves function_profiling_tracepoint_fallback off" do
      expect(Profiler.function_profiling_tracepoint_fallback).to be(false)
    end
  end

  context "without stackprof, with function_profiling_tracepoint_fallback set" do
    before do
      hide_const("StackProf")
      Profiler.function_profiling_tracepoint_fallback = true
    end

    it "falls back on a TracePoint again, hooked on the request's thread only" do
      enabled_on = nil
      allow_any_instance_of(TracePoint).to receive(:enable).and_wrap_original do |original, **kwargs|
        enabled_on = kwargs[:target_thread]
        original.call(**kwargs)
      end

      collector.subscribe

      expect(enabled_on).to equal(Thread.current)
    end
  end

  context "in full mode, chosen from the dashboard" do
    before { Profiler.function_profiling_mode = "full" }

    it "hooks its TracePoint on the request's thread only" do
      enabled_on = nil
      allow_any_instance_of(TracePoint).to receive(:enable).and_wrap_original do |original, **kwargs|
        enabled_on = kwargs[:target_thread]
        original.call(**kwargs)
      end

      collector.subscribe

      expect(enabled_on).to equal(Thread.current)
    end
  end

  context "with stackprof" do
    it "samples with StackProf and installs no TracePoint" do
      expect(TracePoint).not_to receive(:new)

      collector.subscribe
      collector.collect
    end
  end

  def data
    profile.collector_data("function_profile")
  end

  def only(list)
    expect(list.size).to eq(1)
    list.first
  end

  it "describes its tab, hidden until there is data" do
    expect(collector.tab_config).to eq(key: "function_profile", label: "Function Profile", icon: "\u26A1",
                                       priority: 31, enabled: false, default_active: false)
    expect(collector.has_data?).to be false
  end

  context "with stackprof, when another request already runs the sampler" do
    it "records that the sampler was busy, and leaves it running" do
      allow(StackProf).to receive(:start).and_return(false)
      expect(StackProf).not_to receive(:stop)

      collector.subscribe
      collector.collect

      expect(data).to include(enabled: true, mode: "lite", sampler_busy: true, total_calls: 0, functions: [])
    end
  end

  context "with stackprof, released without collecting" do
    it "stops the sampler it started and discards its samples" do
      collector.subscribe
      expect(StackProf.running?).to be true

      collector.unsubscribe

      expect(StackProf.running?).to be false
    end
  end

  context "when function profiling is off" do
    before { Profiler.function_profiling_enabled = false }

    it "records the settings and no sample, and says off in the toolbar" do
      expect(StackProf).not_to receive(:start)

      collector.subscribe
      collector.collect

      expect(data).to eq(enabled: false, max_frames: 2000, mode: "lite", clock: "wall")
      expect(collector.toolbar_summary).to eq(text: "off", color: "gray")
    end
  end

  describe "#toolbar_summary" do
    it "says sampling in lite mode, and tracing in full mode" do
      expect(collector.toolbar_summary).to eq(text: "sampling on", color: "blue")
      Profiler.function_profiling_mode = "full"
      expect(collector.toolbar_summary).to eq(text: "fn profiling on", color: "purple")
    end

    it "says off in lite mode without stackprof" do
      hide_const("StackProf")
      expect(collector.toolbar_summary).to eq(text: "off", color: "gray")
    end
  end

  # Lite mode reads StackProf's raw samples: the result below stands for a request whose
  # controller action spent most of its samples in a model method called through a gem, with
  # garbage collection in some of them.
  context "in lite mode, reading StackProf's samples" do
    let(:app_root) { "/srv/shop/app" }
    let(:frames) do
      {
        1 => { name: "OrdersController#index", file: "/srv/shop/app/controllers/orders_controller.rb", line: 3,
               total_samples: 10, samples: 4 },
        2 => { name: "Order.expensive", file: "/srv/shop/app/models/order.rb", line: 12,
               total_samples: 6, samples: 6 },
        3 => { name: "ActiveRecord::Base.find", file: "/gems/activerecord/base.rb", line: 1,
               total_samples: 6, samples: 0 },
        4 => { name: "(garbage collection)", file: nil, line: nil, total_samples: 2, samples: 2 },
        5 => { name: "<main>", file: "/srv/shop/app/main.rb", line: 1, total_samples: 10, samples: 0 }
      }
    end
    # [depth, outermost .. innermost frame ids, count], and a truncated record at the end.
    let(:raw) { [4, 5, 1, 3, 2, 6, 2, 5, 1, 2, 3, 5, 1, 4, 2, 3, 5, 1] }
    let(:result) { { frames: frames, raw: raw, samples: 10 } }

    before do
      allow(collector).to receive(:app_root_path).and_return(app_root)
      allow(StackProf).to receive(:start).and_return(true)
      allow(StackProf).to receive(:stop)
      allow(StackProf).to receive(:running?).and_return(false)
      allow(StackProf).to receive(:results).and_return(result)
    end

    it "starts the sampler on the clock chosen" do
      { "wall" => :wall, "cpu" => :cpu, "object" => :object }.each do |clock, sp_mode|
        Profiler.function_profiling_clock = clock
        described_class.new(profile).tap(&:subscribe).unsubscribe
        expect(StackProf).to have_received(:start).with(mode: sp_mode, interval: 1000, raw: true)
      end
    end

    it "keeps the application's own frames, with their share of the samples, and counts garbage collection" do
      Profiler.function_profiling_clock = "object"

      collector.subscribe
      collector.collect

      expect(data).to include(enabled: true, mode: "lite", clock: "object", gc_samples: 2, gc_overhead_pct: 20.0,
                              max_frames: 10, frame_cap_reached: false, total_calls: 16, total_duration: 10.0)
      expect(data[:functions].map { |f| f.values_at(:name, :line, :calls, :total_duration, :self_duration) })
        .to eq([["OrdersController#index", 3, 10, 10.0, 4.0], ["Order.expensive", 12, 6, 6.0, 6.0]])
      expect(data[:functions].map { |f| f[:file] }).to all(end_with(".rb"))
    end

    it "builds the call tree from the application's frames, skipping the gem frames between them" do
      Profiler.function_profiling_clock = "object"

      collector.subscribe
      collector.collect

      root = only(data[:root_calls])
      expect(root).to include(name: "OrdersController#index", started_at: 0.0, finished_at: 0.01, duration: 10.0)
      expect(root[:payload]).to include(line: 3, samples: 10, recursive: false)
      child = only(root[:children])
      expect(child).to include(name: "Order.expensive", started_at: 0.0, duration: 6.0, children: [])
      expect(child[:payload]).to include(samples: 6)
    end

    it "measures durations on the wall clock, or on the CPU clock" do
      %w[wall cpu].each do |clock|
        Profiler.function_profiling_clock = clock
        collector = described_class.new(profile)
        allow(collector).to receive(:app_root_path).and_return(app_root)

        collector.subscribe
        collector.collect

        elapsed = data[clock == "cpu" ? :elapsed_cpu_ms : :elapsed_wall_ms]
        expect(data).to include(clock: clock, total_duration: elapsed.round(2))
        expect(data[:elapsed_wall_ms]).to be >= 0
        expect(data[:elapsed_cpu_ms]).to be >= 0
      end
    end

    it "records an empty profile when StackProf returns no result" do
      allow(StackProf).to receive(:results).and_return(nil)

      collector.subscribe
      collector.collect

      expect(data).to eq(enabled: true, mode: "lite", clock: "wall", max_frames: 0, frame_cap_reached: false,
                         total_calls: 0, total_duration: 0, functions: [], root_calls: [])
    end

    it "records no garbage collection when no frame is the collector's" do
      frames.delete(4)

      collector.subscribe
      collector.collect

      expect(data).to include(gc_samples: 0, gc_overhead_pct: 0.0)
    end
  end

  # Full mode traces every call and return of the application's methods, on the request's thread.
  context "in full mode, tracing the application's methods" do
    let(:root) { Dir.mktmpdir }
    let(:app_root) { File.join(root, "app") }

    before do
      Profiler.function_profiling_mode = "full"
      FileUtils.mkdir_p(app_root)
      File.write(File.join(app_root, "fn_profiler_spec_target.rb"), <<~RUBY)
        module FnProfilerSpecTarget
          def self.outer
            inner
            inner
          end

          def self.inner
            [1, 2, 3].map(&:to_s)
          end

          def self.countdown(n)
            n.zero? ? 0 : countdown(n - 1)
          end

          def self.around
            yield
          end
        end
      RUBY
      load File.join(app_root, "fn_profiler_spec_target.rb")
      allow(collector).to receive(:app_root_path).and_return(app_root)
    end

    after { FileUtils.rm_rf(root) }

    def traced
      collector.subscribe
      yield
      collector.collect
    end

    it "records each call with its callees, and aggregates the calls per method" do
      traced { FnProfilerSpecTarget.outer }

      expect(data).to include(enabled: true, mode: "full", clock: "wall", elapsed_cpu_ms: nil, gc_samples: 0,
                              max_frames: 2000, frame_cap_reached: false, total_calls: 3)
      outer = only(data[:root_calls])
      expect(outer[:name]).to end_with("#outer")
      expect(outer[:payload]).to include(line: 2, recursive: false)
      expect(outer[:payload][:file]).to end_with("app/fn_profiler_spec_target.rb")
      expect(outer[:children].map { |c| c[:name] }).to all(end_with("#inner"))
      expect(outer[:children].size).to eq(2)

      functions = data[:functions].to_h { |f| [f[:name].split("#").last, f] }
      expect(functions.transform_values { |f| f[:calls] }).to eq("outer" => 1, "inner" => 2)
      expect(functions["outer"][:self_duration]).to be <= functions["outer"][:total_duration]
      expect(data[:total_duration]).to eq(outer[:duration].round(2))
    end

    it "counts the recursive calls of a method" do
      traced { FnProfilerSpecTarget.countdown(3) }

      countdown = only(data[:functions])
      expect(countdown).to include(calls: 4, recursive_calls: 3)
      expect(only(data[:root_calls])[:payload][:recursive]).to be false
    end

    it "closes the calls still open when the request ends" do
      collector.subscribe
      FnProfilerSpecTarget.around { collector.collect }

      expect(only(data[:root_calls])[:name]).to end_with("#around")
      expect(data[:total_calls]).to eq(1)
    end

    it "stops recording past function_profiling_max_frames and says so" do
      Profiler.function_profiling_max_frames = 3

      traced { FnProfilerSpecTarget.countdown(5) }

      expect(data).to include(max_frames: 3, frame_cap_reached: true)
      expect(data[:total_calls]).to eq(3)
    end

    it "closes every call still open, innermost first" do
      collector.subscribe
      FnProfilerSpecTarget.around { FnProfilerSpecTarget.around { collector.collect } }

      outer = only(data[:root_calls])
      expect(only(outer[:children])[:name]).to end_with("#around")
      expect(data[:total_calls]).to eq(2)
    end

    it "hooks every thread on a Ruby whose TracePoint has no target_thread" do
      enabled_with = []
      allow_any_instance_of(TracePoint).to receive(:enable).and_wrap_original do |original, **kwargs|
        enabled_with << kwargs
        raise ArgumentError, "unknown keyword: :target_thread" if kwargs.key?(:target_thread)

        original.call
      end

      traced { FnProfilerSpecTarget.outer }

      expect(enabled_with).to eq([{ target_thread: Thread.current }, {}])
      expect(data[:total_calls]).to eq(3)
    end

    it "takes the application's root and relative paths from Rails when it is loaded" do
      allow(collector).to receive(:app_root_path).and_call_original
      stub_const("Rails", double("Rails", root: Pathname.new(root)))

      traced { FnProfilerSpecTarget.outer }

      expect(only(data[:root_calls])[:payload][:file]).to eq("app/fn_profiler_spec_target.rb")
    end

    it "leaves the other methods alone" do
      traced { [3, 1, 2].sort }

      expect(data).to include(total_calls: 0, functions: [], root_calls: [])
    end
  end
end
