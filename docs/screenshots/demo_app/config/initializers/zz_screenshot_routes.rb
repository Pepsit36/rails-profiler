# frozen_string_literal: true

Rails.application.routes.append do
  get "/orders", to: "demo#orders"
  get "/checkout", to: "demo#checkout"
  match "/upstream/*path", to: "demo#upstream", via: %i[get post]
end
