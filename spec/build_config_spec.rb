# frozen_string_literal: true

require "spec_helper"
require "json"

# The bundles ship to the browser of every page of the host application: they are minified.
RSpec.describe "front end build scripts" do
  let(:scripts) { JSON.parse(File.read(File.expand_path("../package.json", __dir__))).fetch("scripts") }

  %w[build:js build:toolbar].each do |name|
    it "minifies #{name}" do
      expect(scripts.fetch(name)).to include("--minify")
    end
  end

  it "compresses the stylesheet" do
    expect(scripts.fetch("build:css")).to include("--style=compressed")
  end
end
