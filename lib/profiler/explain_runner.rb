# frozen_string_literal: true

require "profiler/sql_statement"

module Profiler
  # Shared service for running EXPLAIN ANALYZE on a stored query.
  # Used by both the HTTP API controller and the MCP explain_query tool.
  #
  # Only read-only statements are explained: PostgreSQL's EXPLAIN ANALYZE runs the
  # statement, so explaining a write would replay it. The probe itself runs in a
  # transaction that is always rolled back, read-only on PostgreSQL, for what no
  # reading of the statement can rule out (a function with a side effect).
  module ExplainRunner
    # An ArgumentError, so callers answer it as a bad request (422, MCP error).
    class UnsafeStatementError < ArgumentError; end

    # @param profile_token [String]
    # @param query_index   [Integer]
    # @return [Hash] { result:, format: "json"|"text", adapter: String }
    #         or raises ArgumentError / RuntimeError
    def self.run(profile_token, query_index)
      unless Profiler.configuration.enabled
        raise SecurityError, "EXPLAIN is only available when the profiler is enabled"
      end

      profile = Profiler.storage.load(profile_token)
      raise ArgumentError, "Profile not found: #{profile_token}" unless profile

      db_data = profile.collector_data("database")
      raise ArgumentError, "No database data in this profile" unless db_data && db_data["queries"]

      queries = db_data["queries"]
      query_index = query_index.to_i
      unless query_index >= 0 && query_index < queries.size
        raise ArgumentError, "Query index #{query_index} out of range (0..#{queries.size - 1})"
      end

      query = queries[query_index]
      sql   = query["sql"].to_s
      binds = Array(query["binds"])
      if binds.include?(Redaction::MASK)
        raise ArgumentError, "EXPLAIN refused for query #{query_index}: one of its bind values was " \
                             "filtered when captured (config.filter_parameters), so the query cannot be rebuilt"
      end

      conn    = ActiveRecord::Base.connection
      adapter = conn.adapter_name.downcase
      refusal = SqlStatement.read_only_refusal(sql, dialect: dialect_for(adapter))
      raise UnsafeStatementError, refusal if refusal

      full_sql = reconstruct_sql(sql, binds, conn, adapter)

      explain_sql, format = build_explain_statement(full_sql, adapter)

      rows = probe(conn, explain_sql, adapter)

      result = if format == "json"
        # PostgreSQL / MySQL return JSON in rows[0]["QUERY PLAN"] or rows[0]["EXPLAIN"]
        raw = rows.first&.values&.first.to_s
        JSON.parse(raw) rescue raw
      else
        rows.map { |r| r.values.join("\t") }.join("\n")
      end

      { result: result, format: format, adapter: adapter }
    end

    private

    def self.reconstruct_sql(sql, binds, conn, adapter)
      SqlStatement.substitute(sql, binds, dialect: dialect_for(adapter)) { |value| conn.quote(value) }
    end

    def self.dialect_for(adapter)
      if adapter.include?("postgresql") then :postgresql
      elsif adapter.include?("mysql") || adapter.include?("trilogy") then :mysql
      else :sqlite
      end
    end

    # Never commits. Read-only on PostgreSQL only: MySQL refuses SET TRANSACTION once
    # a transaction has begun, and neither MySQL's EXPLAIN nor SQLite's EXPLAIN QUERY
    # PLAN runs the statement. The probe's own savepoint is what undoes READ ONLY
    # inside a transaction the application already opened: when that transaction has
    # run nothing yet, ActiveRecord skips the nested savepoint and rolls back with
    # ROLLBACK AND CHAIN, which would carry READ ONLY over.
    def self.probe(conn, explain_sql, adapter)
      rows = nil
      conn.transaction(requires_new: true) do
        conn.execute("SAVEPOINT profiler_explain")
        begin
          conn.execute("SET TRANSACTION READ ONLY") if adapter.include?("postgresql")
          rows = conn.exec_query(explain_sql, "EXPLAIN").to_a
        ensure
          conn.execute("ROLLBACK TO SAVEPOINT profiler_explain")
        end
        raise ActiveRecord::Rollback
      end
      rows
    end

    def self.build_explain_statement(sql, adapter)
      if adapter.include?("postgresql")
        ["EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}", "json"]
      elsif adapter.include?("mysql")
        ["EXPLAIN FORMAT=JSON #{sql}", "json"]
      else
        ["EXPLAIN QUERY PLAN #{sql}", "text"]
      end
    end
  end
end
