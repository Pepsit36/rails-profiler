# frozen_string_literal: true

require "base64"
require "securerandom"
require "json"
require "zlib"
require_relative "../redaction"

module Profiler
  module Models
    class Profile
      attr_accessor :token, :path, :method, :status, :duration, :memory,
                    :started_at, :finished_at, :params, :headers,
                    :response_headers, :collectors_data, :collectors_metadata,
                    :parent_token, :is_ajax, :profile_type,
                    :request_body, :request_body_encoding,
                    :response_body, :response_body_encoding,
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

      def set_bodies(request_body:, response_body:, req_content_type:, resp_content_type:)
        req  = process_body(request_body, req_content_type)
        resp = process_body(response_body, resp_content_type)
        @request_body          = req[:body]
        @request_body_encoding = req[:encoding]
        @response_body         = resp[:body]
        @response_body_encoding = resp[:encoding]
      end

      def finish(status, response_headers = {})
        @finished_at = Time.now
        @duration = ((@finished_at - @started_at) * 1000).round(2) # milliseconds
        @status = status
        @response_headers = Redaction.filter_headers(response_headers)
      end

      def add_collector_data(name, data)
        @collectors_data[name.to_s] = data
      end

      def collector_data(name)
        @collectors_data[name.to_s]
      end

      def add_collector_metadata(collector)
        config = collector.tab_config
        @collectors_metadata << {
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
          memory: @memory,
          started_at: @started_at&.iso8601,
          finished_at: @finished_at&.iso8601,
          params: @params,
          headers: @headers,
          response_headers: @response_headers,
          request_body: req_body,
          request_body_encoding: req_enc,
          response_body: resp_body,
          response_body_encoding: resp_enc,
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
        profile.memory = data[:memory]
        profile.started_at = data[:started_at] ? Time.parse(data[:started_at]) : nil
        profile.finished_at = data[:finished_at] ? Time.parse(data[:finished_at]) : nil
        profile.params = data[:params]
        profile.headers = data[:headers]
        profile.response_headers = data[:response_headers]
        profile.request_body = data[:request_body]
        profile.request_body_encoding = data[:request_body_encoding] || "text"
        profile.response_body = data[:response_body]
        profile.response_body_encoding = data[:response_body_encoding] || "text"
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
          { body: Base64.strict_encode64(raw.b), encoding: "base64" }
        else
          text = Redaction.filter_body(raw, content_type).encode("UTF-8", invalid: :replace, undef: :replace)
          if compress_body?(text)
            { body: Base64.strict_encode64(Zlib::Deflate.deflate(text)), encoding: "gzip+base64" }
          else
            { body: text, encoding: "text" }
          end
        end
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
