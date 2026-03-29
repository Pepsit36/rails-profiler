# frozen_string_literal: true

require_relative "base_collector"

module Profiler
  module Collectors
    class RequestCollector < BaseCollector
      def icon
        "🌐"
      end

      def priority
        10
      end

      def tab_config
        {
          key: "request",
          label: "Request",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def collect
        data = {
          path: @profile.path,
          method: @profile.method,
          status: @profile.status,
          duration: @profile.duration,
          memory: @profile.memory,
          params: @profile.params,
          headers: @profile.headers,
          response_headers: @profile.response_headers,
          request_body: @profile.request_body,
          request_body_encoding: @profile.request_body_encoding,
          response_body: @profile.response_body,
          response_body_encoding: @profile.response_body_encoding,
          started_at: @profile.started_at&.iso8601,
          finished_at: @profile.finished_at&.iso8601
        }

        store_data(data)
      end

      def toolbar_summary
        status_color = case @profile.status
                      when 200..299 then "green"
                      when 300..399 then "blue"
                      when 400..499 then "orange"
                      when 500..599 then "red"
                      else "gray"
                      end

        {
          text: "#{@profile.method} #{@profile.status}",
          color: status_color,
          duration: @profile.duration,
          memory: format_memory(@profile.memory)
        }
      end

      private

      def format_memory(bytes)
        return "0 B" unless bytes

        if bytes < 1024
          "#{bytes} B"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(2)} KB"
        else
          "#{(bytes / 1024.0 / 1024.0).round(2)} MB"
        end
      end
    end
  end
end
