# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

# Exercises bin/changelog outside of CI: the stamping done by the `release` job
# and the [Unreleased] guard run by the `changelog:check` job, on throwaway git
# repositories built here.
RSpec.describe "bin/changelog" do
  let(:script) { File.expand_path("../bin/changelog", __dir__) }

  def git(dir, *args)
    out, err, status = Open3.capture3("git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out
  end

  def init_repo(dir)
    git(dir, "init", "--quiet")
    git(dir, "symbolic-ref", "HEAD", "refs/heads/master")
    git(dir, "config", "user.email", "test@example.com")
    git(dir, "config", "user.name", "Changelog Spec")
    git(dir, "config", "commit.gpgsign", "false")
  end

  def commit(dir, message, file: "touched.txt")
    path = File.join(dir, file)
    File.write(path, "#{File.read(path) if File.exist?(path)}#{message}\n")
    git(dir, "add", "--all")
    git(dir, "commit", "--quiet", "-m", message)
  end

  def short_sha(dir, ref = "HEAD")
    git(dir, "rev-parse", "--short=7", ref).strip
  end

  def changelog(dir, content)
    File.write(File.join(dir, "CHANGELOG.md"), content)
  end

  def run(dir, *args)
    Open3.capture3(RbConfig.ruby, script, *args, chdir: dir)
  end

  def unreleased_section(text)
    text[/^## \[Unreleased\]\n(.*?)(?=^## |\z)/m, 1].to_s
  end

  def section_for(text, version)
    text[/^## \[#{Regexp.escape(version)}\].*?\n(.*?)(?=^## |\z)/m, 1].to_s
  end

  around do |example|
    Dir.mktmpdir("changelog-spec") do |dir|
      @dir = dir
      init_repo(dir)
      example.run
    end
  end

  let(:dir) { @dir }

  describe "release, with entries already written under [Unreleased]" do
    before do
      changelog(dir, <<~MD)
        # Changelog

        ## [Unreleased]

        ### Fixed

        - stale profiles are no longer served after a cache flush

        ## [0.1.0] - 2026-01-01

        ### Added

        - the first release
      MD
      commit(dir, "chore: seed the changelog")
    end

    it "moves them under the new version and reopens an empty [Unreleased]" do
      out, err, status = run(dir, "release", "--version", "0.2.0", "--date", "2026-02-03")

      expect(status).to be_success, "stderr: #{err}"
      expect(out).to include("Reusing the 3 line(s) already written under [Unreleased]")

      text = File.read(File.join(dir, "CHANGELOG.md"))
      expect(text).to include("## [Unreleased]")
      expect(text).to include("## [0.2.0] - 2026-02-03")
      expect(unreleased_section(text).strip).to be_empty
      expect(section_for(text, "0.2.0")).to include("- stale profiles are no longer served after a cache flush")
      expect(text).to include("## [0.1.0] - 2026-01-01")
    end
  end

  describe "release, with an empty [Unreleased] section" do
    before do
      changelog(dir, "# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-01-01\n\n### Added\n\n- the first release\n")
      commit(dir, "chore: seed the changelog")
      git(dir, "tag", "v0.1.0")
      commit(dir, "fix(storage): survive a missing profile file")
      commit(dir, "ci: tighten the pipeline")
    end

    it "falls back to the commit subjects and prints what it generated" do
      out, err, status = run(dir, "release", "--version", "0.1.1", "--date", "2026-02-04", "--since", "v0.1.0")

      expect(status).to be_success, "stderr: #{err}"
      expect(out).to include("The [Unreleased] section was empty")
      expect(out).to include("--- generated entry ---")
      expect(out).to include("- **storage**: survive a missing profile file")

      text = File.read(File.join(dir, "CHANGELOG.md"))
      expect(unreleased_section(text).strip).to be_empty
      expect(section_for(text, "0.1.1")).to include("### Fixed")
      expect(section_for(text, "0.1.1")).to include("- **storage**: survive a missing profile file")
      # ci: never reaches the changelog.
      expect(text).not_to include("tighten the pipeline")
    end
  end

  describe "release, on a file without any [Unreleased] section" do
    before do
      changelog(dir, "# Changelog\n\n## [0.1.0] - 2026-01-01\n\n### Added\n\n- the first release\n")
      commit(dir, "chore: seed the changelog")
      git(dir, "tag", "v0.1.0")
      commit(dir, "feat(api): expose a profiles endpoint")
    end

    it "warns, inserts one, and generates the version entry from the commits" do
      out, err, status = run(dir, "release", "--version", "0.2.0", "--date", "2026-02-05", "--since", "v0.1.0")

      expect(status).to be_success, "stderr: #{err}"
      expect(out).to include("has no [Unreleased] section")

      text = File.read(File.join(dir, "CHANGELOG.md"))
      expect(text).to match(/\A# Changelog\n\n## \[Unreleased\]\n\n## \[0\.2\.0\] - 2026-02-05\n/)
      expect(section_for(text, "0.2.0")).to include("- **api**: expose a profiles endpoint")
      expect(text).to include("## [0.1.0] - 2026-01-01")
    end
  end

  describe "release, on a repository without a CHANGELOG.md" do
    before do
      commit(dir, "chore: initial commit")
      git(dir, "tag", "v0.1.0")
      commit(dir, "fix: stop leaking a thread local")
    end

    it "creates the file with the Keep a Changelog header" do
      out, err, status = run(dir, "release", "--version", "0.1.1", "--date", "2026-02-06", "--since", "v0.1.0")

      expect(status).to be_success, "stderr: #{err}"
      expect(out).to include("CHANGELOG.md does not exist, creating it.")

      text = File.read(File.join(dir, "CHANGELOG.md"))
      expect(text).to start_with("# Changelog\n")
      expect(text).to include("Keep a Changelog")
      expect(section_for(text, "0.1.1")).to include("- stop leaking a thread local")
    end
  end

  describe "check" do
    before do
      changelog(dir, "# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-01-01\n\n### Added\n\n- the first release\n")
      commit(dir, "chore: seed the changelog")
      git(dir, "checkout", "--quiet", "-b", "fix/leaking-thread-local")
    end

    it "fails when a releasable commit leaves [Unreleased] untouched" do
      commit(dir, "fix: stop leaking a thread local")

      out, err, status = run(dir, "check", "--base", "master")

      expect(status).not_to be_success
      expect(err).to include("changelog check: FAILED")
      expect(err).to include("fix: stop leaking a thread local")
      expect(err).to include("the [Unreleased] section of CHANGELOG.md is unchanged")
      expect(out).to be_empty
    end

    it "passes once the [Unreleased] section describes the change" do
      commit(dir, "fix: stop leaking a thread local")
      changelog(dir, <<~MD)
        # Changelog

        ## [Unreleased]

        ### Fixed

        - thread locals are released when a request ends

        ## [0.1.0] - 2026-01-01

        ### Added

        - the first release
      MD
      commit(dir, "ci: record the change under Unreleased")

      out, err, status = run(dir, "check", "--base", "master")

      expect(status).to be_success, "stderr: #{err}"
      expect(out).to include("changelog check: OK")
    end

    it "requires nothing when the branch holds no releasable commit" do
      commit(dir, "ci: add a lint job")
      commit(dir, "chore: bump a dev dependency")

      out, _err, status = run(dir, "check", "--base", "master")

      expect(status).to be_success
      expect(out).to include("no releasable commit")
    end

    it "catches a releasable line hidden in a commit body, like the release job does" do
      commit(dir, "chore: housekeeping\n\nfix: and quietly repair the cache key too")

      _out, err, status = run(dir, "check", "--base", "master")

      expect(status).not_to be_success
      expect(err).to include("changelog check: FAILED")
    end

    it "ignores edits made to an already released section" do
      commit(dir, "fix: stop leaking a thread local")
      changelog(dir, "# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-01-01\n\n### Added\n\n- the very first release\n")
      commit(dir, "ci: reword an old entry")

      _out, err, status = run(dir, "check", "--base", "master")

      expect(status).not_to be_success
      expect(err).to include("changelog check: FAILED")
    end
  end

  describe "coverage" do
    # v0.1.0 holds one feature and its release commit; v0.2.0 holds one fix, one
    # ci commit and its release commit.
    before do
      commit(dir, "feat: add the profiler")
      @feature = short_sha(dir)
      commit(dir, "chore(release): v0.1.0 [skip ci]")
      git(dir, "tag", "v0.1.0")
      commit(dir, "fix(ui): align the toolbar")
      @fix = short_sha(dir)
      commit(dir, "ci: add a lint job")
      @ci = short_sha(dir)
      commit(dir, "chore(release): bump version to v0.2.0")
      git(dir, "tag", "v0.2.0")
    end

    def complete_changelog(dir, extra: "")
      changelog(dir, <<~MD)
        # Changelog

        ## [Unreleased]

        ## [0.2.0] - 2026-02-01

        ### Fixed

        - **UI:** Align the toolbar <!-- #{@fix} -->

        <!-- excluded:
          #{@ci} pipeline only
        -->
        #{extra}
        ## [0.1.0] - 2026-01-01

        ### Added

        - Add the profiler <!-- #{@feature} -->
      MD
    end

    it "passes when every commit is described or explicitly excluded" do
      complete_changelog(dir)

      out, err, status = run(dir, "coverage")

      expect(status).to be_success, "stderr: #{err}"
      expect(out).to include("changelog coverage: OK")
      expect(out).to include("over 2 tag interval(s)")
    end

    it "accepts a section level covered block instead of per bullet references" do
      changelog(dir, <<~MD)
        # Changelog

        ## [0.2.0] - 2026-02-01

        ### Fixed

        - **UI:** Align the toolbar

        <!-- covered: #{@fix} -->
        <!-- excluded:
          #{@ci} pipeline only
        -->

        ## [0.1.0] - 2026-01-01

        ### Added

        - Add the profiler

        <!-- covered: #{@feature} -->
      MD

      _out, err, status = run(dir, "coverage")

      expect(status).to be_success, "stderr: #{err}"
    end

    it "treats the release commit of a version as covered by its subject alone" do
      complete_changelog(dir)

      _out, err, status = run(dir, "coverage")

      # Neither release commit is referenced anywhere, and both wordings pass.
      expect(status).to be_success, "stderr: #{err}"
      expect(err).not_to include("chore(release)")
    end

    it "does not take a release commit of another version for this one" do
      commit(dir, "chore(release): v0.9.9 [skip ci]")
      stray = short_sha(dir)
      git(dir, "tag", "v0.3.0")
      complete_changelog(dir, extra: "\n## [0.3.0] - 2026-03-01\n\n_Nothing._\n")

      _out, err, status = run(dir, "coverage")

      expect(status).not_to be_success
      expect(err).to include(stray)
    end

    it "fails on a commit that is neither described nor excluded" do
      changelog(dir, <<~MD)
        # Changelog

        ## [0.2.0] - 2026-02-01

        ### Fixed

        - **UI:** Align the toolbar <!-- #{@fix} -->

        ## [0.1.0] - 2026-01-01

        ### Added

        - Add the profiler <!-- #{@feature} -->
      MD

      _out, err, status = run(dir, "coverage")

      expect(status).not_to be_success
      expect(err).to include("changelog coverage: FAILED")
      expect(err).to include("## [0.2.0]")
      expect(err).to include("#{@ci} ci: add a lint job is neither described nor excluded")
    end

    it "fails on a reference that belongs to another interval" do
      changelog(dir, <<~MD)
        # Changelog

        ## [0.2.0] - 2026-02-01

        ### Fixed

        - **UI:** Align the toolbar <!-- #{@fix} -->
        - Add the profiler <!-- #{@feature} -->

        <!-- excluded:
          #{@ci} pipeline only
        -->

        ## [0.1.0] - 2026-01-01

        ### Added

        - Add the profiler <!-- #{@feature} -->
      MD

      _out, err, status = run(dir, "coverage")

      expect(status).not_to be_success
      expect(err).to include("#{@feature} is referenced here but does not belong to v0.1.0..v0.2.0")
    end

    it "fails on an exclusion without a reason" do
      complete_changelog(dir)
      text = File.read(File.join(dir, "CHANGELOG.md")).sub("#{@ci} pipeline only", @ci)
      File.write(File.join(dir, "CHANGELOG.md"), text)

      _out, err, status = run(dir, "coverage")

      expect(status).not_to be_success
      expect(err).to include("malformed reference")
    end

    it "fails on a reference to a commit that does not exist" do
      complete_changelog(dir, extra: "\n<!-- covered: 0123abc -->\n")

      _out, err, status = run(dir, "coverage")

      expect(status).not_to be_success
      expect(err).to include("0123abc is referenced but is not a commit of this repository")
    end

    it "fails on a missing version section" do
      changelog(dir, "# Changelog\n\n## [0.1.0] - 2026-01-01\n\n- Add the profiler <!-- #{@feature} -->\n")

      _out, err, status = run(dir, "coverage")

      expect(status).not_to be_success
      expect(err).to include("no `## [0.2.0]` section in CHANGELOG.md")
    end

    it "refuses to pass on a repository without tags" do
      Dir.mktmpdir("changelog-spec-untagged") do |untagged|
        init_repo(untagged)
        commit(untagged, "feat: add the profiler")
        changelog(untagged, "# Changelog\n\n## [Unreleased]\n")

        _out, err, status = run(untagged, "coverage")

        expect(status).not_to be_success
        expect(err).to include("no tag found in this repository")
        expect(err).to include("GIT_DEPTH")
      end
    end

    it "fails when the file is missing" do
      _out, err, status = run(dir, "coverage")

      expect(status).not_to be_success
      expect(err).to include("CHANGELOG.md not found")
    end
  end

  describe "history" do
    before do
      commit(dir, "feat: add the profiler")
      git(dir, "tag", "v0.1.0")
      commit(dir, "fix(ui): align the toolbar")
      commit(dir, "style: reformat")
      git(dir, "tag", "v0.1.1")
    end

    it "emits one section per tag, newest first, with an empty [Unreleased] on top" do
      out, err, status = run(dir, "history")

      expect(status).to be_success, "stderr: #{err}"
      expect(out).to match(/## \[Unreleased\]\n\n## \[0\.1\.1\] - \d{4}-\d{2}-\d{2}/)
      expect(out.index("## [0.1.1]")).to be < out.index("## [0.1.0]")
      expect(section_for(out, "0.1.1")).to include("- **ui**: align the toolbar")
      expect(section_for(out, "0.1.0")).to include("- add the profiler")
      expect(out).not_to include("reformat")
    end

    it "lists a breaking change whose type is normally skipped" do
      commit(dir, "chore(deps)!: drop Ruby 3.0 support")
      git(dir, "tag", "v0.2.0")

      out, _err, status = run(dir, "history")

      expect(status).to be_success
      expect(section_for(out, "0.2.0")).to include("### Changed")
      expect(section_for(out, "0.2.0")).to include("- **Breaking:** **deps**: drop Ruby 3.0 support")
      expect(section_for(out, "0.2.0")).not_to include("_No notable changes._")
    end

    it "lists a breaking change announced in a commit body" do
      commit(dir, "chore: rework the storage layout\n\nBREAKING CHANGE: profiles stored by 0.1.x are no longer readable")
      git(dir, "tag", "v0.2.0")

      out, _err, status = run(dir, "history")

      expect(status).to be_success
      expect(section_for(out, "0.2.0")).to include("- **Breaking:** rework the storage layout")
    end

    it "puts a breaking feature under Changed rather than Added" do
      commit(dir, "feat(api)!: drop the v1 profile endpoints")
      git(dir, "tag", "v0.2.0")

      out, _err, status = run(dir, "history")

      expect(status).to be_success
      expect(section_for(out, "0.2.0")).to include("### Changed")
      expect(section_for(out, "0.2.0")).not_to include("### Added")
    end

    it "marks a tag with nothing publishable" do
      commit(dir, "chore: tidy up")
      git(dir, "tag", "v0.1.2")

      out, _err, status = run(dir, "history")

      expect(status).to be_success
      expect(section_for(out, "0.1.2")).to include("_No notable changes._")
    end
  end
end
