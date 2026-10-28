# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe "script/check-release-backlog" do
  let(:script) { File.expand_path("../script/check-release-backlog", __dir__) }

  let(:changelog_text) do
    <<~MD
      # Changelog

      ## [Unreleased]

      ## [1.2.0] - 2026-01-02

      <!-- stamped -->

      ### Added

      - b

      ## [1.1.0] - 2026-01-01

      <!-- stamped -->

      ### Added

      - a
    MD
  end

  def git(*args, dir:)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args, chdir: dir)
    raise "git #{args.join(' ')}: #{out}" unless status.success?

    out
  end

  # Runs the check in a clone of an origin whose master carries CHANGELOG_TEXT and the given tags.
  def check(tags:, branch: "feature/x")
    Dir.mktmpdir do |root|
      origin = File.join(root, "origin.git")
      work = File.join(root, "work")
      git("init", "-q", "--bare", "-b", "master", origin, dir: root)
      git("clone", "-q", origin, work, dir: root)
      File.write(File.join(work, "CHANGELOG.md"), changelog_text)
      git("add", ".", dir: work)
      git("commit", "-qm", "init", dir: work)
      git("push", "-q", "origin", "HEAD:master", dir: work)
      tags.each { |t| git("tag", t, dir: work) }
      git("push", "-q", "--tags", dir: work) unless tags.empty?
      git("checkout", "-q", "-b", branch, dir: work)

      _out, err, status = Open3.capture3({ "CI_COMMIT_BRANCH" => branch }, "bash", script, chdir: work)
      [status, err]
    end
  end

  it "passes when every stamped version has its tag" do
    status, = check(tags: %w[v1.1.0 v1.2.0])
    expect(status).to be_success
  end

  it "fails, naming the version, when the top stamped version has no tag" do
    status, err = check(tags: %w[v1.1.0])
    expect(status).not_to be_success
    expect(err).to include("1.2.0").and include("no tag").and include("fix/release-")
  end

  it "names every untagged version" do
    status, err = check(tags: [])
    expect(status).not_to be_success
    expect(err).to include("1.2.0, 1.1.0")
  end

  it "lets a fix/release-* branch through" do
    status, = check(tags: [], branch: "fix/release-tags")
    expect(status).to be_success
  end
end
