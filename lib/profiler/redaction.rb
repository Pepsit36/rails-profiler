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
  # any nesting depth; a regexp is used as is.
  module Redaction
    MASK = "[FILTERED]"

    # Matched by the filter on top of filter_parameters.
    ALWAYS_FILTERED_HEADERS = %w[authorization proxy-authorization cookie set-cookie].freeze

    JSON_TYPES = %r{\Aapplication/(?:[\w.+-]+\+)?json\z}i
    FORM_TYPE = "application/x-www-form-urlencoded"
    MULTIPART_TYPE = %r{\Amultipart/}i

    # Bound on the memo of names already tested against the filter.
    KEY_CACHE_LIMIT = 10_000

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
      end

      # The value unchanged, or MASK when +name+ matches the filter.
      def filter_named(name, value)
        return value unless enabled? && name

        sensitive_key?(name) ? MASK : value
      end

      # Memoized per name: header, ENV and column names come from a small set.
      def sensitive_key?(name)
        key = name.to_s
        state = compiled
        known = state[:keys]
        return known[key] if known.key?(key)

        result = state[:filter].filter(key => true)[key] == MASK
        known[key] = result if known.size < KEY_CACHE_LIMIT
        result
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
          out[name] = sensitive_header?(name) ? MASK : value
        end
      end

      # Filters a raw body according to its content type. JSON and
      # form-urlencoded bodies have their filtered keys masked, multipart
      # bodies are masked entirely, and every other type is kept as is: they
      # carry no key the filter can read, and masking HTML would hide the very
      # pages being profiled.
      def filter_body(raw, content_type)
        return raw unless enabled? && raw.is_a?(String) && !raw.empty?

        mime = content_type.to_s.split(";").first.to_s.strip.downcase
        if mime.match?(JSON_TYPES)
          filter_json(raw, mime)
        elsif mime == FORM_TYPE
          filter_query(raw)
        elsif mime.match?(MULTIPART_TYPE)
          "[FILTERED: #{mime} body, #{raw.bytesize} bytes]"
        else
          raw
        end
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
          # A pair Rack cannot parse is masked rather than trusted.
          "#{name}=#{MASK}"
        end.join("&")
      end

      def filter_url(url)
        return url unless enabled?

        base, query = url.to_s.split("?", 2)
        query.nil? ? url : "#{base}?#{filter_query(query)}"
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
      # values. The deleted marker is kept: it is not a value.
      def env_overrides(overrides)
        overrides.to_h do |name, entry|
          next [name, entry] if env_visible?(name) || !entry.is_a?(Hash)

          masked = entry.to_h do |field, value|
            keep = value.nil? || value == EnvOverrideStore::DELETED_SENTINEL || !%w[value original].include?(field)
            [field, keep ? value : MASK]
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

        @compiled = { filters: filters, filter: ActiveSupport::ParameterFilter.new(filters, mask: MASK), keys: {} }
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
        parsed = JSON.parse(raw)
        filtered = filter_value(parsed)
        filtered == parsed ? raw : JSON.generate(filtered)
      rescue JSON::ParserError
        "[FILTERED: unparseable #{mime} body, #{raw.bytesize} bytes]"
      end
    end
  end
end
