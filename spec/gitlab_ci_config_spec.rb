# frozen_string_literal: true

require "spec_helper"
require "yaml"

# Guards the two pipeline decisions that cannot be checked by running anything:
# which branches the [Unreleased] check applies to, and how long the compiled
# assets stay available for a release re-run.
RSpec.describe ".gitlab-ci.yml" do
  let(:config) { YAML.safe_load(File.read(File.expand_path("../.gitlab-ci.yml", __dir__))) }
  let(:changelog_check) { config.fetch("changelog:check") }

  # Branch prefixes that have actually been merged into master here.
  let(:merged_prefixes) do
    out = IO.popen(["git", "log", "--merges", "--format=%s"], &:read)
    out.scan(/Merge branch '([^'\/]+)\//).flatten.uniq
  end

  it "runs changelog:check on every branch except the default one" do
    expect(changelog_check.fetch("rules").map { |rule| rule["if"] }).to eq(
      ['$CI_COMMIT_BRANCH && $CI_COMMIT_BRANCH != $CI_DEFAULT_BRANCH && $CI_PIPELINE_SOURCE != "merge_request_event"']
    )
  end

  it "does not pin changelog:check to a list of branch prefixes" do
    expect(changelog_check.fetch("rules").first.fetch("if")).not_to include("feature|bugfix")
  end

  it "would have missed branch prefixes that this repository actually uses" do
    old_prefixes = %w[feature bugfix hotfix fix breaking]
    expect(merged_prefixes - old_prefixes).not_to be_empty,
                                                 "the prefix allowlist is only worth replacing if real branches fall outside it"
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
