# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "../peers"
require_relative "../storage/token"

module Profiler
  module Peers
    # Reads one profile from a peer listed in config.peers, through its /_profiler/api. The only
    # target is the URL of the configuration entry found by name: no URL is ever taken as an argument.
    class PeerProxy
      # Same budget as Cluster::SlaveProxy: a slow peer must not hold the request thread for long.
      OPEN_TIMEOUT = 5  # seconds
      READ_TIMEOUT = 10 # seconds

      attr_reader :name

      def initialize(node, open_timeout: nil, read_timeout: nil)
        peer = Peers.find!(node)
        if (problem = Peers.token_problem)
          raise Profiler::Error, "#{problem}: requests to peer #{peer.name.inspect} are refused"
        end

        @name = peer.name
        @base_url = peer.url.to_s.chomp("/")
        @open_timeout = open_timeout || OPEN_TIMEOUT
        @read_timeout = read_timeout || READ_TIMEOUT
      end

      # nil when the peer has no such profile. A token the gem could not have issued is not
      # asked for.
      def load(token)
        return nil unless Storage::Token.valid?(token)

        data = get_json("/_profiler/api/profiles/#{Cluster::Security.escape_segment(token)}")
        return nil if data.nil?
        raise Profiler::Error, "Peer #{@name.inspect} sent an unexpected answer" unless data.is_a?(Hash) && data["token"]

        require_relative "../models/profile"
        Profiler::Models::Profile.from_hash(data.transform_keys(&:to_sym))
      end

      private

      def get_json(path)
        if (reason = Cluster::Security.api_path_denial(path))
          raise Profiler::Error, "Refusing to send a request to peer #{@name.inspect}: #{reason}"
        end

        uri = URI("#{@base_url}#{path}")
        req = Net::HTTP::Get.new(uri)
        req[Profiler::FORGERY_PROTECTION_HEADER] = "1"
        Peers.outgoing_headers.each { |header, value| req[header] = value }
        # The profiler's own call, never recorded in the profile of the request that makes it.
        resp = Profiler.untracked_http do
          Net::HTTP.start(uri.hostname, uri.port, open_timeout: @open_timeout, read_timeout: @read_timeout,
                                                  use_ssl: uri.scheme == "https") { |http| http.request(req) }
        end
        interpret(resp)
      rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, IOError => e
        raise Profiler::Error, "Peer #{@name.inspect} is unreachable (#{e.class}: #{e.message})"
      end

      # Net::HTTP never follows a redirect: a 3xx is reported rather than read as an answer.
      def interpret(resp)
        code = resp.code.to_s
        return nil if code == "404"
        raise Profiler::Error, "Peer #{@name.inspect} answered #{code} (redirect not followed)" if code.start_with?("3")
        if %w[401 403].include?(code)
          raise Profiler::Error, "Peer #{@name.inspect} refused the request (#{code}): check that both instances " \
                                 "share the same config.peer_token"
        end
        raise Profiler::Error, "Peer #{@name.inspect} answered #{code}" unless code == "200"

        JSON.parse(resp.body.to_s)
      rescue JSON::ParserError
        raise Profiler::Error, "Peer #{@name.inspect} answered something that is not JSON"
      end
    end
  end
end
