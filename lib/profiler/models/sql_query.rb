# frozen_string_literal: true

module Profiler
  module Models
    class SqlQuery
      TRANSACTION_REGEX = /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i.freeze

      attr_reader :sql, :duration, :binds, :name, :connection, :backtrace, :started_at

      def initialize(sql:, duration:, binds: [], name: nil, connection: nil, backtrace: [], started_at: nil)
        @sql = sql
        @duration = duration
        @binds = binds
        @name = name
        @connection = connection
        @backtrace = backtrace
        @started_at = started_at
      end

      def slow?(threshold = 100)
        @duration > threshold
      end

      def cached?
        @name == "CACHE"
      end

      def transaction?
        @sql =~ TRANSACTION_REGEX
      end

      def to_h
        {
          sql: @sql,
          started_at: @started_at,
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
