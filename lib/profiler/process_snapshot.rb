# frozen_string_literal: true

require_relative "redaction"

module Profiler
  # What is the same for every request of a process, kept out of the profiles: the route table
  # and ENV. A profile stores the route its request matched; the Routes and Env tabs, the
  # toolbar and the MCP tools get the table and the variables from the process that displays the
  # profile (#hydrate).
  #
  # The route table is built once and built again when the routes are reloaded, in development
  # (reload_routes!, or a change picked up by the reloader): the routes are new objects then.
  # ENV is read when the profile is displayed, masked as it always was: it can change while the
  # process runs, through the profiler's own env overrides among others.
  module ProcessSnapshot
    @mutex = Mutex.new
    @routes = nil # [fingerprint, table, index by [controller, action]]

    class << self
      # The application's routes, the engine's and Rails' own left out, as the Routes tab lists
      # them: { name:, pattern:, verb:, controller_action: }.
      def route_table
        routes_snapshot[1]
      end

      # The route of the table a request to +path+ with +method+ is dispatched to, or nil.
      def matched_route(path, method)
        return nil unless rails_routes?

        recognized = Rails.application.routes.recognize_path(path, method: method)
        routes_snapshot[2][[recognized[:controller], recognized[:action]]]
      rescue StandardError
        nil
      end

      # ENV as the Env tab shows it.
      def env_variables
        Redaction.hide_credentials(Redaction.env_snapshot)
      end

      # Puts the route table and ENV back into +profile+'s data for display. A profile saved by
      # a version before 0.31.1 has its own table and variables, and is left as it is.
      def hydrate(profile)
        return profile unless profile

        data = profile.collectors_data
        if (routes = data["routes"]) && !key?(routes, :routes)
          data["routes"] = with_route_table(routes)
        end
        if (env = data["env"]) && !key?(env, :variables)
          variables = env_variables
          data["env"] = merge(env, variables: variables, total: variables.size)
        end
        profile
      rescue StandardError => e
        warn "Profiler: could not add the routes and ENV to profile #{profile.token}: #{e.message}"
        profile
      end

      private

      def rails_routes?
        defined?(Rails) && Rails.respond_to?(:application) && Rails.application
      end

      def routes_snapshot
        return [nil, [].freeze, {}.freeze] unless rails_routes?

        journey = Rails.application.routes.routes
        list = journey.respond_to?(:routes) ? journey.routes : journey.to_a
        fingerprint = [journey.object_id, list.size, list.first&.object_id, list.last&.object_id]
        snapshot = @routes
        return snapshot if snapshot && snapshot[0] == fingerprint

        @mutex.synchronize do
          @routes = build_snapshot(fingerprint, list) unless @routes && @routes[0] == fingerprint
          @routes
        end
      rescue StandardError
        [nil, [].freeze, {}.freeze]
      end

      def build_snapshot(fingerprint, list)
        index = {}
        table = list.filter_map do |route|
          next if route.respond_to?(:internal) && route.internal

          controller = route.defaults[:controller]
          action = route.defaults[:action]
          next if controller.nil?
          next if controller.start_with?("rails/", "profiler/")

          verb = route.verb
          entry = {
            name: route.name,
            pattern: route.path.spec.to_s.sub(/\(\.:format\)$/, ""),
            verb: (verb && !verb.empty?) ? verb : "ANY",
            controller_action: controller_action(controller, action)
          }.freeze
          index[[controller, action]] ||= entry
          entry
        end
        [fingerprint, table.freeze, index.freeze]
      end

      def controller_action(controller, action)
        return nil unless action

        "#{controller.split("/").map { |s| ActiveSupport::Inflector.camelize(s) }.join("::")}Controller##{action}"
      end

      def with_route_table(routes)
        matched = fetch(routes, :matched)
        table = route_table.map { |route| route.merge(matched: same_route?(route, matched)) }
        merge(routes, routes: table, total: table.size)
      end

      def same_route?(route, matched)
        return false unless matched.is_a?(Hash)

        %i[pattern verb controller_action].all? { |field| route[field] == fetch(matched, field) }
      end

      # Collector data has symbol keys as collected, string keys once read back from storage.
      def key?(hash, key)
        hash.key?(key) || hash.key?(key.to_s)
      end

      def fetch(hash, key)
        hash.key?(key) ? hash[key] : hash[key.to_s]
      end

      def merge(hash, values)
        strings = hash.keys.first.is_a?(String)
        hash.merge(strings ? deep_stringify(values) : values)
      end

      def deep_stringify(value)
        case value
        when Hash then value.to_h { |k, v| [k.to_s, deep_stringify(v)] }
        when Array then value.map { |v| deep_stringify(v) }
        else value
        end
      end
    end
  end
end
