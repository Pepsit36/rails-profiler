# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"

# The cluster proxy names the type it means: DELETE /_profiler/api/profiles/clear?type=X clears
# that type only.
RSpec.describe "Clearing profiles through the profiler API", type: :request do
  include Rack::Test::Methods

  let(:headers) do
    { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost", "HTTP_X_PROFILER_REQUEST" => "1" }
  end
  let(:store) { Profiler::Storage::MemoryStore.new }

  def app
    Rails.application
  end

  before do
    Profiler.configure { |config| config.enabled = true }
    Profiler.instance_variable_set(:@storage, store)
    %w[http job test console].each do |type|
      token = SecureRandom.hex(16)
      store.save(token, build_profile(token: token, profile_type: type))
    end
  end

  after { Profiler.instance_variable_set(:@storage, nil) }

  def remaining
    store.list(limit: 100).map(&:profile_type).sort
  end

  it "clears the profiles of the type given and keeps the others" do
    delete "/_profiler/api/profiles/clear", { type: "job" }, headers

    expect(last_response.status).to eq(204)
    expect(remaining).to eq(%w[console http test])
  end

  it "clears the http profiles when no type is given" do
    delete "/_profiler/api/profiles/clear", {}, headers

    expect(last_response.status).to eq(204)
    expect(remaining).to eq(%w[console job test])
  end

  it "refuses a type it does not know, clearing nothing" do
    delete "/_profiler/api/profiles/clear", { type: "mail" }, headers

    expect(last_response.status).to eq(422)
    expect(remaining.size).to eq(4)
  end
end
