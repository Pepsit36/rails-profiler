# frozen_string_literal: true

require "net/http"

module Profiler
  module Instrumentation
    module NetHttpInstrumentation
      module RequestPatch
        def request(req, body = nil, &block)
          collector = Thread.current[:profiler_http_collector]
          return super unless collector
          # Re-entrancy guard: Net::HTTP#request calls itself recursively when
          # the connection isn't started yet. Only record the outermost call.
          return super if Thread.current[:profiler_http_recording]

          host = address.to_s
          return super if NetHttpInstrumentation.skip_host?(host)

          url = build_url(host, port, req.path, use_ssl?)
          req_body = req.body.to_s
          req_headers = req.to_hash.transform_values { |v| v.join(", ") }
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Thread.current[:profiler_http_recording] = true

          response = super

          duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(2)
          resp_body = response.body.to_s
          collector.record_request(
            url: url,
            method: req.method,
            status: response.code.to_i,
            duration: duration,
            request_headers: req_headers,
            request_body: req_body.empty? ? nil : NetHttpInstrumentation.truncate_body(req_body),
            request_size: req_body.bytesize,
            response_headers: response.to_hash.transform_values { |v| v.join(", ") },
            response_body: NetHttpInstrumentation.truncate_body(resp_body),
            response_size: resp_body.bytesize,
            backtrace: NetHttpInstrumentation.extract_backtrace
          )
          response
        rescue => e
          if defined?(t0) && t0
            duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(2)
            collector&.record_request(
              url: url,
              method: req.method,
              status: 0,
              duration: duration,
              request_headers: defined?(req_headers) ? req_headers : {},
              request_body: nil,
              request_size: 0,
              response_headers: {},
              response_body: nil,
              response_size: 0,
              backtrace: NetHttpInstrumentation.extract_backtrace,
              error: e.message
            )
          end
          raise
        ensure
          Thread.current[:profiler_http_recording] = false
        end

        private

        def build_url(host, port, path, ssl)
          scheme = ssl ? "https" : "http"
          standard_port = (ssl && port == 443) || (!ssl && port == 80)
          standard_port ? "#{scheme}://#{host}#{path}" : "#{scheme}://#{host}:#{port}#{path}"
        end
      end

      SKIP_HOSTS = %w[127.0.0.1 localhost ::1].freeze

      def self.install!
        return if @installed
        Net::HTTP.prepend(RequestPatch)
        @installed = true
      end

      def self.skip_host?(host)
        SKIP_HOSTS.include?(host) ||
          Profiler.configuration.http_skip_hosts.any? { |p| host.match?(p) }
      end

      BODY_TRUNCATE_LIMIT = 4096 # bytes

      def self.truncate_body(body)
        return nil if body.nil? || body.empty?
        if body.bytesize > BODY_TRUNCATE_LIMIT
          body.byteslice(0, BODY_TRUNCATE_LIMIT) + "\n… [truncated, #{body.bytesize} bytes total]"
        else
          body
        end
      end

      def self.extract_backtrace
        caller_locations(5, 15)
          .reject { |l| l.path.to_s.include?("net/http") || l.path.to_s.include?("profiler/instrumentation") }
          .first(5)
          .map { |l| "#{l.path}:#{l.lineno}:in `#{l.label}`" }
      end
    end
  end
end
