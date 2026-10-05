# frozen_string_literal: true

require "spec_helper"
require "stackprof"
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
end
