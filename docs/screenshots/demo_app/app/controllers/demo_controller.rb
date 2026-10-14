# frozen_string_literal: true

require "net/http"
require "json"

# Pages used by docs/screenshots/shoot.mjs. Every host, user and amount here is fictitious.
class DemoController < ApplicationController
  skip_before_action :verify_authenticity_token
  layout false

  # A fictitious billing API, served by this same application (see #upstream) and reached
  # through 127.0.0.1, so that the Outbound HTTP tab shows billing.myapp.test.
  BILLING_HOST = "billing.myapp.test"

  # An HTML page: the toolbar is injected, and the page's own fetch() calls become AJAX
  # sub-requests linked to it.
  def orders
    Rails.logger.info("Listing recent orders for the back office")
    @title = t("demo.title")
    @heading = t("demo.orders")
    t("demo.customers")
    t("demo.missing_banner") # intentionally missing, for the I18n tab
    @customers = User.order(:name).limit(6).to_a
    @posts = Post.includes(:author).order(:id).limit(6).to_a
    @totals = Rails.cache.fetch("orders/totals", expires_in: 1.minute) { { count: 128, revenue: 18_420 } }
    Rails.cache.read("orders/banner")
    Profiler.dump({ page: 1, per_page: 6, filters: { status: "paid" } }, "Pagination")
    render :orders
  end

  # Outbound HTTP, a custom measure, child jobs and mails, in one request.
  def checkout
    place_order
    render json: { ok: true, order: 4211 }
  end

  # The same order as #checkout, answered with an HTML page: its toolbar shows the HTTP, JOB
  # and MAIL items.
  def confirmation
    place_order
    @title = t("demo.title")
    render :confirmation
  end

  # An HTML page whose job ends after its response: its toolbar sees the job run, then end.
  def export
    OrdersExportJob.perform_later(month: "2026-09")
    @title = t("demo.title")
    render :export
  end

  # An HTML page that raises: the development error page gets the toolbar and its 💥 item.
  def broken
    Rails.logger.error("Refund requested for an order that was never paid")
    raise ArgumentError, "Unknown order status: archived"
  end

  # A Hotwire page: Turbo is loaded as a module, a lazy turbo-frame fetches #turbo_frame and a
  # form answers with a turbo-stream. Both requests become AJAX sub-requests of this page.
  def turbo
    @title = t("demo.title")
    @customers = User.order(:name).limit(3).to_a
    render :turbo
  end

  # The frame request, rendered in the minimal layout turbo-rails uses for a Turbo-Frame request
  # (DemoController itself has no layout).
  def turbo_frame
    @customer = User.order(:id).first
    @orders = Post.where(author: @customer).order(:id).limit(3).to_a
    render :turbo_frame, layout: "turbo_rails/frame"
  end

  def turbo_refund
    Rails.logger.info("Refund requested for order #4211")
    @customer = User.order(:id).first
    render turbo_stream: turbo_stream.update("refund_status", html: "Refund of 42,00 \u20ac queued for order #4211")
  end

  def upstream
    case params[:path]
    when "customers/42" then render json: { id: "cus_demo42", name: "Jane Example", plan: "pro" }
    when "charges" then render json: { id: "ch_demo1", status: "succeeded", amount: 4200 }, status: :created
    when "slow" then sleep(0.6) && render(json: { ok: true })
    else render json: { error: "not found" }, status: :not_found
    end
  end

  private

  def place_order
    Rails.logger.info("Checkout started for cart #4211")
    customer = User.order(:id).first
    billing_get("/upstream/customers/42")
    billing_post("/upstream/charges", { amount: 4200, currency: "eur", customer: "cus_demo42" })
    billing_get("/upstream/invoices/999")
    billing_get("/upstream/slow")
    Profiler.measure("checkout.tax_computation", metadata: { country: "FR" }) { sleep 0.03 }
    Rails.logger.warn("Billing API answered 404 for invoice 999")
    DataProcessingJob.perform_later(batch_size: 5)
    ReportGenerationJob.perform_later(report_type: "daily")
    NotificationMailer.welcome(customer).deliver_now
    NotificationMailer.alert(customer, "Payment received for order #4211").deliver_now
    NotificationMailer.welcome(customer).deliver_later
    Profiler.dump({ cart: 4211, total_cents: 4200, items: 3 }, "Cart")
  end

  def billing
    Net::HTTP.new(BILLING_HOST, request.port).tap do |http|
      http.ipaddr = "127.0.0.1"
      http.open_timeout = 2
      http.read_timeout = 5
    end
  end

  def billing_get(path)
    billing.get(path, "Accept" => "application/json", "Authorization" => "Bearer demo-not-a-secret")
  end

  def billing_post(path, payload)
    billing.post(path, payload.to_json, "Content-Type" => "application/json")
  end
end
