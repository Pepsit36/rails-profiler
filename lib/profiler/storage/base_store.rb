# frozen_string_literal: true

require_relative "token"

module Profiler
  module Storage
    class BaseStore
      # Public interface: persists the profile then records the save, for the pages showing it
      # to see it changed (Profiler::SSE).
      # Subclasses implement #do_save, not #save. The token must be one the gem issued
      # (Storage::Token); every other public method answers "not found" for any other token.
      def save(token, profile)
        Token.validate!(token)
        result = do_save(token, profile)
        broadcast_event(token)
        result
      end

      def do_save(token, profile)
        raise NotImplementedError, "#{self.class} must implement #do_save"
      end

      def load(token)
        raise NotImplementedError, "#{self.class} must implement #load"
      end

      def list(limit: 50, offset: 0)
        raise NotImplementedError, "#{self.class} must implement #list"
      end

      def cleanup(older_than: 24 * 60 * 60)
        raise NotImplementedError, "#{self.class} must implement #cleanup"
      end

      def exists?(token)
        !load(token).nil?
      rescue StandardError => e
        Profiler.log_error_once(:store_exists, "#{self.class.name.split("::").last}: could not look up a profile", e)
        false
      end

      def find_by_parent(parent_token)
        raise NotImplementedError, "#{self.class} must implement #find_by_parent"
      end

      def delete(token)
        raise NotImplementedError, "#{self.class} must implement #delete"
      end

      def clear(type: nil)
        raise NotImplementedError, "#{self.class} must implement #clear"
      end

      private

      def broadcast_event(token)
        Profiler::SSE.current.broadcast(token)
      rescue StandardError => e
        # Never let a broadcast failure prevent profile persistence
        Profiler.log_error_once(:store_broadcast, "#{self.class.name.split("::").last}: could not announce a saved profile", e)
      end
    end
  end
end
