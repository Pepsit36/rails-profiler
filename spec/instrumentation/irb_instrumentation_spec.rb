# frozen_string_literal: true

require "spec_helper"
require "profiler/console_profiler"
require "profiler/instrumentation/irb_instrumentation"

RSpec.describe Profiler::Instrumentation::IrbInstrumentation do
  before do
    Profiler.configure do |c|
      c.enabled = true
      c.track_console = true
    end
  end

  # Build a minimal object that mimics IRB::Context with our module prepended
  let(:context_class) do
    klass = Class.new do
      def evaluate(line, line_no, *args)
        # Simulate IRB evaluation returning the line
        line
      end
    end
    klass.prepend(Profiler::Instrumentation::IrbInstrumentation)
    klass
  end

  let(:context) { context_class.new }

  describe "IRB_SKIP_COMMANDS" do
    it "includes exit, quit, exit!, irb and help" do
      expect(described_class::IRB_SKIP_COMMANDS).to include("exit", "quit", "exit!", "irb", "help")
    end
  end

  describe "#evaluate" do
    it "does not profile skip commands" do
      expect(Profiler::ConsoleProfiler).not_to receive(:profile)
      described_class::IRB_SKIP_COMMANDS.each do |cmd|
        context.evaluate(cmd, 1)
      end
    end

    it "does not profile empty input" do
      expect(Profiler::ConsoleProfiler).not_to receive(:profile)
      context.evaluate("", 1)
      context.evaluate("   ", 1)
    end

    it "profiles normal expressions" do
      expect(Profiler::ConsoleProfiler).to receive(:profile).with(expression: "2 + 2").and_call_original
      allow(Profiler.storage).to receive(:save)
      context.evaluate("2 + 2", 1)
    end

    it "does not profile when track_console is false" do
      Profiler.configure { |c| c.track_console = false }
      expect(Profiler::ConsoleProfiler).not_to receive(:profile)
      context.evaluate("User.count", 1)
    end

    it "does not profile when profiler is disabled" do
      Profiler.configure { |c| c.enabled = false }
      expect(Profiler::ConsoleProfiler).not_to receive(:profile)
      context.evaluate("User.count", 1)
    end

    it "strips whitespace from expression before checking skip commands" do
      expect(Profiler::ConsoleProfiler).not_to receive(:profile)
      context.evaluate("  exit  ", 1)
    end
  end
end
