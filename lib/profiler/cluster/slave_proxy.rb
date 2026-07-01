# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Profiler
  module Cluster
    class SlaveProxy
      # A slow or hung slave must not block the master's request thread for long.
      OPEN_TIMEOUT = 5  # seconds
      READ_TIMEOUT = 10 # seconds

      def initialize(slave_name, open_timeout: nil, read_timeout: nil)
        entry = Profiler.slave_registry.find!(slave_name)
        raise Profiler::Error, "Slave profiler '#{slave_name}' is offline" if entry.status == "offline"

        @base_url = entry.url.to_s.chomp("/")
        @open_timeout = open_timeout || OPEN_TIMEOUT
        @read_timeout = read_timeout || READ_TIMEOUT
      end

      # Storage-compatible interface for MCP query tools

      def list(limit: 50, offset: 0, **)
        # all_types mirrors Profiler.storage.list, which returns every profile type;
        # without it the proxy would only ever see http profiles (see ProfilesController#index).
        data = get_json("/_profiler/api/profiles", limit: limit, offset: offset, all_types: true)
        Array(data["profiles"]).map { |h| profile_from_api(h) }
      end

      def load(token)
        data = get_json("/_profiler/api/profiles/#{token}")
        return nil unless data["token"] || data["profile"]

        raw = data["profile"] || data
        profile_from_api(raw)
      end

      def find_by_parent(parent_token)
        data = get_json("/_profiler/api/profiles", parent_token: parent_token, all_types: true)
        Array(data["profiles"]).map { |h| profile_from_api(h) }
      end

      def clear(type: nil)
        params = type ? "?type=#{URI.encode_www_form_component(type)}" : ""
        delete_json("/_profiler/api/profiles/clear#{params}")
      end

      # Generic HTTP access for action tools

      def get_json(path, params = {})
        uri = build_uri(path, params)
        request(uri, Net::HTTP::Get.new(uri))
      end

      def post_json(path, body = {})
        request(*json_request(Net::HTTP::Post, path, body))
      end

      def patch_json(path, body = {})
        request(*json_request(Net::HTTP::Patch, path, body))
      end

      def delete_json(path)
        uri = build_uri(path)
        request(uri, Net::HTTP::Delete.new(uri))
      end

      private

      def build_uri(path, params = {})
        uri = URI("#{@base_url}#{path}")
        unless params.empty?
          uri.query = URI.encode_www_form(params.compact.transform_values(&:to_s))
        end
        uri
      end

      def json_request(klass, path, body)
        uri = build_uri(path)
        req = klass.new(uri)
        req["Content-Type"] = "application/json"
        req.body = body.to_json
        [uri, req]
      end

      def request(uri, req)
        resp = Net::HTTP.start(uri.hostname, uri.port,
                               open_timeout: @open_timeout, read_timeout: @read_timeout,
                               use_ssl: uri.scheme == "https") do |http|
          http.request(req)
        end
        return {} if resp.code == "204"

        parse_response(resp)
      end

      def parse_response(resp)
        return {} if resp.body.nil? || resp.body.empty?

        JSON.parse(resp.body)
      rescue JSON::ParserError
        { "raw" => resp.body }
      end

      def profile_from_api(hash)
        require_relative "../models/profile"
        # from_hash expects symbol keys at the top level
        Profiler::Models::Profile.from_hash(hash.transform_keys(&:to_sym))
      end
    end
  end
end
