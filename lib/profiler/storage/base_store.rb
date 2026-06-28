# frozen_string_literal: true

module Profiler
  module Storage
    class BaseStore
      # Public interface: persists the profile then fires an SSE broadcast.
      # Subclasses implement #do_save, not #save.
      def save(token, profile)
        result = do_save(token, profile)
        broadcast_event(token, profile)
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
      rescue
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

      def broadcast_event(token, profile)
        collectors = profile.collectors_data.keys
        Profiler::SSE.current.broadcast(token, collectors)
      rescue StandardError
        # Never let a broadcast failure prevent profile persistence
      end
    end
  end
end
