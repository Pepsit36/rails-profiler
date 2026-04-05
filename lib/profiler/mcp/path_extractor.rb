# frozen_string_literal: true

require "json"

module Profiler
  module MCP
    module PathExtractor
      # Supports dot-notation JSONPath: $.key, $.key.sub, $.array[0].key
      def self.extract_json(content, path)
        data = JSON.parse(content)
        segments = path.sub(/\A\$\.?/, "").split(".").flat_map do |seg|
          seg =~ /\A(.+)\[(\d+)\]\z/ ? [$1, $2.to_i] : [seg]
        end
        result = segments.reduce(data) do |obj, seg|
          obj.is_a?(Array) ? obj[seg.to_i] : obj[seg]
        end
        JSON.generate(result)
      rescue => e
        "JSONPath error: #{e.message}"
      end

      def self.extract_xml(content, xpath)
        require "nokogiri"
        Nokogiri::XML(content).xpath(xpath).to_s
      rescue => e
        "XPath error: #{e.message}"
      end
    end
  end
end
