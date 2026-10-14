# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Collectors::AjaxCollector do
  let(:page) { build_profile }

  def requests_of(*children)
    described_class.new(page, storage: Profiler::AjaxData::Children.new(children)).collect
    page.collector_data("ajax")["requests"]
  end

  describe "the turbo kind of each request" do
    it "is frame for a request carrying Turbo-Frame" do
      child = build_profile(headers: { "Turbo-Frame" => "customer_card" },
                            response_headers: { "content-type" => "text/html; charset=utf-8" })

      expect(requests_of(child).first["turbo"]).to eq("frame")
    end

    it "is stream for a response in text/vnd.turbo-stream.html, whatever the header's case" do
      lower = build_profile(response_headers: { "content-type" => "text/vnd.turbo-stream.html; charset=utf-8" })
      upper = build_profile(response_headers: { "Content-Type" => "text/vnd.turbo-stream.html" })

      expect(requests_of(lower, upper).map { |r| r["turbo"] }).to eq(%w[stream stream])
    end

    it "is frame for a frame request answered with a stream" do
      child = build_profile(headers: { "Turbo-Frame" => "customer_card" },
                            response_headers: { "content-type" => "text/vnd.turbo-stream.html" })

      expect(requests_of(child).first["turbo"]).to eq("frame")
    end

    it "is nil for any other request, and for a profile saved without headers" do
      json = build_profile(headers: { "Accept" => "application/json" },
                           response_headers: { "content-type" => "application/json" })
      bare = build_profile
      bare.headers = nil
      bare.response_headers = nil

      expect(requests_of(json, bare).map { |r| r["turbo"] }).to eq([nil, nil])
    end
  end
end
