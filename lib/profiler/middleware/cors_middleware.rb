# frozen_string_literal: true

module Profiler
  module Middleware
    class CorsMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        # Apply CORS and frame options to all profiler endpoints
        if env['PATH_INFO'].start_with?('/_profiler/')
          # Handle OPTIONS preflight request
          if env['REQUEST_METHOD'] == 'OPTIONS'
            return [
              200,
              cors_headers(env),
              ['']
            ]
          end

          status, headers, body = @app.call(env)

          # Add CORS headers
          cors_headers(env).each do |key, value|
            headers[key] = value
          end

          # Allow embedding in iframes from Chrome extensions
          headers.delete('X-Frame-Options')
          # Don't set CSP if controller requested to skip it
          unless env['profiler.skip_csp']
            # Allow embedding from standard web origins
            headers['Content-Security-Policy'] = "frame-ancestors 'self' http: https:"
          end

          [status, headers, body]
        else
          @app.call(env)
        end
      end

      private

      def cors_headers(env)
        allowed_origins = Profiler.configuration.cors_allowed_origins
        request_origin = env['HTTP_ORIGIN']

        if allowed_origins.include?('*')
          origin_header = '*'
        elsif request_origin && allowed_origins.include?(request_origin)
          origin_header = request_origin
        end

        headers = {
          'Access-Control-Allow-Methods' => 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers' => 'Content-Type, X-Requested-With, Accept',
          'Access-Control-Expose-Headers' => 'X-Profiler-Token'
        }

        if origin_header
          headers['Access-Control-Allow-Origin'] = origin_header
          headers['Vary'] = 'Origin' unless origin_header == '*'
        end

        headers
      end
    end
  end
end
