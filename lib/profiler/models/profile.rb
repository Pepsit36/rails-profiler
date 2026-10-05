# frozen_string_literal: true

require "base64"
require "securerandom"
require "json"
require "zlib"
require_relative "../redaction"
require_relative "../allocation_counter"

module Profiler
  module Models
    class Profile
      attr_reader :path
      attr_accessor :token, :method, :status, :duration, :allocated_objects,
                    :started_at, :finished_at, :params, :headers,
                    :response_headers, :collectors_data, :collectors_metadata,
                    :parent_token, :is_ajax, :profile_type,
                    :request_body, :request_body_encoding,
                    :response_body, :response_body_encoding,
                    :request_body_size, :request_body_truncated,
                    :response_body_size, :response_body_truncated,
                    :gem_version

      def initialize(request = nil)
        @token = SecureRandom.hex(16)
        @started_at = Time.now
        @collectors_data = {}
        @collectors_metadata = []
        @parent_token = nil
        @is_ajax = false
        @profile_type = "http"

        if request
          @path = request.path
          @method = request.request_method
          @params = sanitize_params(request.params)
          @headers = extract_headers(request.env)
        end
      end

      # The sizes are those of the whole bodies, when a body was cut at max_captured_body_bytes.
      def set_bodies(request_body:, response_body:, req_content_type:, resp_content_type:,
                     request_body_size: nil, response_body_size: nil)
        req  = process_body(request_body, req_content_type)
        resp = process_body(response_body, resp_content_type)
        @request_body          = req[:body]
        @request_body_encoding = req[:encoding]
        @response_body         = resp[:body]
        @response_body_encoding = resp[:encoding]
        @request_body_size, @request_body_truncated = body_size(request_body, request_body_size)
        @response_body_size, @response_body_truncated = body_size(response_body, response_body_size)
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

      def to_h
        req_body,  req_enc  = decode_body(@request_body,  @request_body_encoding)
        resp_body, resp_enc = decode_body(@response_body, @response_body_encoding)

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
          headers: @headers,
          response_headers: @response_headers,
          request_body: req_body,
          request_body_encoding: req_enc,
          response_body: resp_body,
          response_body_encoding: resp_enc,
          request_body_size: @request_body_size,
          request_body_truncated: @request_body_truncated,
          response_body_size: @response_body_size,
          response_body_truncated: @response_body_truncated,
          collectors_data: @collectors_data,
          tabs: @collectors_metadata,
          parent_token: @parent_token,
          is_ajax: @is_ajax
        }
      end

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
        profile.headers = data[:headers]
        profile.response_headers = data[:response_headers]
        profile.request_body = data[:request_body]
        profile.request_body_encoding = data[:request_body_encoding] || "text"
        profile.response_body = data[:response_body]
        profile.response_body_encoding = data[:response_body_encoding] || "text"
        profile.request_body_size = data[:request_body_size]
        profile.request_body_truncated = data[:request_body_truncated] || false
        profile.response_body_size = data[:response_body_size]
        profile.response_body_truncated = data[:response_body_truncated] || false
        profile.parent_token = data[:parent_token]
        profile.is_ajax = data[:is_ajax] || false
        profile.profile_type = data[:profile_type] || "http"
        profile.gem_version = data[:gem_version]

        # Convert collectors_data keys to strings recursively for consistency
        profile.collectors_data = (data[:collectors_data] || {}).transform_keys(&:to_s).transform_values do |value|
          deep_stringify_keys(value)
        end

        # Restore tabs metadata
        profile.collectors_metadata = data[:tabs] || []

        profile
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

        if binary_content_type?(content_type)
          # Masked on the raw bytes, before the encoding hides them from any later search. A
          # compressed format (zip, png, gzip...) does not hold the secret as it is.
          { body: Base64.strict_encode64(Redaction.hide_credentials(raw.b)), encoding: "base64" }
        else
          text = Redaction.filter_body(raw, content_type).encode("UTF-8", invalid: :replace, undef: :replace)
          if compress_body?(text)
            { body: Base64.strict_encode64(Zlib::Deflate.deflate(text)), encoding: "gzip+base64" }
          else
            { body: text, encoding: "text" }
          end
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

      def decode_body(body, encoding)
        return [body, encoding] unless encoding == "gzip+base64"
        return [body, encoding] if body.nil? || body.empty?

        decoded = Zlib::Inflate.inflate(Base64.strict_decode64(body))
        [decoded, "text"]
      rescue Zlib::Error, ArgumentError
        [body, encoding]
      end

      def binary_content_type?(ct)
        ct.to_s.match?(%r{image/(?!svg)|application/(?:pdf|octet-stream|zip)|audio/|video/})
      end

      LEGACY_FILTERED_PARAMS = %w[password password_confirmation token secret].freeze

      def sanitize_params(params)
        return {} unless params

        return Redaction.hide_credentials(params.to_h.except(*LEGACY_FILTERED_PARAMS)) unless Redaction.enabled?

        Redaction.filter_hash(params.to_h)
      end

      ALLOWED_HEADERS = %w[
        Accept Accept-Charset Accept-Encoding Accept-Language
        Authorization Cache-Control Connection Content-Length Content-Type
        Cookie Host If-Modified-Since If-None-Match Origin
        Referer User-Agent
      ].freeze

      def extract_headers(env)
        env.select { |k, _| k.start_with?("HTTP_") }
           .transform_keys { |k| k.sub(/^HTTP_/, "").split("_").map(&:capitalize).join("-") }
           .select { |k, _| ALLOWED_HEADERS.include?(k) }
           .then { |headers| Redaction.filter_headers(headers) }
      end
    end
  end
end
