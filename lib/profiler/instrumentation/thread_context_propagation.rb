# frozen_string_literal: true

module Profiler
  module Instrumentation
    module ThreadContextPropagation
      PROPAGATED_KEYS = %i[
        profiler_http_collector
        profiler_flamegraph_collector
      ].freeze

      def initialize(*args, &block)
        parent_context = PROPAGATED_KEYS.filter_map do |key|
          val = Thread.current[key]
          [key, val] unless val.nil?
        end.to_h

        if parent_context.empty?
          super
        else
          super(*args) do
            parent_context.each { |k, v| Thread.current[k] = v }
            begin
              block&.call
            ensure
              PROPAGATED_KEYS.each { |k| Thread.current[k] = nil }
            end
          end
        end
      end
    end
  end
end

Thread.prepend(Profiler::Instrumentation::ThreadContextPropagation)
