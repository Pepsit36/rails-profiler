# frozen_string_literal: true

require "base64"
require "securerandom"
require "json"
require "zlib"

module Profiler
  module Models
    class Profile
      attr_accessor :token, :path, :method, :status, :duration, :memory,
                    :started_at, :finished_at, :params, :headers,
                    :response_headers, :collectors_data, :collectors_metadata,
                    :parent_token, :is_ajax, :profile_type,
                    :request_body, :request_body_encoding,
                    :response_body, :response_body_encoding

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

      TEXT_BODY_LIMIT   = 512 * 1024
      BINARY_BODY_LIMIT = 256 * 1024

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
        @response_headers = response_headers
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
        {
          profile_type: @profile_type,
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
          request_body: @request_body,
          request_body_encoding: @request_body_encoding,
          response_body: @response_body,
          response_body_encoding: @response_body_encoding,
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
          truncated = raw.b[0, BINARY_BODY_LIMIT]
          { body: Base64.strict_encode64(truncated), encoding: "base64" }
        else
          text = raw.encode("UTF-8", invalid: :replace, undef: :replace)[0, TEXT_BODY_LIMIT]
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

      def binary_content_type?(ct)
        ct.to_s.match?(%r{image/(?!svg)|application/(?:pdf|octet-stream|zip)|audio/|video/})
      end

      def sanitize_params(params)
        return {} unless params

        params.to_h.except("password", "password_confirmation", "token", "secret")
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
      end
    end
  end
end
