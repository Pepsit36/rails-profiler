# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "profiler/instrumentation/sidekiq_middleware"

# The web process, the Puma workers and the Sidekiq processes share one overrides file. A reset
# leaves a RESTORE entry there for each of them: the first process to apply it must not take it
# away from the others.
RSpec.describe Profiler::EnvOverrideStore, "across processes" do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:file) { File.join(tmp_dir, "env_overrides.json") }
  let(:key) { "PROFILER_SPEC_WORKERS" }

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.tmp_path = Pathname.new(tmp_dir)
    end
    ENV.delete(key)
  end

  after do
    ENV.delete(key)
    Profiler.instance_variable_set(:@env_override_store, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  # A forked worker that applies the overrides, then, at each line read on its pipe, applies
  # them again and writes back what ENV holds for key.
  def fork_worker
    commands_r, commands_w = IO.pipe
    answers_r, answers_w = IO.pipe
    pid = fork do
      commands_w.close
      answers_r.close
      store = described_class.new
      store.apply!
      answers_w.puts(ENV[key].inspect)
      answers_w.flush
      while commands_r.gets
        store.apply!
        answers_w.puts(ENV[key].inspect)
        answers_w.flush
      end
    ensure
      # Never back into RSpec, whatever happened.
      exit!(0)
    end
    commands_r.close
    answers_w.close
    { pid: pid, commands: commands_w, answers: answers_r, first: answers_r.gets.chomp }
  end

  def apply_in(worker)
    worker[:commands].puts("apply")
    worker[:commands].flush
    worker[:answers].gets.chomp
  end

  # A worker forked later holds the pipes of the earlier ones: close them all before waiting.
  def stop_all(workers)
    Array(workers).each { |worker| worker[:commands].close }
    Array(workers).each { |worker| Process.wait(worker[:pid]) }
  end

  it "restores the original value in every worker that applied the override, not only the first" do
    web = described_class.new
    web.set(key, "overridden")

    workers = Array.new(2) { fork_worker }
    expect(workers.map { |w| w[:first] }).to all(eq('"overridden"'))

    web.reset(key)

    expect(apply_in(workers[0])).to eq("nil")
    expect(apply_in(workers[1])).to eq("nil")
    # Applied again: still restored, the key is not put back nor touched again.
    expect(apply_in(workers[1])).to eq("nil")
    expect(JSON.parse(File.read(file)).dig(key, "value")).to eq(described_class::RESTORE_SENTINEL)
  ensure
    stop_all(workers)
  end

  it "applies a new override set after the reset in every worker" do
    web = described_class.new
    web.set(key, "first")
    workers = Array.new(2) { fork_worker }

    web.reset(key)
    expect(apply_in(workers[0])).to eq("nil")
    web.set(key, "second")

    expect(apply_in(workers[0])).to eq('"second"')
    expect(apply_in(workers[1])).to eq('"second"')
  ensure
    stop_all(workers)
  end

  it "leaves the key alone in a process that never applied the override" do
    File.write(file, JSON.generate(key => { "value" => described_class::RESTORE_SENTINEL, "original" => "elsewhere" }))
    ENV[key] = "own-value"

    described_class.new.apply!
    expect(ENV[key]).to eq("own-value")
  end

  describe "RESTORE entries" do
    let(:store) { described_class.new }

    it "carry the time of the reset" do
      store.set(key, "x")
      store.reset(key)
      expect(JSON.parse(File.read(file)).dig(key, "reset_at")).to be_within(5).of(Time.now.to_i)
    end

    it "go when the file is next written, once older than RESTORE_TTL" do
      old = Time.now.to_i - described_class::RESTORE_TTL - 1
      File.write(file, JSON.generate(key => { "value" => described_class::RESTORE_SENTINEL, "original" => nil, "reset_at" => old }))

      store.set("PROFILER_SPEC_OTHER", "x")
      expect(JSON.parse(File.read(file)).keys).to eq(["PROFILER_SPEC_OTHER"])
    ensure
      ENV.delete("PROFILER_SPEC_OTHER")
    end

    it "written by an earlier version, without reset_at, start their delay when the file is next written" do
      File.write(file, JSON.generate(key => { "value" => described_class::RESTORE_SENTINEL, "original" => nil }))

      store.set("PROFILER_SPEC_OTHER", "x")
      expect(JSON.parse(File.read(file)).dig(key, "reset_at")).to be_within(5).of(Time.now.to_i)
    ensure
      ENV.delete("PROFILER_SPEC_OTHER")
    end

    it "keep their reset_at through reset_all, so that they still expire" do
      File.write(file, JSON.generate(key => { "value" => described_class::RESTORE_SENTINEL, "original" => nil, "reset_at" => 123 },
                                     "PROFILER_SPEC_OTHER" => { "value" => "x", "original" => nil }))
      allow(Time).to receive(:now).and_return(Time.at(124))

      store.reset_all
      expect(JSON.parse(File.read(file)).dig(key, "reset_at")).to eq(123)
    ensure
      ENV.delete("PROFILER_SPEC_OTHER")
    end
  end

  # Sidekiq runs apply! before every job: the file is read again only when it changed.
  describe "#apply! reading the file" do
    let(:store) { described_class.new }

    before { File.write(file, JSON.generate(key => { "value" => "one", "original" => nil })) }

    it "parses the file once while it does not change" do
      store.apply!
      expect(File).not_to receive(:read)
      expect(JSON).not_to receive(:parse)

      allow(Profiler::JobProfiler).to receive(:profile).and_yield
      Profiler.instance_variable_set(:@env_override_store, store)
      3.times { Profiler::Instrumentation::SidekiqMiddleware.new.call(double, { "class" => "W" }, "q") {} }
      expect(ENV[key]).to eq("one")
    end

    it "reads it again after another process wrote it" do
      store.apply!
      expect(ENV[key]).to eq("one")

      described_class.new.set(key, "two")
      store.apply!
      expect(ENV[key]).to eq("two")
    end

    it "reads it again after it was written in place, keeping its size" do
      store.apply!
      stat = File.stat(file)
      File.write(file, JSON.generate(key => { "value" => "uno", "original" => nil }))
      File.utime(stat.atime, stat.mtime + 1, file)

      store.apply!
      expect(ENV[key]).to eq("uno")
    end

    it "sees the file removed, then written again" do
      store.apply!
      FileUtils.rm_f(file)
      store.apply!
      expect(ENV[key]).to eq("one")

      File.write(file, JSON.generate(key => { "value" => "back", "original" => nil }))
      store.apply!
      expect(ENV[key]).to eq("back")
    end

    it "set, delete and reset always read the file under the lock, not the cache" do
      store.apply!
      File.write(file, JSON.generate(key => { "value" => "one", "original" => nil }, "PROFILER_SPEC_OTHER" => { "value" => "x" }))
      File.utime(Time.now, Time.at(0), file)

      store.set("PROFILER_SPEC_THIRD", "y")
      expect(JSON.parse(File.read(file)).keys).to include("PROFILER_SPEC_OTHER", "PROFILER_SPEC_THIRD")
    ensure
      ENV.delete("PROFILER_SPEC_THIRD")
    end
  end
end
