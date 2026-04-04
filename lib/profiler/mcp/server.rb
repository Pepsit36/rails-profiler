# frozen_string_literal: true

require "mcp"

module Profiler
  module MCP
    class Server
      class << self
        def instance
          @instance ||= new
        end

        def rack_app
          # Memoized at class level — survives route reloads in development
          @rack_app ||= ->(env) { instance.http_transport.handle_request(Rack::Request.new(env)) }
        end
      end

      def initialize
        tools = build_tools
        resources, @resource_handlers = build_resources

        @server = ::MCP::Server.new(
          name: "rails-profiler",
          version: Profiler::VERSION,
          tools: tools,
          resources: resources
        )

        @server.resources_read_handler do |params|
          uri = params[:uri]
          handler = @resource_handlers[uri]
          next [{ uri: uri, mimeType: "application/json", text: "Resource not found: #{uri}" }] unless handler

          result = handler.call
          [{ uri: result[:uri], mimeType: result[:mimeType], text: result[:text] }]
        end
      end

      def http_transport
        @http_transport ||= begin
          t = ::MCP::Server::Transports::StreamableHTTPTransport.new(@server)
          @server.transport = t
          t
        end
      end

      def start(transport: :stdio)
        case transport
        when :stdio
          ::MCP::Server::Transports::StdioTransport.new(@server).open
        when :http
          $stderr.puts "MCP HTTP transport active — endpoint: /_profiler/mcp"
        else
          raise Error, "Unknown transport: #{transport}"
        end
      end

      private

      def build_tools
        require_relative "tools/query_profiles"
        require_relative "tools/get_profile_detail"
        require_relative "tools/analyze_queries"
        require_relative "tools/get_profile_ajax"
        require_relative "tools/get_profile_dumps"
        require_relative "tools/get_profile_http"
        require_relative "tools/query_jobs"
        require_relative "tools/clear_profiles"

        [
          define_tool(
            name: "query_profiles",
            description: "Search and filter profiled requests by path, method, duration, etc.",
            input_schema: {
              properties: {
                path: { type: "string", description: "Filter by request path (partial match)" },
                method: { type: "string", description: "Filter by HTTP method (GET, POST, etc.)" },
                min_duration: { type: "number", description: "Minimum duration in milliseconds" },
                profile_type: { type: "string", description: "Filter by type: 'http' or 'job'" },
                limit: { type: "number", description: "Maximum number of results" }
              }
            },
            handler: Tools::QueryProfiles
          ),
          define_tool(
            name: "get_profile",
            description: "Get detailed profile data by token. Use 'latest' as token to get the most recent profile.",
            input_schema: {
              properties: {
                token: { type: "string", description: "Profile token, or 'latest' for the most recent profile (required)" }
              },
              required: ["token"]
            },
            handler: Tools::GetProfileDetail
          ),
          define_tool(
            name: "analyze_queries",
            description: "Analyze SQL queries for N+1 problems, duplicates, and slow queries. Use 'latest' as token to analyze the most recent profile.",
            input_schema: {
              properties: {
                token: { type: "string", description: "Profile token, or 'latest' for the most recent profile (required)" }
              },
              required: ["token"]
            },
            handler: Tools::AnalyzeQueries
          ),
          define_tool(
            name: "get_profile_ajax",
            description: "Get detailed AJAX sub-request breakdown for a profile. Use 'latest' as token to get the most recent profile.",
            input_schema: {
              properties: {
                token: { type: "string", description: "Profile token, or 'latest' for the most recent profile (required)" }
              },
              required: ["token"]
            },
            handler: Tools::GetProfileAjax
          ),
          define_tool(
            name: "get_profile_dumps",
            description: "Get variable dumps captured during a profile. Use 'latest' as token to get the most recent profile.",
            input_schema: {
              properties: {
                token: { type: "string", description: "Profile token, or 'latest' for the most recent profile (required)" }
              },
              required: ["token"]
            },
            handler: Tools::GetProfileDumps
          ),
          define_tool(
            name: "get_profile_http",
            description: "Get outbound HTTP request breakdown for a profile (external API calls made during the request). Use 'latest' as token to get the most recent profile.",
            input_schema: {
              properties: {
                token: { type: "string", description: "Profile token, or 'latest' for the most recent profile (required)" },
                domain: { type: "string", description: "Filter outbound requests by domain (partial match on host)" }
              },
              required: ["token"]
            },
            handler: Tools::GetProfileHttp
          ),
          define_tool(
            name: "query_jobs",
            description: "Search and filter background job profiles by queue, status, etc.",
            input_schema: {
              properties: {
                queue: { type: "string", description: "Filter by queue name" },
                status: { type: "string", description: "Filter by status (completed, failed)" },
                limit: { type: "number", description: "Maximum number of results" }
              }
            },
            handler: Tools::QueryJobs
          ),
          define_tool(
            name: "clear_profiles",
            description: "Clear profiler history. Omit type to clear everything, or pass 'http'/'job' to clear only requests or jobs.",
            input_schema: {
              properties: {
                type: { type: "string", description: "Optional: 'http' to clear only requests, 'job' to clear only jobs" }
              }
            },
            handler: Tools::ClearProfiles
          )
        ]
      end

      def define_tool(name:, description:, input_schema:, handler:)
        ::MCP::Tool.define(name: name, description: description, input_schema: input_schema) do |server_context: nil, **args|
          result = handler.call(args.transform_keys(&:to_s))
          ::MCP::Tool::Response.new(result)
        end
      end

      def build_resources
        require_relative "resources/recent_requests"
        require_relative "resources/slow_queries"
        require_relative "resources/n1_patterns"
        require_relative "resources/recent_jobs"

        handlers = {
          "profiler://recent" => Resources::RecentRequests,
          "profiler://slow-queries" => Resources::SlowQueries,
          "profiler://n1-patterns" => Resources::N1Patterns,
          "profiler://recent-jobs" => Resources::RecentJobs
        }

        resources = [
          ::MCP::Resource.new(
            uri: "profiler://recent",
            name: "Recent Requests",
            description: "List of recently profiled requests",
            mime_type: "application/json"
          ),
          ::MCP::Resource.new(
            uri: "profiler://slow-queries",
            name: "Slow SQL Queries",
            description: "List of slow database queries across all profiles",
            mime_type: "application/json"
          ),
          ::MCP::Resource.new(
            uri: "profiler://n1-patterns",
            name: "N+1 Query Patterns",
            description: "Cross-profile N+1 query pattern detection across the last 100 profiles",
            mime_type: "application/json"
          ),
          ::MCP::Resource.new(
            uri: "profiler://recent-jobs",
            name: "Recent Jobs",
            description: "List of recently profiled background jobs",
            mime_type: "application/json"
          )
        ]

        [resources, handlers]
      end
    end
  end
end
