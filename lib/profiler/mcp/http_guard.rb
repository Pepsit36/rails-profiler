# frozen_string_literal: true

require "json"
require "uri"
require_relative "../cluster/security"
require_relative "../local_request"

module Profiler
  module MCP
    # Checks a request to the MCP HTTP transport before the MCP server sees it, with the same
    # rules as the profiler's controllers: the profiler must be enabled, the request authorized,
    # and a POST must not be one that another site could forge from a browser.
    #
    # Forgery protection does not use the X-Profiler-Request header, which MCP clients do not
    # send. A POST must carry Content-Type: application/json instead: a cross-site form or
    # "simple" fetch can only send text/plain, form-urlencoded or multipart, and JSON needs a
    # CORS preflight that the profiler grants to configured origins only. A browser also sends
    # its Origin, which has to be the profiler's own or one of cors_allowed_origins. GET (the
    # SSE stream) changes nothing, and DELETE always needs a preflight.
    module HttpGuard
      JSON_MEDIA_TYPE = "application/json"

      class << self
        # Returns nil when the request may proceed, otherwise a Rack response.
        def call(env)
          config = Profiler.configuration
          return deny("Profiler is disabled") unless config.enabled

          request = ActionDispatch::Request.new(env)
          if (host_denial = host_denial(request, config))
            return deny(host_denial)
          end
          return deny("Not authorized to access the profiler") unless config.authorized?(request)
          if (origin_denial = origin_denial(request, config))
            return deny(origin_denial)
          end
          return nil unless config.api_forgery_protection

          forgery_denial(request, config)
        end

        # The DNS rebinding check of the MCP transport, done here so that one rule covers every
        # host: the transport itself only knows exact names, and is created without its own check
        # (see Profiler::MCP::Server#http_transport). A Host header is accepted when it names a
        # loopback address, a host the application lists in config.hosts (when that list is not
        # empty, Rails' HostAuthorization already refuses every other host), or an entry of
        # config.mcp_allowed_hosts. A request without a Host header (HTTP/1.0) is let through, as
        # the transport did: the rebinding vector always carries one.
        def allowed_host?(raw_host, config = Profiler.configuration)
          return true if raw_host.nil?

          full = raw_host.to_s.strip.downcase
          name = host_name(full)
          return false if name.empty?
          return true if LOOPBACK_HOSTS.include?(name)
          return true if Array(config.mcp_allowed_hosts).any? { |entry| host_entry_allows?(entry, name, full) }

          # Rails matches config.hosts against the whole Host header (an entry may carry a port);
          # the bare name covers entries written without one.
          Profiler::LocalRequest.permitted_by_rails_hosts?(full) ||
            Profiler::LocalRequest.permitted_by_rails_hosts?(name)
        end

        private

        LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

        def host_denial(request, config)
          raw = request.get_header("HTTP_HOST")
          return nil if allowed_host?(raw, config)

          "Host #{raw} is not allowed for the MCP endpoint: list it in config.hosts or " \
            "config.mcp_allowed_hosts"
        end

        # A String matches the host name (any port) or the whole host:port, case-insensitively; a
        # Regexp must match the whole host name, without the port.
        def host_entry_allows?(entry, name, full)
          case entry
          when Regexp
            Profiler::Cluster::Security.anchored_pattern?(entry) &&
              Profiler::Cluster::Security.whole_url_pattern(entry).match?(name)
          when String
            allowed = entry.strip.downcase
            allowed == name || allowed == full
          else
            false
          end
        rescue RegexpError
          false
        end

        # "[::1]:3000" gives "::1", "app.local:3000" gives "app.local". Anything else (two hosts, a
        # port that is not a number, text after the brackets) gives "", which is refused.
        def host_name(host)
          match = host.match(/\A\[([^\]]+)\](?::\d+)?\z/) || host.match(/\A([^:\s,]+)(?::\d+)?\z/)
          match ? match[1] : ""
        end

        # The Origin check of the transport, kept whatever api_forgery_protection says: a
        # browser's Origin must be the profiler's own or one of cors_allowed_origins.
        def origin_denial(request, config)
          origin = request.get_header("HTTP_ORIGIN")
          return nil if origin.nil? || origin.empty? || allowed_origin?(origin, request, config)

          "Cross-origin request refused: Origin #{origin} is not allowed"
        end

        def forgery_denial(request, _config)
          if request.post? && media_type(request) != JSON_MEDIA_TYPE
            return deny("A POST to the MCP endpoint needs Content-Type: #{JSON_MEDIA_TYPE}")
          end

          nil
        end

        def media_type(request)
          request.get_header("CONTENT_TYPE").to_s.split(";").first.to_s.strip.downcase
        end

        def allowed_origin?(origin, request, config)
          return true if Array(config.cors_allowed_origins).include?(origin)

          same_origin?(origin, request)
        end

        # The Origin's host and port against the Host header, as the transport compares them: the
        # scheme is left out, since behind a proxy that ends TLS the request says http while the
        # browser's Origin says https, and the default port of the Origin's scheme is dropped.
        def same_origin?(origin, request)
          uri = URI.parse(origin)
          host = request.get_header("HTTP_HOST").to_s.downcase
          return false if uri.host.nil? || host.empty?

          authority = uri.port == uri.default_port ? uri.host.downcase : "#{uri.host.downcase}:#{uri.port}"
          host = host.delete_suffix(":#{uri.default_port}")
          authority == host
        rescue URI::InvalidURIError
          false
        end

        def deny(message)
          [403, { "content-type" => "application/json" }, [{ error: message }.to_json]]
        end
      end
    end
  end
end
