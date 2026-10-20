# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "../instrumentation/request_context"
require_relative "../collectors/scoped_notifications"

module Profiler
  module Alerts
    # POSTs an alert as JSON, from a thread of its own started detached from the request: it must
    # not hold the request's collectors nor record its own HTTP call into the profile. Errors are
    # logged, never raised.
    module Webhook
      module_function

      def post(alert, url, timeout)
        return if url.nil? || url.to_s.empty?

        Instrumentation::RequestContext.detached do
          Thread.new do
            Collectors::ScopedNotifications.forget_inherited_scope
            send_request(url, alert, timeout)
          end
        end
      rescue StandardError => e
        Profiler.log_error("Alerts: could not start the webhook for #{alert[:type]}", e)
      end

      def send_request(url, alert, timeout)
        response = http_for(URI.parse(url.to_s), timeout).request(request_for(url, alert))
        return if response.is_a?(Net::HTTPSuccess)

        Profiler.log_error("Alerts: webhook answered #{response.code} for #{alert[:type]}")
      rescue StandardError => e
        Profiler.log_error("Alerts: webhook failed for #{alert[:type]}", e)
      end

      def http_for(uri, timeout)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = http.read_timeout = http.write_timeout = timeout
        http
      end

      def request_for(url, alert)
        request = Net::HTTP::Post.new(URI.parse(url.to_s).request_uri, "Content-Type" => "application/json")
        request.body = JSON.generate(alert)
        request
      end
    end
  end
end
