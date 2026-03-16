# frozen_string_literal: true

require "spec_helper"
require "profiler/collectors/job_collector"

RSpec.describe Profiler::Collectors::JobCollector do
  let(:profile) { build_profile }
  let(:job_data) do
    {
      job_class: "MyJob",
      job_id: "abc-123",
      queue: "default",
      arguments: ["hello", 42],
      executions: 0
    }
  end

  subject(:collector) { described_class.new(profile, job_data) }

  describe "#initialize" do
    it "sets status to running" do
      expect(collector.instance_variable_get(:@job_data)[:status]).to eq("running")
    end

    it "preserves job_data fields" do
      data = collector.instance_variable_get(:@job_data)
      expect(data[:job_class]).to eq("MyJob")
      expect(data[:job_id]).to eq("abc-123")
      expect(data[:queue]).to eq("default")
      expect(data[:arguments]).to eq(["hello", 42])
      expect(data[:executions]).to eq(0)
    end
  end

  describe "#update_status" do
    it "updates status to completed" do
      collector.update_status("completed")
      expect(collector.instance_variable_get(:@job_data)[:status]).to eq("completed")
    end

    it "updates status to failed" do
      collector.update_status("failed")
      expect(collector.instance_variable_get(:@job_data)[:status]).to eq("failed")
    end

    it "sets error message when provided" do
      collector.update_status("failed", "RuntimeError: boom")
      expect(collector.instance_variable_get(:@job_data)[:error]).to eq("RuntimeError: boom")
    end

    it "does not set error key when no error message" do
      collector.update_status("completed")
      expect(collector.instance_variable_get(:@job_data)).not_to have_key(:error)
    end
  end

  describe "#collect" do
    before { collector.update_status("completed") }

    it "stores job data in the profile" do
      collector.collect
      data = profile.collector_data("job")
      expect(data).not_to be_nil
      expect(data[:job_class]).to eq("MyJob")
    end

    it "stores the final status" do
      collector.collect
      expect(profile.collector_data("job")[:status]).to eq("completed")
    end
  end

  describe "#has_data?" do
    it "returns true when job_data is present" do
      expect(collector.has_data?).to be true
    end

    it "returns false when job_data is empty" do
      empty_collector = described_class.new(profile, {})
      expect(empty_collector.has_data?).to be false
    end
  end

  describe "#tab_config" do
    it "has key 'job'" do
      expect(collector.tab_config[:key]).to eq("job")
    end

    it "has label 'Job'" do
      expect(collector.tab_config[:label]).to eq("Job")
    end

    it "is enabled by default" do
      expect(collector.tab_config[:enabled]).to be true
    end

    it "is default_active" do
      expect(collector.tab_config[:default_active]).to be true
    end

    it "has a lower priority number than other collectors (shown first)" do
      expect(collector.tab_config[:priority]).to be < 20
    end
  end

  describe "#toolbar_summary" do
    it "returns green for a completed job" do
      collector.update_status("completed")
      expect(collector.toolbar_summary[:color]).to eq("green")
    end

    it "returns red for a failed job" do
      collector.update_status("failed")
      expect(collector.toolbar_summary[:color]).to eq("red")
    end

    it "includes the job class in text" do
      expect(collector.toolbar_summary[:text]).to include("MyJob")
    end
  end
end
