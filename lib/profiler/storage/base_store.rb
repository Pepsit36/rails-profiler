# frozen_string_literal: true

require_relative "token"

module Profiler
  module Storage
    class BaseStore
      # Public interface: persists the profile then records the save, for the pages showing it
      # to see it changed (Profiler::SSE). A job's save is also recorded for the profile that
      # enqueued it: the toolbar of that request lists its jobs, and has to see them start and end.
      # Subclasses implement #do_save, not #save. The token must be one the gem issued
      # (Storage::Token); every other public method answers "not found" for any other token.
      def save(token, profile)
        Token.validate!(token)
        result = do_save(token, profile)
        broadcast_event(token)
        broadcast_event(profile.parent_token) if job_with_parent?(profile)
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

      # The profiles sharing a trace id, oldest first.
      def find_by_trace(trace_id)
        raise NotImplementedError, "#{self.class} must implement #find_by_trace"
      end

      # The profiles that replay the profile +source_token+ (Profile#replay_of), oldest first.
      # Unlike parent_token, which links an AJAX call to its page and is indexed by each store,
      # replay_of is carried by the summary every store keeps for its lists, so one scan of the
      # summaries serves the four backends. Replays are rare and the scan is bounded by
      # max_profiles.
      def find_by_replay_of(source_token, page_size: 200)
        return [] unless Token.valid?(source_token)

        found = []
        offset = 0
        loop do
          page = list(limit: page_size, offset: offset, summary: true)
          found.concat(page.select { |profile| profile.replay_of == source_token })
          break if page.size < page_size

          offset += page_size
        end
        found.sort_by { |profile| profile.started_at || Time.at(0) }
      end

      def delete(token)
        raise NotImplementedError, "#{self.class} must implement #delete"
      end

      def clear(type: nil)
        raise NotImplementedError, "#{self.class} must implement #clear"
      end

      private

      # Not for an AJAX request linked to its page: the toolbar reads those on its own links.
      def job_with_parent?(profile)
        profile.profile_type == "job" && Token.valid?(profile.parent_token)
      end

      def broadcast_event(token)
        Profiler::SSE.current.broadcast(token)
      rescue StandardError => e
        # Never let a broadcast failure prevent profile persistence
        Profiler.log_error_once(:store_broadcast, "#{self.class.name.split("::").last}: could not announce a saved profile", e)
      end
    end
  end
end
