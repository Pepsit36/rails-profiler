# frozen_string_literal: true

module Profiler
  # GET /_profiler/health: the state of the circuit of each collector (see
  # Profiler::Collectors::CircuitBreaker), as a page or, with a .json suffix or an Accept
  # header, as JSON. Always 200: an open circuit means a collector is left out of the profiles,
  # not that the profiler or the application is down, and a 503 would trip any probe pointed at it.
  class HealthController < ApplicationController
    def show
      @enabled = Profiler.configuration.collector_circuit_breaker_enabled ? true : false
      @threshold = Profiler.configuration.collector_circuit_breaker_threshold
      @collectors = Profiler.configuration.collectors.map do |collector_class|
        Collectors::CircuitBreaker.status(collector_class).merge(name: collector_class.name.to_s)
      end

      respond_to do |format|
        format.html
        format.json do
          render json: {
            circuit_breaker: { enabled: @enabled, threshold: @threshold },
            collectors: @collectors
          }
        end
      end
    end
  end
end
