# frozen_string_literal: true

require "spec_helper"
require "profiler/console_profiler"

RSpec.describe Profiler::ConsoleProfiler do
  before do
    Profiler.configure do |c|
      c.enabled = true
      c.track_console = true
      c.storage = :memory
      c.track_memory = false
      c.track_http = false
    end
  end

  def run_console(expression: "User.count", &block)
    block ||= -> {}
    described_class.profile(expression: expression, &block)
  end

  describe ".profile" do
    context "when profiler is disabled" do
      before { Profiler.configure { |c| c.enabled = false } }

      it "still executes the block" do
        called = false
        run_console { called = true }
        expect(called).to be true
      end

      it "does not save a profile" do
        run_console { nil }
        expect(Profiler.storage.list.size).to eq(0)
      end
    end

    context "when track_console is false" do
      before { Profiler.configure { |c| c.track_console = false } }

      it "still executes the block" do
        called = false
        run_console { called = true }
        expect(called).to be true
      end

      it "does not save a profile" do
        run_console { nil }
        expect(Profiler.storage.list.size).to eq(0)
      end
    end

    context "when profiling is active" do
      it "saves a profile to storage" do
        run_console { nil }
        expect(Profiler.storage.list.size).to eq(1)
      end

      it "sets profile_type to 'console'" do
        run_console { nil }
        profile = Profiler.storage.list.first
        expect(profile.profile_type).to eq("console")
      end

      it "sets method to 'CONSOLE'" do
        run_console { nil }
        expect(Profiler.storage.list.first.method).to eq("CONSOLE")
      end

      it "sets path to the expression" do
        run_console(expression: "User.where(active: true).count") { nil }
        expect(Profiler.storage.list.first.path).to eq("User.where(active: true).count")
      end

      it "truncates long expressions to 200 chars in path" do
        long_expr = "x" * 250
        run_console(expression: long_expr) { nil }
        expect(Profiler.storage.list.first.path.length).to be <= 204 # 200 + "..."
      end

      it "records duration" do
        run_console { sleep 0.01 }
        expect(Profiler.storage.list.first.duration).to be > 0
      end

      it "sets status 200 on success" do
        run_console { nil }
        expect(Profiler.storage.list.first.status).to eq(200)
      end

      it "returns the block's return value" do
        result = run_console { 42 }
        expect(result).to eq(42)
      end

      it "stores expression in collectors_data['console']" do
        run_console(expression: "2 + 2") { 4 }
        data = Profiler.storage.list.first.collector_data("console")
        expect(data["expression"]).to eq("2 + 2")
      end

      it "stores return value in collectors_data['console']" do
        run_console(expression: "2 + 2") { 4 }
        data = Profiler.storage.list.first.collector_data("console")
        expect(data["return_value"]).to eq("4")
      end
    end

    context "when the console expression raises an error" do
      def run_failing_console
        run_console(expression: "1 / 0") { raise ZeroDivisionError, "divided by 0" }
      rescue ZeroDivisionError
        # expected
      end

      it "re-raises the error" do
        expect { run_console { raise RuntimeError, "boom" } }.to raise_error(RuntimeError, "boom")
      end

      it "still saves a profile" do
        run_failing_console
        expect(Profiler.storage.list.size).to eq(1)
      end

      it "sets status 500" do
        run_failing_console
        expect(Profiler.storage.list.first.status).to eq(500)
      end

      it "captures the exception" do
        run_failing_console
        data = Profiler.storage.list.first.collector_data("exception")
        expect(data).not_to be_nil
        expect(data["exception_class"]).to include("ZeroDivisionError")
      end
    end
  end
end
