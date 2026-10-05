# frozen_string_literal: true

require_relative "collectors/ajax_collector"

module Profiler
  # The AJAX tab of a page: its sub-requests are saved after the page itself, so the tab is
  # computed when the page is shown, from its children, whatever the configured collector list.
  # The children are the ones the caller already read (the same find_by_parent gives the child
  # jobs): only the http ones are sub-requests, the jobs stay in child_jobs.
  module AjaxData
    # Hands the children already read to the AjaxCollector in place of the storage.
    Children = Struct.new(:profiles) do
      def find_by_parent(_parent_token)
        profiles
      end
    end

    module_function

    # Adds the ajax collector data to profile, and its tab when it has none: a page without
    # sub-requests and without the tab is left as it is.
    def attach(profile, children)
      requests = children.select { |child| child.profile_type == "http" }
      # A copy: the memory store hands out the very tabs it keeps.
      tabs = profile.collectors_metadata = (profile.collectors_metadata || []).map(&:dup)
      tab = tabs.find { |entry| (entry[:key] || entry["key"]).to_s == "ajax" }
      return if requests.empty? && tab.nil?

      collector = Collectors::AjaxCollector.new(profile, storage: Children.new(requests))
      collector.collect
      if tab.nil?
        profile.add_collector_metadata(collector)
      elsif tab.key?("key")
        tab["has_data"] = collector.has_data?
      else
        tab[:has_data] = collector.has_data?
      end
    end
  end
end
