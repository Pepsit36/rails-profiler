# frozen_string_literal: true

require "base64"
require "zlib"

module Profiler
  module MCP
    module BodyFormatter
      # Formats a body string for MCP output.
      #
      # params keys used:
      #   "save_bodies"   (boolean) — save to ./tmp/rails-profiler/{token}/{name} and return path
      #   "max_body_size" (number)  — truncate inline body at N chars
      #   "json_path"     (string)  — JSONPath to extract from body when save_bodies is true
      #   "xml_path"      (string)  — XPath to extract from body when save_bodies is true
      #
      # Returns a formatted string ready to embed in markdown, or nil if body is blank.
      def self.format_body(token, name, body, encoding, params)
        return "  *(binary, base64 encoded)*" if encoding == "base64"
        return nil if body.nil? || body.empty?

        if encoding == "gzip+base64"
          begin
            body = Zlib::Inflate.inflate(Base64.strict_decode64(body))
          rescue Zlib::Error, ArgumentError
            # fall through with original body
          end
        end

        if params["save_bodies"]
          path = FileCache.save(token, name, body)
          if path
            result = "  *(saved → `#{path}`)*"
            if params["json_path"]
              extracted = PathExtractor.extract_json(body, params["json_path"])
              result += "\n  `#{params['json_path']}` → `#{extracted}`"
            elsif params["xml_path"]
              extracted = PathExtractor.extract_xml(body, params["xml_path"])
              result += "\n  `#{params['xml_path']}` → `#{extracted}`"
            end
            result
          else
            truncate_body(body, params["max_body_size"])
          end
        else
          truncate_body(body, params["max_body_size"])
        end
      end

      def self.truncate_body(body, max_size)
        max = max_size&.to_i
        content = if max && body.length > max
          "#{body[0, max]}\n... [truncated, #{body.length} chars total]"
        else
          body
        end
        "```\n#{content}\n```"
      end
    end
  end
end
