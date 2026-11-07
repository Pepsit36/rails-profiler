# frozen_string_literal: true

require "digest"

module Profiler
  module Live
    # What a page shows of a profile and of everything under it (the AJAX calls and the jobs it
    # started, and their own jobs): a short opaque string that changes when any of it does. Read
    # from the storage, so a save made by another process (a Sidekiq worker) is seen like any other.
    module Signature
      MAX_DEPTH = 5
      MAX_PROFILES = 100
      GONE = "gone"

      def self.of(storage, token)
        seen = {}
        walk(storage, token, 0, seen)
        return GONE if seen.empty?

        Digest::SHA1.hexdigest(seen.sort.inspect)[0, 16]
      rescue StandardError => e
        Profiler.log_error_once(:live_signature, "Live::Signature: could not read a profile", e)
        GONE
      end

      def self.walk(storage, token, depth, seen)
        return if seen.key?(token) || seen.size >= MAX_PROFILES

        profile = storage.load(token)
        return if profile.nil?

        children = depth < MAX_DEPTH ? storage.find_by_parent(token) : []
        seen[token] = [
          profile.status,
          profile.finished_at&.to_f,
          (profile.collector_data("job") || {})["status"],
          (profile.collector_data("http") || {})["total_requests"],
          Array((profile.collector_data("enqueued_jobs") || {})["jobs"]).size,
          children.map(&:token).sort
        ]
        children.each { |child| walk(storage, child.token, depth + 1, seen) }
      end
      private_class_method :walk
    end
  end
end
