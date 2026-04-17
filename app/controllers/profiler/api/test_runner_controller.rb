# frozen_string_literal: true

require "profiler/test_runner/discovery"
require "profiler/test_runner/runner"

module Profiler
  module Api
    class TestRunnerController < ApplicationController
      skip_before_action :verify_authenticity_token

      def files
        framework = params[:framework]
        tree = Profiler::TestRunner::Discovery.files(framework: framework)
        frameworks = Profiler::TestRunner::Discovery.frameworks

        render json: {
          frameworks: frameworks,
          tree: tree
        }
      end

      def create
        files     = Array(params[:files])
        framework = params[:framework] || detect_framework

        if files.empty?
          return render json: { error: "No files selected" }, status: :unprocessable_entity
        end

        # Validate paths are within Rails root (prevent path traversal)
        root = defined?(Rails) ? Rails.root.to_s : Dir.pwd
        files.each do |f|
          expanded = File.expand_path(File.join(root, f))
          unless expanded.start_with?(root)
            return render json: { error: "Invalid file path: #{f}" }, status: :unprocessable_entity
          end
        end

        run = Profiler::TestRunner::Runner.start(files: files, framework: framework)
        render json: run.to_h, status: :created
      end

      def show
        run = Profiler::TestRunner.run_store.find(params[:id])
        return render json: { error: "Run not found" }, status: :not_found unless run

        render json: run.to_h
      end

      def destroy
        killed = Profiler::TestRunner::Runner.kill(params[:id])
        if killed
          head :no_content
        else
          render json: { error: "Run not found or not running" }, status: :not_found
        end
      end

      private

      def detect_framework
        if Profiler::TestRunner::Discovery.rspec_available?
          "rspec"
        else
          "minitest"
        end
      end
    end
  end
end
