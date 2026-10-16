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

  it "counts signaled among the terminal statuses" do
    expect(described_class::TERMINAL_STATUSES).to include("signaled")
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

    # The runner reads the process 256 bytes at a time, in binary: a character can be cut in two.
    context "with output read in binary pieces" do
      let(:run) { store.create(files: [], framework: "rspec") }

      it "keeps a character cut between two pieces whole" do
        store.append_output(run.id, "a\xC3".b)
        store.append_output(run.id, "\xA9b".b)

        expect(run.output_lines).to all(satisfy { |line| line.encoding == Encoding::UTF_8 && line.valid_encoding? })
        expect(run.output_lines.join).to eq("a\u00e9b")
      end

      it "gives UTF-8 text that JSON takes as it is" do
        store.append_output(run.id, "caf\xC3\xA9\n".b)

        expect { expect(JSON.generate(run.to_h)).to include("caf\u00e9") }.not_to output.to_stderr
      end

      it "replaces bytes that are not UTF-8" do
        store.append_output(run.id, "\xFFok".b)

        expect(run.output_lines.join).to eq("\uFFFDok")
      end

      it "replaces a cut character that nothing completes once the output is over" do
        store.append_output(run.id, "a\xC3".b)
        store.finish_output(run.id)

        expect(run.output_lines.join).to eq("a\uFFFD")
      end
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

  describe "the limit on the output of a run" do
    let(:limit) { 1000 }

    def output_of(run)
      run.output_lines.join
    end

    it "keeps everything under the limit" do
      run = store.create(files: [], framework: "rspec", max_output_bytes: limit)
      store.append_output(run.id, "a" * 700)
      store.finish_output(run.id)
      expect(output_of(run)).to eq("a" * 700)
    end

    it "keeps the beginning and the end, with a visible marker, and no more than the limit" do
      run = store.create(files: [], framework: "rspec", max_output_bytes: limit)
      store.append_output(run.id, "head" + "=" * 996)
      200.times { store.append_output(run.id, "+" * 1024) }
      store.append_output(run.id, "~" * 200 + "the summary")
      store.finish_output(run.id)

      output = output_of(run)
      expect(output).to start_with("head")
      expect(output).to include("[Profiler] Output truncated")
      expect(output).to end_with("the summary")
      expect(output.bytesize).to be < limit + 600 # the limit and the two marker lines
      expect(output).to match(/(\d+) bytes left out/)
      left_out = output[/(\d+) bytes left out/, 1].to_i
      kept = output.count("=+~") + "head".size + "the summary".size
      expect(left_out + kept).to eq(1000 + 200 * 1024 + 211)
    end

    it "shows the marker as soon as the limit is reached, so a page following the run sees it" do
      run = store.create(files: [], framework: "rspec", max_output_bytes: limit)
      store.append_output(run.id, "a" * 2000)
      expect(output_of(run)).to include("[Profiler] Output truncated")
      expect(output_of(run).bytesize).to be < 1000
    end

    it "does not cut a character in two" do
      run = store.create(files: [], framework: "rspec", max_output_bytes: limit)
      store.append_output(run.id, "é" * 2000)
      store.finish_output(run.id)
      expect(output_of(run)).to be_valid_encoding
      expect(output_of(run)).not_to include("\uFFFD")
    end

    it "keeps what the profiler appends once the process printed everything" do
      run = store.create(files: [], framework: "rspec", max_output_bytes: limit)
      store.append_output(run.id, "a" * 5000)
      store.finish_output(run.id)
      store.append_output(run.id, "\n[Profiler] ended by SIGKILL\n")
      expect(output_of(run)).to end_with("[Profiler] ended by SIGKILL\n")
    end

    it "keeps 20 MiB of output under a limit of 5 MiB" do
      run = store.create(files: [], framework: "rspec", max_output_bytes: 5 * 1024 * 1024)
      20.times { store.append_output(run.id, "x" * 1024 * 1024) }
      store.finish_output(run.id)
      expect(output_of(run).bytesize).to be <= 5 * 1024 * 1024 + 1024
    end

    it "keeps everything without a limit" do
      run = store.create(files: [], framework: "rspec")
      store.append_output(run.id, "a" * 5000)
      expect(output_of(run).bytesize).to eq(5000)
    end
  end

  describe "the limit on the runs whose process has not ended" do
    it "refuses a run over the limit, naming the limit" do
      2.times { store.create(files: [], framework: "rspec", max_active: 2) }
      expect { store.create(files: [], framework: "rspec", max_active: 2) }
        .to raise_error(Profiler::TestRunner::TooManyRunsError, /2 test runs are already running.*test_runner_max_active_runs/m)
      expect(store.all.size).to eq(2)
    end

    it "accepts a run again once one is released" do
      first = store.create(files: [], framework: "rspec", max_active: 1)
      store.update(first.id, status: "killed", finished_at: Time.now)
      expect { store.create(files: [], framework: "rspec", max_active: 1) }.to raise_error(Profiler::TestRunner::TooManyRunsError)

      store.release(first.id)
      expect(store.create(files: [], framework: "rspec", max_active: 1)).to be_a(described_class::Run)
    end

    it "refuses the 51st of 50 concurrent runs only past the limit" do
      expect do
        50.times { store.create(files: [], framework: "rspec", max_active: 50) }
      end.not_to raise_error
      expect { store.create(files: [], framework: "rspec", max_active: 50) }.to raise_error(Profiler::TestRunner::TooManyRunsError)
    end

    it "has no limit when none is given" do
      expect { 50.times { store.create(files: [], framework: "rspec") } }.not_to raise_error
    end
  end

  describe "the finished runs kept" do
    it "keeps the most recent finished runs only, never one whose process is still there" do
      still_running = store.create(files: [], framework: "rspec")
      store.update(still_running.id, status: "killed", finished_at: Time.now - 7200)

      runs = (described_class::MAX_FINISHED_RUNS + 5).times.map do |i|
        run = store.create(files: [], framework: "rspec")
        store.update(run.id, status: "passed", finished_at: Time.now - 1000 + i)
        store.release(run.id)
        run
      end
      store.create(files: [], framework: "rspec")

      expect(store.find(still_running.id)).not_to be_nil
      expect(runs.first(5).map { |r| store.find(r.id) }).to all(be_nil)
      expect(runs.last(described_class::MAX_FINISHED_RUNS).map { |r| store.find(r.id) }).to all(be_a(described_class::Run))
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

    it "includes the signal that ended the process" do
      run = store.create(files: [], framework: "rspec")
      store.update(run.id, status: "signaled", signal: "SIGKILL")
      expect(run.to_h).to include(status: "signaled", signal: "SIGKILL", exit_code: nil)
    end

    it "serializes started_at as iso8601" do
      run = store.create(files: [], framework: "rspec")
      expect(run.to_h[:started_at]).to match(/\d{4}-\d{2}-\d{2}T/)
    end
  end
end
