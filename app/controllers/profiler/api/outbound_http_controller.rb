# frozen_string_literal: true

module Profiler
  module Api
    class OutboundHttpController < ApplicationController
      # GET /_profiler/api/outbound_http
      def index
        limit = (params[:limit] || 200).to_i
        profiles = Profiler.storage.list(limit: limit)

        requests = profiles.flat_map do |profile|
          http_data = profile.collector_data("http")
          next [] unless http_data && http_data["requests"]&.any?

          http_data["requests"]
            .reject { |req| profiler_url?(req["url"].to_s) }
            .map { |req| req.merge("profile_token" => profile.token, "profile_started_at" => profile.started_at) }
        end

        requests.sort_by! { |r| r["profile_started_at"] }.reverse!

        render json: requests
      end

      private

      def profiler_url?(url)
        URI.parse(url).path.start_with?("/_profiler")
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
