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
      # What the reads raise: the cause in one line, without a path (the profiler's routes answer
      # it as a 503, the MCP tools as an error).
      class Error < Profiler::Error; end

      @said = {}
      @mutex = Mutex.new

      class << self
        def for(error)
          key = [Process.pid, error.class.name, error.message]
          first = @mutex.synchronize { @said[key] ? false : (@said[key] = true) }
          if first
            Profiler.log_warn("storage unavailable, profiles are not saved until it is fixed", error)
          end
          new(error)
        end

        def reset!
          @mutex.synchronize { @said = {} }
        end
      end

      def initialize(error)
        @error = Error.new("The profiler storage is unavailable: #{self.class.short_cause(error)}")
      end

      # First line of the message, absolute paths replaced, credentials masked, at most 300
      # characters.
      def self.short_cause(error)
        line = error.message.to_s.lines.first.to_s.strip
        line = line.gsub(%r{(?<=\A|[\s'"(=])(?:[A-Za-z]:)?[/\\][^\s'"]*[^\s'":,.;)]}, "[path]")
        line = Redaction.hide_credentials(line) if defined?(Redaction)
        line = line[0, 300]
        line.empty? ? error.class.name : line
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
