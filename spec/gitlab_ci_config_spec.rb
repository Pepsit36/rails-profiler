# frozen_string_literal: true

require "spec_helper"
require "yaml"

# Guards the pipeline decisions that cannot be checked by running anything:
# which branches the [Unreleased] check applies to, how long the compiled assets
# stay available for a release re-run, and what a publication waits for.
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
    expect(images).to include("rspec" => "ruby:3.3", "rspec:ruby3.4" => "ruby:3.4")
  end

  # The oldest-Ruby / Rails 7.1 job is informational until it is green: a red one must not
  # hold back a publication, and it must not be among the jobs publishing waits for.
  it "keeps the oldest Ruby and Rails job informational, and out of the publishing gate" do
    old = config.fetch("rspec:ruby3.1-rails7.1")
    expect(old.fetch("allow_failure")).to be(true)
    expect(old.fetch("variables").fetch("BUNDLE_GEMFILE")).to end_with("gemfiles/rails_7_1.gemfile")
    %w[canary release].each { |job| expect(config.fetch(job).fetch("needs")).not_to include("rspec:ruby3.1-rails7.1") }
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

  # A push to a branch is not reviewed, and canary publishes a gem: it is played
  # by hand, on the same branches as before.
  it "only publishes a canary when someone plays the job" do
    rules = config.fetch("canary").fetch("rules")
    expect(rules).not_to be_empty
    expect(rules).to all(include("when" => "manual", "allow_failure" => true))
    expect(rules.first.fetch("if")).to include('$CI_COMMIT_BRANCH =~ /^(feature|bugfix|hotfix|fix|breaking)\//')
    expect(config.fetch("canary")).not_to include("only", "except", "when")
  end

  it "numbers the canary after the version the branch will publish" do
    script = config.fetch("canary").fetch("script").join("\n")
    expect(script).to include('ruby script/canary-version "${CI_COMMIT_SHORT_SHA}"')
    expect(script).to include("refs/remotes/origin/master")
    expect(script).not_to include("git describe")
    expect(config.fetch("canary").fetch("variables").fetch("GIT_DEPTH")).to eq("0")
  end

  it "keeps the build artifacts around long enough for a release re-run" do
    expect(config.fetch("build").fetch("artifacts").fetch("expire_in")).to eq("1 week")
  end

  # A job with `needs` starts as soon as the jobs it lists succeed, whatever its
  # stage. Without both suites listed here, the only thing holding a publication
  # back after a red suite would be that `build` has no `needs` of its own.
  %w[release canary].each do |job|
    it "publishes from #{job} only after both suites, the lint, the type check, the front-end tests, the build and the package check" do
      expect(config.fetch(job).fetch("needs")).to contain_exactly("rspec", "rspec:ruby3.4", "rubocop", "typecheck", "vitest", "build", "package:check")
    end

    # A `needs` naming a job absent from the pipeline makes GitLab refuse to
    # create the pipeline at all.
    it "needs only jobs that run in every pipeline #{job} runs in" do
      config.fetch(job).fetch("needs").each do |needed|
        expect(config.fetch(needed)).not_to include("rules", "only", "except")
      end
    end
  end

  it "checks the installed gem between the build and the publication" do
    package_check = config.fetch("package:check")
    expect(config.fetch("stages")).to eq(%w[test build package publish])
    expect(package_check.fetch("stage")).to eq("package")
    expect(package_check.fetch("needs")).to eq(["build"])
    expect(package_check.fetch("script")).to eq(["ruby script/check-gem-package"])
  end

  it "serialises releases and drives them from the versioned script" do
    expect(config.fetch("release").fetch("resource_group")).to eq("release")
    expect(config.fetch("release").fetch("script")).to eq(["bash script/release.sh"])
  end
end
