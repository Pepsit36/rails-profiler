# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "logger"
require "active_support/logger"
require "profiler/test_profiler"
require "profiler/collectors/dump_collector"
require "profiler/collectors/log_collector"
require "profiler/collectors/mailer_collector"

# Profiler.dump records into the slot a DumpCollector holds while a profile runs. Outside of
# any such profile (a request the profiler skips, a test profile without a dump collector) there
# is nobody to read the dump, so it must not be kept on the thread.
RSpec.describe "Profiler.dump outside a profile" do
  include Rack::Test::Methods

  let(:inner_app) do
    lambda do |env|
      Profiler.dump(env["PATH_INFO"], "path")
      [200, { "Content-Type" => "text/plain" }, ["ok"]]
    end
  end

  def app
    Profiler::Middleware::ProfilerMiddleware.new(inner_app)
  end

  def default_host
    "localhost"
  end

  before do
    Thread.current[:profiler_dumps] = nil
    Profiler.configure do |c|
      c.enabled = true
      c.storage = :memory
      c.track_memory = false
      c.track_http = false
      c.skip_paths = [%r{\A/skipped}]
      c.collectors = [Profiler::Collectors::DumpCollector]
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  after { Thread.current[:profiler_dumps] = nil }

  it "keeps nothing on the thread across unprofiled and profiled requests" do
    2000.times do |i|
      get "/skipped/#{i}"
      get "/profiled/#{i}" if (i % 100).zero?
    end

    expect(Array(Thread.current[:profiler_dumps]).size).to eq(0)
  end

  it "still records the dumps of a profiled request, and only those" do
    get "/skipped/before"
    get "/profiled"

    profile = Profiler.storage.load(last_response.headers["X-Profiler-Token"])
    dumps = profile.collectors_data["dump"]["dumps"]
    expect(dumps.map { |d| d["value"] }).to eq(["/profiled"])
  end

  it "keeps nothing from a test profile, which has no dump collector" do
    200.times do
      Profiler::TestProfiler.profile(test_name: "T#t", test_file: "spec/t_spec.rb", test_line: 1,
                                     framework: :rspec) { Profiler.dump(:in_test) }
    end

    expect(Array(Thread.current[:profiler_dumps]).size).to eq(0)
  end

  context "with the other thread-local slots the collectors hand back" do
    let(:broadcaster) { ActiveSupport::BroadcastLogger.new(Logger.new(nil)) }
    let(:inner_app) do
      lambda do |env|
        Rails.logger.info(env["PATH_INFO"])
        Profiler.dump(env["PATH_INFO"])
        ActiveSupport::Notifications.instrument("process.action_mailer", mailer: "UserMailer", action: "welcome", args: [])
        [200, { "Content-Type" => "text/plain" }, ["ok"]]
      end
    end

    before do
      stub_const("Rails", Module.new)
      logger = broadcaster
      Rails.define_singleton_method(:logger) { logger }
      Profiler.configure do |c|
        c.track_http = true
        c.track_mailers = true
        c.collectors = [
          Profiler::Collectors::DumpCollector,
          Profiler::Collectors::LogCollector,
          Profiler::Collectors::HttpCollector,
          Profiler::Collectors::MailerCollector
        ]
      end
    end

    it "leaves none of them filled on the thread after unprofiled and profiled requests" do
      500.times do |i|
        get "/skipped/#{i}"
        get "/profiled/#{i}" if (i % 50).zero?
      end

      expect(%i[profiler_dumps profiler_logs profiler_http_collector profiler_pending_processes]
        .to_h { |key| [key, Thread.current[key]] }).to eq(
          profiler_dumps: nil, profiler_logs: nil, profiler_http_collector: nil, profiler_pending_processes: nil
        )
      expect(broadcaster.broadcasts.size).to eq(1)
    end
  end

  it "returns the dumped value either way" do
    expect(Profiler.dump(:value)).to eq(:value)
  end
end
