# frozen_string_literal: true

require "spec_helper"
require "open3"

# The gem reads some files from its own tree at run time, and rescues the error
# when one is missing: a file left out of spec.files fails nothing, the feature
# just goes silent for every user of the published gem.
RSpec.describe "profiler.gemspec" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:files) { Gem::Specification.load(File.join(root, "profiler.gemspec")).files }

  it "packages the AJAX interceptor the toolbar injector reads" do
    expect(files).to include("app/assets/javascript/profiler-ajax-interceptor.js")
  end

  it "packages every file of app/assets/javascript" do
    sources = Dir.glob("app/assets/javascript/**/*", base: root).select { |f| File.file?(File.join(root, f)) }
    expect(sources).not_to be_empty
    expect(files).to include(*sources)
  end

  # The same script as the package:check CI job, which also wants the compiled
  # assets of the `build` job. Those are not here, hence --skip-builds.
  it "builds a gem that installs with its run time assets" do
    command = [RbConfig.ruby, File.join(root, "script", "check-gem-package"), "--skip-builds"]
    output, status = Bundler.with_unbundled_env { Open3.capture2e(*command) }
    expect(status).to be_success, output
    expect(output).to include("The installed gem carries its 1 run time asset(s).")
  end
end
