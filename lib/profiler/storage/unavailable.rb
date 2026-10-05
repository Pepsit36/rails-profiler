# frozen_string_literal: true

module Profiler
  module Storage
    # Stands in for a store that could not be created (an index or lock replaced by a symbolic
    # link, a directory that cannot be written, a database that cannot be opened): the cause is
    # said once per process, without a backtrace, rather than with one on every request. Saves are
    # dropped; reads, which a person asked for from the dashboard or an MCP tool, raise the cause.
    # Profiler.storage tries to create the store again on its next call, so fixing the cause is
    # enough.
    class Unavailable
      @said = {}
      @mutex = Mutex.new

      class << self
        def for(error)
          key = [Process.pid, error.class.name, error.message]
          first = @mutex.synchronize { @said[key] ? false : (@said[key] = true) }
          if first
            warn "[Profiler] storage unavailable, profiles are not saved until it is fixed: " \
                 "#{error.class}: #{error.message}"
          end
          new(error)
        end

        def reset!
          @mutex.synchronize { @said = {} }
        end
      end

      def initialize(error)
        @error = error
      end

      def save(token, _profile)
        token
      end

      %i[load list cleanup exists? find_by_parent delete clear].each do |name|
        define_method(name) { |*, **| raise @error }
      end
    end
  end
end
