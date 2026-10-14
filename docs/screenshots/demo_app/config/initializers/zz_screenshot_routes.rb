# frozen_string_literal: true

Rails.application.routes.append do
  get "/orders", to: "demo#orders"
  get "/orders/confirmation", to: "demo#confirmation"
  get "/orders/broken", to: "demo#broken"
  get "/orders/export", to: "demo#export"
  get "/checkout", to: "demo#checkout"
  match "/upstream/*path", to: "demo#upstream", via: %i[get post]
  get "/orders/turbo", to: "demo#turbo"
  get "/orders/turbo/customer", to: "demo#turbo_frame"
  post "/orders/turbo/refund", to: "demo#turbo_refund"
end
