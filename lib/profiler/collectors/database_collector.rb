# frozen_string_literal: true

require_relative "base_collector"
require_relative "../models/sql_query"

module Profiler
  module Collectors
    class DatabaseCollector < BaseCollector
      BACKTRACE_DEPTH = 10
      MAX_SCANNED_FRAMES = 100
      FRAMES_PAST_APPLICATION = 15


      # Frames between the application's code and the subscriber: the profiler itself, the
      # notifications bus and Active Record.
      INTERNAL_FRAMES = [
        File.expand_path("..", __dir__) + "/",
        "/active_support/notifications",
        "/active_record/"
      ].freeze

      def initialize(profile)
        super
        @queries = []
        @subscriptions = []
        @seen_statements = {}
      end

      def icon
        "🗄️"
      end

      def priority
        20
      end

      def tab_config
        {
          key: "database",
          label: "Database",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: true
        }
      end

      def subscribe
        return unless defined?(ActiveSupport::Notifications)

        @backtrace_mode = Profiler.configuration.sql_backtrace&.to_sym
        @slow_query_threshold = Profiler.configuration.slow_query_threshold

        @subscriptions << subscribe_notification("sql.active_record") do |name, started, finished, unique_id, payload|
          duration = ((finished - started) * 1000).round(2) # milliseconds

          # Skip schema queries and internal Rails queries
          next if payload[:name] == "SCHEMA"
          next if payload[:sql] =~ /^(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i

          query = Models::SqlQuery.new(
            sql: payload[:sql],
            duration: duration,
            binds: extract_binds(payload[:binds]),
            name: payload[:name],
            connection: payload[:connection],
            backtrace: backtrace?(payload[:sql], duration) ? extract_backtrace : []
          )

          @queries << query
        end
      end

      def collect
        unsubscribe

        data = {
          total_queries: @queries.size,
          total_duration: @queries.sum(&:duration).round(2),
          slow_queries: @queries.select { |q| q.slow?(Profiler.configuration.slow_query_threshold) }.size,
          cached_queries: @queries.count(&:cached?),
          queries: @queries.map(&:to_h)
        }

        store_data(data)
      end

      # Collect reads only what the collector gathered itself.
      def collect_from_any_thread?
        true
      end

      def unsubscribe
        unsubscribe_notifications(@subscriptions)
      end

      def toolbar_summary
        total = @queries.size
        slow = @queries.select { |q| q.slow?(Profiler.configuration.slow_query_threshold) }.size
        duration = @queries.sum(&:duration).round(2)

        color = if slow > 0
                  "red"
                elsif total > Profiler.configuration.max_queries_warning
                  "orange"
                else
                  "green"
                end

        {
          text: "#{total} queries (#{duration}ms)",
          color: color,
          slow_queries: slow
        }
      end

      private

      def extract_binds(binds)
        return [] unless binds

        binds.map do |bind|
          if bind.respond_to?(:value)
            name = bind.name if bind.respond_to?(:name)
            Profiler::Redaction.filter_named(name, bind.value)
          else
            bind
          end
        end
      rescue StandardError
        # Never let the profiler raise into the application's query.
        binds.map { Profiler::Redaction::MASK }
      end

      # Capturing the caller costs tens of microseconds. The first run of a statement locates
      # it, an N+1 loop included (its repeats are the same statement with other values); a slow
      # query is always located.
      def backtrace?(sql, duration)
        case @backtrace_mode
        when :all then true
        when :none then false
        else
          key = statement_key(sql)
          first = !@seen_statements.key?(key)
          @seen_statements[key] = true if first
          first || duration > @slow_query_threshold
        end
      end

      # The statement with its values left out, exactly as the N+1 detection of the Database tab
      # (DatabaseTab.tsx) and of the MCP (Resources::N1Patterns) groups queries: the first query
      # of each group is then always one whose caller was captured, values inlined in the SQL
      # (MySQL) included.
      def statement_key(sql)
        sql.to_s
           .gsub(/\$\d+/, "?")
           .gsub(/\b\d+\b/, "?")
           .gsub(/'[^']*'/, "?")
           .gsub(/"[^"]*"/, "?")
           .strip
      end

      # The code that ran the query: the frames Rails.backtrace_cleaner keeps, as the exception
      # tab shows them, or without Rails, the frames outside gems and Ruby itself. Whatever stands
      # in between (the profiler, Active Support, Active Record, the driver, other gems) is left
      # out, so that the first frames are the application's.
      def extract_backtrace
        cleaner = rails_backtrace_cleaner
        cleaned = []
        plain = []
        scanned = 0
        last_kept = nil
        while scanned < MAX_SCANNED_FRAMES && cleaned.size < BACKTRACE_DEPTH
          chunk = caller_locations(1 + scanned, 25)
          break if chunk.nil? || chunk.empty?

          chunk.each do |loc|
            scanned += 1
            path = loc.path.to_s
            next if INTERNAL_FRAMES.any? { |internal| path.include?(internal) }
            # Gems and Ruby are never the application's code, and Rails' cleaner silences them
            # too: a string test spares it most frames.
            next if library_frame?(path)

            line = "#{path}:#{loc.lineno}:in `#{loc.label}`"
            if cleaner && (kept = clean_frame(cleaner, line))
              cleaned << kept
              last_kept = scanned
            end
            plain << line if plain.size < BACKTRACE_DEPTH
            break if cleaned.size == BACKTRACE_DEPTH
          end
          # Without Rails, the first frames outside gems are enough; with it, the application's
          # frames come together: a few frames past the last one kept, the rest is the framework.
          break if cleaner.nil? && plain.size >= BACKTRACE_DEPTH
          break if last_kept && scanned - last_kept > FRAMES_PAST_APPLICATION
        end

        frames = cleaned.empty? ? plain : cleaned
        frames.empty? ? fallback_backtrace : frames
      end

      def rails_backtrace_cleaner
        Rails.backtrace_cleaner if defined?(Rails) && Rails.respond_to?(:backtrace_cleaner)
      rescue StandardError
        nil
      end

      # The frame as the cleaner shows it, or nil when it silences it.
      def clean_frame(cleaner, line)
        cleaner.respond_to?(:clean_frame) ? cleaner.clean_frame(line) : cleaner.clean([line]).first
      rescue StandardError
        nil
      end

      def fallback_backtrace
        (caller_locations(1, BACKTRACE_DEPTH + 20) || []).filter_map do |loc|
          path = loc.path.to_s
          "#{path}:#{loc.lineno}:in `#{loc.label}`" unless INTERNAL_FRAMES.any? { |internal| path.include?(internal) }
        end.first(BACKTRACE_DEPTH)
      end

      # Ruby itself and the directories gems are installed in; an application that lives under a
      # directory called gems is not one.
      def library_frame?(path)
        path.start_with?("<internal:") || library_prefixes.any? { |dir| path.start_with?(dir) }
      end

      def library_prefixes
        @library_prefixes ||= begin
          dirs = [RbConfig::CONFIG["rubylibdir"], RbConfig::CONFIG["rubyarchdir"], RbConfig::CONFIG["bindir"]]
          dirs.concat(Gem.path) if defined?(Gem)
          dirs << bundle_path
          dirs.compact.reject(&:empty?).map { |dir| File.join(File.expand_path(dir), "") }.uniq.freeze
        end
      end

      # Bundler raises without a Gemfile.
      def bundle_path
        Bundler.bundle_path.to_s if defined?(Bundler) && Bundler.respond_to?(:bundle_path)
      rescue StandardError
        nil
      end
    end
  end
end
