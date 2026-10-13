# frozen_string_literal: true

Rails.application.routes.append do
  get "/orders", to: "demo#orders"
  get "/orders/confirmation", to: "demo#confirmation"
  get "/orders/broken", to: "demo#broken"
  get "/checkout", to: "demo#checkout"
  match "/upstream/*path", to: "demo#upstream", via: %i[get post]
end
