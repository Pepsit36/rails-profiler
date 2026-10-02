# CLAUDE.md

Instructions for Claude, and any other agent, working in this repository.

## Versions are computed, never chosen

- `lib/profiler/version.rb` stays at `0.0.0` on `master`. Never edit it and never bump a version
  by hand. The `release` CI job sets it for the build only, and never commits it.
- The version comes from `bin/changelog version`, the single implementation shared by the branch
  stamp, the branch check and the release job.
- On a branch, the base is the highest of the last tag reachable from HEAD **and** the versions
  `CHANGELOG.md` already carries outside your own section, so a version stamped by a branch merged
  before yours counts; the commits that decide the bump are the ones your branch adds on top of
  `master`, not everything since the last tag. `bin/changelog stamp` prints both, as in
  `Counting from origin/master (0a1b2c3d): base 1.1.0, publishing 1.1.1.`
- Only three things publish: `feat:` publishes a minor, `fix:` publishes a patch, and a breaking
  marker (`BREAKING CHANGE:` in a body, or `type!:`) publishes a major. **Every other type
  publishes nothing**, `perf`, `build`, `deps`, `revert`, `security`, `refactor`, `docs`, `chore`,
  `ci`, `test` and `style` included.
- So a revert that users need to receive has to be written as a `fix:`. `revert:` alone reaches
  nobody: the gem is never republished and the fix stays in the registry.
- Merging a `fix:` or `feat:` commit into `master` **publishes the gem** to the GitLab registry
  and to rubygems.org. Choose the commit type deliberately.
- **Only non-merge commits count.** A merge commit repeats the merge request title, and titles
  are not read: a request titled `feat:` whose commits are all fixes publishes a patch. Write a
  title that describes the request anyway, for the humans reading it.
- Do not merge by squash. The squashed commit carries the merge request title, so its type can
  disagree with the version stamped in the branch; the `release` job then refuses to publish and
  says so. This project merges with a merge commit.

## Every releasable branch stamps CHANGELOG.md

1. Describe the change under `## [Unreleased]` in `CHANGELOG.md`, in Keep a Changelog form
   (`### Added`, `### Changed`, `### Removed`, `### Fixed`, `### Security`), written for a user of
   the gem: what changes for them, not which file moved. Follow the style of the entries already
   there: bold scope, full sentence, code in backticks.
2. When the branch is ready, run `bin/changelog stamp`. It works out the version this merge will
   publish and turns `[Unreleased]` into `[X.Y.Z] - YYYY-MM-DD`, reopening an empty one above.
   Commit `CHANGELOG.md`.
3. After any rebase on `master`, or any new commit, run `bin/changelog stamp` again: it corrects
   the number and the date, and folds the new `[Unreleased]` entries into the stamped section.
4. Never edit a section that already carries a tag.

A section written by `stamp` carries `<!-- stamped -->` and no sha. The sha comments at the end of
bullets belong to the older sections only: do not remove them, and never invent one.

Two open merge requests both touching `CHANGELOG.md` will conflict, every time. Resolve it by
putting **your own** entries back under `## [Unreleased]`, leaving every section below it exactly
as it was, then running `bin/changelog stamp` again, which gives your section the number that
follows theirs. Never fold your entry into someone else's section and never drop it; the branch
check compares the file with the merge base and fails if a section it inherited was changed,
reordered or removed.

`changelog:check` runs in the branch pipeline, on every branch except the default one. It fails
when the branch has a publishable commit and the top section of `CHANGELOG.md` does not carry
exactly the version the merge will publish, and when a section is stamped with no publishable
commit behind it. Its message names the version and the command:

    This branch publishes 0.30.5, but [Unreleased] is still the top section of CHANGELOG.md.
    Run `bin/changelog stamp` and commit CHANGELOG.md.

Run it; do not work around the check. The same job runs `bin/changelog coverage`, which walks
every tag interval reachable from HEAD and wants each non-merge commit either cited by its sha in
the section of its version, or listed in that section's `excluded:` comment with a reason, or
inside a `<!-- stamped -->` section, which accounts for its whole interval.

## Merging

- The project merges with "Merge commit with semi-linear history": a branch has to be rebased on
  `master` before it can merge, which is what keeps the stamped version correct. After a rebase,
  stamp again.
- The `release` resource group must process its pipelines oldest first, otherwise two merges a few
  minutes apart can publish out of order; the job refuses to publish rather than get it wrong.
- Merges go through the merge request and its pipeline. Never push to `master`; the CI does not
  either, it only pushes a tag.

## Commits

- English, Conventional Commits, with a scope when one applies: `fix(instrumentation): ...`.
- Branch names: `feature/...`, `bugfix/...`, `hotfix/...`, `fix/...`, `breaking/...` get a
  `canary` prerelease published on every push, which is expected. Any other prefix works too,
  without the prerelease.
- No history rewrite on a shared branch: follow-up commits.
- No em dash anywhere: code, commits, CHANGELOG, merge request descriptions.

## Tests

- `bundle exec rspec` must pass. CI runs it on `ruby:3.3`.
- `bash script/release-dry-run.sh` must pass after any change to `script/release.sh`,
  `bin/changelog` or the `release` job. It needs no network and no credential.
