# frozen_string_literal: true

require "monitor"
require_relative "scoped_id_generator"

module Profiler
  module Otel
    # Finds or builds the OpenTelemetry SDK the profiler exports through. The only place that
    # requires "opentelemetry/..." and the only one that reaches the OpenTelemetry constants, and
    # it does so only once config.otel_enabled is true: the gem declares no dependency on
    # OpenTelemetry (like stackprof, it is optional), so an application that never heard of it
    # loads and profiles exactly as before. Written so that metrics can share it: +available?+,
    # +resource+ and the OTLP settings are not specific to traces.
    module Sdk
      LOCK = Monitor.new
      REQUIRES = ["opentelemetry/sdk", "opentelemetry/exporter/otlp"].freeze
      ENDPOINT_ENV = %w[OTEL_EXPORTER_OTLP_TRACES_ENDPOINT OTEL_EXPORTER_OTLP_ENDPOINT].freeze

      @state = nil

      class << self
        # The tracer provider spans are started from, nil when export is off or cannot work. Warns
        # once (Profiler.log_error) when it cannot; never raises.
        def tracer_provider
          return nil unless Profiler.configuration.otel_enabled

          state = @state || LOCK.synchronize { @state ||= setup_tracer_provider }
          state[:provider]
        rescue StandardError, LoadError => e
          LOCK.synchronize { @state = { provider: nil } }
          Profiler.log_error("OpenTelemetry export disabled: setup failed", e)
          nil
        end

        # Whether the SDK and the OTLP exporter can be loaded. Loads them (the sole place that
        # does), and says so in the log once if they cannot.
        def available?
          return @available unless @available.nil?

          LOCK.synchronize do
            return @available unless @available.nil?

            @available = load_gems
          end
        end

        # The attributes every signal of this process carries.
        def resource_attributes
          { "service.name" => Profiler.configuration.resolved_otel_service_name }
        end

        # The endpoint the profiler's own exporter posts to: otel_otlp_endpoint, else the standard
        # OTEL_EXPORTER_OTLP_* variables the exporter itself reads. nil when neither is set.
        def otlp_endpoint
          configured = Profiler.configuration.otel_otlp_endpoint.to_s.strip
          return configured unless configured.empty?

          ENDPOINT_ENV.each do |name|
            value = ENV[name].to_s.strip
            return value unless value.empty?
          end
          nil
        end

        # Forgets everything decided so far (the specs, and a configuration change).
        def reset!
          LOCK.synchronize do
            @state = nil
            @available = nil
          end
        end

        private

        def load_gems
          REQUIRES.each { |name| require name }
          true
        rescue LoadError => e
          Profiler.log_error(
            "config.otel_enabled is true but the OpenTelemetry gems are not available (#{e.message}); " \
            "add opentelemetry-sdk and opentelemetry-exporter-otlp to the application's Gemfile. " \
            "OpenTelemetry export is off."
          )
          false
        end

        def setup_tracer_provider
          return { provider: nil } unless available?

          existing = host_tracer_provider
          return { provider: scoped(existing) } if existing

          own = build_own_tracer_provider
          { provider: own && scoped(own) }
        end

        # The SDK provider the application initialised for itself, if any. The API's global
        # provider is a proxy until one is installed; its delegate is the SDK's.
        def host_tracer_provider
          provider = OpenTelemetry.tracer_provider
          provider = provider.delegate if provider.respond_to?(:delegate)
          sdk_provider?(provider) ? provider : nil
        end

        def sdk_provider?(provider)
          defined?(OpenTelemetry::SDK::Trace::TracerProvider) &&
            provider.is_a?(OpenTelemetry::SDK::Trace::TracerProvider)
        end

        # Our own provider, never installed as the global one: the application's OpenTelemetry
        # stays as it is. OTLP over http/protobuf, the protocol of opentelemetry-exporter-otlp.
        def build_own_tracer_provider
          endpoint = otlp_endpoint
          unless endpoint
            Profiler.log_error(
              "config.otel_enabled is true but there is no OpenTelemetry SDK in the application and " \
              "config.otel_otlp_endpoint is not set: OpenTelemetry export is off."
            )
            return nil
          end

          exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: endpoint)
          provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
            resource: OpenTelemetry::SDK::Resources::Resource.create(resource_attributes)
          )
          provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter))
          at_exit { provider.shutdown }
          provider
        end

        # The provider with its id generator wrapped, once.
        def scoped(provider)
          unless provider.respond_to?(:id_generator=)
            Profiler.log_error("OpenTelemetry export disabled: the tracer provider cannot take an id generator")
            return nil
          end

          unless provider.id_generator.is_a?(ScopedIdGenerator)
            provider.id_generator = ScopedIdGenerator.new(provider.id_generator)
          end
          provider
        end
      end
    end
  end
end
