# frozen_string_literal: true

require "spec_helper"

# Runs against a real PostgreSQL, where EXPLAIN ANALYZE executes the statement it
# explains. Needs the `pg` gem and a disposable database, for instance:
#
#   PROFILER_TEST_POSTGRES_URL=postgres://postgres@localhost/profiler_test bundle exec rspec spec/explain_runner_postgresql_spec.rb
#
# Without the variable the examples are filtered out, not reported as pending.
POSTGRES_URL = ENV["PROFILER_TEST_POSTGRES_URL"]

RSpec.describe "Profiler::ExplainRunner on a real PostgreSQL", if: POSTGRES_URL do
  before(:all) do
    require "active_record"
    require "pg"
    require "profiler/explain_runner"
    ActiveRecord::Base.establish_connection(POSTGRES_URL)
  end

  after(:all) do
    ActiveRecord::Base.remove_connection
  end

  let(:conn) { ActiveRecord::Base.connection }

  before do
    Profiler.configure { |c| c.enabled = true }
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
    conn.execute("DROP TABLE IF EXISTS profiler_explain_widgets")
    conn.execute("CREATE TABLE profiler_explain_widgets (id integer PRIMARY KEY, name text)")
    conn.execute("INSERT INTO profiler_explain_widgets SELECT g, 'w' || g FROM generate_series(101, 112) g")
    conn.execute("DROP SEQUENCE IF EXISTS profiler_explain_seq")
    conn.execute("CREATE SEQUENCE profiler_explain_seq")
  end

  after do
    conn.execute("DROP TABLE IF EXISTS profiler_explain_widgets")
    conn.execute("DROP SEQUENCE IF EXISTS profiler_explain_seq")
  end

  def explain(sql, binds = [])
    profile = build_profile
    profile.add_collector_data("database", { "queries" => [{ "sql" => sql, "binds" => binds }] })
    Profiler.storage.save(profile.token, profile)
    Profiler::ExplainRunner.run(profile.token, 0)
  end

  def widget_count
    conn.select_value("SELECT count(*) FROM profiler_explain_widgets").to_i
  end

  {
    "DELETE"             => ["DELETE FROM profiler_explain_widgets WHERE id = $1", [101]],
    "UPDATE"             => ["UPDATE profiler_explain_widgets SET name = 'x' WHERE id = $1", [101]],
    "INSERT"             => ["INSERT INTO profiler_explain_widgets VALUES ($1, $2)", [100, "new"]],
    "a CTE that deletes" => ["WITH d AS (DELETE FROM profiler_explain_widgets WHERE id = $1 RETURNING id) SELECT * FROM d", [101]]
  }.each do |label, (sql, binds)|
    it "refuses #{label} and changes no row", :aggregate_failures do
      expect { explain(sql, binds) }.to raise_error(ArgumentError, /read-only/)
      expect(widget_count).to eq(12)
      expect(conn.select_value("SELECT name FROM profiler_explain_widgets WHERE id = 101")).to eq("w101")
    end
  end

  it "explains a SELECT with EXPLAIN ANALYZE" do
    result = explain("SELECT * FROM profiler_explain_widgets WHERE id = $1", [103])

    expect(result[:format]).to eq("json")
    expect(result[:result].first).to include("Plan", "Execution Time")
  end

  it "explains a SELECT with twelve binds" do
    sql = "SELECT * FROM profiler_explain_widgets WHERE id IN (#{(1..12).map { |i| "$#{i}" }.join(", ")})"
    plan = explain(sql, (101..112).to_a)[:result].first["Plan"]

    expect(plan["Actual Rows"]).to eq(12)
  end

  it "runs the probe read-only, so a SELECT with a side effect fails and changes nothing" do
    expect { explain("SELECT nextval('profiler_explain_seq')") }.to raise_error(ActiveRecord::StatementInvalid, /read-only transaction/)
    expect(conn.select_value("SELECT nextval('profiler_explain_seq')").to_i).to eq(1)
  end

  it "leaves the connection usable and outside any transaction" do
    explain("SELECT 1")

    expect(conn.transaction_open?).to be(false)
    expect(conn.select_value("SHOW transaction_read_only")).to eq("off")
  end

  it "inside an open transaction, probes in a savepoint and leaves that transaction writable" do
    conn.transaction do
      explain("SELECT * FROM profiler_explain_widgets")

      expect(conn.select_value("SHOW transaction_read_only")).to eq("off")
      conn.execute("DELETE FROM profiler_explain_widgets WHERE id = 101")
      raise ActiveRecord::Rollback
    end

    expect(widget_count).to eq(12)
  end

  it "inside an open transaction, leaves it usable after a probe that fails" do
    conn.transaction do
      expect { explain("SELECT nextval('profiler_explain_seq')") }.to raise_error(ActiveRecord::StatementInvalid)

      expect(conn.select_value("SHOW transaction_read_only")).to eq("off")
      expect(conn.select_value("SELECT count(*) FROM profiler_explain_widgets").to_i).to eq(12)
      raise ActiveRecord::Rollback
    end
  end
end
