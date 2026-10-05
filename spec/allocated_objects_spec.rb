# frozen_string_literal: true

require "spec_helper"
require "rack"
require "profiler/job_profiler"
require "profiler/console_profiler"
require "profiler/test_profiler"

# GC.stat has no :total_allocated_size on the supported Rubies: what the profiler measures is
# a number of allocated objects, and it reports it as such.
RSpec.describe "Allocated objects" do
  ALLOCATIONS = 20_000

  def allocate!
    ALLOCATIONS.times { Object.new }
  end

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = []
      c.skip_paths = []
      c.track_memory = true
      c.track_http = false
      c.track_jobs = true
      c.track_console = true
      c.storage = :memory
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def latest(type)
    Profiler.storage.list(limit: 10).find { |p| p.profile_type == type }
  end

  shared_examples "an allocation count" do
    it "is the number of objects allocated, not a byte figure" do
      expect(profile.allocated_objects).to be_between(ALLOCATIONS, ALLOCATIONS * 2)
      expect(profile.to_h[:allocated_objects]).to eq(profile.allocated_objects)
    end
  end

  context "for a request" do
    let(:profile) do
      app = lambda do |_env|
        allocate!
        [200, Rack::Headers["content-type" => "text/plain"], ["ok"]]
      end
      env = Rack::MockRequest.env_for("http://localhost/", "REMOTE_ADDR" => "127.0.0.1")
      _status, headers, body = Profiler::Middleware::ProfilerMiddleware.new(app).call(env)
      body.close if body.respond_to?(:close)
      Profiler.storage.load(headers["X-Profiler-Token"])
    end

    include_examples "an allocation count"
  end

  context "for a job" do
    let(:profile) do
      Profiler::JobProfiler.profile(job_class: "MyJob", job_id: "1", queue: "q", arguments: [], executions: 0) { allocate! }
      latest("job")
    end

    include_examples "an allocation count"
  end

  context "for a console command" do
    let(:profile) do
      Profiler::ConsoleProfiler.profile(expression: "allocate!") { allocate! }
      latest("console")
    end

    include_examples "an allocation count"
  end

  context "for a test" do
    let(:profile) do
      Profiler::TestProfiler.profile(test_name: "T#t", test_file: "t.rb", test_line: 1, framework: :rspec) { allocate! }
      latest("test")
    end

    include_examples "an allocation count"
  end

  describe "a profile saved before the rename" do
    it "reads the old memory figure back as the allocation count it was made of" do
      profile = Profiler::Models::Profile.from_hash(token: "t", memory: 40 * 1234)
      expect(profile.allocated_objects).to eq(1234)
    end
  end

  describe "the warning threshold" do
    it "is named for a number of objects" do
      expect(Profiler::Configuration.new).to respond_to(:allocated_objects_warning_threshold)
    end

    it "still takes the deprecated memory_warning_threshold, read as objects times 40" do
      config = Profiler::Configuration.new
      expect { config.memory_warning_threshold = 40 * 1000 }.to output(/deprecated/).to_stderr
      expect(config.allocated_objects_warning_threshold).to eq(1000)
      expect(config.memory_warning_threshold).to eq(40 * 1000)
    end
  end
end
