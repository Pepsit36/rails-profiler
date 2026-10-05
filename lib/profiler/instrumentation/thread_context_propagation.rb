# frozen_string_literal: true

require_relative "request_context"

module Profiler
  module Instrumentation
    # A thread the application starts while a request is profiled works for that request: it gets
    # the request's context (RequestContext) for the life of its block. A thread a pool creates
    # (concurrent-ruby, Puma) does not: it outlives the request, and the tasks it runs bring
    # their own context (ExecutorContextPropagation).
    module ThreadContextPropagation
      PROPAGATED_KEYS = RequestContext::KEYS

      def initialize(*args, &block)
        # Ruby refuses a Thread with no block, and the wrapper below is a block, so
        # without this the error would never come while a profile is being collected.
        return super if block.nil?

        context = RequestContext.capture
        return super if context.nil?
        return super(*args, &RequestContext.without_inherited(block)) if RequestContext.creating_pool_thread?

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
          RequestContext.with(context) { block&.call(*block_args) }
        end
        wrapper.ruby2_keywords

        super(*args, &wrapper)
      end
      ruby2_keywords :initialize
    end
  end
end

Thread.prepend(Profiler::Instrumentation::ThreadContextPropagation)
