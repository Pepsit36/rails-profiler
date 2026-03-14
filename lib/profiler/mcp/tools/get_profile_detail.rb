# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class GetProfileDetail
        def self.call(params)
          token = params["token"]
          unless token
            return [
              {
                type: "text",
                text: "Error: token parameter is required"
              }
            ]
          end

          profile = Profiler.storage.load(token)
          unless profile
            return [
              {
                type: "text",
                text: "Profile not found: #{token}"
              }
            ]
          end

          text = format_profile_detail(profile)

          [
            {
              type: "text",
              text: text
            }
          ]
        end

        private

        def self.format_profile_detail(profile)
          lines = []
          lines << "# Profile Details: #{profile.token}\n"
          lines << "**Request:** #{profile.method} #{profile.path}"
          lines << "**Status:** #{profile.status}"
          lines << "**Duration:** #{profile.duration.round(2)} ms"
          lines << "**Memory:** #{(profile.memory / 1024.0 / 1024.0).round(2)} MB" if profile.memory
          lines << "**Time:** #{profile.started_at}\n"

          # Database section
          db_data = profile.collector_data("database")
          if db_data && db_data["total_queries"]
            lines << "## Database"
            lines << "- Total Queries: #{db_data['total_queries']}"
            lines << "- Total Duration: #{db_data['total_duration'].round(2)} ms"
            lines << "- Slow Queries: #{db_data['slow_queries']}"
            lines << "- Cached Queries: #{db_data['cached_queries']}\n"

            if db_data["queries"] && !db_data["queries"].empty?
              lines << "### Query Details"
              db_data["queries"].first(10).each_with_index do |query, index|
                lines << "\n**Query #{index + 1}** (#{query['duration'].round(2)}ms):"
                lines << "```sql"
                lines << query['sql']
                lines << "```"
              end

              if db_data["queries"].size > 10
                lines << "\n_... and #{db_data['queries'].size - 10} more queries_"
              end
            end
            lines << ""
          end

          # Performance section
          perf_data = profile.collector_data("performance")
          if perf_data && perf_data["total_events"]
            lines << "## Performance Timeline"
            lines << "- Total Events: #{perf_data['total_events']}"
            lines << "- Total Duration: #{perf_data['total_duration'].round(2)} ms\n"

            if perf_data["events"] && !perf_data["events"].empty?
              lines << "### Events"
              perf_data["events"].first(10).each do |event|
                lines << "- **#{event['name']}**: #{event['duration'].round(2)} ms"
              end

              if perf_data["events"].size > 10
                lines << "\n_... and #{perf_data['events'].size - 10} more events_"
              end
            end
            lines << ""
          end

          # Views section
          view_data = profile.collector_data("view")
          if view_data && (view_data["total_views"] || view_data["total_partials"])
            lines << "## View Rendering"
            lines << "- Templates: #{view_data['total_views']}"
            lines << "- Partials: #{view_data['total_partials']}"
            lines << "- Total Duration: #{view_data['total_duration'].round(2)} ms\n"
          end

          # Cache section
          cache_data = profile.collector_data("cache")
          if cache_data && cache_data["total_reads"]
            lines << "## Cache"
            lines << "- Reads: #{cache_data['total_reads']}"
            lines << "- Writes: #{cache_data['total_writes']}"
            lines << "- Deletes: #{cache_data['total_deletes']}"
            lines << "- Hit Rate: #{cache_data['hit_rate']}%\n"
          end

          lines.join("\n")
        end
      end
    end
  end
end
