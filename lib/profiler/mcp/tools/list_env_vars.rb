# frozen_string_literal: true

require_relative "../slave_support"
require_relative "../../env_override_store"

module Profiler
  module MCP
    module Tools
      class ListEnvVars
        def self.call(params)
          if (proxy = MCP::SlaveSupport.with_slave_proxy(params))
            data = proxy.get_json("/_profiler/api/env_vars",
              include_all: params["include_all"], filter: params["filter"])
            text = format_slave_env_vars(data, params)
            return [{ type: "text", text: text }]
          end

          include_all = params["include_all"]
          filter = params["filter"]&.downcase

          if include_all
            vars = ENV.to_h.sort.to_h
            overrides = Profiler.env_override_store.all_overrides

            vars = vars.select { |k, _| k.downcase.include?(filter) } if filter

            if vars.empty?
              return [{ type: "text", text: "No environment variables match filter '#{params["filter"]}'." }]
            end

            rows = vars.map do |key, value|
              override = overrides[key]
              overridden = override ? "✓ (was: #{override["original"] || "(unset)"})" : ""
              "| #{key} | #{value} | #{overridden} |"
            end

            text = "**ENV variables (#{vars.size}#{filter ? ", filtered by '#{params["filter"]}'" : ""})**\n\n"
            text += "| Key | Current Value | Overridden |\n"
            text += "|-----|--------------|------------|\n"
            text += rows.join("\n")
          else
            overrides = Profiler.env_override_store.all_overrides
            overrides = overrides.select { |k, _| k.downcase.include?(filter) } if filter

            if overrides.empty?
              msg = filter ? "No overrides match filter '#{params["filter"]}'." : "No overrides active."
              return [{ type: "text", text: msg }]
            end

            rows = overrides.map do |key, entry|
              current = entry["value"] == EnvOverrideStore::DELETED_SENTINEL ? "(deleted)" : entry["value"]
              original = entry["original"] || "(unset)"
              "| #{key} | #{current} | #{original} |"
            end

            text = "**Active ENV overrides (#{overrides.size})**\n\n"
            text += "| Key | Current Value | Original Value |\n"
            text += "|-----|--------------|----------------|\n"
            text += rows.join("\n")
          end

          [{ type: "text", text: text }]
        end

        private

        def self.format_slave_env_vars(data, params)
          overrides = data["overrides"] || {}
          filter = params["filter"]&.downcase

          if params["include_all"]
            vars = (data["variables"] || {}).sort.to_h
            vars = vars.select { |k, _| k.downcase.include?(filter) } if filter
            return "No environment variables match filter '#{params["filter"]}'." if vars.empty?

            rows = vars.map do |key, value|
              override = overrides[key]
              overridden = override ? "✓ (was: #{override["original"] || "(unset)"})" : ""
              "| #{key} | #{value} | #{overridden} |"
            end
            "**ENV variables (#{vars.size})**\n\n| Key | Current Value | Overridden |\n|-----|--------------|------------|\n" + rows.join("\n")
          else
            overrides = overrides.select { |k, _| k.downcase.include?(filter) } if filter
            return "No overrides active." if overrides.empty?

            rows = overrides.map do |key, entry|
              current = entry["value"] == Profiler::EnvOverrideStore::DELETED_SENTINEL ? "(deleted)" : entry["value"]
              "| #{key} | #{current} | #{entry["original"] || "(unset)"} |"
            end
            "**Active ENV overrides (#{overrides.size})**\n\n| Key | Current Value | Original Value |\n|-----|--------------|----------------|\n" + rows.join("\n")
          end
        end
      end
    end
  end
end
