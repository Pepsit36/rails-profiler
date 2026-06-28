# frozen_string_literal: true

require_relative "../../../../lib/profiler/cluster/slave_proxy"

module Profiler
  module Api
    class SlaveProxyController < Profiler::ApplicationController
      skip_before_action :verify_authenticity_token

      def forward
        proxy = Cluster::SlaveProxy.new(params[:slave_name])
        sub_path = params[:path].to_s
        full_path = "/_profiler/api/#{sub_path}"

        result = case request.method
                 when "GET"
                   proxy.get_json(full_path, request.query_parameters.to_h)
                 when "POST"
                   proxy.post_json(full_path, parsed_body)
                 when "PATCH"
                   proxy.patch_json(full_path, parsed_body)
                 when "DELETE"
                   proxy.delete_json(full_path)
                 else
                   return head :method_not_allowed
                 end

        render json: result
      rescue Profiler::Error => e
        render json: { error: e.message }, status: :bad_gateway
      rescue => e
        render json: { error: "Proxy error: #{e.message}" }, status: :bad_gateway
      end

      private

      def parsed_body
        return {} if request.body.nil?

        raw = request.body.read
        return {} if raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
