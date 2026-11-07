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
        broadcast_ancestors(profile)
        result
      end

      # Something that changes whenever a profile is saved, by any process sharing the storage, and
      # that is cheap to read: the live event stream only looks at the profiles once it moved.
      # The announced saves of the event bus count for the stores that are not shared through a
      # file; a store that is overrides this.
      def live_marker
        Profiler::SSE.current.generation
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

      # A job's save is recorded for the profile that enqueued it and, going up, for each job that
      # enqueued that one: the toolbar of the request lists the whole chain.
      MAX_ANCESTORS = 5

      def broadcast_ancestors(profile)
        current = profile
        MAX_ANCESTORS.times do
          break unless job_with_parent?(current)

          broadcast_event(current.parent_token)
          current = load(current.parent_token)
          break if current.nil?
        end
      rescue StandardError => e
        Profiler.log_error_once(:store_broadcast_ancestors, "#{self.class.name.split("::").last}: could not announce a saved job to the profiles above it", e)
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
