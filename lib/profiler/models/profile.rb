# frozen_string_literal: true

require "base64"
require "securerandom"
require "json"
require "zlib"
require_relative "../redaction"
require_relative "../body_content"
require_relative "../allocation_counter"

module Profiler
  module Models
    class Profile
      attr_reader :path
      attr_accessor :token, :method, :status, :duration, :allocated_objects,
                    :started_at, :finished_at, :params, :headers,
                    :response_headers, :collectors_data, :collectors_metadata,
                    :parent_token, :replay_of, :server_port, :url_scheme, :is_ajax, :profile_type,
                    :request_body, :request_body_encoding,
                    :response_body, :response_body_encoding,
                    :request_body_size, :request_body_truncated, :request_body_size_is_minimum,
                    :response_body_size, :response_body_truncated, :response_body_size_is_minimum,
                    :collectors_released_after_seconds, :params_truncated,
                    :gem_version, :trace_id, :span_id, :parent_span_id

      # +params+: false leaves the params to capture_params, for a caller that builds the profile
      # before the router has run.
      def initialize(request = nil, params: true)
        @token = SecureRandom.hex(16)
        @started_at = Time.now
        @collectors_data = {}
        @collectors_metadata = []
        @parent_token = nil
        @replay_of = nil
        @is_ajax = false
        @profile_type = "http"

        if request
          @path = request.path
          @method = request.request_method
          capture_params(request) if params
          @headers = extract_headers(request.env)
          @server_port, @url_scheme = listening_endpoint(request.env)
        end
      end

      # The request's params as the controller sees them. Read once the router has run: Rails
      # adds the route parameters (:id...) and applies the routes' param_encoding only then, so
      # a read before it keeps neither.
      def capture_params(request)
        @params, @params_truncated = cap_params(sanitize_params(utf8_params(request.params)),
                                                Profiler.configuration.max_captured_body_bytes)
      end

      # The sizes are those of the whole bodies, when a body was cut at max_captured_body_bytes;
      # *_size_is_minimum when the whole size is not known (no Content-Length, a stream that
      # stopped), only that it is at least that.
      def set_bodies(request_body:, response_body:, req_content_type:, resp_content_type:,
                     request_body_size: nil, response_body_size: nil,
                     request_body_size_is_minimum: false, response_body_size_is_minimum: false)
        req  = process_body(request_body, req_content_type)
        resp = process_body(response_body, resp_content_type)
        @request_body          = req[:body]
        @request_body_encoding = req[:encoding]
        @response_body         = resp[:body]
        @response_body_encoding = resp[:encoding]
        @request_body_size, @request_body_truncated = body_size(request_body, request_body_size)
        @response_body_size, @response_body_truncated = body_size(response_body, response_body_size)
        @request_body_size_is_minimum = request_body_size_is_minimum ? true : false
        @response_body_size_is_minimum = response_body_size_is_minimum ? true : false
      end

      # Deprecated: the number of allocated objects times 40, the figure earlier versions
      # reported as bytes. Still written in to_h, for the readers that only know it.
      def memory
        @allocated_objects&.*(AllocationCounter::LEGACY_BYTES_PER_OBJECT)
      end

      def memory=(value)
        @allocated_objects = value && value / AllocationCounter::LEGACY_BYTES_PER_OBJECT
      end

      def finish(status, response_headers = {})
        @finished_at = Time.now
        @duration = ((@finished_at - @started_at) * 1000).round(2) # milliseconds
        @status = status
        @response_headers = Redaction.filter_headers(response_headers)
      end

      # Every collector stores its data here: logs, exception messages, dumps and SQL text are free
      # text with no name to filter on, so the profiler's own credentials are masked by value.
      def add_collector_data(name, data)
        @collectors_data[name.to_s] = Redaction.hide_credentials(data)
      end

      # The path is free text for a console profile: the expression typed.
      def path=(value)
        @path = Redaction.hide_credentials(value)
      end

      def collector_data(name)
        @collectors_data[name.to_s]
      end

      def add_collector_metadata(collector)
        @collectors_metadata << collector_metadata(collector)
      end

      # A collector collected again, after the profile's tabs were listed (a streamed response
      # that failed part way): its tab keeps its place, with what it now has.
      def refresh_collector_metadata(collector)
        entry = collector_metadata(collector)
        index = @collectors_metadata.index { |tab| tab[:key] == entry[:key] }
        index ? @collectors_metadata[index] = entry : @collectors_metadata << entry
      end

      def collector_metadata(collector)
        config = collector.tab_config
        {
          key: config[:key],
          label: config[:label],
          icon: config[:icon],
          priority: config[:priority],
          enabled: config[:enabled],
          default_active: config[:default_active],
          render_mode: collector.render_mode.to_s,
          has_data: collector.has_data?
        }
      end
      private :collector_metadata

      # The profile as the stores keep it: a body compressed by compress_bodies stays gzip+base64.
      # decode_bodies: true gives the bodies as text, for the responses that show them.
      def to_h(decode_bodies: false)
        req_body,  req_enc  = @request_body,  @request_body_encoding
        resp_body, resp_enc = @response_body, @response_body_encoding
        if decode_bodies
          req_body,  req_enc  = self.class.decode_body(req_body, req_enc)
          resp_body, resp_enc = self.class.decode_body(resp_body, resp_enc)
        end

        {
          profile_type: @profile_type,
          gem_version: @gem_version,
          token: @token,
          path: @path,
          method: @method,
          status: @status,
          duration: @duration,
          allocated_objects: @allocated_objects,
          memory: memory,
          started_at: @started_at&.iso8601,
          finished_at: @finished_at&.iso8601,
          params: @params,
          params_truncated: @params_truncated,
          headers: @headers,
          response_headers: @response_headers,
          request_body: req_body,
          request_body_encoding: req_enc,
          response_body: resp_body,
          response_body_encoding: resp_enc,
          request_body_size: @request_body_size,
          request_body_truncated: @request_body_truncated,
          request_body_size_is_minimum: @request_body_size_is_minimum,
          response_body_size: @response_body_size,
          response_body_truncated: @response_body_truncated,
          response_body_size_is_minimum: @response_body_size_is_minimum,
          collectors_released_after_seconds: @collectors_released_after_seconds,
          collectors_data: @collectors_data,
          tabs: @collectors_metadata,
          parent_token: @parent_token,
          trace_id: @trace_id,
          span_id: @span_id,
          parent_span_id: @parent_span_id,
          replay_of: @replay_of,
          server_port: @server_port,
          url_scheme: @url_scheme,
          is_ajax: @is_ajax
        }
      end

      # The stored form, as #to_h.
      def to_json(*args)
        to_h.to_json(*args)
      end

      def self.from_json(json_string)
        data = JSON.parse(json_string, symbolize_names: true)
        from_hash(data)
      end

      def self.from_hash(data)
        profile = new
        profile.token = data[:token]
        profile.path = data[:path]
        profile.method = data[:method]
        profile.status = data[:status]
        profile.duration = data[:duration]
        # A profile saved before allocated_objects only carries memory, the count times 40.
        if data.key?(:allocated_objects)
          profile.allocated_objects = data[:allocated_objects]
        else
          profile.memory = data[:memory]
        end
        profile.started_at = data[:started_at] ? Time.parse(data[:started_at]) : nil
        profile.finished_at = data[:finished_at] ? Time.parse(data[:finished_at]) : nil
        profile.params = data[:params]
        profile.params_truncated = data[:params_truncated]
        profile.headers = data[:headers]
        profile.response_headers = data[:response_headers]
        profile.request_body = data[:request_body]
        profile.request_body_encoding = data[:request_body_encoding] || "text"
        profile.response_body = data[:response_body]
        profile.response_body_encoding = data[:response_body_encoding] || "text"
        profile.request_body_size = data[:request_body_size]
        # Left nil when the store did not keep them (SqliteStore rebuilds a profile from its
        # columns): the request collector's data still has them.
        profile.request_body_truncated = data[:request_body_truncated]
        profile.request_body_size_is_minimum = data[:request_body_size_is_minimum]
        profile.response_body_size = data[:response_body_size]
        profile.response_body_truncated = data[:response_body_truncated]
        profile.response_body_size_is_minimum = data[:response_body_size_is_minimum]
        profile.collectors_released_after_seconds = data[:collectors_released_after_seconds]
        profile.parent_token = data[:parent_token]
        profile.replay_of = data[:replay_of]
        profile.server_port = data[:server_port]
        profile.url_scheme = data[:url_scheme]
        profile.is_ajax = data[:is_ajax] || false
        profile.profile_type = data[:profile_type] || "http"
        profile.gem_version = data[:gem_version]
        profile.trace_id = data[:trace_id]
        profile.span_id = data[:span_id]
        profile.parent_span_id = data[:parent_span_id]

        # Convert collectors_data keys to strings recursively for consistency
        profile.collectors_data = (data[:collectors_data] || {}).transform_keys(&:to_s).transform_values do |value|
          deep_stringify_keys(value)
        end

        # Restore tabs metadata
        profile.collectors_metadata = data[:tabs] || []

        profile
      end

      # A body kept gzip+base64 as text, with its encoding then "text"; any other body as it is.
      # One that cannot be decompressed (cut, damaged) is returned as it is: unreadable at worst.
      def self.decode_body(body, encoding)
        return [body, encoding] unless encoding == "gzip+base64"
        return [body, encoding] if body.nil? || body.empty?

        decoded = Zlib::Inflate.inflate(Base64.strict_decode64(body))
        [decoded.force_encoding(Encoding::UTF_8).scrub, "text"]
      rescue Zlib::Error, ArgumentError
        [body, encoding]
      end

      def self.deep_stringify_keys(obj)
        case obj
        when Hash
          obj.transform_keys(&:to_s).transform_values { |v| deep_stringify_keys(v) }
        when Array
          obj.map { |item| deep_stringify_keys(item) }
        else
          obj
        end
      end

      private

      def process_body(raw, content_type)
        return { body: nil, encoding: "text" } if raw.nil? || raw.empty?

        if BodyContent.binary?(raw, content_type)
          # Masked on the raw bytes, before the encoding hides them from any later search. A
          # compressed format (zip, png, gzip...) does not hold the secret as it is.
          { body: Base64.strict_encode64(Redaction.hide_credentials(raw.b)), encoding: "base64" }
        else
          text = utf8_text(Redaction.filter_body(raw, content_type), content_type)
          if compress_body?(text)
            # The fastest level: paid on the request, a quarter larger than the default level.
            { body: Base64.strict_encode64(Zlib::Deflate.deflate(text, Zlib::BEST_SPEED)), encoding: "gzip+base64" }
          else
            { body: text, encoding: "text" }
          end
        end
      end

      # The text as UTF-8: a body read from the wire is binary, and is taken for the charset its
      # Content-Type declares (UTF-8 when it declares none, or one Ruby does not know). Bytes
      # that do not belong to it are replaced, never raised on.
      def utf8_text(text, content_type)
        return text.encode("UTF-8", invalid: :replace, undef: :replace) unless text.encoding == Encoding::BINARY

        charset = content_type.to_s[/charset\s*=\s*"?([^\s";]+)/i, 1]
        source = begin
          charset ? Encoding.find(charset) : Encoding::UTF_8
        rescue ArgumentError
          Encoding::UTF_8
        end
        # "internal" is a name Ruby knows but resolves to nil, "utf-7" is a dummy encoding with no converter.
        source ||= Encoding::UTF_8
        begin
          text.dup.force_encoding(source).encode("UTF-8", invalid: :replace, undef: :replace)
        rescue EncodingError
          text.dup.force_encoding(Encoding::UTF_8).encode("UTF-8", invalid: :replace, undef: :replace)
        end
      end

      # The params with their strings in UTF-8: a route's param_encoding gives some another
      # encoding, which the profile must not carry into its JSON.
      def utf8_params(value)
        case value
        when Hash then value.to_h { |k, v| [utf8_params(k), utf8_params(v)] }
        when Array then value.map { |v| utf8_params(v) }
        when String
          value.encoding == Encoding::UTF_8 ? value : value.encode("UTF-8", invalid: :replace, undef: :replace)
        else value
        end
      end

      def body_size(captured, total)
        captured_size = captured.to_s.bytesize
        total ||= captured_size
        [total, total > captured_size]
      end

      def compress_body?(text)
        Profiler.configuration.compress_bodies &&
          text.bytesize > Profiler.configuration.compress_body_threshold
      end

      LEGACY_FILTERED_PARAMS = %w[password password_confirmation token secret].freeze

      # The key added to params cut at max_captured_body_bytes, so that the cut shows wherever
      # the params are read.
      PARAMS_TRUNCATED_KEY = "[profiler]"

      # A copy of +params+ whose JSON stays within about +limit+ bytes: long strings are cut, and
      # the entries past the limit left out. The application's own params are never touched.
      # Returns the params and whether they were cut.
      def cap_params(params, limit)
        return [params, false] if limit.nil? || !params.is_a?(Hash)

        budget = [limit]
        cut = [false]
        capped = cap_value(params, budget, cut)
        return [capped, false] unless cut[0]

        capped[PARAMS_TRUNCATED_KEY] = "params truncated at #{limit} bytes (max_captured_body_bytes)"
        [capped, true]
      end

      def cap_value(value, budget, cut)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), out|
            cost = key.to_s.bytesize + 4
            if cost >= budget[0]
              cut[0] = true
              break out
            end
            budget[0] -= cost
            out[key] = cap_value(item, budget, cut)
          end
        when Array
          value.each_with_object([]) do |item, out|
            if budget[0] <= 1
              cut[0] = true
              break out
            end
            budget[0] -= 1
            out << cap_value(item, budget, cut)
          end
        when String
          cost = value.bytesize + 2
          if cost > budget[0]
            cut[0] = true
            value = Redaction.cut_bytes(value, [budget[0] - 2, 0].max).scrub("")
            cost = value.bytesize + 2
          end
          budget[0] -= cost
          value
        else
          budget[0] -= value.to_s.bytesize
          value
        end
      end

      def sanitize_params(params)
        return {} unless params

        return Redaction.hide_credentials(params.to_h.except(*LEGACY_FILTERED_PARAMS)) unless Redaction.enabled?

        Redaction.filter_hash(params.to_h)
      end

      ALLOWED_HEADERS = %w[
        Accept Accept-Charset Accept-Encoding Accept-Language
        Authorization Cache-Control Connection Content-Length Content-Type
        Cookie Host If-Modified-Since If-None-Match Origin
        Referer User-Agent Turbo-Frame X-Forwarded-Proto
      ].freeze

      # The port the application server really listens on and the scheme of that connection, read
      # from the connection itself and from nothing a client wrote. SERVER_PORT is not used: Puma
      # derives it from the Host header (Host: localhost:6379 gives SERVER_PORT 6379), and it derives
      # rack.url_scheme from X-Forwarded-Proto. Puma exposes the accepted connection as
      # env["puma.socket"]: its local port is the listening port, and a TLS socket means https. Any
      # other server gives no port (nil), and a replay then needs config.replay_port.
      def listening_endpoint(env)
        socket = env["puma.socket"]
        port = socket_port(socket)
        return [nil, nil] unless port

        [port, socket.class.name.to_s.match?(/SSL/) ? "https" : "http"]
      end

      def socket_port(socket)
        return nil unless socket

        io = socket.respond_to?(:to_io) ? socket.to_io : socket
        address = io.local_address
        port = address.ip? ? address.ip_port : nil
        port&.between?(1, 65_535) ? port : nil
      rescue StandardError
        nil
      end

      def extract_headers(env)
        headers = env.select { |k, _| k.start_with?("HTTP_") }
                     .transform_keys { |k| k.sub(/^HTTP_/, "").split("_").map(&:capitalize).join("-") }
        headers["Content-Type"] = env["CONTENT_TYPE"] if env["CONTENT_TYPE"]
        headers.select { |k, _| ALLOWED_HEADERS.include?(k) }
               .then { |h| Redaction.filter_headers(h) }
      end
    end
  end
end
