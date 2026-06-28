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
            return [{ type: "text", text: "Error: token parameter is required" }]
          end

          if query_index.nil?
            return [{ type: "text", text: "Error: query_index parameter is required" }]
          end

          if (proxy = MCP::SlaveSupport.with_slave_proxy(params))
            result = proxy.post_json("/_profiler/api/explain", { token: token, query_index: query_index.to_i })
            text = result["error"] ? "Error: #{result["error"]}" : result.inspect
            return [{ type: "text", text: text }]
          end

          unless Profiler.configuration.enabled
            return [{ type: "text", text: "Error: EXPLAIN is only available when the profiler is enabled" }]
          end

          data = Profiler::ExplainRunner.run(token, query_index.to_i)

          lines = []
          lines << "# EXPLAIN ANALYZE — Query ##{query_index}"
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
        rescue ArgumentError => e
          [{ type: "text", text: "Error: #{e.message}" }]
        rescue => e
          [{ type: "text", text: "EXPLAIN failed: #{e.message}" }]
        end
      end
    end
  end
end
