# frozen_string_literal: true

require "stringio"
require "profiler/test_runner/discovery"
require "profiler/test_runner/runner"

module Profiler
  module Api
    class TestRunnerController < ApplicationController
      # How long the page waits before asking for the output that came since.
      STREAM_RETRY_MS = 1000

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

        # Runner.start accepts only discovered test files
        run = Profiler::TestRunner::Runner.start(files: files, framework: framework)
        render json: run.to_h, status: :created
      rescue Profiler::TestRunner::InvalidFileError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def show
        run = Profiler::TestRunner.run_store.find(params[:id])
        return render json: { error: "Run not found" }, status: :not_found unless run

        render json: run.to_h
      end

      # Server-sent events with the output of a run from the position the page holds: what is
      # there now, then the response ends. The page's EventSource comes back after `retry`, with
      # the position reached in Last-Event-ID, so no server thread waits on a run that prints
      # nothing, however many pages follow it.
      def stream
        position = [(request.headers["Last-Event-ID"].presence || params[:position]).to_i, 0].max
        result = Profiler::TestRunner.run_store.read_output(params[:id], position: position)
        if result[:status] == "not_found"
          render json: { error: "Run not found" }, status: :not_found
          return
        end

        body = StringIO.new
        body.write("retry: #{STREAM_RETRY_MS}\n\n")
        sse = ActionController::Live::SSE.new(body, event: "output")
        result[:chunks].each.with_index(position + 1) do |chunk, id|
          sse.write({ chunk: chunk }, id: id)
        end
        if result[:finished]
          run = Profiler::TestRunner.run_store.find(params[:id])
          sse.write({ status: result[:status], exit_code: run&.exit_code }, event: "done")
        end

        response.headers["Cache-Control"] = "no-cache"
        render plain: body.string, content_type: "text/event-stream"
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
