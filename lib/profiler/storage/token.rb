# frozen_string_literal: true

module Profiler
  module Storage
    # The format of a profile token, as Models::Profile issues it (SecureRandom.hex(16)) for every
    # kind of profile. The backends check a token against it before they turn it into a file name,
    # a directory or a key: a token is client input for the controllers, the cluster proxy and the
    # MCP tools, which all call the storage directly.
    module Token
      FORMAT = /\A[0-9a-f]{32}\z/

      def self.valid?(token)
        token.is_a?(String) && FORMAT.match?(token)
      end

      # For the writers: the gem only writes under the tokens it issued, so another one is a bug.
      def self.validate!(token)
        raise ArgumentError, "invalid profile token: #{token.inspect[0, 80]}" unless valid?(token)

        token
      end
    end
  end
end
