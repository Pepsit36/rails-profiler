# frozen_string_literal: true

require_relative "base_collector"
require_relative "../process_snapshot"

module Profiler
  module Collectors
    class EnvCollector < BaseCollector
      def icon
        "⚙️"
      end

      def priority
        90
      end

      def tab_config
        {
          key: "env",
          label: "Env",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      # ENV is the process's, not the request's: an HTTP profile keeps none of it, and the Env tab
      # shows the variables of the process that displays the profile, which is the one that served
      # the request (ProcessSnapshot). A job, a console expression or a test runs in another
      # process (Sidekiq, the console, rspec): its profile keeps that process's ENV, masked.
      def collect
        if @profile.profile_type.to_s == "http"
          store_data({ scope: "process" })
        else
          variables = Profiler::Redaction.env_snapshot
          store_data({ variables: variables, total: variables.size })
        end
      end

      def toolbar_summary
        { text: "#{ENV.size} vars", color: "gray" }
      end
    end
  end
end
