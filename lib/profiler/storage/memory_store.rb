# frozen_string_literal: true

require "concurrent-ruby"
require_relative "base_store"
require_relative "summary"
require_relative "../models/profile"

module Profiler
  module Storage
    # Keeps the profiles in the process, as the Hashes of Profile#to_h, at most max_profiles of
    # them (100 when neither the option nor config.max_profiles sets it: this store always has a
    # cap). Beside them, the start time, type and parent of each, and the children of each parent,
    # so that listing, finding the children and evicting deserialize only what they return.
    class MemoryStore < BaseStore
      Entry = Struct.new(:at, :type, :parent, :sequence)

      def initialize(options = {})
        @profiles = Concurrent::Hash.new
        @max_profiles = options[:max_profiles] || Profiler.configuration.max_profiles || 100
        @mutex = Mutex.new
        @entries = {}
        @children = {}
        @sequence = 0
        @sorted = nil
      end

      def do_save(token, profile)
        data = serialize_profile(profile)
        @mutex.synchronize do
          cleanup_if_needed unless @profiles.key?(token)
          remove_entry(token)
          @profiles[token] = data
          @entries[token] = Entry.new(profile.started_at.to_f, data[:profile_type].to_s, profile.parent_token, @sequence += 1)
          (@children[profile.parent_token] ||= {})[token] = true if profile.parent_token
          @sorted = nil
        end
        token
      end

      def load(token)
        return nil unless Token.valid?(token)

        data = @profiles[token]
        return nil unless data

        deserialize_profile(data)
      end

      # Newest first; summary: true leaves the bodies, headers and nested collector data out.
      def list(limit: 50, offset: 0, type: nil, summary: false)
        page = @mutex.synchronize do
          tokens = sorted_tokens
          tokens = tokens.select { |token| @entries[token].type == type.to_s } if type
          tokens.drop(offset).first(limit).filter_map { |token| @profiles[token] }
        end
        page.map { |data| summary ? Summary.to_profile(Summary.build(data)) : deserialize_profile(data) }
      end

      def cleanup(older_than: 24 * 60 * 60)
        cutoff = (Time.now - older_than).to_f
        @mutex.synchronize do
          @entries.select { |_, entry| entry.at < cutoff }.each_key { |token| remove(token) }
        end
      end

      def find_by_parent(parent_token)
        return [] unless Token.valid?(parent_token)

        children = @mutex.synchronize { (@children[parent_token] || {}).keys.filter_map { |token| @profiles[token] } }
        children.map { |data| deserialize_profile(data) }.sort_by(&:started_at)
      end

      def delete(token)
        return unless Token.valid?(token)

        @mutex.synchronize { remove(token) }
      end

      def clear(type: nil)
        @mutex.synchronize do
          @entries.select { |_, entry| type.nil? || entry.type == type.to_s }.each_key { |token| remove(token) }
        end
      end

      private

      # Called before a new profile is added: removes the oldest down to 80% of the cap.
      def cleanup_if_needed
        return if @profiles.size < @max_profiles

        profiles_to_remove = @profiles.size - (@max_profiles * 0.8).to_i
        return if profiles_to_remove <= 0

        sorted_tokens.last(profiles_to_remove).each { |token| remove(token) }
      end

      def remove(token)
        removed = @profiles.delete(token)
        remove_entry(token)
        removed
      end

      def remove_entry(token)
        entry = @entries.delete(token)
        return unless entry

        if entry.parent && (siblings = @children[entry.parent])
          siblings.delete(token)
          @children.delete(entry.parent) if siblings.empty?
        end
        @sorted = nil
      end

      # Newest first; two profiles started in the same instant, the one saved last first.
      def sorted_tokens
        @sorted ||= @entries.sort_by { |_, entry| [-entry.at, -entry.sequence] }.map(&:first)
      end

      def serialize_profile(profile)
        profile.to_h
      end

      def deserialize_profile(data)
        Models::Profile.from_hash(data)
      end
    end
  end
end
