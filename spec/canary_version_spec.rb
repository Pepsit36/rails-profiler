# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

# script/canary-version numbers the prerelease the `canary` job publishes. A
# prerelease sorts before the release it is cut from, so the number has to be
# built on the next version, not on the last tag, for a canary to sort after the
# last release.
RSpec.describe "script/canary-version" do
  let(:script) { File.expand_path("../script/canary-version", __dir__) }
  let(:sha) { "abc1234" }

  def git(dir, *args)
    out, err, status = Open3.capture3("git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out
  end

  def commit(dir, message)
    path = File.join(dir, "touched.txt")
    File.write(path, "#{File.read(path) if File.exist?(path)}#{message}\n")
    git(dir, "add", "--all")
    git(dir, "commit", "--quiet", "-m", message)
  end

  def canary(dir, short_sha = sha)
    Open3.capture3(RbConfig.ruby, script, short_sha, chdir: dir)
  end

  around do |example|
    Dir.mktmpdir("canary-version-spec") do |dir|
      @dir = dir
      git(dir, "init", "--quiet")
      git(dir, "symbolic-ref", "HEAD", "refs/heads/master")
      git(dir, "config", "user.email", "test@example.com")
      git(dir, "config", "user.name", "Canary Spec")
      git(dir, "config", "commit.gpgsign", "false")
      commit(dir, "feat: add the profiler")
      git(dir, "tag", "v1.2.0")
      # bin/changelog counts the branch from origin/master, as in the canary job.
      git(dir, "update-ref", "refs/remotes/origin/master", "HEAD")
      git(dir, "checkout", "--quiet", "-b", "fix/something")
      example.run
    end
  end

  let(:dir) { @dir }

  {
    "fix: repair the cache key" => "1.2.1",
    "feat: add a panel" => "1.3.0",
    "chore: tidy the scripts" => "1.2.1"
  }.each do |message, next_version|
    it "numbers a canary of a `#{message[/\A[a-z]+/]}` branch after the last release" do
      commit(dir, message)

      out, err, status = canary(dir)
      version = Gem::Version.new(out.strip)

      expect(status).to be_success, err
      expect(out.strip).to eq("#{next_version}.pre.#{sha}")
      expect(version).to be_prerelease
      expect(version).to be > Gem::Version.new("1.2.0")
      expect(version).to be < Gem::Version.new(next_version)
    end
  end

  it "counts a version CHANGELOG.md carries ahead of the last tag" do
    File.write(File.join(dir, "CHANGELOG.md"), "# Changelog\n\n## [Unreleased]\n\n## [1.4.0] - 2026-10-14\n")
    commit(dir, "docs: describe the canary")

    out, err, status = canary(dir)

    expect(status).to be_success, err
    expect(out.strip).to eq("1.4.1.pre.#{sha}")
  end

  it "refuses anything but a short sha" do
    _out, err, status = canary(dir, "abc; rm -rf /")

    expect(status).not_to be_success
    expect(err).to include("is not a short commit sha")
  end
end
