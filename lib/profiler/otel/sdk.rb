# frozen_string_literal: true

require "monitor"
require_relative "scoped_id_generator"

module Profiler
  module Otel
    # Finds or builds the OpenTelemetry SDK the profiler exports through. The only place that
    # requires "opentelemetry/..." and the only one that reaches the OpenTelemetry constants, and
    # it does so only once config.otel_enabled is true: the gem declares no dependency on
    # OpenTelemetry (like stackprof, it is optional), so an application that never heard of it
    # loads and profiles exactly as before. Traces and metrics share it: the detection of the
    # application's own provider, the resource and the OTLP settings are the same, only the gems
    # and the provider class differ (see SIGNALS). Each signal is decided on its own, so the
    # trace gems without the metrics ones (or the reverse) gives one signal and a warning for the
    # other.
    module Sdk
      LOCK = Monitor.new

      # What differs between the signals: the gems to load, the API's global provider accessor,
      # the SDK class of a provider, and the standard endpoint variables.
      SIGNALS = {
        traces: {
          requires: ["opentelemetry/sdk", "opentelemetry/exporter/otlp"],
          gems: "opentelemetry-sdk and opentelemetry-exporter-otlp",
          endpoint_env: %w[OTEL_EXPORTER_OTLP_TRACES_ENDPOINT OTEL_EXPORTER_OTLP_ENDPOINT].freeze
        },
        metrics: {
          requires: ["opentelemetry/sdk", "opentelemetry-metrics-sdk", "opentelemetry/exporter/otlp_metrics"],
          gems: "opentelemetry-metrics-api, opentelemetry-metrics-sdk and opentelemetry-exporter-otlp-metrics " \
                "(alpha, pin an exact version of each)",
          endpoint_env: %w[OTEL_EXPORTER_OTLP_METRICS_ENDPOINT OTEL_EXPORTER_OTLP_ENDPOINT].freeze
        }
      }.freeze
      ENDPOINT_ENV = SIGNALS.dig(:traces, :endpoint_env)

      @state = {}
      @available = {}

      class << self
        # The tracer provider spans are started from, nil when export is off or cannot work. Warns
        # once (Profiler.log_error) when it cannot; never raises.
        def tracer_provider
          provider_for(:traces) { setup(:traces, :host_tracer_provider, :build_own_tracer_provider) { |p| scoped(p) } }
        end

        # The meter provider metrics are recorded with, nil when export is off or cannot work. The
        # application's SDK MeterProvider when it has one, else our own, never installed globally.
        def meter_provider
          provider_for(:metrics) { setup(:metrics, :host_meter_provider, :build_own_meter_provider) }
        end

        # Whether the SDK and the OTLP exporter of a signal can be loaded. Loads them (the sole
        # place that does), and says so in the log once if they cannot.
        def available?(signal = :traces)
          return @available[signal] unless @available[signal].nil?

          LOCK.synchronize do
            return @available[signal] unless @available[signal].nil?

            @available[signal] = load_gems(signal)
          end
        end

        # The attributes every signal of this process carries.
        def resource_attributes
          { "service.name" => Profiler.configuration.resolved_otel_service_name }
        end

        # The endpoint the profiler's own exporter posts to: otel_otlp_endpoint, else the standard
        # OTEL_EXPORTER_OTLP_* variables the exporter itself reads. nil when neither is set.
        def otlp_endpoint(signal = :traces)
          configured = Profiler.configuration.otel_otlp_endpoint.to_s.strip
          unless configured.empty?
            # One setting serves both signals: the traces path means the metrics one.
            return signal == :metrics ? configured.sub(%r{/v1/traces/?\z}, "/v1/metrics") : configured
          end

          SIGNALS.fetch(signal)[:endpoint_env].each do |name|
            value = ENV[name].to_s.strip
            return value unless value.empty?
          end
          nil
        end

        # Forgets everything decided so far (the specs, and a configuration change).
        def reset!
          LOCK.synchronize do
            @state = {}
            @available = {}
          end
        end

        private

        # The provider of a signal: nil when export is off, decided once (in the block), nil with
        # one logged error when the setup raises.
        def provider_for(signal)
          return nil unless Profiler.configuration.otel_enabled

          state = @state[signal] || LOCK.synchronize { @state[signal] ||= yield }
          state[:provider]
        rescue StandardError, LoadError => e
          LOCK.synchronize { @state[signal] = { provider: nil } }
          Profiler.log_error("OpenTelemetry #{signal} export disabled: setup failed", e)
          nil
        end

        def load_gems(signal)
          SIGNALS.fetch(signal)[:requires].each { |name| require name }
          true
        rescue LoadError => e
          Profiler.log_error(
            "config.otel_enabled is true but the OpenTelemetry #{signal} gems are not available " \
            "(#{e.message}); add #{SIGNALS.fetch(signal)[:gems]} to the application's Gemfile. " \
            "OpenTelemetry #{signal} export is off."
          )
          false
        end

        # The host's provider when it has one (then prepared by the block, if any), else our own.
        def setup(signal, host_finder, builder)
          return { provider: nil } unless available?(signal)

          provider = send(host_finder) || send(builder)
          provider = yield(provider) if provider && block_given?
          { provider: provider }
        end

        # The SDK provider the application initialised for itself, if any. The API's global
        # provider is a proxy until one is installed; its delegate is the SDK's.
        def host_tracer_provider
          provider = OpenTelemetry.tracer_provider
          provider = provider.delegate if provider.respond_to?(:delegate)
          provider if defined?(OpenTelemetry::SDK::Trace::TracerProvider) &&
                      provider.is_a?(OpenTelemetry::SDK::Trace::TracerProvider)
        end

        def host_meter_provider
          provider = OpenTelemetry.meter_provider
          provider = provider.delegate if provider.respond_to?(:delegate)
          provider if defined?(OpenTelemetry::SDK::Metrics::MeterProvider) &&
                      provider.is_a?(OpenTelemetry::SDK::Metrics::MeterProvider)
        end

        # The endpoint of our own exporter, nil (after one logged error) when there is none.
        def endpoint_or_warn(signal)
          endpoint = otlp_endpoint(signal)
          return endpoint if endpoint

          Profiler.log_error(
            "config.otel_enabled is true but there is no OpenTelemetry SDK in the application and " \
            "config.otel_otlp_endpoint is not set: OpenTelemetry #{signal} export is off."
          )
          nil
        end

        def resource
          OpenTelemetry::SDK::Resources::Resource.create(resource_attributes)
        end

        # Our own provider, never installed as the global one: the application's OpenTelemetry
        # stays as it is. OTLP over http/protobuf, the protocol of opentelemetry-exporter-otlp.
        def build_own_tracer_provider
          endpoint = endpoint_or_warn(:traces) or return nil

          exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: endpoint)
          provider = OpenTelemetry::SDK::Trace::TracerProvider.new(resource: resource)
          provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter))
          at_exit { provider.shutdown }
          provider
        end

        # Same, for metrics: a periodic reader pushes what was recorded to the OTLP metrics exporter.
        def build_own_meter_provider
          endpoint = endpoint_or_warn(:metrics) or return nil

          exporter = OpenTelemetry::Exporter::OTLP::Metrics::MetricsExporter.new(endpoint: endpoint)
          provider = OpenTelemetry::SDK::Metrics::MeterProvider.new(resource: resource)
          provider.add_metric_reader(OpenTelemetry::SDK::Metrics::Export::PeriodicMetricReader.new(exporter: exporter))
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
