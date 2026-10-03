# frozen_string_literal: true

require "ipaddr"

module Profiler
  # Decides whether a request comes from this machine, for authorization_mode :allow_local.
  #
  # The client address is read from REMOTE_ADDR only. Forwarding headers (X-Forwarded-For,
  # X-Real-IP, Forwarded, X-Forwarded-Host) can be forged, so they never grant access: they
  # can only refuse it, when a local reverse proxy reports a remote client. The Host header
  # has to be a local name, or one the application allows in config.hosts, which defeats DNS
  # rebinding: a rebound page reaches 127.0.0.1 under the attacker's own domain name. The
  # test environment skips that Host check: rebinding needs a browser visiting the server,
  # and the application's own request specs send Host www.example.com.
  module LocalRequest
    FORWARDING_HEADERS = {
      "HTTP_X_FORWARDED_FOR" => "X-Forwarded-For",
      "HTTP_X_REAL_IP" => "X-Real-IP",
      "HTTP_FORWARDED" => "Forwarded"
    }.freeze

    @warned = false
    @warn_mutex = Mutex.new

    class << self
      # Returns nil when the request is local, otherwise a sentence naming the cause.
      def denial_reason(request)
        remote_addr = request.get_header("REMOTE_ADDR").to_s
        unless loopback_address?(remote_addr)
          return "REMOTE_ADDR #{remote_addr.empty? ? "(missing)" : remote_addr} is not a loopback address"
        end

        FORWARDING_HEADERS.each do |key, name|
          value = request.get_header(key)
          next if value.nil? || value.empty?

          nodes = key == "HTTP_FORWARDED" ? forwarded_param(value, "for") : value.split(",")
          remote = nodes.map { |node| strip_port(node) }.find { |address| !loopback_address?(address) }
          return "the #{name} header reports a non-local client (#{remote})" if remote
        end

        host_denial_reason(request) unless test_environment?
      end

      def local?(request)
        denial_reason(request).nil?
      end

      # Logs why a request was refused, once per process, so that an application running in
      # Docker does not just stop being profiled with no explanation.
      def warn_once(reason)
        @warn_mutex.synchronize do
          return if @warned

          @warned = true
        end

        message = "[Profiler] Request refused or not profiled by authorization_mode :allow_local: #{reason}. " \
                  "The profiler only serves and captures requests made from this machine. " \
                  "If the application runs in Docker or behind a remote proxy, either set " \
                  "config.authorization_mode = :allow_authorized with a config.authorize_with block " \
                  "that admits your network (see the Access control section of the README), or set " \
                  "config.authorization_mode = :allow_all, which offers no protection at all. " \
                  "This message is logged once per process."
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.warn(message)
        else
          warn(message)
        end
      end

      def reset_warning!
        @warn_mutex.synchronize { @warned = false }
      end

      def loopback_address?(value)
        address = value.to_s.strip.delete_prefix("[").delete_suffix("]").sub(/%.*\z/, "")
        return false if address.empty?

        ip = IPAddr.new(address)
        ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
        ip.loopback?
      rescue IPAddr::Error
        false
      end

      private

      def host_denial_reason(request)
        # A request with no Host header does not come from a browser, so it cannot be a
        # rebound page; REMOTE_ADDR alone decides.
        raw_host = request.get_header("HTTP_HOST").to_s
        unless raw_host.empty?
          host = host_name(raw_host)
          return "the Host header #{host.inspect} is not a local name" unless allowed_host?(host)
        end

        forwarded_hosts = request.get_header("HTTP_X_FORWARDED_HOST").to_s.split(",")
        remote = forwarded_hosts.map { |h| host_name(h) }.find { |h| !allowed_host?(h) }
        return "the X-Forwarded-Host header #{remote.inspect} is not a local name" if remote

        forwarded = request.get_header("HTTP_FORWARDED").to_s
        remote = forwarded_param(forwarded, "host").map { |h| host_name(h) }.find { |h| !allowed_host?(h) }
        return "the Forwarded header names a non-local host (#{remote.inspect})" if remote

        nil
      end

      def test_environment?
        defined?(Rails) && Rails.respond_to?(:env) && Rails.env.test?
      end

      # Values of one parameter (for=, host=) of a Forwarded header (RFC 7239), quotes removed.
      def forwarded_param(value, param)
        value.split(/[,;]/).filter_map do |pair|
          name, node = pair.split("=", 2)
          next unless name.to_s.strip.casecmp?(param)

          node.to_s.strip.delete_prefix('"').delete_suffix('"')
        end
      end

      # "127.0.0.1:5555" -> "127.0.0.1", "[::1]:5555" -> "::1", "::1" -> "::1",
      # "localhost:3000" -> "localhost". A bare IPv6 address has more than one colon.
      def strip_port(value)
        value = value.to_s.strip
        if value.start_with?("[")
          value[1...(value.index("]") || value.length)]
        elsif value.count(":") == 1
          value.split(":", 2).first
        else
          value
        end
      end

      def host_name(value)
        strip_port(value).downcase.chomp(".")
      end

      def allowed_host?(host)
        return false if host.empty?
        return true if host == "localhost" || host.end_with?(".localhost")
        return true if loopback_address?(host)

        permitted_by_rails_hosts?(host)
      end

      # When the application restricts config.hosts, ActionDispatch::HostAuthorization has
      # already refused every other host; a host it lists is one the developer trusts.
      def permitted_by_rails_hosts?(host)
        return false unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application
        return false unless defined?(ActionDispatch::HostAuthorization::Permissions)

        hosts = Rails.application.config.hosts
        return false if hosts.nil? || hosts.empty?

        ActionDispatch::HostAuthorization::Permissions.new(hosts).allows?(host)
      end
    end
  end
end
