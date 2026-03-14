# frozen_string_literal: true

require "json"

module Profiler
  module MCP
    class Server
      PROTOCOL_VERSION = "2024-11-05"

      def initialize
        @tools = {}
        @resources = {}
        register_tools
        register_resources
      end

      def start(transport: :stdio)
        case transport
        when :stdio
          start_stdio
        when :http
          start_http
        else
          raise Error, "Unknown transport: #{transport}"
        end
      end

      private

      def start_stdio
        $stderr.puts "MCP Server starting (stdio transport)..."

        loop do
          line = $stdin.gets
          break unless line

          begin
            request = JSON.parse(line.strip)
            response = handle_request(request)
            puts response.to_json
            $stdout.flush
          rescue => e
            error_response = {
              jsonrpc: "2.0",
              id: request&.dig("id"),
              error: {
                code: -32603,
                message: e.message
              }
            }
            puts error_response.to_json
            $stdout.flush
          end
        end
      end

      def handle_request(request)
        method = request["method"]
        params = request["params"] || {}
        id = request["id"]

        case method
        when "initialize"
          {
            jsonrpc: "2.0",
            id: id,
            result: {
              protocolVersion: PROTOCOL_VERSION,
              capabilities: {
                tools: { listChanged: false },
                resources: { subscribe: false, listChanged: false }
              },
              serverInfo: {
                name: "rails-profiler",
                version: Profiler::VERSION
              }
            }
          }

        when "tools/list"
          {
            jsonrpc: "2.0",
            id: id,
            result: {
              tools: @tools.values.map { |tool| tool[:schema] }
            }
          }

        when "tools/call"
          tool_name = params["name"]
          tool_params = params["arguments"] || {}
          tool = @tools[tool_name]

          if tool
            result = tool[:handler].call(tool_params)
            {
              jsonrpc: "2.0",
              id: id,
              result: {
                content: result
              }
            }
          else
            {
              jsonrpc: "2.0",
              id: id,
              error: {
                code: -32601,
                message: "Tool not found: #{tool_name}"
              }
            }
          end

        when "resources/list"
          {
            jsonrpc: "2.0",
            id: id,
            result: {
              resources: @resources.values.map { |resource| resource[:schema] }
            }
          }

        when "resources/read"
          uri = params["uri"]
          resource = @resources.values.find { |r| r[:schema][:uri] == uri }

          if resource
            content = resource[:handler].call
            {
              jsonrpc: "2.0",
              id: id,
              result: {
                contents: [content]
              }
            }
          else
            {
              jsonrpc: "2.0",
              id: id,
              error: {
                code: -32601,
                message: "Resource not found: #{uri}"
              }
            }
          end

        else
          {
            jsonrpc: "2.0",
            id: id,
            error: {
              code: -32601,
              message: "Method not found: #{method}"
            }
          }
        end
      end

      def register_tools
        require_relative "tools/query_profiles"
        require_relative "tools/get_profile_detail"
        require_relative "tools/analyze_queries"

        add_tool(
          name: "query_profiles",
          description: "Search and filter profiled requests by path, method, duration, etc.",
          input_schema: {
            type: "object",
            properties: {
              path: { type: "string", description: "Filter by request path (partial match)" },
              method: { type: "string", description: "Filter by HTTP method (GET, POST, etc.)" },
              min_duration: { type: "number", description: "Minimum duration in milliseconds" },
              limit: { type: "number", description: "Maximum number of results", default: 20 }
            }
          },
          handler: Tools::QueryProfiles
        )

        add_tool(
          name: "get_profile",
          description: "Get detailed profile data by token",
          input_schema: {
            type: "object",
            properties: {
              token: { type: "string", description: "Profile token (required)" }
            },
            required: ["token"]
          },
          handler: Tools::GetProfileDetail
        )

        add_tool(
          name: "analyze_queries",
          description: "Analyze SQL queries for N+1 problems, duplicates, and slow queries",
          input_schema: {
            type: "object",
            properties: {
              token: { type: "string", description: "Profile token (required)" }
            },
            required: ["token"]
          },
          handler: Tools::AnalyzeQueries
        )
      end

      def register_resources
        require_relative "resources/recent_requests"
        require_relative "resources/slow_queries"

        add_resource(
          uri: "profiler://recent",
          name: "Recent Requests",
          description: "List of recently profiled requests",
          mime_type: "application/json",
          handler: Resources::RecentRequests
        )

        add_resource(
          uri: "profiler://slow-queries",
          name: "Slow SQL Queries",
          description: "List of slow database queries across all profiles",
          mime_type: "application/json",
          handler: Resources::SlowQueries
        )
      end

      def add_tool(name:, description:, input_schema:, handler:)
        @tools[name] = {
          schema: {
            name: name,
            description: description,
            inputSchema: input_schema
          },
          handler: handler
        }
      end

      def add_resource(uri:, name:, description:, mime_type:, handler:)
        @resources[uri] = {
          schema: {
            uri: uri,
            name: name,
            description: description,
            mimeType: mime_type
          },
          handler: handler
        }
      end
    end
  end
end
