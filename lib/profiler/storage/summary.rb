# frozen_string_literal: true

require_relative "../models/profile"

module Profiler
  module Storage
    # What the profile lists show of a profile, for the stores to keep apart from the profile
    # itself: the top-level fields without the bodies, params, headers and tabs, and for each
    # collector its scalar values only (database.total_queries, job.queue, test.test_name...),
    # nested lists and hashes left out. Built from Profile#to_h, after the collectors and the
    # redaction have run: a summary is a subset of the stored profile and holds no value the
    # profile does not.
    module Summary
      DROPPED = %i[params headers response_headers request_body request_body_encoding
                   response_body response_body_encoding tabs].freeze

      module_function

      # From a Profile, or the Hash its #to_h returns.
      def build(profile)
        data = profile.is_a?(Hash) ? profile : profile.to_h
        summary = data.transform_keys(&:to_sym).except(*DROPPED)
        summary[:collectors_data] = (summary[:collectors_data] || {}).to_h do |name, values|
          [name.to_s, values.is_a?(Hash) ? values.select { |_, value| scalar?(value) }.transform_keys(&:to_s) : {}]
        end
        summary
      end

      # The Profile a list shows, from a summary with string or symbol keys.
      def to_profile(summary)
        Models::Profile.from_hash(summary.transform_keys(&:to_sym))
      end

      def scalar?(value)
        value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      end
    end
  end
end
