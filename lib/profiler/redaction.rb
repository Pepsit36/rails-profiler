# frozen_string_literal: true

require "json"
require "set"
require "rack/utils"
require "active_support/parameter_filter"

module Profiler
  # The single filter applied to everything the profiler captures: request
  # params, headers, bodies and URLs (incoming and outgoing), SQL binds, job
  # arguments, mailer arguments and ENV.
  #
  # It is built on ActiveSupport::ParameterFilter from the host application's
  # Rails.application.config.filter_parameters plus
  # Profiler.configuration.filter_parameters, so it follows Rails semantics:
  # a symbol or string matches any key containing it, case-insensitively, at
  # any nesting depth; a regexp is used as is; a proc rewrites values.
  #
  # It never raises: it runs inside notification subscribers and the Net::HTTP
  # patch, where an exception would reach the application. When the filter
  # fails (a proc that does not expect a value, say), the value is masked.
  module Redaction
    MASK = "[FILTERED]"

    # Matched by the filter on top of filter_parameters.
    ALWAYS_FILTERED_HEADERS = %w[authorization proxy-authorization cookie set-cookie].freeze

    # Headers whose value is a URL: their query string goes through the filter.
    URL_HEADERS = %w[referer location content-location].freeze

    JSON_TYPES = %r{\A(?:application|text)/(?:[\w.+-]+\+)?json\z}i
    NDJSON_TYPES = %r{\A[\w.+-]+/x-ndjson\z}i
    FORM_TYPE = "application/x-www-form-urlencoded"
    MULTIPART_TYPE = %r{\Amultipart/}i

    # A JSON object key, escapes included, as it appears in the raw text.
    JSON_KEY = /"((?:[^"\\]|\\.)*)"\s*:/m

    # The characters outside ASCII whose case folding yields ASCII letters
    # (Unicode CaseFolding.txt): with any of them, a case-insensitive regexp
    # can match an ASCII filter where a plain ASCII search cannot.
    FOLDS_TO_ASCII = /[\u00DF\u0130\u0149\u017F\u01F0\u1E96-\u1E9A\u1E9E\u212A\uFB00-\uFB06]/

    # Bound on the memo of names already tested against the filter.
    KEY_CACHE_LIMIT = 10_000

    # The value a name is tested with: procs in filter_parameters rewrite it
    # in place, so it has to be a string, and a throwaway one.
    PROBE = "x"

    class << self
      def enabled?
        Profiler.configuration.redact_sensitive_data != false
      end

      # The ParameterFilter, rebuilt only when the list of filters changes.
      def parameter_filter
        compiled[:filter]
      end

      def filter_hash(hash)
        return hash unless enabled? && hash.is_a?(Hash)

        parameter_filter.filter(hash)
      rescue StandardError
        hash.transform_values { MASK }
      end

      # Filters any value: hashes through the filter, arrays element by
      # element, anything else unchanged (it carries no key to match).
      def filter_value(value)
        return value unless enabled?

        case value
        when Hash then filter_hash(value)
        when Array then value.map { |v| filter_value(v) }
        else value
        end
      rescue StandardError
        MASK
      end

      # The value unchanged, or MASK when +name+ matches the filter.
      def filter_named(name, value)
        return value unless enabled? && name

        sensitive_key?(name) ? MASK : value
      end

      # Memoized per name: header, ENV, column and JSON key names come from a
      # small set. A filter that raises makes the name sensitive.
      def sensitive_key?(name)
        key = name.to_s
        state = compiled
        known = state[:keys]
        return known[key] if known.key?(key)

        result = state[:filter].filter(key => +PROBE)[key] == MASK
        known[key] = result if known.size < KEY_CACHE_LIMIT
        result
      rescue StandardError
        true
      end

      # Header names are tested as written and with dashes as underscores, so
      # that X-Api-Key matches :_key as x_api_key would.
      def sensitive_header?(name)
        key = name.to_s.downcase
        ALWAYS_FILTERED_HEADERS.include?(key) || sensitive_key?(key) || sensitive_key?(key.tr("-", "_"))
      end

      def filter_headers(headers)
        return headers unless enabled? && headers.respond_to?(:each_with_object)

        headers.each_with_object({}) do |(name, value), out|
          out[name] = filter_header(name, value)
        end
      end

      # Filters a raw body according to its content type. JSON, NDJSON and
      # form-urlencoded bodies have their filtered keys masked, multipart
      # bodies are masked entirely, and every other type is kept as is: they
      # carry no key the filter can read, and masking HTML would hide the very
      # pages being profiled.
      def filter_body(raw, content_type)
        return raw unless enabled? && raw.is_a?(String) && !raw.empty?

        mime = content_type.to_s.split(";").first.to_s.strip.downcase
        if mime.match?(JSON_TYPES)
          filter_json(raw, mime)
        elsif mime.match?(NDJSON_TYPES)
          raw.split("\n", -1).map { |line| line.strip.empty? ? line : filter_json(line, mime) }.join("\n")
        elsif mime == FORM_TYPE
          filter_query(raw)
        elsif mime.match?(MULTIPART_TYPE)
          "[FILTERED: #{mime} body, #{raw.bytesize} bytes]"
        else
          raw
        end
      rescue StandardError
        "[FILTERED: #{mime} body that could not be filtered, #{raw.bytesize} bytes]"
      end

      # Masks the filtered values of a query string, pair by pair, leaving the
      # rest of the string exactly as it was.
      def filter_query(query)
        return query unless enabled? && query.is_a?(String) && !query.empty?

        query.split("&", -1).map do |pair|
          name, value = pair.split("=", 2)
          next pair if value.nil? || value.empty?

          parsed = Rack::Utils.parse_nested_query(pair)
          parameter_filter.filter(parsed) == parsed ? pair : "#{name}=#{MASK}"
        rescue StandardError
          # A pair Rack or the filter cannot handle is masked rather than trusted.
          "#{name}=#{MASK}"
        end.join("&")
      end

      def filter_url(url)
        return url unless enabled? && url.is_a?(String)

        rest, fragment = url.split("#", 2)
        base, query = rest.split("?", 2)
        return url if query.nil?

        "#{base}?#{filter_query(query)}#{"##{fragment}" if fragment}"
      end

      # ENV as the profiler shows it: names kept, values masked unless the
      # name is in config.env_allowlist and does not match the filter.
      def env_snapshot(env = ENV.to_h)
        listed = env_allowlist_matcher
        env.sort.to_h { |name, value| [name, env_visible?(name, listed) ? value : MASK] }
      end

      def env_value(name, value)
        env_visible?(name) ? value : MASK
      end

      # ENV overrides with the same rule applied to their current and original
      # values. The deleted and restore markers are kept: they are not values.
      def env_overrides(overrides)
        overrides.to_h do |name, entry|
          next [name, entry] if env_visible?(name) || !entry.is_a?(Hash)

          masked = entry.to_h do |field, value|
            [field, keep_override_field?(field, value) ? value : MASK]
          end
          [name, masked]
        end
      end

      def env_visible?(name, listed = env_allowlist_matcher)
        listed.call(name.to_s) && !(enabled? && sensitive_key?(name))
      end

      private

      def compiled
        filters = current_filters
        state = @compiled
        return state if state && state[:filters] == filters

        @compiled = {
          filters: filters,
          filter: ActiveSupport::ParameterFilter.new(filters, mask: MASK),
          keys: {}
        }.merge(key_matchers(filters))
      end

      # What the JSON pre-test needs, built as ParameterFilter builds its own
      # patterns: strings and symbols as one case-insensitive alternation,
      # regexps as they are. Procs rewrite values whatever the key, and dotted
      # filters match a key path: neither can be judged from key names, so
      # they make the filters opaque.
      def key_matchers(filters)
        opaque = filters.any? { |f| f.respond_to?(:call) || f.to_s.include?(".") }
        regexps, strings = filters.partition { |f| f.is_a?(Regexp) }
        words = strings.empty? ? nil : Regexp.new(strings.map { |s| Regexp.escape(s.to_s) }.join("|"), Regexp::IGNORECASE)
        {
          opaque: opaque,
          # Searched with String#include? in the downcased text: several times
          # faster than the case-insensitive alternation on a large body.
          word_list: regexps.empty? && strings.all? { |s| s.to_s.ascii_only? } ? strings.map { |s| s.to_s.downcase } : nil,
          any_key: Regexp.union([words, *regexps].compact)
        }
      end

      def filter_header(name, value)
        if sensitive_header?(name)
          MASK
        elsif URL_HEADERS.include?(name.to_s.downcase)
          filter_url(value)
        else
          value
        end
      rescue StandardError
        MASK
      end

      def keep_override_field?(field, value)
        value.nil? ||
          value == EnvOverrideStore::DELETED_SENTINEL ||
          value == EnvOverrideStore::RESTORE_SENTINEL ||
          !%w[value original].include?(field)
      end

      def env_allowlist_matcher
        allowlist = Profiler.configuration.env_allowlist
        return ->(_name) { true } if allowlist == :all

        regexps, names = Array(allowlist).partition { |entry| entry.is_a?(Regexp) }
        names = names.to_set(&:to_s)
        ->(name) { names.include?(name) || regexps.any? { |r| r.match?(name) } }
      end

      def current_filters
        filters = Array(Profiler.configuration.filter_parameters)
        app_filters = rails_filter_parameters
        app_filters.empty? ? filters : app_filters + filters
      end

      def rails_filter_parameters
        return [] unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

        Array(::Rails.application.config.filter_parameters)
      rescue StandardError
        []
      end

      def filter_json(raw, mime)
        return raw unless json_needs_parse?(raw)

        parsed = JSON.parse(raw)
        filtered = filter_value(parsed)
        filtered == parsed ? raw : JSON.generate(filtered)
      rescue JSON::ParserError
        "[FILTERED: unparseable #{mime} body, #{raw.bytesize} bytes]"
      end

      # A cheap pre-test that spares the parse of a body no key of which the
      # filter can match. With only ASCII string filters, a body whose text
      # contains none of them anywhere, in any case, is spared at once; this
      # holds unless the text has a character that case-folds onto ASCII
      # letters (FOLDS_TO_ASCII) or an escape. Otherwise each key is read from
      # the raw text and tested as ParameterFilter would; a key written with
      # an escape cannot be judged that way, so it sends the body to the
      # parser, as procs and dotted filters do.
      def json_needs_parse?(raw)
        state = compiled
        return true if state[:opaque]
        if (words = state[:word_list]) && !raw.include?("\\") && (raw.ascii_only? || !raw.match?(FOLDS_TO_ASCII))
          text = raw.downcase(:ascii)
          return false if words.none? { |word| text.include?(word) }
        end

        any_key = state[:any_key]
        raw.scan(JSON_KEY) { |(key)| return true if key.include?("\\") || any_key.match?(key) }
        false
      end
    end
  end
end
