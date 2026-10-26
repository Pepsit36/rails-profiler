# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"

# A framework that is not a string must be answered with 422, not crash into a 500.
RSpec.describe "Test runner framework validation", type: :request do
  include Rack::Test::Methods

  let(:headers) do
    { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost", "HTTP_X_PROFILER_REQUEST" => "1" }
  end

  def app
    Rails.application
  end

  before { Profiler.configure { |config| config.enabled = true } }

  [123, ["rspec"], {}].each do |bad|
    it "answers 422 to POST runs with framework #{bad.inspect}" do
      body = { files: ["spec/fake_spec.rb"], framework: bad }.to_json
      post "/_profiler/api/test_runner/runs", body, headers.merge("CONTENT_TYPE" => "application/json")
      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)["error"]).to match(/framework must be a string/i)
    end
  end

  it "answers 422 to GET files with an array framework" do
    get "/_profiler/api/test_runner/files?framework[]=rspec", {}, headers
    expect(last_response.status).to eq(422)
  end
end
