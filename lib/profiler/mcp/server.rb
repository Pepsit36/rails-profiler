# frozen_string_literal: true

require "mcp"
require_relative "http_guard"

module Profiler
  module MCP
    class Server
      class << self
        def instance
          @instance ||= new
        end

        def rack_app
          # Memoized at class level — survives route reloads in development
          @rack_app ||= lambda do |env|
            HttpGuard.call(env) || instance.http_transport.handle_request(Rack::Request.new(env))
          end
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

          begin
            result = handler.call
            [{ uri: result[:uri], mimeType: result[:mimeType], text: result[:text] }]
          rescue Profiler::Storage::Unavailable::Error => e
            [{ uri: uri, mimeType: "text/plain", text: e.message }]
          end
        end
      end

      def http_transport
        @http_transport ||= begin
          t = ::MCP::Server::Transports::StreamableHTTPTransport.new(@server, **http_transport_options)
          @server.transport = t
          t
        end
      end

      # HttpGuard checks the Host and Origin headers of every request before the transport sees
      # it, with config.hosts, config.mcp_allowed_hosts and Regexp entries, which the transport's
      # own check (exact names only) cannot express. Older mcp versions have no such check, nor
      # the option.
      def http_transport_options
        params = ::MCP::Server::Transports::StreamableHTTPTransport.instance_method(:initialize).parameters
        params.any? { |_type, name| name == :dns_rebinding_protection } ? { dns_rebinding_protection: false } : {}
      end

      def start(transport: :stdio)
        case transport
        when :stdio
          ::MCP::Server::Transports::StdioTransport.new(@server).open
        when :http
          Profiler.log_info("MCP: HTTP transport active, endpoint /_profiler/mcp")
        else
          raise Error, "Unknown transport: #{transport}"
        end
      end

      private

      def build_tools
        require_relative "slave_support"
        require_relative "file_cache"
        require_relative "path_extractor"
        require_relative "body_formatter"
        require_relative "tools/query_profiles"
        require_relative "tools/get_profile_detail"
        require_relative "tools/analyze_queries"
        require_relative "tools/explain_query"
        require_relative "tools/get_profile_ajax"
        require_relative "tools/get_profile_dumps"
        require_relative "tools/get_profile_http"
        require_relative "tools/get_profile_mailers"
        require_relative "tools/query_jobs"
        require_relative "tools/query_mailers"
        require_relative "tools/query_test_profiles"
        require_relative "tools/get_test_profile_detail"
        require_relative "tools/run_tests"
        require_relative "tools/query_console_profiles"
        require_relative "tools/clear_profiles"
        require_relative "tools/list_env_vars"
        require_relative "tools/set_env_var"
        require_relative "tools/delete_env_var"
        require_relative "tools/reset_env_var"
        require_relative "tools/reset_all_env_vars"
        require_relative "tools/list_slaves"

        slave_param = { type: "string", description: "Name of a connected slave profiler to target. Omit to use this profiler's own data." }

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
                limit: { type: "number", description: "Maximum number of results (default 20)" },
                fields: { type: "array", items: { type: "string" }, description: "Columns to include. Valid values: time, type, method, path, duration, queries, status, token. Omit for all." },
                cursor: { type: "string", description: "Pagination cursor: ISO8601 timestamp of the last item seen. Returns profiles older than this." },
                slave: slave_param
              }
            },
            handler: Tools::QueryProfiles
          ),
          define_tool(
            name: "get_profile",
            description: "Get detailed profile data by token. Use 'latest' as token to get the most recent profile.",
            input_schema: {
              properties: {
                token: { type: "string", description: "Profile token, or 'latest' for the most recent profile (required)" },
                sections: { type: "array", items: { type: "string" }, description: "Sections to include. Valid values: overview, exception, job, console, request, response, curl, database, performance, views, cache, ajax, http, mailers, routes, dumps, logs, env, i18n, related_jobs. Omit for all." },
                save_bodies: { type: "boolean", description: "Save request/response bodies to temp files and return paths instead of inlining content." },
                max_body_size: { type: "number", description: "Truncate inlined body content at N characters. Ignored when save_bodies is true." },
                json_path: { type: "string", description: "JSONPath expression to extract from response body (e.g. '$.data.items[0]'). Only applied when save_bodies is true." },
                xml_path: { type: "string", description: "XPath expression to extract from response body (e.g. '//items/item[1]/name'). Only applied when save_bodies is true." },
                log_min_level: { type: "string", description: "Minimum log level to include in the logs section: DEBUG, INFO, WARN, ERROR, FATAL. Only applied when 'logs' section is requested." },
                env_filter: { type: "string", description: "Required when requesting the env section. Case-insensitive substring filter on ENV key name (e.g. 'RAILS', 'DATABASE')." },
                slave: slave_param
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
                token: { type: "string", description: "Profile token, or 'latest' for the most recent profile (required)" },
                summary_only: { type: "boolean", description: "Return only the summary statistics section, skipping slow query and N+1 details." },
                slave: slave_param
              },
              required: ["token"]
            },
            handler: Tools::AnalyzeQueries
          ),
          define_tool(
            name: "explain_query",
            description: "Run EXPLAIN ANALYZE on a specific query from a profile. Returns the query execution plan with cost and row estimates. Only read-only statements (SELECT, WITH ... SELECT, TABLE, VALUES) are explained, in a transaction always rolled back; other queries return an error. Only available in development/test environments.",
            input_schema: {
              properties: {
                token: { type: "string", description: "Profile token, or 'latest' for the most recent profile (required)" },
                query_index: { type: "integer", description: "Zero-based index of the query within the profile's database queries list (required)" },
                slave: slave_param
              },
              required: ["token", "query_index"]
            },
            handler: Tools::ExplainQuery
          ),
          define_tool(
            name: "get_profile_ajax",
            description: "Get detailed AJAX sub-request breakdown for a profile. Use 'latest' as token to get the most recent profile.",
            input_schema: {
              properties: {
                token: { type: "string", description: "Profile token, or 'latest' for the most recent profile (required)" },
                slave: slave_param
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
                token: { type: "string", description: "Profile token, or 'latest' for the most recent profile (required)" },
                slave: slave_param
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
                domain: { type: "string", description: "Filter outbound requests by domain (partial match on host)" },
                save_bodies: { type: "boolean", description: "Save request/response bodies to temp files and return paths instead of inlining content." },
                max_body_size: { type: "number", description: "Truncate inlined body content at N characters. Ignored when save_bodies is true." },
                json_path: { type: "string", description: "JSONPath expression to extract from response bodies (e.g. '$.data.items[0]'). Only applied when save_bodies is true." },
                xml_path: { type: "string", description: "XPath expression to extract from response bodies (e.g. '//items/item[1]/name'). Only applied when save_bodies is true." },
                slave: slave_param
              },
              required: ["token"]
            },
            handler: Tools::GetProfileHttp
          ),
          define_tool(
            name: "get_profile_mailers",
            description: "Get detailed mailer activity for a profile: delivered emails, errors, and queued deliveries — including email bodies when capture_mail_body is enabled.",
            input_schema: {
              properties: {
                token: { type: "string", description: "Profile token, or 'latest' for the most recent profile (required)" },
                mailer_class: { type: "string", description: "Filter by mailer class name (partial match, e.g. 'UserMailer')" },
                action: { type: "string", description: "Filter by mailer action (partial match, e.g. 'welcome_email')" },
                delivery_mode: { type: "string", description: "Filter by delivery mode: 'deliver_now', 'deliver_later', or 'queued'" },
                save_bodies: { type: "boolean", description: "Save email bodies to temp files and return paths instead of inlining content." },
                max_body_size: { type: "number", description: "Truncate inlined body content at N characters." },
                slave: slave_param
              },
              required: ["token"]
            },
            handler: Tools::GetProfileMailers
          ),
          define_tool(
            name: "query_jobs",
            description: "Search and filter background job profiles by queue, status, etc.",
            input_schema: {
              properties: {
                queue: { type: "string", description: "Filter by queue name" },
                status: { type: "string", description: "Filter by status (completed, failed)" },
                limit: { type: "number", description: "Maximum number of results (default 20)" },
                fields: { type: "array", items: { type: "string" }, description: "Columns to include. Valid values: time, job_class, queue, status, duration, token. Omit for all." },
                cursor: { type: "string", description: "Pagination cursor: ISO8601 timestamp of the last item seen. Returns jobs older than this." },
                slave: slave_param
              }
            },
            handler: Tools::QueryJobs
          ),
          define_tool(
            name: "query_mailers",
            description: "Search and filter ActionMailer deliveries across profiles. Returns emails sent via deliver_now or deliver_later.",
            input_schema: {
              properties: {
                mailer_class: { type: "string", description: "Filter by mailer class name (partial match, e.g. 'UserMailer')" },
                action: { type: "string", description: "Filter by mailer action name (partial match, e.g. 'welcome_email')" },
                delivery_mode: { type: "string", description: "Filter by delivery mode: 'deliver_now' or 'deliver_later'" },
                has_error: { type: "boolean", description: "Filter to only emails with delivery errors" },
                limit: { type: "number", description: "Maximum number of results (default 20)" },
                fields: { type: "array", items: { type: "string" }, description: "Columns to include. Valid values: time, profile, mailer, action, subject, to, mode, duration, status, token. Omit for all." },
                cursor: { type: "string", description: "Pagination cursor: ISO8601 timestamp of the last item seen." },
                slave: slave_param
              }
            },
            handler: Tools::QueryMailers
          ),
          define_tool(
            name: "query_test_profiles",
            description: "Search and filter test profiles (RSpec/Minitest) by test name, status, or duration.",
            input_schema: {
              properties: {
                test_name: { type: "string", description: "Filter by test name (partial match)" },
                status: { type: "string", description: "Filter by status: 'passed', 'failed', or 'pending'" },
                min_duration: { type: "number", description: "Minimum duration in milliseconds" },
                limit: { type: "number", description: "Maximum number of results (default 20)" },
                fields: { type: "array", items: { type: "string" }, description: "Columns to include. Valid values: time, test_name, status, duration, queries, n1, token. Omit for all." },
                cursor: { type: "string", description: "Pagination cursor: ISO8601 timestamp of the last item seen." },
                slave: slave_param
              }
            },
            handler: Tools::QueryTestProfiles
          ),
          define_tool(
            name: "get_test_profile",
            description: "Get detailed data for a test profile: metadata, SQL queries, N+1 patterns, cache, exception. Use 'latest' as token for the most recent test.",
            input_schema: {
              properties: {
                token: { type: "string", description: "Test profile token, or 'latest' for the most recent test profile (required)" },
                slave: slave_param
              },
              required: ["token"]
            },
            handler: Tools::GetTestProfileDetail
          ),
          define_tool(
            name: "run_tests",
            description: "Run test files and wait for results. Returns output, status, duration, and tokens of test profiles created. Synchronous with configurable timeout (default 120s).",
            input_schema: {
              properties: {
                files: {
                  type: "array",
                  items: { type: "string" },
                  description: "Relative paths of test files to run (e.g. ['spec/models/user_spec.rb']). Omit to run all discovered tests."
                },
                framework: {
                  type: "string",
                  description: "Test framework: 'rspec' or 'minitest'. Auto-detected if omitted."
                },
                timeout_seconds: {
                  type: "number",
                  description: "Maximum seconds to wait for tests to finish (default: 120)."
                },
                max_output: {
                  type: "number",
                  description: "Maximum characters of output to return (tail). Default: 4000."
                },
                slave: slave_param
              }
            },
            handler: Tools::RunTests
          ),
          define_tool(
            name: "query_console_profiles",
            description: "Search and filter Rails console profiling sessions (IRB/rails console executions).",
            input_schema: {
              properties: {
                expression: { type: "string", description: "Filter by expression content (partial match, e.g. 'User.find')" },
                status: { type: "string", description: "Filter by status: 'completed' or 'failed'" },
                min_duration: { type: "number", description: "Minimum duration in milliseconds" },
                limit: { type: "number", description: "Maximum number of results (default 20)" },
                fields: { type: "array", items: { type: "string" }, description: "Columns to include. Valid values: time, expression, return_value, status, duration, queries, token. Omit for all." },
                cursor: { type: "string", description: "Pagination cursor: ISO8601 timestamp of the last item seen. Returns profiles older than this." },
                slave: slave_param
              }
            },
            handler: Tools::QueryConsoleProfiles
          ),
          define_tool(
            name: "clear_profiles",
            description: "Clear profiler history. Omit type to clear everything, or pass 'http', 'job', 'test', or 'console' to clear only that type.",
            input_schema: {
              properties: {
                type: { type: "string", description: "Optional: 'http' to clear only requests, 'job' to clear only jobs, 'test' to clear only test profiles, 'console' to clear only console sessions" },
                slave: slave_param
              }
            },
            handler: Tools::ClearProfiles
          ),
          define_tool(
            name: "list_env_vars",
            description: "List environment variables. By default shows only active overrides. Pass include_all: true to see all ENV vars.",
            input_schema: {
              properties: {
                include_all: { type: "boolean", description: "If true, return all ENV variables (not just overrides). Default: false." },
                filter: { type: "string", description: "Case-insensitive substring filter on key name." },
                slave: slave_param
              }
            },
            handler: Tools::ListEnvVars
          ),
          define_tool(
            name: "set_env_var",
            description: "Set an environment variable and persist the override across app restarts.",
            input_schema: {
              properties: {
                key:   { type: "string", description: "Environment variable name (required)" },
                value: { type: "string", description: "New value (required)" },
                slave: slave_param
              },
              required: ["key", "value"]
            },
            handler: Tools::SetEnvVar
          ),
          define_tool(
            name: "delete_env_var",
            description: "Delete an environment variable for this session (persisted across restarts until reset).",
            input_schema: {
              properties: {
                key: { type: "string", description: "Environment variable name (required)" },
                slave: slave_param
              },
              required: ["key"]
            },
            handler: Tools::DeleteEnvVar
          ),
          define_tool(
            name: "reset_env_var",
            description: "Restore an overridden environment variable to its original value.",
            input_schema: {
              properties: {
                key: { type: "string", description: "Environment variable name to restore (required)" },
                slave: slave_param
              },
              required: ["key"]
            },
            handler: Tools::ResetEnvVar
          ),
          define_tool(
            name: "reset_all_env_vars",
            description: "Restore all overridden environment variables to their original values.",
            input_schema: { properties: { slave: slave_param } },
            handler: Tools::ResetAllEnvVars
          ),
          define_tool(
            name: "list_slaves",
            description: "List all slave profilers connected to this master profiler, with their connection status.",
            input_schema: { properties: {} },
            handler: Tools::ListSlaves
          )
        ]
      end

      def define_tool(name:, description:, input_schema:, handler:)
        ::MCP::Tool.define(name: name, description: description, input_schema: input_schema) do |server_context: nil, **args|
          result = handler.call(args.transform_keys(&:to_s))
          result.is_a?(::MCP::Tool::Response) ? result : ::MCP::Tool::Response.new(result)
        rescue Profiler::Storage::Unavailable::Error => e
          ::MCP::Tool::Response.new([{ type: "text", text: e.message }], error: true)
        end
      end

      def build_resources
        require_relative "resources/recent_requests"
        require_relative "resources/slow_queries"
        require_relative "resources/n1_patterns"
        require_relative "resources/recent_jobs"
        require_relative "resources/slow_tests"
        require_relative "resources/failing_tests"
        require_relative "resources/recent_console"

        handlers = {
          "profiler://recent"          => Resources::RecentRequests,
          "profiler://slow-queries"    => Resources::SlowQueries,
          "profiler://n1-patterns"     => Resources::N1Patterns,
          "profiler://recent-jobs"     => Resources::RecentJobs,
          "profiler://slow-tests"      => Resources::SlowTests,
          "profiler://failing-tests"   => Resources::FailingTests,
          "profiler://recent-console"  => Resources::RecentConsole
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
          ),
          ::MCP::Resource.new(
            uri: "profiler://slow-tests",
            name: "Slow Tests",
            description: "Top 10 slowest test profiles with query counts and N+1 detection",
            mime_type: "application/json"
          ),
          ::MCP::Resource.new(
            uri: "profiler://failing-tests",
            name: "Failing Tests",
            description: "Recent test profiles with status 'failed', including exception messages",
            mime_type: "application/json"
          ),
          ::MCP::Resource.new(
            uri: "profiler://recent-console",
            name: "Recent Console Sessions",
            description: "List of recently profiled Rails console (IRB) executions",
            mime_type: "application/json"
          )
        ]

        [resources, handlers]
      end
    end
  end
end
