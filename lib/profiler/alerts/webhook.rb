# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Profiler
  module Alerts
    # POSTs an alert as JSON. Called from the detached thread of Alerts.check, which holds nothing
    # of the request, so its own HTTP call is not recorded into a profile and it never delays the
    # request. Errors are logged, never raised.
    module Webhook
      module_function

      # The URL as a String, nil when none is given. Raises ArgumentError for a URL that cannot be
      # called: not http(s), no host, or credentials in it (never sent, so refused).
      def validate!(value)
        return nil if value.nil? || value.to_s.strip.empty?

        uri = URI.parse(value.to_s.strip)
        unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
          raise ArgumentError, "config.alert_webhook_url: #{value.to_s.inspect} must be an http(s) URL with a host"
        end
        if uri.userinfo
          raise ArgumentError, "config.alert_webhook_url: credentials in the URL are not sent; " \
                               "put the secret in the path or a query parameter of the receiver"
        end
        uri.to_s
      rescue URI::InvalidURIError
        raise ArgumentError, "config.alert_webhook_url: #{value.to_s.inspect} is not a valid URL"
      end

      def post(alert, url, timeout)
        return if url.nil? || url.to_s.empty?

        send_request(url, alert, timeout)
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
