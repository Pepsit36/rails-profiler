# frozen_string_literal: true

require "spec_helper"
require "active_job"
require "profiler/instrumentation/active_job_instrumentation"
require "profiler/job_profiler"

RSpec.describe Profiler::Instrumentation::ActiveJobInstrumentation do
  before do
    # Set inline adapter so perform_later runs synchronously
    ActiveJob::Base.queue_adapter = :inline

    Profiler.configure do |c|
      c.enabled = true
      c.track_jobs = true
      c.storage = :memory
      c.track_memory = false
      c.track_http = false
    end

    stub_const("TestJob", Class.new(ActiveJob::Base) do
      include Profiler::Instrumentation::ActiveJobInstrumentation
      def perform(value)
        value * 2
      end
    end)
  end

  describe "around_perform hook" do
    it "calls JobProfiler.profile when a job is performed" do
      expect(Profiler::JobProfiler).to receive(:profile).with(
        hash_including(
          job_class: "TestJob",
          queue: "default"
        )
      ).and_yield

      TestJob.perform_later(5)
    end

    it "passes job_id and executions to JobProfiler" do
      received_args = nil
      allow(Profiler::JobProfiler).to receive(:profile) do |**kwargs, &blk|
        received_args = kwargs
        blk.call
      end

      TestJob.perform_later(1)

      expect(received_args[:job_id]).not_to be_nil
      expect(received_args[:executions]).to eq(0)
    end
  end

  describe "end-to-end: profile saved on job execution" do
    before do
      # Don't mock — let it run fully with memory storage
    end

    it "saves a job profile to storage" do
      TestJob.perform_later(10)
      expect(Profiler.storage.list.size).to eq(1)
    end

    it "profile has profile_type 'job'" do
      TestJob.perform_later(10)
      expect(Profiler.storage.list.first.profile_type).to eq("job")
    end

    it "profile path is the job class name" do
      TestJob.perform_later(10)
      expect(Profiler.storage.list.first.path).to eq("TestJob")
    end
  end
end
