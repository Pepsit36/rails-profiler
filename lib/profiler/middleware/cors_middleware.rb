# frozen_string_literal: true

module Profiler
  module Middleware
    # Sets the framing headers of every profiler response, and its CORS headers when
    # extension_cors_enabled is set. Both settings are read on each request.
    class CorsMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless profiler_path?(env['PATH_INFO'].to_s)

        cors = Profiler.configuration.extension_cors_enabled

        # Handle OPTIONS preflight request
        if cors && env['REQUEST_METHOD'] == 'OPTIONS'
          return [200, cors_headers(env), ['']]
        end

        status, headers, body = @app.call(env)
        headers = headers.dup

        cors_headers(env).each { |key, value| set_header(headers, key, value) } if cors

        # frame-ancestors decides in every browser that knows it, which then ignores
        # X-Frame-Options; SAMEORIGIN only protects older browsers.
        set_header(headers, 'X-Frame-Options', 'SAMEORIGIN')
        set_header(headers, 'Content-Security-Policy', "frame-ancestors #{frame_ancestors}")

        [status, headers, body]
      end

      private

      # "/_profiler" itself is the dashboard URL; "/_profilerfoo" belongs to the application.
      def profiler_path?(path)
        path == '/_profiler' || path.start_with?('/_profiler/')
      end

      def frame_ancestors
        sources = Array(Profiler.configuration.frame_ancestors).map(&:to_s).reject(&:empty?)
        sources.empty? ? "'none'" : sources.join(' ')
      end

      def cors_headers(env)
        allowed_origins = Array(Profiler.configuration.cors_allowed_origins)
        request_origin = env['HTTP_ORIGIN']

        if request_origin && allowed_origins.include?(request_origin)
          origin_header = request_origin
        elsif allowed_origins.include?('*') && !credentialed?(env)
          # Never on a request carrying credentials: they may be what authorizes it.
          origin_header = '*'
        end

        headers = {
          'Access-Control-Allow-Methods' => 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers' => "Content-Type, X-Requested-With, Accept, #{Profiler::FORGERY_PROTECTION_HEADER}",
          'Access-Control-Expose-Headers' => 'X-Profiler-Token'
        }

        if origin_header
          headers['Access-Control-Allow-Origin'] = origin_header
          headers['Vary'] = 'Origin' unless origin_header == '*'
        end

        headers
      end

      def credentialed?(env)
        !env['HTTP_COOKIE'].to_s.empty? || !env['HTTP_AUTHORIZATION'].to_s.empty?
      end

      # Replaces a header whatever the case of its existing key, plain Hash or Rack::Headers.
      def set_header(headers, name, value)
        headers.keys.each { |key| headers.delete(key) if key.to_s.casecmp?(name) }
        headers[name] = value
      end
    end
  end
end
