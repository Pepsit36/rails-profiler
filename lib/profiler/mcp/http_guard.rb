# frozen_string_literal: true

require "json"
require "uri"

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
          return deny("Not authorized to access the profiler") unless config.authorized?(request)
          return nil unless config.api_forgery_protection

          forgery_denial(request, config)
        end

        private

        def forgery_denial(request, config)
          origin = request.get_header("HTTP_ORIGIN")
          if origin && !origin.empty? && !allowed_origin?(origin, request, config)
            return deny("Cross-origin request refused: Origin #{origin} is not allowed")
          end

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

          same_origin?(origin, request.base_url)
        end

        def same_origin?(origin, base_url)
          a = URI.parse(origin)
          b = URI.parse(base_url)
          a.scheme.to_s.casecmp?(b.scheme.to_s) && a.host.to_s.casecmp?(b.host.to_s) && a.port == b.port
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
