# frozen_string_literal: true

require "mcp"

require_relative "../slave_support"
require_relative "../../replay"

module Profiler
  module MCP
    module Tools
      # Sends a profiled request again, for real, to the application's own host (see
      # Profiler::Replay). A real side-effecting action, like run_tests: the MCP channel has no
      # interactive confirmation, so the client that calls the tool answers for the request it
      # replays, POST, DELETE and the other methods with side effects included. The dashboard asks
      # the user to confirm; the server adds no further guard for this channel.
      class ReplayRequest
        # The only arguments read: anything else is refused by Profiler::Replay, and the ones that
        # name a host, port or URL are refused by name.
        def self.call(params)
          token = params["token"]
          return error_response("token parameter is required") unless token

          options = params.except("token", "slave")
          if (proxy = MCP::SlaveSupport.with_slave_proxy(params))
            return run_on_slave(proxy, params["slave"], token, options)
          end

          result = Profiler::Replay.call(token, options)
          [{ type: "text", text: format_result(result) }]
        rescue Profiler::Replay::Error => e
          error_response(e.message)
        end

        def self.run_on_slave(proxy, slave, token, options)
          data = proxy.post_json("/_profiler/api/profiles/#{token}/replay", options)
          return error_response("Error replaying on slave '#{slave}': #{data["error"]}") if data["error"]

          result = Profiler::Replay::Result.new(source_token: data["source_token"], target: data["target"],
                                                replays: Array(data["replays"]).map { |r| r.transform_keys(&:to_sym) },
                                                notes: Array(data["notes"]))
          [{ type: "text", text: format_result(result) }]
        end

        def self.format_result(result)
          lines = ["# Replay of `#{result.source_token}`", "", "Sent to #{result.target} (the host of the original request).", ""]
          lines << "| # | Status | New profile | Duration |"
          lines << "|---|--------|-------------|----------|"
          result.replays.each do |replay|
            if replay[:error]
              lines << "| #{replay[:index]} | **error** | #{replay[:error]} | |"
            else
              profile = replay[:token] ? "`#{replay[:token]}`" : "(not profiled)"
              lines << "| #{replay[:index]} | #{replay[:status]} | #{profile} | #{replay[:duration_ms]}ms |"
            end
          end
          result.notes.each { |note| lines << "" << "Note: #{note}" }
          lines.join("\n")
        end

        def self.error_response(message)
          ::MCP::Tool::Response.new([{ type: "text", text: "Error: #{message}" }], error: true)
        end
      end
    end
  end
end
