# frozen_string_literal: true

require "ipaddr"
require "uri"
require "active_support/security_utils"

module Profiler
  module Cluster
    # The rules a master and its slaves apply to each other: the shared secret they exchange,
    # and the URLs a master agrees to send requests to.
    module Security
      SECRET_HEADER = "X-Profiler-Cluster-Secret"
      SECRET_ENV_KEY = "HTTP_X_PROFILER_CLUSTER_SECRET"
      # A shorter secret, or a blank one, is treated as if none were configured.
      MIN_SECRET_LENGTH = 32
      API_PREFIX = "/_profiler/api/"

      class << self
        # Whether a secret has to be presented. False only with cluster_require_secret = false
        # and no cluster_secret, the behaviour of 0.30.6.
        def secret_required?
          config = Profiler.configuration
          config.cluster_require_secret || configured_secret?
        end

        def configured_secret?
          secret_problem.nil?
        end

        # Why the configured secret cannot be used, or nil when it can.
        def secret_problem
          secret = Profiler.configuration.cluster_secret.to_s
          return "No config.cluster_secret is configured" if secret.strip.empty?
          return nil if secret.strip.length >= MIN_SECRET_LENGTH

          "config.cluster_secret is shorter than #{MIN_SECRET_LENGTH} characters, so it is ignored " \
            "as if none were configured"
        end

        # Logged once at boot on a cluster node whose secret cannot be used, since every cluster
        # request is then refused.
        def warn_about_configuration(logger)
          config = Profiler.configuration
          return unless config.cluster_master? || config.slave?
          return unless (problem = secret_problem) && secret_required?

          logger.warn("[Profiler Cluster] #{problem}: registrations, heartbeats and proxied requests " \
                      "are refused. Generate one with `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'` " \
                      "and give the same value to every node.")
        end

        # Constant-time comparison of the secret a request carries with the configured one.
        # Always false when no usable secret is configured.
        def valid_secret?(presented)
          return false unless configured_secret?

          expected = Profiler.configuration.cluster_secret.to_s
          return false if presented.to_s.empty?

          ActiveSupport::SecurityUtils.secure_compare(presented.to_s, expected)
        end

        def request_secret_valid?(request)
          valid_secret?(request.get_header(SECRET_ENV_KEY))
        end

        # The headers to send with a request to another node of the cluster.
        def outgoing_headers
          configured_secret? ? { SECRET_HEADER => Profiler.configuration.cluster_secret.to_s } : {}
        end

        # Returns nil when the master may send requests to this slave URL, otherwise the reason.
        def slave_url_denial(url)
          config = Profiler.configuration
          target = normalize(url)
          return "#{url.inspect} is not a valid http(s) URL" unless target

          if target[:scheme] == "http" && !loopback_host?(target[:host]) && !config.cluster_allow_insecure_http
            return "#{url} uses plain HTTP to a host that is not a loopback address: HTTPS is required " \
                   "(or set config.cluster_allow_insecure_http = true)"
          end

          allowed = config.cluster_allowed_slave_urls
          return nil if allowed == :any
          return nil if Array(allowed).any? { |entry| covers?(normalize(entry), target) }

          "#{url} is not allowed by config.cluster_allowed_slave_urls"
        end

        # Same transport rule for the master URL a slave sends its secret to.
        def master_url_denial(url)
          target = normalize(url)
          return "master_url #{url.inspect} is not a valid http(s) URL" unless target
          return nil if target[:scheme] == "https" || loopback_host?(target[:host])
          return nil if Profiler.configuration.cluster_allow_insecure_http

          "master_url #{url} uses plain HTTP to a host that is not a loopback address: HTTPS is required " \
            "(or set config.cluster_allow_insecure_http = true)"
        end

        # The URL as the registry keeps it: lower-case scheme and host, no default port, IPv6
        # between brackets, path segments re-encoded, no trailing slash. Nil when not acceptable.
        def normalized_url(url)
          parts = normalize(url)
          return nil unless parts

          host = parts[:host].include?(":") ? "[#{parts[:host]}]" : parts[:host]
          default_port = parts[:scheme] == "https" ? 443 : 80
          port = parts[:port] == default_port ? "" : ":#{parts[:port]}"
          path = parts[:segments].map { |segment| escape_segment(segment) }.join("/")
          "#{parts[:scheme]}://#{host}#{port}#{path.empty? ? "" : "/#{path}"}"
        end

        # One path segment of a request to a slave, from a value that may come from a client (a
        # proxied path, a profile token). "?", "#" and "%" are encoded, so they stay in the
        # segment; ".", ".." and anything holding a "/" are refused, so the request cannot leave
        # the slave's API.
        def escape_segment(value)
          segment = value.to_s
          if segment.empty? || segment == "." || segment == ".." || segment.match?(%r{[/\\]})
            raise Profiler::Error, "Refusing to send #{segment.inspect} as a path segment to a slave profiler"
          end

          URI.encode_www_form_component(segment).gsub("+", "%20")
        end

        # The final check on a path sent to a slave: under /_profiler/api/, with no dot or empty
        # segment once decoded.
        def api_path_denial(path)
          raw = path.to_s.split("?", 2).first
          return "#{path.inspect} is not under #{API_PREFIX}" unless raw.start_with?(API_PREFIX)

          segments = raw.delete_prefix("/").split("/", -1)
          decoded = segments.map { |segment| URI.decode_www_form_component(segment) }
          return nil if decoded.none? { |segment| segment.empty? || segment == "." || segment == ".." || segment.include?("/") }

          "#{path.inspect} holds an empty, \".\", \"..\" or encoded \"/\" path segment"
        rescue ArgumentError
          "#{path.inspect} is not a valid path"
        end

        # Scheme, host and port compared after normalization (case, default port, IPv6 brackets),
        # and a path prefix compared segment by segment.
        def covers?(entry, target)
          return false unless entry

          entry[:scheme] == target[:scheme] && entry[:host] == target[:host] && entry[:port] == target[:port] &&
            (entry[:segments].empty? || target[:segments].first(entry[:segments].size) == entry[:segments])
        end

        # Returns { scheme:, host:, port:, segments: }, or nil for anything that is not a plain
        # http(s) URL: user info, a query, a fragment, or a "." or ".." path segment are refused
        # rather than interpreted.
        def normalize(url)
          uri = URI.parse(url.to_s.strip)
          return nil unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
          return nil if uri.userinfo || uri.query || uri.fragment

          segments = uri.path.to_s.split("/").reject(&:empty?)
          decoded = segments.map { |segment| URI.decode_www_form_component(segment) }
          return nil if decoded.any? { |segment| segment == "." || segment == ".." || segment.include?("/") }

          { scheme: uri.scheme.downcase, host: uri.hostname.downcase, port: uri.port, segments: decoded }
        rescue URI::Error, ArgumentError
          nil
        end

        def loopback_host?(host)
          host = host.to_s.downcase
          return true if host == "localhost"

          IPAddr.new(host).loopback?
        rescue IPAddr::Error
          false
        end
      end
    end
  end
end
