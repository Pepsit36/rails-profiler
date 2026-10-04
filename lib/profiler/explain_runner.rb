# frozen_string_literal: true

module Profiler
  # Shared service for running EXPLAIN ANALYZE on a stored query.
  # Used by both the HTTP API controller and the MCP explain_query tool.
  module ExplainRunner
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
      full_sql = reconstruct_sql(sql, binds, conn, adapter)

      explain_sql, format = build_explain_statement(full_sql, adapter)

      rows = conn.exec_query(explain_sql, "EXPLAIN").to_a

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
      return sql if binds.empty?

      if adapter.include?("postgresql")
        result = sql.dup
        binds.each_with_index do |value, i|
          result = result.gsub("$#{i + 1}", conn.quote(value))
        end
        result
      else
        # MySQL / SQLite: replace ? sequentially
        result = sql.dup
        binds.each do |value|
          result = result.sub("?", conn.quote(value))
        end
        result
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
