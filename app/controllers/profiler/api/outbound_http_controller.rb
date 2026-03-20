# frozen_string_literal: true

module Profiler
  module Api
    class OutboundHttpController < ApplicationController
      skip_before_action :verify_authenticity_token

      # GET /_profiler/api/outbound_http
      def index
        limit = (params[:limit] || 200).to_i
        profiles = Profiler.storage.list(limit: limit)

        requests = profiles.flat_map do |profile|
          http_data = profile.collector_data("http")
          next [] unless http_data && http_data["requests"]&.any?

          http_data["requests"].map do |req|
            req.merge("profile_token" => profile.token, "profile_started_at" => profile.started_at)
          end
        end

        requests.sort_by! { |r| r["profile_started_at"] }.reverse!

        render json: requests
      end
    end
  end
end
