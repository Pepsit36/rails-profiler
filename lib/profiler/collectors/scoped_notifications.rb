# frozen_string_literal: true

require_relative "../current_context"

module Profiler
  module Collectors
    # ActiveSupport::Notifications subscriptions scoped to the request that made them.
    #
    # The notifications bus is process-wide: a collector subscribed on it directly receives the
    # events of every thread, another request's SQL included. Here the process holds one
    # subscriber per event name, whatever the number of requests being profiled, and hands each
    # event to the handlers of the execution context that emitted it only.
    #
    # The context is ActiveSupport::IsolatedExecutionState, which Rails itself scopes its
    # connections and instrumenters to: a thread, or a fiber with
    # config.active_support.isolation_level = :fiber. ActionController::Live shares it with the
    # thread it runs the action in, and ThreadContextPropagation hands it to the threads a request
    # starts. A thread with no scope of its own that carries a profile's token
    # (Profiler::CurrentContext), as a server thread iterating a streamed body does, gets the scope
    # opened under that token. A scope lasts until its last handler is released, after the
    # response body is closed for a streamed response, wherever that release runs; the next
    # request of the thread then opens a new one, so a thread still holding the old scope, or the
    # old token, receives nothing more.
    module ScopedNotifications
      STATE_KEY = :profiler_notification_scope

      # The handlers of one request, by event name.
      class Scope
        attr_reader :token

        def initialize(token = nil)
          @token = token
          @mutex = Mutex.new
          @handlers = {}
          @size = 0
          @closed = false
        end

        def closed?
          @closed
        end

        def handlers_for(event)
          @handlers[event]
        end

        # False when the scope was closed meanwhile: the caller opens a new one.
        def add(event, handler)
          @mutex.synchronize do
            return false if @closed

            @handlers[event] = [*@handlers[event], handler].freeze
            @size += 1
            true
          end
        end

        # nil when the handler was not there (released already), :last when it was the scope's
        # last one, :removed otherwise.
        def remove(event, handler)
          @mutex.synchronize do
            list = @handlers[event]
            return nil unless list&.any? { |h| h.equal?(handler) }

            rest = list.reject { |h| h.equal?(handler) }
            rest.empty? ? @handlers.delete(event) : @handlers[event] = rest.freeze
            @size -= 1
            @closed = @size.zero?
            @closed ? :last : :removed
          end
        end
      end

      Handle = Struct.new(:scope, :event, :handler)

      @mutex = Mutex.new
      @subscribers = {} # event name => [subscriber, handler count]
      @by_token = {}.freeze # profile token => the scope opened under it, replaced on write

      class << self
        # Calls +handler+ with (name, started, finished, id, payload), monotonic times, for each
        # +event+ the current execution context emits until the handle is unsubscribed.
        def subscribe(event, &handler)
          # The process subscriber first: when the notifier fails, nothing was added to the scope.
          retain(event)
          scope = current_scope
          scope = open_scope until scope.add(event, handler)
          Handle.new(scope, event, handler)
        end

        # Safe from any thread, and more than once.
        def unsubscribe(handle)
          return unless handle

          removed = handle.scope.remove(handle.event, handle.handler)
          return unless removed

          release(handle.event)
          close_scope(handle.scope) if removed == :last
        end

        # The current context's scope, for ThreadContextPropagation to hand to a new thread.
        def current
          scope = state[STATE_KEY]
          scope unless scope.nil? || scope.closed?
        end

        # The scope the current context's events go to.
        def routed_scope
          scope = state[STATE_KEY]
          return scope unless scope.nil? || scope.closed?

          token = CurrentContext.token
          @by_token[token] if token
        end

        def adopt(scope)
          state[STATE_KEY] = scope
        end

        private

        def state
          defined?(ActiveSupport::IsolatedExecutionState) ? ActiveSupport::IsolatedExecutionState : Thread.current
        end

        def current_scope
          current || open_scope
        end

        def open_scope
          token = CurrentContext.token
          scope = Scope.new(token)
          if token
            @mutex.synchronize { @by_token = @by_token.merge(token => scope).freeze }
          end
          state[STATE_KEY] = scope
        end

        def close_scope(scope)
          state[STATE_KEY] = nil if state[STATE_KEY].equal?(scope)
          return unless scope.token

          @mutex.synchronize do
            @by_token = @by_token.reject { |_, s| s.equal?(scope) }.freeze if @by_token[scope.token].equal?(scope)
          end
        end

        def retain(event)
          @mutex.synchronize do
            entry = (@subscribers[event] ||= [subscribe_process(event), 0])
            entry[1] += 1
          end
        end

        def release(event)
          @mutex.synchronize do
            entry = @subscribers[event]
            return unless entry

            entry[1] -= 1
            return unless entry[1] <= 0

            ActiveSupport::Notifications.unsubscribe(entry[0])
            @subscribers.delete(event)
          end
        end

        def subscribe_process(event)
          ActiveSupport::Notifications.monotonic_subscribe(event) do |name, started, finished, id, payload|
            routed_scope&.handlers_for(event)&.each do |handler|
              handler.call(name, started, finished, id, payload)
            rescue StandardError => e
              # Never into the application's query, nor at the expense of the other collectors.
              warn "Profiler: a collector failed on #{event}: #{e.class}: #{e.message}"
            end
          end
        end
      end
    end
  end
end
