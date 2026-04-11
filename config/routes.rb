# frozen_string_literal: true

require "profiler/mcp/server"

Profiler::Engine.routes.draw do
  mount Profiler::MCP::Server.rack_app, at: "mcp"

  root to: "profiles#index"

  resources :profiles, only: [:index, :show] do
    member do
      get :timeline
      get :database
      get :views
      get :cache
      get :performance
      get :flamegraph
    end
  end

  get "assets/profiler-toolbar.js", to: "assets#toolbar_js"
  get "assets/profiler.js", to: "assets#main_js"
  get "assets/profiler.css", to: "assets#main_css"

  namespace :api do
    resources :profiles, only: [:index, :show, :destroy] do
      collection { delete :clear }
    end
    resources :jobs, only: [:index, :show, :destroy] do
      collection { delete :clear }
    end
    resources :outbound_http, only: [:index]
    get "toolbar/:token", to: "toolbar#show"
    post "ajax/link", to: "ajax#link"
    post "explain", to: "explain#create"
    resource :function_profiling, only: [:show, :update], controller: "function_profiling"
    resource :env_vars, only: [:show, :update], controller: "env_vars"
  end
end
