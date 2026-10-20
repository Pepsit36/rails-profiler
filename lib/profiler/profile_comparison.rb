# frozen_string_literal: true

require_relative "peers"
require_relative "peers/peer_proxy"
require_relative "profile_diff"

module Profiler
  # Loads two profiles, each from this instance or from a peer of config.peers, and diffs them.
  # The node is a name in config.peers (or blank / "local"); it is never a URL.
  module ProfileComparison
    NotFound = Class.new(Profiler::Error)

    class << self
      # Both nodes are resolved before any profile is read, so an unknown node fails
      # without a single outgoing call.
      def call(token_a, token_b, node_a: nil, node_b: nil)
        sources = [node_a, node_b].map { |node| source_for(node) }
        profile_a = sources[0].load(token_a)
        profile_b = sources[1].load(token_b)

        missing = []
        missing << "Profile not found: #{token_a}#{on_node(node_a)}" unless profile_a
        missing << "Profile not found: #{token_b}#{on_node(node_b)}" unless profile_b
        raise NotFound, missing.join("\n") if missing.any?

        ProfileDiff.new(profile_a, profile_b, node_a: label(node_a), node_b: label(node_b)).compute
      end

      private

      def source_for(node)
        Peers.local?(node) ? Profiler.storage : Peers::PeerProxy.new(node)
      end

      def label(node)
        Peers.local?(node) ? Peers::LOCAL_NODE : node.to_s
      end

      def on_node(node)
        Peers.local?(node) ? "" : " (node #{node})"
      end
    end
  end
end
