# frozen_string_literal: true

require "ipaddr"
require "uri"
require "active_support/security_utils"
require_relative "cluster/security"

module Profiler
  # Static, explicit list of other instances (config.peers) whose profiles can be read to be
  # compared with the local ones. Deliberately separate from the master/slave cluster: nothing
  # here is registered at runtime, and the URLs come from the operator's configuration only,
  # never from a request, an API parameter or an MCP tool argument.
  module Peers
    TOKEN_HEADER = "X-Profiler-Peer-Token"
    TOKEN_ENV_KEY = "HTTP_X_PROFILER_PEER_TOKEN"
    MIN_TOKEN_LENGTH = 32
    # The names that mean "this instance" in a node selector.
    LOCAL_NODE = "local"

    Peer = Struct.new(:name, :url)

    class << self
      # The validated peers, checked once per configured list (the list is static and trusted).
      # Raises Profiler::Error naming the first invalid entry.
      def all
        list = Profiler.configuration.peers
        return [] if list.nil? || list.empty?

        cache = @validated
        return cache[1] if cache && cache[0].equal?(list) && cache[2] == list.hash

        peers = validate!(list)
        @validated = [list, peers, list.hash]
        peers
      end

      def names
        all.map(&:name)
      end

      def local?(node)
        node.nil? || node.to_s.strip.empty? || node.to_s == LOCAL_NODE
      end

      # The peer called node, or a Profiler::Error. Never builds a peer from anything but config.peers.
      def find!(node)
        peers = all
        peer = peers.find { |p| p.name == node.to_s }
        return peer if peer

        known = peers.empty? ? "none configured (config.peers is empty)" : peers.map(&:name).join(", ")
        raise Profiler::Error, "Unknown node #{node.to_s.inspect}: it is not in config.peers (known nodes: #{known})"
      end

      # Why the configured token cannot be used, or nil when it can.
      def token_problem
        token = Profiler.configuration.peer_token.to_s
        return "No config.peer_token is configured" if token.strip.empty?
        return nil if token.strip.length >= MIN_TOKEN_LENGTH

        "config.peer_token is shorter than #{MIN_TOKEN_LENGTH} characters, so it is ignored as if none were configured"
      end

      def configured_token?
        token_problem.nil?
      end

      def outgoing_headers
        { TOKEN_HEADER => Profiler.configuration.peer_token.to_s }
      end

      # Constant-time comparison of the token a request carries; false when none is configured.
      def valid_token?(presented)
        return false unless configured_token?
        return false if presented.to_s.empty?

        ActiveSupport::SecurityUtils.secure_compare(presented.to_s, Profiler.configuration.peer_token.to_s)
      end

      def request_token_valid?(request)
        valid_token?(request.get_header(TOKEN_ENV_KEY))
      end

      # Logged once at boot when peers are configured without a usable token: every call to a
      # peer is then refused.
      def warn_about_configuration(logger)
        return if Profiler.configuration.peers.to_a.empty?
        return unless (problem = token_problem)

        Profiler.log_warn("Peers: #{problem}: comparing profiles across nodes is refused. Generate one with " \
                          "`ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'` and give the same value to " \
                          "every instance.", logger: logger)
      end

      def reset!
        @validated = nil
      end

      private

      def validate!(list)
        raise Profiler::Error, "config.peers must be an Array of { name:, url: }" unless list.is_a?(Array)

        peers = list.each_with_index.map { |entry, index| build_peer(entry, index) }
        duplicate = peers.map(&:name).tally.find { |_, count| count > 1 }
        raise Profiler::Error, "config.peers: the name #{duplicate[0].inspect} is used twice" if duplicate

        peers
      end

      def build_peer(entry, index)
        unless entry.respond_to?(:to_h) && !entry.is_a?(Array)
          raise Profiler::Error, "config.peers[#{index}] must be a Hash with :name and :url"
        end

        hash = entry.to_h.transform_keys(&:to_s)
        name = hash["name"].to_s.strip
        unless name.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/) && name != LOCAL_NODE
          raise Profiler::Error, "config.peers[#{index}]: name #{hash["name"].inspect} must be 1 to 64 letters, " \
                                 "digits, dots, dashes or underscores, and cannot be #{LOCAL_NODE.inspect}"
        end
        if (reason = url_denial(hash["url"]))
          raise Profiler::Error, "config.peers[#{index}] (#{name}): #{reason}"
        end

        Peer.new(name, Cluster::Security.normalized_url(hash["url"]).freeze)
      end

      # nil when the peer URL is acceptable: a plain http(s) URL, with HTTPS required unless the
      # host is a loopback address or config.peer_allow_insecure_http is set.
      def url_denial(url)
        target = Cluster::Security.normalize(url)
        return "#{url.inspect} is not a valid http(s) URL" unless target
        return nil if target[:scheme] == "https" || Cluster::Security.loopback_host?(target[:host])
        return nil if Profiler.configuration.peer_allow_insecure_http

        "#{url} uses plain HTTP to a host that is not a loopback address: HTTPS is required " \
          "(or set config.peer_allow_insecure_http = true)"
      end
    end
  end
end
