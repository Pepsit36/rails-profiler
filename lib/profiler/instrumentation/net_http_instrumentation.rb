# frozen_string_literal: true

require "net/http"
require "base64"
require "zlib"
require "stringio"
require "securerandom"

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
          request_id = SecureRandom.hex(8)
          started_at = Time.now.iso8601(3)
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Thread.current[:profiler_http_recording] = true

          response = super

          duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(2)
          resp_body_raw = response.body.to_s
          resp_content_encoding = response["content-encoding"].to_s.strip.downcase
          resp_body = NetHttpInstrumentation.decompress_body(resp_body_raw, resp_content_encoding)
          resp_content_type = response["content-type"].to_s
          req_content_type = req["content-type"].to_s

          processed_req = req_body.empty? ? { body: nil, encoding: "text" } : NetHttpInstrumentation.process_body(req_body, req_content_type)
          processed_resp = NetHttpInstrumentation.process_body(resp_body, resp_content_type)

          t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          collector.record_request(
            id: request_id,
            started_at: started_at,
            url: url,
            method: req.method,
            status: response.code.to_i,
            duration: duration,
            request_headers: req_headers,
            request_body: processed_req[:body],
            request_body_encoding: processed_req[:encoding],
            request_size: req_body.bytesize,
            response_headers: response.to_hash.transform_values { |v| v.join(", ") },
            response_body: processed_resp[:body],
            response_body_encoding: processed_resp[:encoding],
            response_size: resp_body_raw.bytesize,
            backtrace: NetHttpInstrumentation.extract_backtrace
          )

          fg = Thread.current[:profiler_flamegraph_collector]
          fg&.record_http_event(started_at: t0, finished_at: t1, url: url, method: req.method, status: response.code.to_i)

          response
        rescue => e
          if defined?(t0) && t0
            duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(2)
            collector&.record_request(
              id: defined?(request_id) ? request_id : SecureRandom.hex(8),
              started_at: defined?(started_at) ? started_at : Time.now.iso8601(3),
              url: url,
              method: req.method,
              status: 0,
              duration: duration,
              request_headers: defined?(req_headers) ? req_headers : {},
              request_body: nil,
              request_body_encoding: "text",
              request_size: 0,
              response_headers: {},
              response_body: nil,
              response_body_encoding: "text",
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

      TEXT_BODY_LIMIT   = 512 * 1024 # 512 KB
      BINARY_BODY_LIMIT = 256 * 1024 # 256 KB (before base64)

      TEXT_CONTENT_TYPES   = /\A(text\/|application\/(json|xml|xhtml|javascript|x-www-form-urlencoded)|image\/svg)/i
      BINARY_CONTENT_TYPES = /\A(image\/|application\/pdf|application\/octet-stream|application\/zip|audio\/|video\/)/i

      def self.install!
        return if @installed
        Net::HTTP.prepend(RequestPatch)
        @installed = true
      end

      def self.skip_host?(host)
        SKIP_HOSTS.include?(host) ||
          Profiler.configuration.http_skip_hosts.any? { |p| host.match?(p) }
      end

      def self.decompress_body(body, content_encoding)
        return body if content_encoding.empty? || body.nil? || body.empty?

        case content_encoding
        when "gzip", "x-gzip"
          Zlib::GzipReader.new(StringIO.new(body)).read
        when "deflate"
          Zlib::Inflate.inflate(body)
        else
          body
        end
      rescue StandardError
        body
      end

      def self.process_body(body, content_type)
        return { body: nil, encoding: "text" } if body.nil? || body.empty?

        mime = content_type.split(";").first.to_s.strip

        if mime.match?(BINARY_CONTENT_TYPES)
          truncated = body.byteslice(0, BINARY_BODY_LIMIT) || ""
          { body: Base64.strict_encode64(truncated.b), encoding: "base64" }
        else
          # Text (including unknown content types)
          text = body.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
          { body: text.byteslice(0, TEXT_BODY_LIMIT), encoding: "text" }
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
