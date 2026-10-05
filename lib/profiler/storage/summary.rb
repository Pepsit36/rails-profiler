# frozen_string_literal: true

require_relative "../models/profile"

module Profiler
  module Storage
    # What the profile lists show of a profile, for the stores to keep apart from the profile
    # itself: the top-level fields without the bodies, params, headers and tabs, and for each
    # collector its scalar values only (database.total_queries, job.queue, test.test_name...),
    # nested lists and hashes and the request collector's copy of the bodies left out, strings
    # cut at MAX_SCALAR_LENGTH (a console return value, an exception message). Built from
    # Profile#to_h, after the collectors and the redaction have run: a summary is a subset of the
    # stored profile (a long string cut to its start) and holds no value the profile does not.
    module Summary
      MAX_SCALAR_LENGTH = 500

      DROPPED = %i[params headers response_headers request_body request_body_encoding
                   response_body response_body_encoding tabs].freeze

      # The request collector keeps a copy of the bodies: no more listed than the profile's own.
      DROPPED_SCALARS = %w[request_body request_body_encoding response_body response_body_encoding].freeze

      module_function

      # From a Profile, or the Hash its #to_h returns.
      def build(profile)
        data = profile.is_a?(Hash) ? profile : profile.to_h
        summary = data.transform_keys(&:to_sym).except(*DROPPED)
        summary[:collectors_data] = (summary[:collectors_data] || {}).to_h do |name, values|
          [name.to_s, values.is_a?(Hash) ? scalars(values) : {}]
        end
        summary
      end

      # The Profile a list shows, from a summary with string or symbol keys.
      def to_profile(summary)
        Models::Profile.from_hash(summary.transform_keys(&:to_sym))
      end

      def scalars(values)
        values.each_with_object({}) do |(key, value), kept|
          next unless scalar?(value)
          next if DROPPED_SCALARS.include?(key.to_s)

          kept[key.to_s] = value.is_a?(String) && value.length > MAX_SCALAR_LENGTH ? value[0, MAX_SCALAR_LENGTH] : value
        end
      end

      def scalar?(value)
        value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      end
    end
  end
end
