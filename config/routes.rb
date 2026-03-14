# frozen_string_literal: true

Profiler::Engine.routes.draw do
  root to: "profiles#index"

  resources :profiles, only: [:index, :show] do
    member do
      get :timeline
      get :database
      get :views
      get :cache
      get :performance
    end
  end

  get "assets/profiler-toolbar.js", to: "assets#toolbar_js"

  namespace :api do
    resources :profiles, only: [:index, :show]
    get "toolbar/:token", to: "toolbar#show"
    post "ajax/link", to: "ajax#link"
  end
end
