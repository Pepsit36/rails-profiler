# frozen_string_literal: true

require "spec_helper"
require "concurrent"
require "profiler/test_runner/run_store"

RSpec.describe Profiler::TestRunner::RunStore do
  subject(:store) { described_class.new }

  describe "#create" do
    it "returns a run with a unique id" do
      run = store.create(files: ["spec/foo_spec.rb"], framework: "rspec")
      expect(run.id).not_to be_nil
      expect(run.id).to match(/\A[0-9a-f]{16}\z/)
    end

    it "sets initial status to 'pending'" do
      run = store.create(files: [], framework: "rspec")
      expect(run.status).to eq("pending")
    end

    it "stores files and framework" do
      run = store.create(files: ["a.rb", "b.rb"], framework: "minitest")
      expect(run.files).to eq(["a.rb", "b.rb"])
      expect(run.framework).to eq("minitest")
    end

    it "assigns unique ids across multiple creates" do
      ids = 5.times.map { store.create(files: [], framework: "rspec").id }
      expect(ids.uniq.size).to eq(5)
    end
  end

  describe "#find" do
    it "returns the run by id" do
      run = store.create(files: [], framework: "rspec")
      expect(store.find(run.id)).to equal(run)
    end

    it "returns nil for unknown id" do
      expect(store.find("nonexistent")).to be_nil
    end
  end

  describe "#update" do
    it "updates status on the run" do
      run = store.create(files: [], framework: "rspec")
      store.update(run.id, status: "running")
      expect(run.status).to eq("running")
    end

    it "updates multiple attributes at once" do
      run = store.create(files: [], framework: "rspec")
      store.update(run.id, status: "passed", exit_code: 0)
      expect(run.status).to eq("passed")
      expect(run.exit_code).to eq(0)
    end

    it "returns nil for unknown id" do
      expect(store.update("unknown", status: "running")).to be_nil
    end
  end

  describe "#append_output" do
    it "adds a chunk to the run's output_lines" do
      run = store.create(files: [], framework: "rspec")
      store.append_output(run.id, "line 1\n")
      store.append_output(run.id, "line 2\n")
      expect(run.output_lines.join).to eq("line 1\nline 2\n")
    end

    it "does nothing for unknown id" do
      expect { store.append_output("unknown", "text") }.not_to raise_error
    end
  end

  describe "#wait_for_output" do
    context "when run is in a terminal state" do
      it "returns immediately with all output and finished: true" do
        run = store.create(files: [], framework: "rspec")
        store.append_output(run.id, "done\n")
        store.update(run.id, status: "passed")

        result = store.wait_for_output(run.id, position: 0, timeout: 1)
        expect(result[:chunks]).to eq(["done\n"])
        expect(result[:finished]).to be true
        expect(result[:status]).to eq("passed")
      end
    end

    context "when run has new output from position" do
      it "returns only chunks since the given position" do
        run = store.create(files: [], framework: "rspec")
        store.append_output(run.id, "chunk0\n")
        store.append_output(run.id, "chunk1\n")
        store.update(run.id, status: "passed")

        result = store.wait_for_output(run.id, position: 1, timeout: 1)
        expect(result[:chunks]).to eq(["chunk1\n"])
        expect(result[:position]).to eq(2)
      end
    end

    context "when run id is unknown" do
      it "returns not_found result with finished: true" do
        result = store.wait_for_output("bogus", position: 0, timeout: 1)
        expect(result[:status]).to eq("not_found")
        expect(result[:finished]).to be true
      end
    end

    context "when new output arrives asynchronously" do
      it "unblocks when output is appended" do
        run = store.create(files: [], framework: "rspec")

        result = nil
        t = Thread.new do
          result = store.wait_for_output(run.id, position: 0, timeout: 2)
        end

        sleep 0.05
        store.append_output(run.id, "async chunk\n")
        store.update(run.id, status: "passed")
        t.join(3)

        expect(result).not_to be_nil
        expect(result[:chunks]).to include("async chunk\n")
      end
    end
  end

  describe "Run#to_h" do
    it "includes output as a joined string" do
      run = store.create(files: ["a.rb"], framework: "rspec")
      store.append_output(run.id, "hello\n")
      store.append_output(run.id, "world\n")
      h = run.to_h
      expect(h[:output]).to eq("hello\nworld\n")
      expect(h.key?(:output_lines)).to be false
    end

    it "serializes started_at as iso8601" do
      run = store.create(files: [], framework: "rspec")
      expect(run.to_h[:started_at]).to match(/\d{4}-\d{2}-\d{2}T/)
    end
  end
end
