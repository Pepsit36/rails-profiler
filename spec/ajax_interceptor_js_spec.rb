# frozen_string_literal: true

require "spec_helper"
require "open3"

# The AJAX interceptor is plain JavaScript injected into every profiled page: its tests run under
# Node (spec/javascript), from here so that `bundle exec rspec` runs them wherever Node is
# installed. The CI images (ruby:3.x) have none: the example is skipped there.
RSpec.describe "AJAX interceptor (JavaScript)" do
  let(:node) do
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "node") }
       .find { |path| File.executable?(path) }
  end

  it "links Turbo Frame and Stream requests, and not Turbo Drive visits, to the page" do
    skip "node is not installed" unless node

    test_file = File.expand_path("javascript/ajax_interceptor.test.mjs", __dir__)
    output, status = Open3.capture2e(node, "--test", test_file)

    expect(status).to be_success, output
  end
end
