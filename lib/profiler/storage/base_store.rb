# frozen_string_literal: true

module Profiler
  module Storage
    class BaseStore
      def save(token, profile)
        raise NotImplementedError, "#{self.class} must implement #save"
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
    end
  end
end
