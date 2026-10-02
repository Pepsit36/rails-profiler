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

        return super if parent_context.empty?

        # Thread.new hands its arguments to the block, so the wrapper has to take
        # them and pass them on. Ruby 3.4 depends on it in the stdlib: the Happy
        # Eyeballs hostname resolution of Socket.tcp runs
        #   Thread.new(*thread_args) { |*thread_args| resolve_hostname(*thread_args) }
        # and a wrapper that swallows the arguments leaves the name unresolved.
        # The wrapper is a named proc rather than a literal block because only a
        # proc can be given the ruby2_keywords flag, which, together with the one
        # on this method, keeps a trailing keyword hash a keyword hash rather than
        # flattening it into a positional argument.
        wrapper = proc do |*block_args|
          parent_context.each { |k, v| Thread.current[k] = v }
          begin
            block&.call(*block_args)
          ensure
            PROPAGATED_KEYS.each { |k| Thread.current[k] = nil }
          end
        end
        wrapper.ruby2_keywords

        super(*args, &wrapper)
      end
      ruby2_keywords :initialize
    end
  end
end

Thread.prepend(Profiler::Instrumentation::ThreadContextPropagation)
