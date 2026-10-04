# frozen_string_literal: true

require "mcp"

require_relative "../slave_support"

require_relative "../../test_runner/discovery"
require_relative "../../test_runner/run_store"
require_relative "../../test_runner/runner"

module Profiler
  module MCP
    module Tools
      class RunTests
        DEFAULT_TIMEOUT    = 120
        DEFAULT_MAX_OUTPUT = 4000
        POLL_TIMEOUT       = 10 # seconds per wait_for_output call

        def self.call(params)
          if (proxy = MCP::SlaveSupport.with_slave_proxy(params))
            return run_on_slave(proxy, params)
          end

          files          = Array(params["files"])
          framework      = params["framework"]&.to_s
          timeout_secs   = (params["timeout_seconds"] || DEFAULT_TIMEOUT).to_i
          max_output     = (params["max_output"] || DEFAULT_MAX_OUTPUT).to_i

          # Auto-detect framework if not provided
          framework ||= begin
            available = Profiler::TestRunner::Discovery.frameworks.map(&:to_s)
            available.first || "rspec"
          end

          # If no files specified, discover all for the given framework
          if files.empty?
            tree = Profiler::TestRunner::Discovery.files(framework: framework.to_sym)
            files = tree.flat_map { |dir| dir[:files].map { |f| f[:path] } }
          end

          if files.empty?
            return [{ type: "text", text: "No test files found for framework '#{framework}'." }]
          end

          run_started_at = Time.now
          begin
            run = Profiler::TestRunner::Runner.start(files: files, framework: framework)
          rescue Profiler::TestRunner::InvalidFileError => e
            return ::MCP::Tool::Response.new([{ type: "text", text: e.message }], error: true)
          end

          output_pos = 0
          deadline   = Time.now + timeout_secs
          timed_out  = false

          until Profiler::TestRunner::RunStore::TERMINAL_STATUSES.include?(run.status)
            remaining = (deadline - Time.now).to_i
            if remaining <= 0
              timed_out = true
              break
            end

            wait = [POLL_TIMEOUT, remaining].min
            result = Profiler::TestRunner.run_store.wait_for_output(run.id, position: output_pos, timeout: wait)
            output_pos = result[:position]
            break if result[:finished]
          end

          full_output = run.output_lines.join
          tail_output = full_output.length > max_output ? "…(truncated)\n" + full_output[-(max_output)..] : full_output

          # Collect test profiles created during this run
          profile_tokens = collect_run_profiles(run_started_at)

          [{ type: "text", text: format_result(run, tail_output, timed_out, profile_tokens, files, framework) }]
        end

        private

        def self.run_on_slave(proxy, params)
          files        = Array(params["files"])
          framework    = params["framework"].to_s
          timeout_secs = (params["timeout_seconds"] || DEFAULT_TIMEOUT).to_i
          max_output   = (params["max_output"] || DEFAULT_MAX_OUTPUT).to_i

          run_data = proxy.post_json("/_profiler/api/test_runner/runs", { files: files, framework: framework.presence || "rspec" })

          if run_data["error"]
            return [{ type: "text", text: "Error starting tests on slave: #{run_data["error"]}" }]
          end

          run_id  = run_data["id"]
          deadline = Time.now + timeout_secs
          timed_out = false

          loop do
            break if Time.now > deadline && (timed_out = true)
            run_data = proxy.get_json("/_profiler/api/test_runner/runs/#{run_id}")
            break if %w[completed failed cancelled].include?(run_data["status"])
            sleep 2
          end

          output = run_data["output_lines"]&.join.to_s
          output = "…(truncated)\n" + output[-(max_output)..] if output.length > max_output

          text = "# Test Run on slave '#{params["slave"]}' #{timed_out ? "(timed out)" : ""}\n\n"
          text += "| Field | Value |\n|-------|-------|\n"
          text += "| Run ID | `#{run_id}` |\n"
          text += "| Status | **#{run_data["status"]}** |\n"
          text += "| Exit code | #{run_data["exit_code"].inspect} |\n\n"
          text += "## Output\n```\n#{output.strip}\n```"
          [{ type: "text", text: text }]
        end

        def self.collect_run_profiles(since)
          Profiler.storage.list(limit: 500).select do |p|
            p.profile_type == "test" && p.started_at && p.started_at >= since
          end.map(&:token)
        rescue
          []
        end

        def self.format_result(run, output, timed_out, profile_tokens, files, framework)
          lines = []
          lines << "# Test Run #{timed_out ? "(timed out)" : ""}\n"

          lines << "## Summary"
          lines << "| Field | Value |"
          lines << "|-------|-------|"
          lines << "| Run ID | `#{run.id}` |"
          lines << "| Framework | #{framework} |"
          lines << "| Files | #{files.size} |"
          lines << "| Status | **#{run.status}** |"
          lines << "| Exit code | #{run.exit_code.inspect} |"
          lines << "| Duration | #{run.to_h[:duration]&.round(0)}ms |"

          if timed_out
            lines << ""
            lines << "> ⚠ Timed out — run is still in progress. Use run ID `#{run.id}` to check later."
          end

          lines << "\n## Output (last #{output.length} chars)"
          lines << "```"
          lines << output.strip
          lines << "```"

          if profile_tokens.any?
            lines << "\n## Test Profiles Created (#{profile_tokens.size})"
            lines << "Use `get_test_profile` with any of these tokens for detailed SQL/cache/exception data:"
            profile_tokens.first(10).each { |t| lines << "- `#{t}`" }
            lines << "- _(#{profile_tokens.size - 10} more…)_" if profile_tokens.size > 10
          end

          lines.join("\n")
        end
      end
    end
  end
end
