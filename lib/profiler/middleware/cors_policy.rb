# frozen_string_literal: true

module Profiler
  module Middleware
    # Validation of CORS configuration at boot time.
    module CorsPolicy
      module_function

      # Logged once at boot when cors_allowed_origins contains "*", which is dangerous.
      def warn_about_configuration(logger)
        return unless Profiler.configuration.extension_cors_enabled
        return unless Array(Profiler.configuration.cors_allowed_origins).include?("*")

        Profiler.log_warn(
          "CORS: '*' (wildcard origin) is set in cors_allowed_origins, which allows any website to access " \
          "the profiler if a visitor browses the profiler. Set cors_allowed_origins to specific origins instead.",
          logger: logger
        )
      end
    end
  end
end
