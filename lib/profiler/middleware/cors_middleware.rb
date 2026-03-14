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
              cors_headers,
              ['']
            ]
          end

          status, headers, body = @app.call(env)

          # Add CORS headers
          cors_headers.each do |key, value|
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

      def cors_headers
        {
          'Access-Control-Allow-Origin' => '*',
          'Access-Control-Allow-Methods' => 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers' => 'Content-Type, X-Requested-With, Accept',
          'Access-Control-Expose-Headers' => 'X-Profiler-Token'
        }
      end
    end
  end
end
