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

      class << self
        # Whether a secret has to be presented. False only with cluster_require_secret = false
        # and no cluster_secret, the behaviour of 0.30.6.
        def secret_required?
          config = Profiler.configuration
          config.cluster_require_secret || configured_secret?
        end

        def configured_secret?
          !Profiler.configuration.cluster_secret.to_s.empty?
        end

        # Constant-time comparison of the secret a request carries with the configured one.
        # Always false when no secret is configured.
        def valid_secret?(presented)
          expected = Profiler.configuration.cluster_secret.to_s
          return false if expected.empty? || presented.to_s.empty?

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
