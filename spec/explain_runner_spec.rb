# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "sqlite3"
require "profiler/explain_runner"
require "profiler/mcp/tools/explain_query"

RSpec.describe Profiler::ExplainRunner do
  # Records every statement the runner sends, so a spec can say what reached the
  # database without a PostgreSQL or MySQL server. Transactions follow
  # ActiveRecord: ActiveRecord::Rollback is swallowed and rolls back.
  class FakeExplainConnection
    attr_reader :log

    def initialize(adapter_name)
      @adapter_name = adapter_name
      @log = []
    end

    attr_reader :adapter_name

    def quote(value)
      value.is_a?(Numeric) ? value.to_s : "'#{value.to_s.gsub("'", "''")}'"
    end

    def transaction(requires_new: nil, joinable: true)
      @log << "BEGIN"
      yield
      @log << "COMMIT"
    rescue ActiveRecord::Rollback
      @log << "ROLLBACK"
    end

    def execute(sql, _name = nil)
      @log << sql
    end

    def exec_query(sql, _name = nil)
      @log << sql
      ActiveRecord::Result.new(["QUERY PLAN"], [["[{\"Plan\": {}}]"]])
    end
  end

  before do
    Profiler.configure { |c| c.enabled = true }
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def store_query(sql, binds = [])
    profile = build_profile
    profile.add_collector_data("database", { "queries" => [{ "sql" => sql, "binds" => binds }] })
    Profiler.storage.save(profile.token, profile)
    profile.token
  end

  def explain(sql, binds = [])
    described_class.run(store_query(sql, binds), 0)
  end

  def explain_statements(log)
    log.grep(/\AEXPLAIN/)
  end

  WRITES = {
    "DELETE"                  => "DELETE FROM widgets WHERE id = 1",
    "UPDATE"                  => "UPDATE widgets SET name = 'x' WHERE id = 1",
    "INSERT"                  => "INSERT INTO widgets (name) VALUES ('x')",
    "MERGE"                   => "MERGE INTO widgets w USING other o ON w.id = o.id WHEN MATCHED THEN DELETE",
    "TRUNCATE"                => "TRUNCATE widgets",
    "DROP"                    => "DROP TABLE widgets",
    "CREATE TABLE AS"         => "CREATE TABLE copy AS SELECT * FROM widgets",
    "a CTE that deletes"      => "WITH d AS (DELETE FROM widgets WHERE id = 1 RETURNING id) SELECT * FROM d",
    "a CTE that inserts"      => "WITH i AS (INSERT INTO widgets (name) VALUES ('x') RETURNING id) SELECT id FROM i",
    "SELECT INTO"             => "SELECT * INTO backup FROM widgets",
    "SELECT INTO OUTFILE"     => "SELECT * FROM widgets INTO OUTFILE '/tmp/widgets'",
    "SELECT FOR UPDATE"       => "SELECT * FROM widgets WHERE id = 1 FOR UPDATE",
    "SELECT FOR SHARE"        => "SELECT * FROM widgets WHERE id = 1 FOR SHARE",
    "LOCK IN SHARE MODE"      => "SELECT * FROM widgets WHERE id = 1 LOCK IN SHARE MODE",
    "a second statement"      => "SELECT 1; DELETE FROM widgets",
    "leading comments"        => "/* app:42 */ -- note\n  DELETE FROM widgets WHERE id = 1",
    "a parenthesised DELETE"  => "( DELETE FROM widgets )",
    "an EXPLAIN ANALYZE"      => "EXPLAIN ANALYZE DELETE FROM widgets",
    "CALL"                    => "CALL cleanup_widgets()",
    "COPY"                    => "COPY widgets TO '/tmp/widgets'",
    "an empty statement"      => "  -- nothing\n"
  }.freeze

  READS = {
    "SELECT"                       => "SELECT * FROM widgets WHERE id = 1",
    "lowercase select"             => "select * from widgets",
    "a leading comment"            => "/* app:42 */ -- note\n SELECT * FROM widgets",
    "a parenthesised UNION"        => "(SELECT id FROM widgets) UNION (SELECT id FROM widgets)",
    "a read-only CTE"              => "WITH r AS (SELECT id FROM widgets) SELECT * FROM r",
    "TABLE"                        => "TABLE widgets",
    "VALUES"                       => "VALUES (1, 'a'), (2, 'b')",
    "a write keyword in a literal" => "SELECT * FROM widgets WHERE name = 'DELETE; DROP TABLE widgets'",
    "a write keyword quoted"       => "SELECT \"update\", \"delete\" FROM widgets",
    "a keyword as a prefix"        => "SELECT updated_at, deleted, inserted_by FROM widgets",
    "a trailing semicolon"         => "SELECT 1;"
  }.freeze

  # Statements read the way each database reads them: what a literal, a quoted
  # identifier or a comment is differs, and a keyword hidden by a misreading
  # would be explained.
  DIALECT_WRITES = {
    "PostgreSQL" => {
      "FOR UPDATE after a backslash-ended literal" => "SELECT 'C:\\' FROM widgets FOR UPDATE",
      "FOR UPDATE after a dollar-quoted literal"  => "SELECT $q$ it's $q$ FROM widgets FOR UPDATE"
    },
    "Mysql2" => {
      "FOR UPDATE after a # comment with a quote" => "SELECT 1 # it's\n FROM widgets FOR UPDATE",
      "FOR UPDATE after --1, which is not a comment" => "SELECT 1--1 FROM widgets FOR UPDATE",
      "FOR UPDATE after an escaped quote"           => "SELECT 'it\\'s' FROM widgets FOR UPDATE",
      "an executable comment"                       => "SELECT * FROM widgets /*! INTO OUTFILE '/tmp/w' */",
      "FOR UPDATE after a non-nesting comment"      => "SELECT 1 /* a /* b */ FROM widgets FOR UPDATE"
    },
    "SQLite" => {
      "DELETE after a non-nesting comment" => "/* a /* b */ DELETE FROM widgets"
    }
  }.freeze

  DIALECT_READS = {
    "PostgreSQL" => {
      "DELETE in a dollar-quoted literal" => "SELECT $body$ DELETE FROM widgets; $body$",
      "DELETE in an E'' literal"          => "SELECT E'it\\'s DELETE' FROM widgets",
      "DELETE in a nested comment"        => "/* outer /* inner */ DELETE */ SELECT 1"
    },
    "Mysql2" => {
      "keywords in backticks"        => "SELECT `update`, `delete` FROM widgets",
      "DELETE in a # comment"        => "SELECT 1 # DELETE",
      "DELETE after an escaped quote" => "SELECT 'it\\' DELETE' FROM widgets",
      "an optimizer hint"            => "SELECT /*+ MAX_EXECUTION_TIME(1000) */ * FROM widgets"
    },
    "SQLite" => {
      "keywords in backticks" => "SELECT `update`, `delete` FROM widgets"
    }
  }.freeze

  { "PostgreSQL" => "postgresql", "Mysql2" => "mysql2", "SQLite" => "sqlite" }.each do |adapter_name, adapter|
    describe "statements that are not read-only (#{adapter_name}, statements sent)" do
      let(:conn) { FakeExplainConnection.new(adapter_name) }

      before { allow(ActiveRecord::Base).to receive(:connection).and_return(conn) }

      WRITES.merge(DIALECT_WRITES[adapter_name]).each do |label, sql|
        it "refuses #{label} and sends nothing to the database" do
          expect { explain(sql) }.to raise_error(ArgumentError, /read-only/)
          expect(conn.log).to be_empty
        end
      end

      READS.merge(DIALECT_READS[adapter_name]).each do |label, sql|
        it "explains #{label}" do
          expect(explain(sql)).to include(adapter: adapter)
          expect(explain_statements(conn.log).size).to eq(1)
        end
      end
    end
  end

  it "answers a refusal with an error that names the reason" do
    allow(ActiveRecord::Base).to receive(:connection).and_return(FakeExplainConnection.new("PostgreSQL"))

    expect { explain("WITH d AS (DELETE FROM widgets RETURNING id) SELECT * FROM d") }
      .to raise_error(described_class::UnsafeStatementError, /only read-only statements .* it contains DELETE/)
  end

  describe "the probe transaction" do
    it "on PostgreSQL, runs the EXPLAIN read-only, in a transaction rolled back even on success" do
      conn = FakeExplainConnection.new("PostgreSQL")
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)

      explain("SELECT * FROM widgets WHERE id = $1", [7])

      expect(conn.log).to eq([
        "BEGIN",
        "SAVEPOINT profiler_explain",
        "SET TRANSACTION READ ONLY",
        "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM widgets WHERE id = 7",
        "ROLLBACK TO SAVEPOINT profiler_explain",
        "ROLLBACK"
      ])
    end

    it "on MySQL, runs the plain EXPLAIN in a transaction rolled back even on success" do
      conn = FakeExplainConnection.new("Mysql2")
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)

      explain("SELECT * FROM widgets WHERE id = ?", [7])

      expect(conn.log).to eq([
        "BEGIN",
        "SAVEPOINT profiler_explain",
        "EXPLAIN FORMAT=JSON SELECT * FROM widgets WHERE id = 7",
        "ROLLBACK TO SAVEPOINT profiler_explain",
        "ROLLBACK"
      ])
    end
  end

  describe "placeholder reconstruction" do
    it "replaces $10 and above as whole placeholders (PostgreSQL)" do
      conn = FakeExplainConnection.new("PostgreSQL")
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)

      sql = "SELECT * FROM widgets WHERE id IN (#{(1..11).map { |i| "$#{i}" }.join(", ")})"
      explain(sql, (101..111).to_a)

      expect(explain_statements(conn.log)).to eq([
        "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM widgets WHERE id IN " \
        "(101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111)"
      ])
    end

    it "leaves placeholders inside literals, and inside substituted values, alone (PostgreSQL)" do
      conn = FakeExplainConnection.new("PostgreSQL")
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)

      explain("SELECT '$1', $1, $2 FROM widgets", ["costs $2", "it's"])

      expect(explain_statements(conn.log)).to eq([
        "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT '$1', 'costs $2', 'it''s' FROM widgets"
      ])
    end

    it "leaves the jsonb ? operator alone (PostgreSQL)" do
      conn = FakeExplainConnection.new("PostgreSQL")
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)

      explain("SELECT * FROM widgets WHERE data ? 'k' AND id = $1", [5])

      expect(explain_statements(conn.log)).to eq([
        "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM widgets WHERE data ? 'k' AND id = 5"
      ])
    end

    it "replaces ? in order, ignoring ? inside literals and substituted values (MySQL)" do
      conn = FakeExplainConnection.new("Mysql2")
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)

      binds = ["a?b"] + (2..12).to_a
      sql = "SELECT '?' FROM widgets WHERE name = ? AND id IN (#{Array.new(11, "?").join(", ")})"
      explain(sql, binds)

      expect(explain_statements(conn.log)).to eq([
        "EXPLAIN FORMAT=JSON SELECT '?' FROM widgets WHERE name = 'a?b' AND id IN " \
        "(2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)"
      ])
    end
  end

  describe "on a real SQLite database" do
    before(:all) do
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    end

    after(:all) do
      ActiveRecord::Base.remove_connection
    end

    let(:conn) { ActiveRecord::Base.connection }

    before do
      conn.execute("DROP TABLE IF EXISTS widgets")
      conn.execute("CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT)")
      12.times { |i| conn.execute("INSERT INTO widgets (name) VALUES ('w#{i + 1}')") }
    end

    def widget_count
      conn.select_value("SELECT COUNT(*) FROM widgets")
    end

    it "explains a SELECT" do
      result = explain("SELECT * FROM widgets WHERE id = ?", [3])

      expect(result[:format]).to eq("text")
      expect(result[:adapter]).to eq("sqlite")
      expect(result[:result]).to match(/SEARCH widgets/)
    end

    it "refuses a DELETE and leaves the rows in place" do
      expect { explain("DELETE FROM widgets WHERE id = ?", [3]) }.to raise_error(ArgumentError, /read-only/)
      expect(widget_count).to eq(12)
    end

    it "rolls back the probe even when it succeeds" do
      # Stands for a function with a side effect called from a SELECT, which no
      # reading of the statement can rule out.
      allow(conn).to receive(:exec_query).and_wrap_original do |original, sql, *args|
        conn.execute("INSERT INTO widgets (name) VALUES ('side effect')") if sql.start_with?("EXPLAIN")
        original.call(sql, *args)
      end

      explain("SELECT * FROM widgets", [])

      expect(widget_count).to eq(12)
    end

    it "inside an open transaction, rolls back only the probe" do
      conn.transaction do
        conn.execute("INSERT INTO widgets (name) VALUES ('kept')")
        explain("SELECT * FROM widgets", [])
      end

      expect(widget_count).to eq(13)
    end

    it "explains a query with twelve binds" do
      sql = "SELECT * FROM widgets WHERE id IN (#{Array.new(12, "?").join(", ")})"

      expect(explain(sql, (1..12).to_a)[:result]).to match(/SEARCH widgets/)
    end
  end

  describe "the MCP explain_query tool" do
    it "returns an error for a DELETE, without touching the database" do
      conn = FakeExplainConnection.new("PostgreSQL")
      allow(ActiveRecord::Base).to receive(:connection).and_return(conn)

      text = Profiler::MCP::Tools::ExplainQuery.call(
        "token" => store_query("DELETE FROM widgets WHERE id = $1", [1]), "query_index" => 0
      ).first[:text]

      expect(text).to start_with("Error:")
      expect(text).to include("read-only")
      expect(conn.log).to be_empty
    end
  end
end
