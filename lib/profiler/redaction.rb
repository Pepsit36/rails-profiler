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
  # fails (a proc that does not expect a value, say), the value is masked and
  # the failure is logged once per error class, without the value.
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

    # The characters outside ASCII whose case folding yields ASCII letters
    # (Unicode CaseFolding.txt): with any of them, a case-insensitive regexp
    # can match an ASCII filter where a plain ASCII search cannot.
    FOLDS_TO_ASCII = /[ßİŉſǰẖ-ẚẞKﬀ-ﬆ]/

    # What makes a regexp filter unfit for a search of the whole body text:
    # anchors, word boundaries and lookarounds can match a key on its own and
    # fail on the same key inside the text.
    CONTEXT_SENSITIVE_REGEXP = /\\[AzZbBG]|[\^$]|\(\?<?[=!]/

    # Bound on the memo of names already tested against the filter.
    KEY_CACHE_LIMIT = 10_000

    # The value a name alone is tested with: procs in filter_parameters
    # rewrite it in place, so it has to be a string, and a throwaway one.
    PROBE = "x"

    class << self
      def enabled?
        Profiler.configuration.redact_sensitive_data != false
      end

      # The ParameterFilter, rebuilt only when the list of filters changes.
      def parameter_filter
        compiled[:filter]
      end

      # Keys are masked by the filters that are not procs; the procs then
      # rewrite each string left, once, under its own key. Running the procs
      # through ParameterFilter instead would dup every other value first,
      # Active Record models included.
      def filter_hash(hash)
        return hash unless enabled? && hash.is_a?(Hash)

        state = compiled
        masked = state[:plain].filter(hash)
        state[:proc_filter] ? apply_procs_tree(masked, nil, hash, state[:procs]) : masked
      rescue StandardError => e
        report(e, "filtering a hash")
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
      rescue StandardError => e
        report(e, "filtering a value")
        MASK
      end

      # A value known by its name (SQL bind, mailer argument): MASK when the
      # name matches the filter, else the value as the procs of
      # filter_parameters rewrite it.
      def filter_named(name, value)
        return value unless enabled? && name
        return MASK if sensitive_key?(name)

        apply_procs([name.to_s], value)
      end

      # Whether the name alone matches the filter. Memoized per name: header,
      # ENV, column and key names come from a small set. A filter that raises
      # makes the name sensitive.
      def sensitive_key?(name)
        key = name.to_s
        state = compiled
        known = state[:keys]
        return known[key] if known.key?(key)

        result = state[:plain].filter(key => +PROBE)[key] == MASK
        known[key] = result if known.size < KEY_CACHE_LIMIT
        result
      rescue StandardError => e
        report(e, "testing a name")
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
      #
      # Bodies usually arrive as binary strings (rack.input, Net::HTTP): they
      # are read as UTF-8, or as bytes when they are not valid UTF-8.
      def filter_body(raw, content_type)
        return raw unless enabled? && raw.is_a?(String) && !raw.empty?

        mime = content_type.to_s.split(";").first.to_s.strip.downcase
        text = readable(raw)
        if mime.match?(JSON_TYPES)
          filter_json(text, mime)
        elsif mime.match?(NDJSON_TYPES)
          text.split("\n", -1).map { |line| line.strip.empty? ? line : filter_json(line, mime) }.join("\n")
        elsif mime == FORM_TYPE
          filter_query(text)
        elsif mime.match?(MULTIPART_TYPE)
          "[FILTERED: #{mime} body, #{raw.bytesize} bytes]"
        else
          raw
        end
      rescue StandardError => e
        report(e, "filtering a #{mime} body")
        "[FILTERED: #{mime} body that could not be filtered, #{raw.bytesize} bytes]"
      end

      # Masks the filtered values of a query string, pair by pair, leaving the
      # rest of the string exactly as it was.
      def filter_query(query)
        return query unless enabled? && query.is_a?(String) && !query.empty?

        readable(query).split("&", -1).map do |pair|
          name, value = pair.split("=", 2)
          next pair if value.nil? || value.empty?

          parsed = Rack::Utils.parse_nested_query(pair)
          parameter_filter.filter(parsed) == parsed ? pair : "#{name}=#{MASK}"
        rescue StandardError
          # A pair Rack or the filter cannot handle is masked rather than trusted.
          "#{name}=#{MASK}"
        end.join("&")
      end

      # A URL, or a list of them as Rack 3 gives a repeated header.
      def filter_url(url)
        return url unless enabled?
        return url.map { |u| filter_url(u) } if url.is_a?(Array)
        return url unless url.is_a?(String)

        rest, fragment = readable(url).split("#", 2)
        base, query = rest.split("?", 2)
        return url if query.nil?

        "#{base}?#{filter_query(query)}#{"##{fragment}" if fragment}"
      rescue StandardError => e
        report(e, "filtering a URL")
        MASK
      end

      # ENV as the profiler shows it: names kept, values masked unless the
      # name is in config.env_allowlist and does not match the filter.
      def env_snapshot(env = ENV.to_h)
        listed = env_allowlist_matcher
        env.sort.to_h { |name, value| [name, env_visible?(name, listed) ? apply_procs([name], value) : MASK] }
      end

      def env_value(name, value)
        env_visible?(name) ? apply_procs([name.to_s], value) : MASK
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

      # Whether +value+, stripped, is the mask: a value exported while masked,
      # which must never be written back as if it were the real one.
      def mask?(value)
        value.to_s.strip == MASK
      end

      private

      def compiled
        filters = current_filters
        state = @compiled
        return state if state && state[:filters] == filters

        @reported = Set.new
        procs, plain = filters.partition { |f| f.respond_to?(:call) }
        @compiled = {
          filters: filters,
          filter: ActiveSupport::ParameterFilter.new(filters, mask: MASK),
          plain: ActiveSupport::ParameterFilter.new(plain, mask: MASK),
          proc_filter: procs.empty? ? nil : ActiveSupport::ParameterFilter.new(procs, mask: MASK),
          procs: procs,
          keys: {}
        }.merge(text_matchers(filters))
      end

      # What the JSON pre-test needs: the string filters, downcased, for a
      # plain search, and as one case-insensitive alternation as
      # ParameterFilter builds it, for text outside ASCII; the regexp filters
      # that can be searched for in the whole text. Procs rewrite values
      # whatever the key, dotted filters match a key path, and other regexps
      # depend on where the key ends: any of them makes the filters opaque,
      # and every body is then parsed.
      def text_matchers(filters)
        procs = filters.any? { |f| f.respond_to?(:call) }
        regexps, strings = filters.reject { |f| f.respond_to?(:call) }.partition { |f| f.is_a?(Regexp) }
        opaque = procs ||
                 filters.any? { |f| !f.respond_to?(:call) && f.to_s.include?(".") } ||
                 regexps.any? { |r| r.source.match?(CONTEXT_SENSITIVE_REGEXP) } ||
                 strings.any? { |s| !s.to_s.ascii_only? }
        words = strings.map { |s| s.to_s.downcase }
        {
          opaque: opaque,
          words: words,
          words_regexp: words.empty? ? nil : Regexp.new(words.map { |w| Regexp.escape(w) }.join("|"), Regexp::IGNORECASE),
          regexps: regexps
        }
      end

      def filter_header(name, value)
        return MASK if sensitive_header?(name)

        value = filter_url(value) if URL_HEADERS.include?(name.to_s.downcase)
        apply_procs([name.to_s, name.to_s.tr("-", "_")], value)
      rescue StandardError => e
        report(e, "filtering a header")
        MASK
      end

      # The value as the procs of filter_parameters rewrite it under each of
      # +names+. Nothing to do without procs: the names were already tested.
      #
      # Only strings: any other object would be duplicated for the procs,
      # which runs the application's copy hooks; it is shown through its
      # inspect, as before. The procs run once: under the first of +names+
      # that changes the value, so that a proc which undoes itself (reverse!)
      # is not applied twice.
      def apply_procs(names, value)
        return value unless enabled? && value.is_a?(String)

        filter = compiled[:proc_filter]
        return value unless filter

        names.uniq.each do |name|
          result = filter.filter(name => value)[name]
          return result unless result == value
        end
        value
      rescue StandardError => e
        report(e, "applying a filter_parameters proc")
        MASK
      end

      # Walks a tree the non-proc filters have already masked and lets the
      # procs rewrite each string leaf, once, as ParameterFilter does: a copy
      # of the key and of the value, and the original params for a proc of
      # arity 3. A leaf masked by the filter is the MASK object itself and is
      # left alone, also as ParameterFilter does; a value that only reads
      # "[FILTERED]" is a different object and still goes to the procs.
      def apply_procs_tree(value, key, original, procs)
        case value
        when Hash then value.each_with_object(value.class.new) { |(k, v), out| out[k] = apply_procs_tree(v, k, original, procs) }
        when Array then value.map { |v| apply_procs_tree(v, key, original, procs) }
        when String then key.nil? || value.equal?(MASK) ? value : call_procs(procs, key, value, original)
        else value
        end
      end

      def call_procs(procs, key, value, original)
        key = key.dup if key.duplicable?
        value = value.dup
        procs.each { |b| b.arity == 2 ? b.call(key, value) : b.call(key, value, original) }
        value
      rescue StandardError => e
        report(e, "applying a filter_parameters proc")
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

      # The string as UTF-8 when it is valid UTF-8, else as bytes, so that
      # string operations and regexps never meet an incompatible encoding.
      def readable(string)
        return string if string.encoding == Encoding::UTF_8 && string.valid_encoding?

        utf8 = string.dup.force_encoding(Encoding::UTF_8)
        utf8.valid_encoding? ? utf8 : string.b
      end

      def filter_json(text, mime)
        return text unless json_needs_parse?(text)

        parsed = JSON.parse(text)
        filtered = filter_value(parsed)
        filtered == parsed ? text : JSON.generate(filtered)
      rescue JSON::ParserError, JSON::GeneratorError
        "[FILTERED: unparseable #{mime} body, #{text.bytesize} bytes]"
      end

      # A cheap pre-test that spares the parse of a body in whose text no
      # filter matches anywhere: no key of it can match either. Any match, in
      # a key or in a value, sends the body to the parser, which also masks
      # an unreadable body entirely. Text that is not valid UTF-8, holds an
      # escape (a key can be written password) or, for a plain ASCII
      # search, a character that case-folds onto ASCII letters is not judged
      # here, nor is any body under opaque filters.
      def json_needs_parse?(text)
        state = compiled
        return true if state[:opaque]
        return true if text.encoding != Encoding::UTF_8 || text.include?("\\")

        state[:regexps].any? { |r| r.match?(text) } || words_in_text?(state, text)
      end

      def words_in_text?(state, text)
        words = state[:words]
        return false if words.empty?
        return state[:words_regexp].match?(text) unless text.ascii_only? || !text.match?(FOLDS_TO_ASCII)

        lowered = text.downcase(:ascii)
        words.any? { |word| lowered.include?(word) }
      end

      # Logs a failure of the filter once per error class, with no value and
      # no message: either could carry what was being masked.
      def report(error, during)
        reported = (@reported ||= Set.new)
        return if reported.include?(error.class)

        reported << error.class
        message = "[Profiler] Redaction: #{error.class} while #{during}; the value was masked instead."
        logger = ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
        logger ? logger.warn(message) : Kernel.warn(message)
      rescue StandardError
        nil
      end
    end
  end
end
