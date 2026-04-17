# frozen_string_literal: true

module Profiler
  module TestHelpers
    module Reporter
      def self.print
        return unless Profiler.enabled?

        profiles = Profiler.storage.list(limit: 1000).select { |p| p.profile_type == "test" }
        return if profiles.empty?

        total_queries = profiles.sum do |p|
          (p.collector_data("database") || {})["total_queries"].to_i
        end

        # Count profiles with N+1 patterns
        n1_profiles = profiles.select { |p| has_n1?(p) }

        lines = []
        lines << ""
        lines << "\e[36m┌─ Profiler Test Report " + "─" * 44 + "┐\e[0m"
        lines << "\e[36m│\e[0m #{profiles.size} tests · #{total_queries} queries · #{n1_profiles.size} N+1 detected" +
                 " " * [0, 51 - "#{profiles.size} tests · #{total_queries} queries · #{n1_profiles.size} N+1 detected".length].max +
                 "\e[36m│\e[0m"
        lines << "\e[36m├─ Slowest tests " + "─" * 50 + "┤\e[0m"

        slowest = profiles.sort_by { |p| -p.duration }.first(5)
        slowest.each_with_index do |p, i|
          test_data = p.collector_data("test") || {}
          db_data   = p.collector_data("database") || {}
          n1 = has_n1?(p)
          queries = db_data["total_queries"].to_i
          name = (test_data["test_name"] || p.path).to_s
          name = name.length > 42 ? name[0, 39] + "..." : name
          n1_flag = n1 ? " \e[31m⚠ N+1\e[0m" : ""
          line = "\e[36m│\e[0m  #{i + 1}. #{name}"
          stats = "#{p.duration.round(0).to_i}ms  #{queries}q#{n1_flag}"
          pad = [0, 65 - name.length - stats.gsub(/\e\[[0-9;]*m/, "").length].max
          lines << "#{line}#{" " * pad}#{stats}"
        end

        if n1_profiles.any?
          lines << "\e[36m├─ N+1 patterns " + "─" * 50 + "┤\e[0m"
          n1_profiles.first(3).each do |p|
            test_data = p.collector_data("test") || {}
            name = (test_data["test_name"] || p.path).to_s
            name = name.length > 60 ? name[0, 57] + "..." : name
            lines << "\e[36m│\e[0m  \e[33m#{name}\e[0m"
          end
        end

        lines << "\e[36m└" + "─" * 66 + "┘\e[0m"
        lines << ""

        $stdout.puts lines.join("\n")
      rescue => e
        warn "Profiler Reporter: failed to generate report: #{e.message}"
      end

      def self.has_n1?(profile)
        db_data = profile.collector_data("database") || {}
        queries = db_data["queries"] || []
        return false if queries.size < 3

        normalized = queries.group_by { |q| normalize_sql(q["sql"].to_s) }
        normalized.any? { |_, qs| qs.size >= 3 }
      end

      def self.normalize_sql(sql)
        sql.gsub(/\$\d+/, "?")
           .gsub(/\b\d+\b/, "?")
           .gsub(/'[^']*'/, "?")
           .gsub(/"[^"]*"/, "?")
           .strip
      end
    end
  end
end
