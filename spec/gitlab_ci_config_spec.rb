# frozen_string_literal: true

require "spec_helper"
require "yaml"

# Guards the two pipeline decisions that cannot be checked by running anything:
# which branches the [Unreleased] check applies to, and how long the compiled
# assets stay available for a release re-run.
RSpec.describe ".gitlab-ci.yml" do
  let(:config) { YAML.safe_load(File.read(File.expand_path("../.gitlab-ci.yml", __dir__))) }
  let(:changelog_check) { config.fetch("changelog:check") }

  it "runs changelog:check on every branch except the default one" do
    expect(changelog_check.fetch("rules").map { |rule| rule["if"] }).to eq(
      ['$CI_COMMIT_BRANCH && $CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH && $CI_PIPELINE_SOURCE != "merge_request_event"']
    )
  end

  it "does not pin changelog:check to a list of branch prefixes" do
    expect(changelog_check.fetch("rules").first.fetch("if")).not_to include("feature|bugfix")
  end

  it "stays out of merge request pipelines" do
    expect(changelog_check.fetch("rules").first.fetch("if")).to include('$CI_PIPELINE_SOURCE != "merge_request_event"')
    expect(changelog_check).not_to have_key("only")
    expect(config).not_to have_key("workflow")
  end

  it "runs changelog:check next to rspec, in the test stage" do
    expect(changelog_check.fetch("stage")).to eq("test")
    expect(config.fetch("rspec").fetch("stage")).to eq("test")
  end

  # From Ruby 3.4 on, the standard library calls Thread.new with arguments, in the
  # Happy Eyeballs hostname resolution of Socket.tcp, and the gem prepends a module
  # to Thread#initialize. Dropping the 3.4 job would make that class of breakage
  # invisible again.
  it "runs the suite on both supported Ruby minor versions" do
    images = config.select { |_, job| job.is_a?(Hash) && job["script"].to_a.include?("bundle exec rspec") }
                   .transform_values { |job| job.fetch("image") }
    expect(images).to eq("rspec" => "ruby:3.3", "rspec:ruby3.4" => "ruby:3.4")
  end

  it "gives each rspec job its own bundle cache, since the bundle is per Ruby ABI" do
    expect(config.fetch("rspec:ruby3.4").fetch("stage")).to eq("test")
    expect(config.fetch("rspec:ruby3.4").fetch("cache").fetch("key"))
      .not_to eq(config.fetch("rspec").fetch("cache").fetch("key"))
  end

  it "runs both changelog checks, and needs the full history for the second" do
    expect(changelog_check.fetch("script")).to include("ruby bin/changelog check --base origin/master")
    expect(changelog_check.fetch("script")).to include("ruby bin/changelog coverage")
    expect(changelog_check.fetch("variables").fetch("GIT_DEPTH")).to eq("0")
  end

  it "keeps the coverage check out of the release job" do
    expect(config.fetch("release").fetch("script").join(" ")).not_to include("coverage")
  end

  it "leaves the canary rule untouched" do
    expect(config.fetch("canary").fetch("rules").first.fetch("if"))
      .to include('$CI_COMMIT_BRANCH =~ /^(feature|bugfix|hotfix|fix|breaking)\//')
  end

  it "keeps the build artifacts around long enough for a release re-run" do
    expect(config.fetch("build").fetch("artifacts").fetch("expire_in")).to eq("1 week")
  end

  it "serialises releases and drives them from the versioned script" do
    expect(config.fetch("release").fetch("resource_group")).to eq("release")
    expect(config.fetch("release").fetch("script")).to eq(["bash script/release.sh"])
  end
end
