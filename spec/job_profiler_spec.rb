# frozen_string_literal: true

require "spec_helper"
require "profiler/job_profiler"

RSpec.describe Profiler::JobProfiler do
  before do
    Profiler.configure do |c|
      c.enabled = true
      c.track_jobs = true
      c.storage = :memory
      c.track_memory = false
      c.track_http = false
    end
  end

  def run_job(job_class: "MyJob", job_id: "jid-001", queue: "default",
              arguments: [], executions: 0, &block)
    block ||= -> {}
    described_class.profile(
      job_class: job_class,
      job_id: job_id,
      queue: queue,
      arguments: arguments,
      executions: executions,
      &block
    )
  end

  describe ".profile" do
    context "when profiler is disabled" do
      before { Profiler.configure { |c| c.enabled = false } }

      it "still executes the block" do
        called = false
        run_job { called = true }
        expect(called).to be true
      end

      it "does not save a profile" do
        run_job { nil }
        expect(Profiler.storage.list.size).to eq(0)
      end
    end

    context "when track_jobs is false" do
      before { Profiler.configure { |c| c.track_jobs = false } }

      it "still executes the block" do
        called = false
        run_job { called = true }
        expect(called).to be true
      end

      it "does not save a profile" do
        run_job { nil }
        expect(Profiler.storage.list.size).to eq(0)
      end
    end

    context "when profiling is active" do
      it "saves a profile to storage" do
        run_job { nil }
        expect(Profiler.storage.list.size).to eq(1)
      end

      it "sets profile_type to 'job'" do
        run_job { nil }
        profile = Profiler.storage.list.first
        expect(profile.profile_type).to eq("job")
      end

      it "sets method to 'JOB'" do
        run_job { nil }
        expect(Profiler.storage.list.first.method).to eq("JOB")
      end

      it "sets path to the job class name" do
        run_job(job_class: "ReportGenerationJob") { nil }
        expect(Profiler.storage.list.first.path).to eq("ReportGenerationJob")
      end

      it "records duration" do
        run_job { sleep 0.01 }
        expect(Profiler.storage.list.first.duration).to be > 0
      end

      it "stores job metadata in collectors_data['job']" do
        run_job(job_class: "MyJob", job_id: "id-42", queue: "critical", executions: 2) { nil }
        data = Profiler.storage.list.first.collector_data("job")
        expect(data["job_class"]).to eq("MyJob")
        expect(data["job_id"]).to eq("id-42")
        expect(data["queue"]).to eq("critical")
        expect(data["executions"]).to eq(2)
      end

      it "marks job as completed on success" do
        run_job { nil }
        data = Profiler.storage.list.first.collector_data("job")
        expect(data["status"]).to eq("completed")
      end

      it "sets status 200 on success" do
        run_job { nil }
        expect(Profiler.storage.list.first.status).to eq(200)
      end

      it "returns the block's return value" do
        result = run_job { 42 }
        expect(result).to eq(42)
      end
    end

    context "when the job raises an error" do
      def run_failing_job
        run_job { raise RuntimeError, "boom" }
      rescue RuntimeError
        # expected
      end

      it "re-raises the error" do
        expect { run_job { raise RuntimeError, "boom" } }.to raise_error(RuntimeError, "boom")
      end

      it "still saves a profile" do
        run_failing_job
        expect(Profiler.storage.list.size).to eq(1)
      end

      it "marks the job as failed" do
        run_failing_job
        data = Profiler.storage.list.first.collector_data("job")
        expect(data["status"]).to eq("failed")
      end

      it "records the error message" do
        run_failing_job
        data = Profiler.storage.list.first.collector_data("job")
        expect(data["error"]).to include("RuntimeError")
        expect(data["error"]).to include("boom")
      end

      it "sets status 500" do
        run_failing_job
        expect(Profiler.storage.list.first.status).to eq(500)
      end
    end

    context "when the job is interrupted with Interrupt" do
      def run_interrupted_job
        run_job { raise Interrupt }
      rescue Interrupt
        # expected
      end

      it "re-raises the Interrupt" do
        expect { run_job { raise Interrupt } }.to raise_error(Interrupt)
      end

      it "still saves a profile" do
        run_interrupted_job
        expect(Profiler.storage.list.size).to eq(1)
      end

      it "marks the job as failed" do
        run_interrupted_job
        data = Profiler.storage.list.first.collector_data("job")
        expect(data["status"]).to eq("failed")
      end

      it "sets status 500" do
        run_interrupted_job
        expect(Profiler.storage.list.first.status).to eq(500)
      end

      it "records the exception" do
        run_interrupted_job
        data = Profiler.storage.list.first.collector_data("job")
        expect(data["error"]).to include("Interrupt")
      end
    end

    context "with the token of the request that enqueued it" do
      let(:parent) { SecureRandom.hex(16) }

      def run_child_job(&block)
        described_class.profile(job_class: "ReportJob", job_id: "jid-002", queue: "default",
                                arguments: [], executions: 0, parent_token: parent, &block)
      end

      it "is saved running before it performs, for that request to list it" do
        seen = nil
        run_child_job do
          running = Profiler.storage.find_by_parent(parent).first
          seen = [running.collector_data("job")["status"], running.duration, running.path]
        end
        expect(seen).to eq(["running", 0.0, "ReportJob"])
      end

      it "is saved again, completed, once it has performed" do
        run_child_job { nil }
        job = Profiler.storage.find_by_parent(parent)
        expect(job.size).to eq(1)
        expect(job.first.collector_data("job")["status"]).to eq("completed")
        expect(job.first.duration).to be_a(Float)
      end

      it "is saved again, failed, when it fails" do
        expect { run_child_job { raise "boom" } }.to raise_error("boom")
        expect(Profiler.storage.find_by_parent(parent).first.collector_data("job")["status"]).to eq("failed")
      end
    end

    context "without a request that enqueued it" do
      it "is only saved once it has performed" do
        saved_during = nil
        run_job { saved_during = Profiler.storage.list.size }
        expect(saved_during).to eq(0)
        expect(Profiler.storage.list.size).to eq(1)
      end
    end

    context "argument sanitization" do
      it "passes through simple types unchanged" do
        run_job(arguments: [1, "hello", true, nil]) { nil }
        data = Profiler.storage.list.first.collector_data("job")
        expect(data["arguments"]).to eq([1, "hello", true, nil])
      end

      it "truncates long strings to 200 chars" do
        long_string = "x" * 300
        run_job(arguments: [long_string]) { nil }
        data = Profiler.storage.list.first.collector_data("job")
        expect(data["arguments"].first.length).to be <= 204 # 200 + "..."
      end

      it "handles nil arguments gracefully" do
        run_job(arguments: nil) { nil }
        data = Profiler.storage.list.first.collector_data("job")
        expect(data["arguments"]).to eq([])
      end
    end
  end
end
