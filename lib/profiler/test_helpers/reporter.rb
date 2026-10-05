# frozen_string_literal: true

module Profiler
  module TestHelpers
    module Reporter
      WIDTH = 68

      def self.print
        return unless Profiler.enabled?

        profiles = Profiler.storage.list(limit: 1000, type: "test").select { |p| p.profile_type == "test" }
        return if profiles.empty?

        passed  = profiles.count { |p| test_status(p) == "passed" }
        failed  = profiles.count { |p| test_status(p) == "failed" }
        pending = profiles.count { |p| test_status(p) == "pending" }

        total_queries = profiles.sum { |p| (p.collector_data("database") || {})["total_queries"].to_i }
        n1_profiles   = profiles.select { |p| has_n1?(p) }
        total_ms      = profiles.sum(&:duration).round(0).to_i

        lines = []
        lines << ""
        lines << cyan("┌─ Profiler Test Report " + "─" * (WIDTH - 23) + "┐")
        lines << cyan("│") + " #{profiles.size} tests · #{passed} passed · #{failed} failed · #{pending} pending" +
                 pad_to(WIDTH - 1, "#{profiles.size} tests · #{passed} passed · #{failed} failed · #{pending} pending") +
                 cyan("│")
        lines << cyan("│") + " Total: #{total_ms}ms · #{total_queries} queries · #{n1_profiles.size} N+1 detected" +
                 pad_to(WIDTH - 1, "Total: #{total_ms}ms · #{total_queries} queries · #{n1_profiles.size} N+1 detected") +
                 cyan("│")

        # Slowest tests
        slowest = profiles.sort_by { |p| -p.duration }.first(5)
        lines << cyan("├─ Slowest tests " + "─" * (WIDTH - 17) + "┤")
        slowest.each_with_index do |p, i|
          test_data = p.collector_data("test") || {}
          db_data   = p.collector_data("database") || {}
          name      = truncate(test_data["test_name"] || p.path, 44)
          queries   = db_data["total_queries"].to_i
          n1_flag   = has_n1?(p) ? " #{red("⚠ N+1")}" : ""
          stats_raw = "#{p.duration.round(0).to_i}ms  #{queries}q"
          pad       = [0, WIDTH - 6 - name.length - stats_raw.length].max
          lines << cyan("│") + "  #{i + 1}. #{name}#{" " * pad}#{stats_raw}#{n1_flag}"
        end

        # N+1 patterns
        if n1_profiles.any?
          lines << cyan("├─ N+1 patterns " + "─" * (WIDTH - 16) + "┤")
          n1_profiles.first(3).each do |p|
            test_data = p.collector_data("test") || {}
            db_data   = p.collector_data("database") || {}
            queries   = db_data["queries"] || []
            pattern   = top_n1_pattern(queries)
            name      = truncate(test_data["test_name"] || p.path, WIDTH - 4)
            lines << cyan("│") + "  #{yellow("▸")} #{yellow(truncate(pattern.to_s, WIDTH - 6))}"
            lines << cyan("│") + "    → #{name}"
          end
        end

        # Failed tests
        failed_profiles = profiles.select { |p| test_status(p) == "failed" }
        if failed_profiles.any?
          lines << cyan("├─ Failed tests " + "─" * (WIDTH - 15) + "┤")
          failed_profiles.first(5).each do |p|
            test_data = p.collector_data("test") || {}
            name      = test_data["test_name"] || p.path
            exception = test_data["exception_message"]
            lines << cyan("│") + "  #{red("✗")} #{truncate(name, WIDTH - 5)}"
            lines << cyan("│") + "    #{truncate(exception.to_s, WIDTH - 6)}" if exception
          end
        end

        lines << cyan("└" + "─" * WIDTH + "┘")
        lines << ""

        $stdout.puts lines.join("\n")
      rescue => e
        Profiler.log_error("Reporter: could not generate the report", e)
      end

      def self.has_n1?(profile)
        db_data = profile.collector_data("database") || {}
        queries = db_data["queries"] || []
        return false if queries.size < 3

        queries.group_by { |q| normalize_sql(q["sql"].to_s) }.any? { |_, qs| qs.size >= 3 }
      end

      def self.test_status(profile)
        (profile.collector_data("test") || {})["status"] || "passed"
      end

      def self.top_n1_pattern(queries)
        return "" if queries.size < 3

        queries.group_by { |q| normalize_sql(q["sql"].to_s) }
               .select { |_, qs| qs.size >= 3 }
               .max_by { |_, qs| qs.size }
               &.first || ""
      end

      def self.normalize_sql(sql)
        sql.gsub(/\$\d+/, "?").gsub(/\b\d+\b/, "?").gsub(/'[^']*'/, "?").gsub(/"[^"]*"/, "?").strip
      end

      def self.truncate(str, max)
        str = str.to_s
        str.length > max ? str[0, max - 3] + "..." : str
      end

      def self.pad_to(width, str)
        visible = str.gsub(/\e\[[0-9;]*m/, "")
        " " * [0, width - visible.length - 1].max
      end

      def self.cyan(str)    = "\e[36m#{str}\e[0m"
      def self.yellow(str)  = "\e[33m#{str}\e[0m"
      def self.red(str)     = "\e[31m#{str}\e[0m"
    end
  end
end
