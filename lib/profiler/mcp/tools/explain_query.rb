# frozen_string_literal: true

require_relative "../slave_support"

require "profiler/explain_runner"

module Profiler
  module MCP
    module Tools
      class ExplainQuery
        def self.call(params)
          token       = params["token"]
          query_index = params["query_index"]

          unless token
            return ::MCP::Tool::Response.new(
              [{ type: "text", text: "Error: token parameter is required" }],
              error: true
            )
          end

          if query_index.nil?
            return ::MCP::Tool::Response.new(
              [{ type: "text", text: "Error: query_index parameter is required" }],
              error: true
            )
          end

          if (proxy = MCP::SlaveSupport.with_slave_proxy(params))
            result = proxy.post_json("/_profiler/api/explain", { token: token, query_index: query_index.to_i })
            if result["error"]
              return ::MCP::Tool::Response.new(
                [{ type: "text", text: "Error: #{result["error"]}" }],
                error: true
              )
            end
            return [{ type: "text", text: result.inspect }]
          end

          storage = MCP::SlaveSupport.resolve_storage(params)
          resolved_token = if token == "latest"
            latest = storage.list(limit: 1).first
            latest ? latest.token : token
          else
            token
          end

          if (reason = Profiler::ExplainRunner.refusal)
            return ::MCP::Tool::Response.new(
              [{ type: "text", text: "Error: #{reason}" }],
              error: true
            )
          end

          data = Profiler::ExplainRunner.run(resolved_token, query_index.to_i)

          lines = []
          lines << "# EXPLAIN ANALYZE - Query ##{query_index}"
          lines << "Adapter: `#{data[:adapter]}`\n"

          if data[:format] == "json"
            lines << "```json"
            lines << JSON.pretty_generate(data[:result])
            lines << "```"
          else
            lines << "```"
            lines << data[:result].to_s
            lines << "```"
          end

          [{ type: "text", text: lines.join("\n") }]
        rescue Profiler::ExplainRunner::RefusedError => e
          ::MCP::Tool::Response.new(
            [{ type: "text", text: "Error: #{e.message}" }],
            error: true
          )
        rescue Profiler::Error => e
          # The profiler's own refusals (unknown, offline or refused slave) carry a message made for the caller.
          ::MCP::Tool::Response.new(
            [{ type: "text", text: "Error: #{e.message}" }],
            error: true
          )
        rescue StandardError => e
          # The database's message carries the SQL, and sometimes a path: the log only.
          Profiler.log_error("MCP explain_query: failed for query #{query_index.to_i} of profile #{token.to_s.inspect}", e)
          [{ type: "text", text: "EXPLAIN failed (the application log has the details)" }]
        end
      end
    end
  end
end
