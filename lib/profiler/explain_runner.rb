# frozen_string_literal: true

require "profiler/sql_statement"

module Profiler
  # Shared service for running EXPLAIN ANALYZE on a stored query.
  # Used by both the HTTP API controller and the MCP explain_query tool.
  #
  # Only read-only statements are explained: PostgreSQL's EXPLAIN ANALYZE runs the
  # statement, so explaining a write would replay it. The probe itself runs, for
  # what no reading of the statement can rule out (a function with a side effect),
  # on a connection of its own that is closed afterwards, in a transaction that is
  # always rolled back, read-only and time-limited on PostgreSQL.
  module ExplainRunner
    # An ArgumentError, so callers answer it as a bad request (422, MCP error).
    class UnsafeStatementError < ArgumentError; end

    # PostgreSQL's EXPLAIN ANALYZE runs the query: a slow one is stopped after this.
    PROBE_STATEMENT_TIMEOUT = "30s"

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

      rows = probe(explain_sql, adapter)

      result = if format == "json"
        # PostgreSQL / MySQL return JSON in rows[0]["QUERY PLAN"] or rows[0]["EXPLAIN"]
        raw = rows.first&.values&.first.to_s
        begin
          JSON.parse(raw)
        rescue JSON::ParserError
          raw
        end
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

    # Runs on a connection of its own, opened outside the pool and closed
    # afterwards, so that nothing the probe does to its session outlives it (an
    # advisory lock, a setting, a LISTEN), the application's own transaction is
    # never touched, and a full pool does not keep Explain waiting.
    # The transaction is always rolled back. On PostgreSQL it is also read-only and
    # time-limited, and the EXPLAIN goes by the extended protocol, which refuses
    # more than one statement: a COMMIT slipped in could not end the read-only
    # transaction. Neither MySQL's EXPLAIN nor SQLite's EXPLAIN QUERY PLAN runs the
    # statement.
    def self.probe(explain_sql, adapter)
      conn = open_probe_connection
      begin
        rows = nil
        conn.transaction do
          if adapter.include?("postgresql")
            conn.execute("SET TRANSACTION READ ONLY")
            conn.execute("SET LOCAL statement_timeout = #{conn.quote(PROBE_STATEMENT_TIMEOUT)}")
            rows = conn.raw_connection.exec_params(explain_sql, []).to_a
          else
            rows = conn.exec_query(explain_sql, "EXPLAIN").to_a
          end
          raise ActiveRecord::Rollback
        end
        rows
      ensure
        conn.disconnect!
      end
    end

    def self.open_probe_connection
      db_config = ActiveRecord::Base.connection_pool.db_config
      if db_config.respond_to?(:new_connection) # Active Record 7.2 and later
        db_config.new_connection
      else
        ActiveRecord::Base.public_send(db_config.adapter_method, db_config.configuration_hash)
      end
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
