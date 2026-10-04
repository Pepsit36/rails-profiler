# frozen_string_literal: true

require "profiler/mcp/server"

Profiler::Engine.routes.draw do
  # Read on each request rather than when the routes are drawn: the application's initializer
  # may set these options after the engine routes are loaded. A route that does not match
  # answers 404, as if it were not there.
  constraints(->(_request) { Profiler.configuration.mcp_http_enabled? }) do
    mount Profiler::MCP::Server.rack_app, at: "mcp"
  end

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

  get "test_runner", to: "test_runner#index"

  namespace :api do
    resources :profiles, only: [:index, :show, :destroy] do
      collection { delete :clear }
    end
    resources :jobs, only: [:index, :show, :destroy] do
      collection { delete :clear }
    end
    resources :console, only: [:index, :show, :destroy] do
      collection { delete :clear }
    end
    resources :tests, only: [:index, :show, :destroy] do
      collection { delete :clear }
    end
    resources :outbound_http, only: [:index]
    get "toolbar/:token", to: "toolbar#show"
    post "ajax/link", to: "ajax#link"
    post "explain", to: "explain#create"
    resource :function_profiling, only: [:show, :update], controller: "function_profiling"
    resource :env_vars, only: [:show, :update], controller: "env_vars"
    delete "env_vars/reset", to: "env_vars#reset_override"
    delete "env_vars/reset_all", to: "env_vars#reset_all"
    get    "test_runner/files",           to: "test_runner#files"
    post   "test_runner/runs",            to: "test_runner#create"
    get    "test_runner/runs/:id",        to: "test_runner#show",   as: :test_runner_run
    get    "test_runner/runs/:id/stream", to: "test_runner#stream", as: :test_runner_run_stream
    delete "test_runner/runs/:id",        to: "test_runner#destroy"
    get    "events/:token",               to: "events#subscribe",  as: :profile_events

    # Cluster endpoints (master-side)
    post "cluster/register",  to: "cluster#register"
    post "cluster/heartbeat", to: "cluster#heartbeat"
    get  "cluster/slaves",    to: "cluster#slaves"

    # Slave proxy — must be last to avoid shadowing other api routes
    scope "/slaves/:slave_name" do
      match "*path", to: "slave_proxy#forward", via: :all
    end
  end
end
