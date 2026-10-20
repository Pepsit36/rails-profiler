# frozen_string_literal: true

module Profiler
  class CompareController < ApplicationController
    def show
      @token_a = params[:a]
      @token_b = params[:b]
      @node_a = params[:node_a].to_s
      @node_b = params[:node_b].to_s

      redirect_to root_path unless @token_a.present? && @token_b.present?
    end
  end
end
