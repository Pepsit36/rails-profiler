# frozen_string_literal: true

require "net/http"
require "base64"
require "zlib"
require "stringio"
require "securerandom"
require_relative "../redaction"

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
          # The profiler's own calls (Profiler.untracked_http).
          return super if Thread.current[:profiler_http_untracked]

          host = address.to_s
          return super if NetHttpInstrumentation.skip_host?(host, port)

          url = Redaction.filter_url(build_url(host, port, req.path, use_ssl?))
          limit = Profiler.configuration.max_captured_body_bytes
          captured = NetHttpInstrumentation.capture_request_body(req, body, limit)
          req_headers = Redaction.filter_headers(req.to_hash.transform_values { |v| v.join(", ") })
          req_content_type = req["content-type"].to_s
          req_body = captured[:content]
          processed_req = req_body.nil? || req_body.empty? ? { body: nil, encoding: "text" } : NetHttpInstrumentation.process_body(req_body, req_content_type)

          request_id = SecureRandom.hex(8)
          started_at = Time.now.iso8601(3)
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          # Register the request as pending before the network call so that
          # fire-and-forget threads appear in the UI immediately, even if
          # collect() runs before this thread completes.
          entry = collector.register_pending(
            id: request_id,
            started_at: started_at,
            url: url,
            method: req.method,
            request_headers: req_headers,
            request_body: processed_req[:body],
            request_body_encoding: processed_req[:encoding],
            request_size: captured[:size],
            request_body_truncated: captured[:truncated],
            request_body_not_captured: captured[:not_captured],
            backtrace: NetHttpInstrumentation.extract_backtrace
          )

          Thread.current[:profiler_http_recording] = true

          response = super

          duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(2)
          resp_body_raw = response.body.to_s
          resp_content_encoding = response["content-encoding"].to_s.strip.downcase
          resp_body = NetHttpInstrumentation.decompress_body(resp_body_raw, resp_content_encoding, limit)
          resp_truncated = limit ? resp_body.bytesize > limit : false
          resp_body = Redaction.cut_bytes(resp_body, limit) if resp_truncated
          resp_content_type = response["content-type"].to_s
          processed_resp = NetHttpInstrumentation.process_body(resp_body, resp_content_type)

          t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          collector.complete_request(
            entry,
            status: response.code.to_i,
            duration: duration,
            response_headers: Redaction.filter_headers(response.to_hash.transform_values { |v| v.join(", ") }),
            response_body: processed_resp[:body],
            response_body_encoding: processed_resp[:encoding],
            response_size: resp_body_raw.bytesize,
            response_body_truncated: resp_truncated
          )

          fg = Thread.current[:profiler_flamegraph_collector]
          fg&.record_http_event(started_at: t0, finished_at: t1, url: url, method: req.method, status: response.code.to_i)

          response
        rescue => e
          duration = defined?(t0) && t0 ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(2) : 0.0
          if defined?(entry) && entry
            collector.fail_request(entry, error: e.message, duration: duration)
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

      TEXT_CONTENT_TYPES   = /\A(text\/|application\/(json|xml|xhtml|javascript|x-www-form-urlencoded)|image\/svg)/i
      BINARY_CONTENT_TYPES = /\A(image\/|application\/pdf|application\/octet-stream|application\/zip|audio\/|video\/)/i

      def self.install!
        return if @installed
        Net::HTTP.prepend(RequestPatch)
        @installed = true
      end

      # The hosts of http_skip_hosts, and the cluster's master (host and port): a slave's calls to
      # it are the profiler's, whichever code makes them.
      def self.skip_host?(host, port = nil)
        config = Profiler.configuration
        return true if config.http_skip_hosts.any? { |pattern| host.match?(pattern) }

        master = master_address(config.master_url)
        !master.nil? && master[0].casecmp?(host) && (port.nil? || master[1] == port)
      end

      def self.master_address(url)
        return nil if url.nil? || url.to_s.empty?

        uri = URI(url.to_s)
        uri.host ? [uri.host.delete_prefix("[").delete_suffix("]"), uri.port] : nil
      rescue URI::Error
        nil
      end

      # What a profile keeps of the body Net::HTTP is about to send: at most +limit+ bytes, and
      # the whole size when known. A body_stream is read only when it can be put back where it
      # was (a StringIO, a file); a pipe, a socket or an object without pos is never touched, as
      # reading it would leave nothing to send.
      def self.capture_request_body(req, body, limit)
        content = req.body
        content = body if (content.nil? || content.empty?) && body
        unless content.nil? || content.to_s.empty?
          content = content.to_s
          truncated = limit ? content.bytesize > limit : false
          return { content: truncated ? Redaction.cut_bytes(content, limit) : content,
                   size: content.bytesize, truncated: truncated, not_captured: false }
        end

        stream = req.body_stream
        return { content: nil, size: 0, truncated: false, not_captured: false } unless stream

        declared = req["content-length"].to_s
        declared = declared.match?(/\A\d+\z/) ? declared.to_i : nil
        return { content: nil, size: declared, truncated: false, not_captured: true } unless rewindable?(stream)

        position = stream.pos
        begin
          read = (limit ? stream.read(limit + 1) : stream.read).to_s
        ensure
          stream.pos = position
        end
        truncated = limit ? read.bytesize > limit : false
        { content: truncated ? Redaction.cut_bytes(read, limit) : read,
          size: declared || read.bytesize, truncated: truncated, not_captured: false }
      rescue IOError, SystemCallError => e
        Profiler.log_error_once(:net_http_body_stream, "NetHttpInstrumentation: could not read a request body_stream", e)
        { content: nil, size: declared, truncated: false, not_captured: true }
      end

      def self.rewindable?(stream)
        return false unless stream.respond_to?(:pos) && stream.respond_to?(:pos=) && stream.respond_to?(:read)
        return stream.stat.file? if stream.respond_to?(:stat)

        true
      rescue IOError, SystemCallError
        false
      end

      # Inflated up to +limit+ + 1 bytes at most: a small compressed answer can stand for a huge
      # text, which a profile never keeps whole.
      def self.decompress_body(body, content_encoding, limit = nil)
        return body if content_encoding.empty? || body.nil? || body.empty?

        case content_encoding
        when "gzip", "x-gzip"
          reader = Zlib::GzipReader.new(StringIO.new(body))
          (limit ? reader.read(limit + 1) : reader.read).to_s
        when "deflate"
          inflate_capped(body, limit)
        else
          body
        end
      rescue Zlib::Error
        body
      end

      def self.inflate_capped(body, limit)
        return Zlib::Inflate.inflate(body) unless limit

        out = +""
        inflater = Zlib::Inflate.new
        offset = 0
        while offset < body.bytesize && out.bytesize <= limit && !inflater.finished?
          out << inflater.inflate(body.byteslice(offset, 16 * 1024))
          offset += 16 * 1024
        end
        out
      ensure
        inflater&.close
      end

      def self.process_body(body, content_type)
        return { body: nil, encoding: "text" } if body.nil? || body.empty?

        mime = content_type.split(";").first.to_s.strip

        if mime.match?(BINARY_CONTENT_TYPES)
          # Masked on the raw bytes, before the encoding hides them from any later search.
          { body: Base64.strict_encode64(Redaction.hide_credentials(body.b)), encoding: "base64" }
        else
          text = Redaction.filter_body(body, content_type)
                          .encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
          { body: text, encoding: "text" }
        end
      end

      def self.extract_backtrace
        depth = Profiler.configuration.http_backtrace_depth
        frames = caller_locations(5, depth || 1000)
                   .reject { |l| l.path.to_s.include?("net/http") || l.path.to_s.include?("profiler/instrumentation") }
                   .map { |l| "#{l.path}:#{l.lineno}:in `#{l.label}`" }
        depth ? frames.first(depth) : frames
      end
    end
  end
end
