# frozen_string_literal: true

module Profiler
  module Models
    class SqlQuery
      attr_reader :sql, :duration, :binds, :name, :connection, :backtrace

      def initialize(sql:, duration:, binds: [], name: nil, connection: nil, backtrace: [])
        @sql = sql
        @duration = duration
        @binds = binds
        @name = name
        @connection = connection
        @backtrace = backtrace
      end

      def slow?(threshold = 100)
        @duration > threshold
      end

      def cached?
        @name == "CACHE"
      end

      def transaction?
        @sql =~ /^(BEGIN|COMMIT|ROLLBACK)/i
      end

      def to_h
        {
          sql: @sql,
          duration: @duration,
          binds: @binds,
          name: @name,
          connection: @connection&.class&.name,
          backtrace: @backtrace.map(&:to_s),
          slow: slow?,
          cached: cached?,
          transaction: transaction?
        }
      end

      def to_json(*args)
        to_h.to_json(*args)
      end
    end
  end
end
