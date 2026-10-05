# frozen_string_literal: true

require "concurrent"
require_relative "request_context"

module Profiler
  module Instrumentation
    # A task posted to a concurrent-ruby executor while a request is profiled runs in that
    # request's context, whichever pool thread runs it and whenever: Concurrent::Promises,
    # Concurrent::Future, ActiveJob's :async adapter and ActionController::Live all post their
    # work this way. The pool thread has its own context back once the task returns.
    module ExecutorContextPropagation
      def post(*args, &task)
        return super if task.nil?

        context = RequestContext.capture
        return super if context.nil?

        wrapper = proc do |*task_args|
          RequestContext.with(context) { task.call(*task_args) }
        end
        wrapper.ruby2_keywords
        super(*args, &wrapper)
      end
      ruby2_keywords :post

      # The executors that define post themselves; the others inherit it from one of them.
      EXECUTORS = %w[
        Concurrent::RubyExecutorService
        Concurrent::SimpleExecutorService
        Concurrent::TimerSet
        Concurrent::SerializedExecutionDelegator
      ].freeze

      def self.install!
        EXECUTORS.each do |name|
          executor = Object.const_get(name)
          executor.prepend(self) unless executor.ancestors.include?(self)
        rescue NameError
          next # not in this version of concurrent-ruby
        end
      end
    end
  end
end

Profiler::Instrumentation::ExecutorContextPropagation.install!
