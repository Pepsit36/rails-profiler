# frozen_string_literal: true

require "spec_helper"
require "profiler/console_profiler"
require "profiler/test_profiler"
require "profiler/job_profiler"
require "profiler/collectors/http_collector"

# A storage that fails (a disk full, a link refused, Redis gone) loses the profile, never the
# application's job, console command, test or outbound HTTP call: the save is isolated and warned
# about, as the HTTP middleware already does for requests.
RSpec.describe "Storage errors on the application's paths" do
  let(:failing_storage) do
    Class.new(Profiler::Storage::BaseStore) do
      def do_save(_token, _profile)
        raise Errno::ENOSPC
      end
    end.new
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.track_jobs = true
      config.track_console = true
      config.track_memory = false
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, failing_storage)
  end

  it "lets a job succeed" do
    result = nil
    expect do
      result = Profiler::JobProfiler.profile(job_class: "W", job_id: "1", queue: "q", arguments: [], executions: 0) { :done }
    end.to output(/\[Profiler\].*JobProfiler.*could not save.*No space left/).to_stderr
    expect(result).to eq(:done)
  end

  it "keeps the job's own exception" do
    expect do
      expect do
        Profiler::JobProfiler.profile(job_class: "W", job_id: "1", queue: "q", arguments: [], executions: 0) do
          raise ArgumentError, "the job's own"
        end
      end.to raise_error(ArgumentError, "the job's own")
    end.to output(/could not save/).to_stderr
  end

  it "lets a console command succeed" do
    result = nil
    expect { result = Profiler::ConsoleProfiler.profile(expression: "1 + 1") { 2 } }
      .to output(/\[Profiler\].*ConsoleProfiler.*could not save/).to_stderr
    expect(result).to eq(2)
  end

  it "lets a test succeed" do
    result = nil
    expect do
      result = Profiler::TestProfiler.profile(test_name: "t", test_file: "spec/t_spec.rb", test_line: 1,
                                              framework: :rspec) { :passed }
    end.to output(/\[Profiler\].*TestProfiler.*could not save/).to_stderr
    expect(result).to eq(:passed)
  end

  it "lets an outbound HTTP call that ends after the profile was collected go on" do
    collector = Profiler::Collectors::HttpCollector.new(build_profile)
    collector.collect

    entry = nil
    expect { entry = collector.register_pending(method: "GET", url: "http://example.test/") }
      .to output(/\[Profiler\].*HttpCollector.*could not save/).to_stderr
    expect(entry).to include(url: "http://example.test/")
  end
end
