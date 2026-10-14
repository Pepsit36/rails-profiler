# frozen_string_literal: true

# Enqueued by /orders/export and run after its response, on the async adapter whatever the
# application's, so that the toolbar of that page shows it running, then completed.
class OrdersExportJob < ApplicationJob
  self.queue_adapter = :async
  queue_as :exports

  def perform(month:)
    Rails.logger.info("Exporting the orders of #{month}")
    sleep 3
  end
end
