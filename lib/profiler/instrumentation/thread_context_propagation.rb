# frozen_string_literal: true

module Profiler
  module Instrumentation
    module ThreadContextPropagation
      PROPAGATED_KEYS = %i[
        profiler_http_collector
        profiler_flamegraph_collector
      ].freeze

      def initialize(*args, &block)
        # Ruby refuses a Thread with no block, and the wrapper below is a block, so
        # without this the error would never come while a profile is being collected.
        return super if block.nil?

        parent_context = PROPAGATED_KEYS.filter_map do |key|
          val = Thread.current[key]
          [key, val] unless val.nil?
        end.to_h
        # The request's notification scope: the queries of a thread it starts are its own.
        scope = Profiler::Collectors::ScopedNotifications.current if defined?(Profiler::Collectors::ScopedNotifications)

        return super if parent_context.empty? && scope.nil?

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
          Profiler::Collectors::ScopedNotifications.adopt(scope) if scope
          begin
            block&.call(*block_args)
          ensure
            PROPAGATED_KEYS.each { |k| Thread.current[k] = nil }
            Profiler::Collectors::ScopedNotifications.adopt(nil) if scope
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
