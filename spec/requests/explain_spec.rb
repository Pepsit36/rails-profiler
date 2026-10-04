# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "sqlite3"
require "tmpdir"
require "fileutils"
require_relative "../support/rails_app"

# SEC-07 through the real controller stack: the explain endpoint explains a read
# and refuses a write, which PostgreSQL's EXPLAIN ANALYZE would run again.
RSpec.describe "POST /_profiler/api/explain", type: :request do
  include Rack::Test::Methods

  let(:writing) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost", "HTTP_X_PROFILER_REQUEST" => "1" } }
  let(:storage) { Profiler::Storage::MemoryStore.new }
  let(:conn) { ActiveRecord::Base.connection }

  def app
    Rails.application
  end

  def json
    JSON.parse(last_response.body)
  end

  before(:all) do
    @dir = Dir.mktmpdir("profiler-explain-request")
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(@dir, "explain.sqlite3"))
  end

  after(:all) do
    ActiveRecord::Base.remove_connection
    FileUtils.remove_entry(@dir)
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, storage)
    conn.execute("DROP TABLE IF EXISTS widgets")
    conn.execute("CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT)")
    3.times { |i| conn.execute("INSERT INTO widgets (name) VALUES ('w#{i + 1}')") }
  end

  def explain(sql, binds)
    profile = build_profile(collectors_data: { "database" => { "queries" => [{ "sql" => sql, "binds" => binds }] } })
    storage.save(profile.token, profile)
    post "/_profiler/api/explain", { token: profile.token, query_index: 0 }, writing
  end

  it "refuses a write with 422 and the reason, and changes no row" do
    explain("DELETE FROM widgets WHERE id = ?", [1])

    expect(last_response.status).to eq(422)
    expect(json["error"]).to match(/EXPLAIN refused: only read-only statements .* it starts with DELETE/)
    expect(conn.select_value("SELECT COUNT(*) FROM widgets")).to eq(3)
  end

  it "refuses a CTE that writes" do
    explain("WITH d AS (DELETE FROM widgets RETURNING id) SELECT * FROM d", [])

    expect(last_response.status).to eq(422)
    expect(json["error"]).to match(/it contains DELETE/)
  end

  it "explains a SELECT" do
    explain("SELECT * FROM widgets WHERE id = ?", [2])

    expect(last_response.status).to eq(200)
    expect(json).to include("format" => "text", "adapter" => "sqlite")
    expect(json["result"]).to match(/SEARCH widgets/)
  end
end
