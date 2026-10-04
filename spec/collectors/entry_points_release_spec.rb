# frozen_string_literal: true

require "spec_helper"
require "profiler/job_profiler"
require "profiler/console_profiler"
require "profiler/test_profiler"

# Jobs, console commands and tests start collectors like the request middleware does: a
# collector that fails to subscribe, or to collect, must not leave the others installed.
RSpec.describe "Collector release in the job, console and test profilers" do
  NOTIFICATIONS = %w[sql.active_record cache_read.active_support process_action.action_controller].freeze

  def subscriber_counts
    NOTIFICATIONS.to_h { |name| [name, ActiveSupport::Notifications.notifier.listeners_for(name).size] }
  end

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.track_jobs = true
      c.track_console = true
      c.storage = :memory
      c.track_memory = false
      c.track_http = false
    end
  end

  {
    "JobProfiler" => lambda { |&block|
      Profiler::JobProfiler.profile(job_class: "MyJob", job_id: "j1", queue: "default",
                                    arguments: [], executions: 0, &block)
    },
    "ConsoleProfiler" => ->(&block) { Profiler::ConsoleProfiler.profile(expression: "1 + 1", &block) },
    "TestProfiler" => lambda { |&block|
      Profiler::TestProfiler.profile(test_name: "T#t", test_file: "spec/t_spec.rb", test_line: 1,
                                     framework: :rspec, &block)
    }
  }.each do |name, run|
    describe name do
      it "runs the block once, unprofiled, and releases the others when a collector fails to subscribe" do
        allow_any_instance_of(Profiler::Collectors::ExceptionCollector).to receive(:subscribe).and_raise("subscribe failed")
        before_counts = subscriber_counts
        calls = 0

        result = run.call { calls += 1; :done }

        expect(result).to eq(:done)
        expect(calls).to eq(1)
        expect(subscriber_counts).to eq(before_counts)
      end

      it "releases a collector whose collect fails before its own clean-up" do
        allow_any_instance_of(Profiler::Collectors::DatabaseCollector).to receive(:collect).and_raise("collect failed")
        before_counts = subscriber_counts

        expect(run.call { :done }).to eq(:done)
        expect(subscriber_counts).to eq(before_counts)
      end

      it "releases every collector when the block raises" do
        before_counts = subscriber_counts

        expect { run.call { raise ArgumentError, "failed" } }.to raise_error(ArgumentError, "failed")
        expect(subscriber_counts).to eq(before_counts)
      end
    end
  end
end
