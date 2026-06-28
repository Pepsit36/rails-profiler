# frozen_string_literal: true

module Profiler
  module MCP
    module SlaveSupport
      def self.resolve_storage(params)
        if (slave_name = params["slave"])
          require_relative "../cluster/slave_proxy"
          Cluster::SlaveProxy.new(slave_name)
        else
          Profiler.storage
        end
      end

      def self.with_slave_proxy(params)
        return nil unless params["slave"]

        require_relative "../cluster/slave_proxy"
        Cluster::SlaveProxy.new(params["slave"])
      end
    end
  end
end
