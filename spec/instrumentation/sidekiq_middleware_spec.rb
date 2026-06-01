# frozen_string_literal: true

require "spec_helper"
require "profiler/instrumentation/sidekiq_middleware"
require "profiler/job_profiler"

RSpec.describe Profiler::Instrumentation::SidekiqMiddleware do
  subject(:middleware) { described_class.new }

  let(:worker) { double("worker") }
  let(:job) do
    {
      "class" => "HardWorker",
      "jid"   => "abc123def456",
      "args"  => [1, "hello"],
      "retry_count" => 2
    }
  end
  let(:queue) { "critical" }

  describe "#call" do
    it "delegates to JobProfiler.profile with the right arguments" do
      expect(Profiler::JobProfiler).to receive(:profile).with(
        job_class: "HardWorker",
        job_id: "abc123def456",
        queue: "critical",
        arguments: [1, "hello"],
        executions: 2,
        parent_token: nil
      )

      middleware.call(worker, job, queue) {}
    end

    it "executes the given block" do
      allow(Profiler::JobProfiler).to receive(:profile).and_yield

      called = false
      middleware.call(worker, job, queue) { called = true }
      expect(called).to be true
    end

    it "defaults retry_count to 0 when absent" do
      job_without_retries = job.except("retry_count")

      expect(Profiler::JobProfiler).to receive(:profile).with(
        hash_including(executions: 0)
      )

      middleware.call(worker, job_without_retries, queue) {}
    end
  end
end
