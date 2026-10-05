# frozen_string_literal: true

require "spec_helper"
require "profiler/collectors/database_collector"
require "profiler/mcp/resources/n1_patterns"

# Capturing the caller of a query costs tens of microseconds, paid on every query of the page:
# about 18 ms for 200 queries. The collector keeps it where it tells something: the first time a
# statement runs in the request, which locates an N+1 loop, and every slow query.
RSpec.describe Profiler::Collectors::DatabaseCollector, "backtraces" do
  let(:profile) { Profiler::Models::Profile.new }
  subject(:collector) { described_class.new(profile) }

  let(:sql_backtrace) { nil }

  before do
    Profiler.configure do |c|
      c.slow_query_threshold = 5
      c.sql_backtrace = sql_backtrace if sql_backtrace
    end
    collector.subscribe
  end

  after { collector.unsubscribe }

  # The event carries its own start and finish, 50 ms apart for a slow query and 0.1 ms otherwise,
  # whatever the machine's load: a query measured on the clock could pass the 5 ms threshold
  # while the thread waits for a CPU, and get a backtrace it is not meant to get.
  def query(sql, slow: false)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    finished = started + (slow ? 0.05 : 0.0001)
    ActiveSupport::Notifications.publish("sql.active_record", started, finished, SecureRandom.hex(10),
                                         { sql: sql, name: "User Load", binds: [] })
  end

  def backtraces
    collector.collect
    profile.collector_data("database")[:queries].map { |q| q[:backtrace] }
  end

  it "locates the first run of a statement, and not the twenty repeats of an N+1 loop" do
    20.times { query("SELECT * FROM comments WHERE post_id = ?") }

    first, *repeats = backtraces
    expect(first).not_to be_empty
    expect(repeats).to all(be_empty)
  end

  it "locates the first run of an N+1 loop whose values are inlined in the SQL, as with MySQL" do
    (1..20).each { |id| query("SELECT * FROM comments WHERE post_id = #{id} AND state = 'open'") }

    first, *repeats = backtraces
    expect(first).not_to be_empty
    expect(repeats).to all(be_empty)
  end

  # The Database tab (DatabaseTab.tsx, computeN1Groups) and the MCP resource group the queries
  # of a profile by normalized statement and show the backtrace of each group's first query.
  describe "the N+1 detection" do
    def run_page
      3.times { |i| query("SELECT * FROM posts WHERE id = #{i}") }
      query("SELECT * FROM users")
      (1..12).each { |id| query("SELECT * FROM comments WHERE post_id = #{id}") }
      query("SELECT * FROM comments WHERE post_id = 99", slow: true)
    end

    it "still has the location of every group, as the Database tab reads it" do
      run_page
      collector.collect
      queries = profile.collector_data("database")[:queries]

      groups = queries.group_by { |q| Profiler::MCP::Resources::N1Patterns.normalize_sql(q[:sql]) }
      expect(groups.size).to eq(3)
      expect(groups.values.map { |group| group.first[:backtrace] }).to all(be_any)
      expect(queries.last[:backtrace]).to be_any # the slow one
    end

    it "still has the location of every pattern in the MCP n1-patterns resource" do
      storage = Profiler::Storage::MemoryStore.new
      Profiler.instance_variable_set(:@storage, storage)
      run_page
      collector.collect
      profile.finish(200)
      storage.save(profile.token, profile)

      patterns = JSON.parse(Profiler::MCP::Resources::N1Patterns.call[:text])["patterns"]

      expect(patterns.map { |p| p["total_occurrences"] }).to contain_exactly(13, 3)
      expect(patterns.map { |p| p["backtrace"] }).to all(be_any)
      expect(patterns.map { |p| p["backtrace"].first }).to all(include(__FILE__))
    end
  end

  it "locates every distinct statement" do
    query("SELECT * FROM posts")
    query("SELECT * FROM users")

    expect(backtraces).to all(be_any)
  end

  it "locates every slow query, repeated or not" do
    3.times { query("SELECT * FROM comments WHERE post_id = ?", slow: true) }

    expect(backtraces).to all(be_any)
  end

  it "points at the code that ran the query, not at the profiler or ActiveSupport" do
    query("SELECT 1")

    expect(backtraces.first.first).to include(__FILE__)
    expect(backtraces.first.join).not_to include("active_support/notifications")
  end

  context "with config.sql_backtrace = :all, the behavior of earlier versions" do
    let(:sql_backtrace) { :all }

    it "locates every query" do
      20.times { query("SELECT * FROM comments WHERE post_id = ?") }

      expect(backtraces).to all(be_any)
    end
  end

  context "with config.sql_backtrace = :none" do
    let(:sql_backtrace) { :none }

    it "locates no query" do
      query("SELECT 1", slow: true)

      expect(backtraces).to all(be_empty)
    end
  end
end

# With a real Active Record, the query runs under frames of Active Support (connection locks,
# instrumentation) and of the database driver before reaching the application's code.
RSpec.describe Profiler::Collectors::DatabaseCollector, "backtraces of a real Active Record query" do
  before(:all) do
    require "active_record"
    require "sqlite3"
    require "tmpdir"
    require "fileutils"
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.connection.create_table(:profiler_spec_posts) { |t| t.string :title }
    class ProfilerSpecPost < ActiveRecord::Base; end
  end

  after(:all) { ActiveRecord::Base.remove_connection }

  let(:profile) { Profiler::Models::Profile.new }
  let(:collector) { described_class.new(profile) }

  def load_posts
    ProfilerSpecPost.where(title: "x").to_a
  end

  def first_frames
    collector.subscribe
    load_posts
    collector.collect
    query = profile.collector_data("database")[:queries].find { |q| q[:sql].include?("profiler_spec_posts") }
    query[:backtrace].first(3)
  end

  it "starts at the application's code, within the three frames the MCP n1-patterns resource keeps" do
    expect(first_frames.first).to include("#{__FILE__}:")
    expect(first_frames.first).to include("load_posts")
  end

  # Rails 7.0 runs the query under ActiveSupport::Concurrency locks; any gem can stand between
  # the application and Active Record the same way.
  it "skips the frames of the gems between the application and Active Record" do
    dir = Dir.mktmpdir
    allow(Gem).to receive(:path).and_return([*Gem.path, dir])
    library = File.join(dir, "gems", "profiler-spec-wrapper-1.0", "lib", "wrapper.rb")
    FileUtils.mkdir_p(File.dirname(library))
    File.write(library, "module ProfilerSpecWrapper; def self.around; yield; end; end\n")
    load library
    collector.subscribe
    ProfilerSpecWrapper.around { load_posts }
    collector.collect

    query = profile.collector_data("database")[:queries].find { |q| q[:sql].include?("profiler_spec_posts") }
    expect(query[:backtrace].first).to include("load_posts")
    expect(query[:backtrace].join).not_to include("profiler-spec-wrapper")
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  # An application may itself live under a directory called gems (/srv/gems/shop): only the
  # directories gems are installed in are left out.
  it "keeps the application's frames when its path holds a gems directory" do
    dir = Dir.mktmpdir
    app_file = File.join(dir, "gems", "shop", "app", "models", "catalog.rb")
    FileUtils.mkdir_p(File.dirname(app_file))
    File.write(app_file, "module ProfilerSpecCatalog; def self.load(&block); block.call; end; end\n")
    load app_file
    collector.subscribe
    ProfilerSpecCatalog.load { load_posts }
    collector.collect

    query = profile.collector_data("database")[:queries].find { |q| q[:sql].include?("profiler_spec_posts") }
    expect(query[:backtrace].join("\n")).to include(app_file)
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  context "in a Rails application" do
    let(:cleaner) do
      ActiveSupport::BacktraceCleaner.new.tap do |c|
        c.add_filter { |line| line.sub("#{File.dirname(__FILE__)}/", "") }
        c.add_silencer { |line| line.include?("/gems/") || line.include?("/ruby/") }
      end
    end

    before { stub_const("Rails", double("Rails", backtrace_cleaner: cleaner)) }

    it "uses Rails.backtrace_cleaner, as the exception tab does" do
      expect(first_frames.first).to start_with("#{File.basename(__FILE__)}:")
    end
  end
end
