# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require_relative "storage/token"
require_relative "local_request"
require_relative "redaction"
require_relative "models/profile"

module Profiler
  # Sends a profiled request again, for real, to the application that served it, so that the
  # replay is profiled like any other request and linked to the original (Profile#replay_of).
  #
  # The target is the host and port the original request was made to, as the profile captured
  # them (the Host header, and X-Forwarded-Proto for the scheme). It is read from the stored
  # profile only: no option names a host, a port, a scheme or a URL, the ones that try are
  # refused, and the Host header of an override is ignored. The captured host must also be a
  # local name or one config.hosts allows (the check authorization_mode :allow_local applies),
  # so a profile that recorded a forged Host header cannot aim a replay elsewhere. Redirects
  # are never followed. The call itself goes through Profiler.untracked_http: it is not
  # recorded in whatever profile is current, and cannot profile itself in a loop.
  #
  # Every method is allowed, side effects included: whoever asks (the dashboard, after its
  # confirmation; an MCP client, which answers for the call it makes) answers for the request.
  module Replay
    class Error < StandardError; end
    class Disabled < Error; end
    class NotFound < Error; end
    class Invalid < Error; end

    # Carries the source token to the replayed request; the middleware reads it (only while
    # replay_enabled) to set Profile#replay_of.
    SOURCE_HEADER = "X-Profiler-Replay-Of"
    SOURCE_ENV_KEY = "HTTP_X_PROFILER_REPLAY_OF"
    RESPONSE_TOKEN_HEADER = "X-Profiler-Token"

    METHODS = %w[GET HEAD POST PUT PATCH DELETE OPTIONS].freeze
    BODYLESS_METHODS = %w[GET HEAD DELETE OPTIONS].freeze
    OPTIONS = %i[count method path query params body headers cookies timeout].freeze
    # Options that would aim the request somewhere else: refused, never ignored in silence.
    TARGET_OPTIONS = %w[host hostname port scheme protocol url uri base_url origin target server address
                        forwarded_host x_forwarded_host].freeze
    # Headers an override may not set: those that name the target or that the transport owns.
    FORBIDDEN_HEADERS = %w[host forwarded x-forwarded-host x-forwarded-server x-forwarded-proto x-forwarded-port
                           x-original-host x-host x-http-host-override content-length connection
                           transfer-encoding upgrade te trailer proxy-authorization
                           x-profiler-replay-of x-profiler-token].freeze
    # Whitespace and control characters, which have no place in the request line.
    REQUEST_LINE_UNSAFE = /[\x00-\x20\x7f]/
    ROUTE_PARAMS = %w[controller action].freeze
    MAX_TIMEOUT = 120

    Result = Struct.new(:source_token, :target, :replays, :notes, keyword_init: true) do
      def to_h
        { source_token: source_token, target: target, replays: replays, notes: notes }
      end
    end

    class << self
      # +options+ (string or symbol keys): count, method, path, query, params, body, headers,
      # cookies, timeout. Raises a Replay::Error subclass for everything the caller can fix.
      def call(source_token, options = {}, storage: Profiler.storage)
        options = normalize_options(options)
        raise Disabled, disabled_message unless Profiler.configuration.replay_enabled

        source = load_source(source_token, storage)
        count = replay_count(options[:count])
        target = target_for(source)
        request = build_request(source, options)
        timeout = replay_timeout(options[:timeout])

        replays = []
        Profiler.untracked_http do
          count.times do |index|
            replays << send_once(target, request, source.token, timeout, index + 1)
            break if replays.last[:error]
          end
        end
        Result.new(source_token: source.token, target: target[:origin], replays: replays,
                   notes: request[:notes])
      end

      def disabled_message
        "Replaying requests is disabled. Set config.replay_enabled = true to allow it."
      end

      private

      def normalize_options(options)
        options = (options || {}).to_h.transform_keys(&:to_s)
        target_keys = options.keys & TARGET_OPTIONS
        unless target_keys.empty?
          raise Invalid, "A replay always goes to the host of the original request: #{target_keys.join(", ")} " \
                         "cannot be set."
        end
        unknown = options.keys - OPTIONS.map(&:to_s)
        raise Invalid, "Unknown replay option(s): #{unknown.join(", ")}." unless unknown.empty?

        options.transform_keys(&:to_sym)
      end

      def load_source(token, storage)
        raise NotFound, "Profile not found: #{token.to_s[0, 64]}" unless Storage::Token.valid?(token)

        profile = storage.load(token)
        raise NotFound, "Profile not found: #{token}" unless profile
        unless profile.profile_type == "http" && profile.method && profile.path
          raise Invalid, "Only a profiled HTTP request can be replayed."
        end

        profile
      end

      def replay_count(value)
        count = value.nil? ? 1 : Integer(value, exception: false)
        max = Profiler.configuration.replay_max_count.to_i
        unless count && count >= 1 && count <= max
          raise Invalid, "count must be a whole number from 1 to #{max} (config.replay_max_count)."
        end

        count
      end

      def replay_timeout(value)
        default = Profiler.configuration.replay_timeout.to_f
        seconds = value.nil? ? default : Float(value, exception: false)
        raise Invalid, "timeout must be a number of seconds." unless seconds && seconds.positive?

        [seconds, MAX_TIMEOUT].min
      end

      # The host and port of the original request, from the profile alone.
      def target_for(source)
        headers = headers_by_name(source.headers)
        host = headers["host"].to_s.strip
        raise Invalid, "The profile has no Host header, so the original host is unknown." if host.empty?

        scheme = headers["x-forwarded-proto"].to_s.split(",").first.to_s.strip.downcase == "https" ? "https" : "http"
        uri = parse_host(scheme, host)
        unless LocalRequest.host_allowed?(host)
          raise Invalid, "The host #{uri.hostname.inspect} of the original request is neither local nor allowed " \
                         "by config.hosts: refusing to send a request to it."
        end

        { scheme: scheme, host: uri.hostname, port: uri.port, origin: "#{scheme}://#{uri.authority}" }
      end

      def parse_host(scheme, host)
        uri = URI.parse("#{scheme}://#{host}")
        valid = uri.is_a?(URI::HTTP) && uri.hostname && uri.userinfo.nil? &&
                (uri.path.nil? || uri.path.empty?) && uri.query.nil? && uri.fragment.nil?
        raise Invalid, "The Host header #{host.inspect} of the original request is not a host name." unless valid

        uri
      rescue URI::InvalidURIError
        raise Invalid, "The Host header #{host.inspect} of the original request is not a host name."
      end

      def headers_by_name(headers)
        (headers || {}).each_with_object({}) { |(name, value), out| out[name.to_s.downcase] = value }
      end

      def build_request(source, options)
        notes = []
        method = (options[:method] || source.method).to_s.upcase
        raise Invalid, "Unsupported HTTP method #{method.inspect} (allowed: #{METHODS.join(", ")})." unless METHODS.include?(method)

        path, path_query = split_path(options[:path] || source.path)
        headers = base_headers(source, options, notes)
        body, query = body_and_query(source, options, method, path_query, headers, notes)

        { method: method, path: query.to_s.empty? ? path : "#{path}?#{query}", headers: headers, body: body,
          notes: notes }
      end

      def split_path(value)
        value = value.to_s
        path, query = value.split("?", 2)
        unless path.match?(%r{\A/(?!/)[^\s\\\x00-\x1f\x7f]*\z})
          raise Invalid, "path must be an absolute path of the application (starting with a single \"/\")."
        end
        raise Invalid, "the query string of path must not contain whitespace or control characters." if query&.match?(REQUEST_LINE_UNSAFE)

        [path, query]
      end

      def base_headers(source, options, notes)
        headers = {}
        redacted = []
        (source.headers || {}).each do |name, value|
          next if FORBIDDEN_HEADERS.include?(name.to_s.downcase)

          if value == Redaction::MASK
            redacted << name
            next
          end
          headers[name.to_s] = value.to_s
        end
        notes << "Not sent, masked in the profile: #{redacted.join(", ")}." unless redacted.empty?

        ignored = []
        (options[:headers] || {}).each do |name, value|
          if FORBIDDEN_HEADERS.include?(name.to_s.downcase) || name.to_s.match?(/[\r\n:\s]/) || value.to_s.match?(/[\r\n]/)
            ignored << name.to_s
            next
          end
          headers.delete_if { |existing, _| existing.casecmp?(name.to_s) }
          headers[name.to_s] = value.to_s
        end
        notes << "Ignored headers (they name the target or belong to the transport): #{ignored.join(", ")}." unless ignored.empty?

        apply_cookies(headers, options[:cookies])
        headers
      end

      def apply_cookies(headers, cookies)
        return if cookies.nil?

        value = cookies.respond_to?(:map) && !cookies.is_a?(String) ? cookies.map { |k, v| "#{k}=#{v}" }.join("; ") : cookies.to_s
        raise Invalid, "cookies must not contain line breaks." if value.match?(/[\r\n]/)

        headers.delete_if { |name, _| name.casecmp?("Cookie") }
        headers["Cookie"] = value unless value.empty?
      end

      def body_and_query(source, options, method, path_query, headers, notes)
        params = options.key?(:params) ? options[:params] : default_params(source, notes)
        query = options.key?(:query) ? encode_query(options[:query]) : path_query
        body = nil

        if options.key?(:body)
          body = options[:body].to_s
        elsif !options.key?(:params) && !BODYLESS_METHODS.include?(method) && (stored = stored_body(source, notes))
          body = stored
        end

        if params.is_a?(Hash) && !params.empty? && !options.key?(:query) && path_query.nil? && body.nil?
          if BODYLESS_METHODS.include?(method)
            query = encode_query(params)
          else
            body, content_type = encode_params_body(params, headers)
            headers["Content-Type"] ||= content_type
          end
        end

        [body, query]
      end

      def default_params(source, notes)
        return {} unless source.params.is_a?(Hash)

        route = source.collector_data("request").to_h
        params = source.params.reject { |key, _| route["controller_action"] && ROUTE_PARAMS.include?(key.to_s) }
        masked = params.select { |_, value| value == Redaction::MASK }.keys
        notes << "Parameters masked in the profile were not sent: #{masked.join(", ")}." unless masked.empty?
        params.reject { |_, value| value == Redaction::MASK }
      end

      def stored_body(source, notes)
        return nil if source.request_body.nil? || source.request_body.empty?

        if source.request_body_truncated
          notes << "The stored request body is truncated (max_captured_body_bytes): the replay sends what was kept."
        end
        if source.request_body_encoding == "base64"
          Base64.strict_decode64(source.request_body)
        else
          Models::Profile.decode_body(source.request_body, source.request_body_encoding).first
        end
      rescue ArgumentError
        nil
      end

      def encode_query(value)
        case value
        when nil then nil
        when Hash then URI.encode_www_form(flatten_params(value))
        else value.to_s.gsub(REQUEST_LINE_UNSAFE, "")
        end
      end

      def encode_params_body(params, headers)
        content_type = headers.find { |name, _| name.casecmp?("Content-Type") }&.last.to_s
        if content_type.include?("json")
          [JSON.generate(params), content_type]
        else
          [URI.encode_www_form(flatten_params(params)), "application/x-www-form-urlencoded"]
        end
      end

      def flatten_params(value, prefix = nil)
        case value
        when Hash
          value.flat_map { |k, v| flatten_params(v, prefix ? "#{prefix}[#{k}]" : k.to_s) }
        when Array
          value.flat_map { |v| flatten_params(v, "#{prefix}[]") }
        else
          [[prefix.to_s, value.to_s]]
        end
      end

      def send_once(target, request, source_token, timeout, index)
        http = Net::HTTP.new(target[:host], target[:port])
        http.use_ssl = target[:scheme] == "https"
        http.open_timeout = http.read_timeout = http.write_timeout = timeout
        message = Net::HTTPGenericRequest.new(request[:method], !request[:body].nil?, request[:method] != "HEAD",
                                              request[:path], request[:headers].merge(SOURCE_HEADER => source_token))
        message.body = request[:body] if request[:body]
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = http.start { |connection| connection.request(message) }
        token = response[RESPONSE_TOKEN_HEADER]
        { index: index, status: response.code.to_i, token: Storage::Token.valid?(token) ? token : nil,
          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(2) }
      rescue StandardError => e
        { index: index, status: nil, token: nil, error: "#{e.class}: #{e.message}" }
      end
    end
  end
end
