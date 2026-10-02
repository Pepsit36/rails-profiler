#!/usr/bin/env bash
#
# Dry run for script/release.sh, with a simulated origin and simulated
# registries. No GitLab, no runner, no rubygems.org, no credential: the
# registries are directories, and the two probe functions plus the two push
# functions are replaced through the --stubs injection point.
#
# Scenarios:
#   1. normal release: changelog stamped, commit holding only CHANGELOG.md,
#      tag on that commit, atomic push, gem on both registries;
#   2. rubygems.org refuses the push, then the job is re-run on the same
#      pipeline SHA: the tag is already there, so the gem is published from the
#      tag to the registry that is still missing it;
#   3. master advanced during the pipeline: explicit failure, nothing pushed;
#   4. the push is refused (pre-receive hook standing in for a protected
#      branch): noisy failure naming the GitLab settings;
#   5. re-run while the version is present on both registries: exits 0 without
#      republishing anything;
#   6. a registry that refuses the push as already published: tolerated, but
#      only because a second probe confirms the version is really there.
#
# Usage: script/release-dry-run.sh [work directory]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${1:-$(mktemp -d)}"
FAILURES=0

banner() { printf '\n========== %s ==========\n' "$*"; }
ok() { printf 'PASS  %s\n' "$*"; }
ko() { printf 'FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

assert_has() {
  if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else ko "$3"; fi
}
assert_lacks() {
  if printf '%s' "$1" | grep -qF -- "$2"; then ko "$3"; else ok "$3"; fi
}
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else ko "$3 (got '$1', wanted '$2')"; fi
}

# --- the stubs the release script will source --------------------------------

write_stubs() {
  cat > "$1" <<'STUBS'
# Dry-run stubs. Sourced by script/release.sh after its own definitions, so
# these four functions plus build_gem replace the real registry access.
gem_present_gitlab() {
  if [ -f "$REG_DIR/gitlab/$1" ]; then
    log "  probe GitLab registry (simulated) for ${GEM_NAME} $1: present"
    return 0
  fi
  log "  probe GitLab registry (simulated) for ${GEM_NAME} $1: absent"
  return 1
}

gem_present_rubygems() {
  # Simulates a registry that accepted the version between our probe and our
  # push: the first probe answers "absent", later ones answer "present".
  if [ -f "$REG_DIR/rubygems.race" ] && [ ! -f "$REG_DIR/rubygems.race.used" ]; then
    touch "$REG_DIR/rubygems.race.used"
    log "  probe rubygems.org (simulated) for ${GEM_NAME} $1: absent"
    return 1
  fi
  if [ -f "$REG_DIR/rubygems/$1" ]; then
    log "  probe rubygems.org (simulated) for ${GEM_NAME} $1: present"
    return 0
  fi
  log "  probe rubygems.org (simulated) for ${GEM_NAME} $1: absent"
  return 1
}

build_gem() {
  printf '%s\n' "${GEM_NAME}-$1.gem"
}

gem_push_gitlab() {
  touch "$REG_DIR/gitlab/$1"
  printf 'Pushing gem to simulated GitLab registry...\nSuccessfully registered gem: %s (%s)\n' "$GEM_NAME" "$1"
}

gem_push_rubygems() {
  if [ -f "$REG_DIR/rubygems.down" ]; then
    printf 'Pushing gem to https://rubygems.org...\nThere was a problem saving your gem: 502 Bad Gateway\n'
    return 1
  fi
  if [ -f "$REG_DIR/rubygems/$1" ]; then
    printf 'Pushing gem to https://rubygems.org...\nRepushing of gem versions is not allowed.\n'
    return 1
  fi
  touch "$REG_DIR/rubygems/$1"
  printf 'Pushing gem to https://rubygems.org...\nSuccessfully registered gem: %s (%s)\n' "$GEM_NAME" "$1"
}
STUBS
}

# --- fixture ----------------------------------------------------------------

# Builds <case>/origin.git (bare master), <case>/work (clone at the pipeline
# SHA) and <case>/registry. Echoes the pipeline SHA.
make_fixture() {
  local case_dir="$1" origin="$1/origin.git" work="$1/work"

  mkdir -p "$case_dir" "$1/registry/gitlab" "$1/registry/rubygems"
  git init --quiet --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/master

  git init --quiet "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/master
  git -C "$work" config user.email "ci@gitlab"
  git -C "$work" config user.name "GitLab CI"

  mkdir -p "$work/bin" "$work/script" "$work/lib/profiler"
  cp "$REPO_ROOT/bin/changelog" "$work/bin/changelog"
  cp "$REPO_ROOT/script/release.sh" "$work/script/release.sh"
  printf '# frozen_string_literal: true\n\nmodule Profiler\n  VERSION = "0.0.0"\nend\n' \
    > "$work/lib/profiler/version.rb"
  cat > "$work/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

### Fixed

- a missing profile file no longer breaks the profile list

## [0.1.0] - 2026-01-01

### Added

- the first release
MD

  git -C "$work" add --all
  git -C "$work" commit --quiet -m "chore: initial tree"
  git -C "$work" tag v0.1.0
  printf 'touched\n' > "$work/touched.txt"
  git -C "$work" add --all
  git -C "$work" commit --quiet -m "fix(storage): survive a missing profile file"
  git -C "$work" remote add origin "$origin"
  git -C "$work" push --quiet origin master v0.1.0

  write_stubs "$case_dir/stubs.sh"
  git -C "$work" rev-parse HEAD
}

# Runs script/release.sh in a working copy, as the CI job would.
run_release() {
  local work="$1" case_dir="$2" sha="$3"
  (
    cd "$work" || exit 1
    REG_DIR="$case_dir/registry" \
    CI_COMMIT_SHA="$sha" \
    RUBYGEMS_API_KEY="dry-run-placeholder-not-a-secret" \
      bash script/release.sh --stubs "$case_dir/stubs.sh" 2>&1
  )
}

# A re-run of the job: GitLab checks out the same pipeline SHA in a fresh clone.
fresh_checkout() {
  local case_dir="$1" sha="$2" name="$3"
  git clone --quiet "$case_dir/origin.git" "$case_dir/$name"
  git -C "$case_dir/$name" config user.email "ci@gitlab"
  git -C "$case_dir/$name" config user.name "GitLab CI"
  git -C "$case_dir/$name" checkout --quiet --detach "$sha"
  printf '%s\n' "$case_dir/$name"
}

# --- scenario 1: normal release ---------------------------------------------

scenario_normal() {
  banner "1. normal release"
  local case_dir="$ROOT/normal" sha out
  sha="$(make_fixture "$case_dir")"
  out="$(run_release "$case_dir/work" "$case_dir" "$sha")"
  local status=$?
  printf '%s\n' "$out"

  printf -- '--- assertions ---\n'
  assert_eq "$status" "0" "the job succeeds"
  assert_has "$out" "Next version: 0.1.1" "0.1.1 derived from the fix: commit"
  assert_has "$out" "Reusing the 3 line(s) already written under [Unreleased]" "the hand written entry is reused"
  assert_has "$out" "Release commit" "a release commit is made"
  assert_has "$out" "Pushed the release commit and v0.1.1 to master" "commit and tag pushed atomically"
  assert_has "$out" "is published on both registries" "both registries got the gem"

  local tagged_files pushed_master changelog
  tagged_files="$(git -C "$case_dir/origin.git" show --format='' --name-only v0.1.1)"
  assert_eq "$tagged_files" "CHANGELOG.md" "the release commit holds CHANGELOG.md and nothing else"
  pushed_master="$(git -C "$case_dir/origin.git" rev-parse master)"
  assert_eq "$pushed_master" "$(git -C "$case_dir/origin.git" rev-list -n1 v0.1.1)" "the tag sits on the commit at the tip of master"
  changelog="$(git -C "$case_dir/origin.git" show "v0.1.1:CHANGELOG.md")"
  assert_has "$changelog" "## [0.1.1] - " "the pushed changelog carries the stamped section"
  assert_has "$changelog" "- a missing profile file no longer breaks the profile list" "the entry moved under 0.1.1"
  assert_lacks "$(git -C "$case_dir/origin.git" show v0.1.1 --format='' --name-only)" "version.rb" "version.rb was never committed"
  assert_has "$(cd "$case_dir/work" && git status --porcelain)" "lib/profiler/version.rb" "version.rb is only dirty in the workspace"
  assert_eq "$(ls "$case_dir/registry/gitlab")" "0.1.1" "GitLab registry holds 0.1.1"
  assert_eq "$(ls "$case_dir/registry/rubygems")" "0.1.1" "rubygems.org holds 0.1.1"
}

# --- scenario 2: failed publication, then re-run -----------------------------

scenario_retry() {
  banner "2. rubygems.org refuses, then the job is re-run on the same pipeline SHA"
  local case_dir="$ROOT/retry" sha out status rerun
  sha="$(make_fixture "$case_dir")"
  touch "$case_dir/registry/rubygems.down"

  printf -- '--- first run (rubygems.org down) ---\n'
  out="$(run_release "$case_dir/work" "$case_dir" "$sha")"
  status=$?
  printf '%s\n' "$out"
  printf -- '--- assertions ---\n'
  assert_eq "$status" "1" "the first run fails loudly"
  assert_has "$out" "502 Bad Gateway" "the rubygems.org refusal is in the log"
  assert_has "$out" "Pushed the release commit and v0.1.1 to master" "commit and tag are already pushed"
  assert_has "$out" "re-running this job will publish from the tag" "the log says what a re-run will do"
  assert_eq "$(ls "$case_dir/registry/gitlab")" "0.1.1" "GitLab registry got 0.1.1"
  assert_eq "$(ls "$case_dir/registry/rubygems")" "" "rubygems.org did not"

  rm -f "$case_dir/registry/rubygems.down"
  printf -- '--- re-run of the same job, fresh checkout of the pipeline SHA ---\n'
  rerun="$(fresh_checkout "$case_dir" "$sha" "rerun")"
  printf 'git describe --tags --abbrev=0 from the pipeline SHA: %s\n' \
    "$(git -C "$rerun" describe --tags --abbrev=0)"
  printf 'v0.1.1 is an ancestor of the pipeline SHA: %s\n' \
    "$(git -C "$rerun" merge-base --is-ancestor v0.1.1 "$sha" && echo yes || echo no)"
  out="$(run_release "$rerun" "$case_dir" "$sha")"
  status=$?
  printf '%s\n' "$out"
  printf -- '--- assertions ---\n'
  assert_eq "$status" "0" "the re-run succeeds"
  assert_has "$out" "Next version: 0.1.1" "the same version is derived again"
  assert_has "$out" "re-run of a release whose publication did not complete" "the re-run path is taken, not a skip"
  assert_lacks "$out" "already exists, skipping" "the old silent skip is gone"
  assert_has "$out" "Publishing 0.1.1 from the tag v0.1.1" "publication happens from the tag"
  assert_has "$out" "Registry gitlab: 0.1.1 already published, nothing to push" "GitLab is left alone"
  assert_has "$out" "Registry rubygems: pushed" "rubygems.org gets the gem"
  assert_eq "$(ls "$case_dir/registry/rubygems")" "0.1.1" "rubygems.org now holds 0.1.1"
  assert_eq "$(git -C "$case_dir/origin.git" rev-list --count master)" "3" "no second release commit was pushed"
}

# --- scenario 3: master advanced during the pipeline ------------------------

scenario_advanced() {
  banner "3. master advanced during the pipeline"
  local case_dir="$ROOT/advanced" sha out status other
  sha="$(make_fixture "$case_dir")"

  other="$case_dir/other"
  git clone --quiet "$case_dir/origin.git" "$other"
  git -C "$other" config user.email "dev@example.com"
  git -C "$other" config user.name "Someone Else"
  printf 'later\n' > "$other/later.txt"
  git -C "$other" add --all
  git -C "$other" commit --quiet -m "fix(ui): a later change"
  git -C "$other" push --quiet origin master

  out="$(run_release "$case_dir/work" "$case_dir" "$sha")"
  status=$?
  printf '%s\n' "$out"
  printf -- '--- assertions ---\n'
  assert_eq "$status" "1" "the job fails"
  assert_has "$out" "master advanced during this pipeline" "the reason is explicit"
  assert_has "$out" "Not rebasing" "no rebase is attempted"
  assert_has "$out" "no tag and no commit were pushed" "the log says nothing was pushed"
  assert_has "$out" "The next pipeline on master will publish this change" "the log says what happens next"
  assert_eq "$(git -C "$case_dir/origin.git" tag -l 'v0.1.1')" "" "no v0.1.1 tag on origin"
  assert_eq "$(git -C "$case_dir/origin.git" rev-parse master)" "$(git -C "$other" rev-parse HEAD)" "master is untouched by the job"
  assert_eq "$(ls "$case_dir/registry/gitlab")" "" "nothing was published"
}

# --- scenario 4: the push is refused ----------------------------------------

scenario_refused() {
  banner "4. the push is refused (protected branch / job token rights)"
  local case_dir="$ROOT/refused" sha out status hook
  sha="$(make_fixture "$case_dir")"

  hook="$case_dir/origin.git/hooks/pre-receive"
  cat > "$hook" <<'HOOK'
#!/bin/sh
echo "GitLab: You are not allowed to push code to protected branches on this project." >&2
exit 1
HOOK
  chmod +x "$hook"

  out="$(run_release "$case_dir/work" "$case_dir" "$sha")"
  status=$?
  printf '%s\n' "$out"
  printf -- '--- assertions ---\n'
  assert_eq "$status" "1" "the job fails"
  assert_has "$out" "was refused" "the refusal is reported"
  assert_has "$out" "No gem was published" "the log says the release is not done"
  assert_has "$out" 'Settings > CI/CD > Job token permissions > "Allow Git push requests to the repository"' "the job token setting is named"
  assert_has "$out" 'Settings > Repository > Protected branches > master > "Allowed to push and merge"' "the protected branch setting is named"
  assert_eq "$(git -C "$case_dir/origin.git" tag -l 'v0.1.1')" "" "no tag reached origin"
  assert_eq "$(ls "$case_dir/registry/gitlab")" "" "nothing was published"
}

# --- scenario 5: re-run with the version already on both registries ---------

scenario_already_everywhere() {
  banner "5. re-run while 0.1.1 is present on both registries"
  local case_dir="$ROOT/already" sha out status rerun
  sha="$(make_fixture "$case_dir")"
  out="$(run_release "$case_dir/work" "$case_dir" "$sha")" || true

  rerun="$(fresh_checkout "$case_dir" "$sha" "rerun")"
  out="$(run_release "$rerun" "$case_dir" "$sha")"
  status=$?
  printf '%s\n' "$out"
  printf -- '--- assertions ---\n'
  assert_eq "$status" "0" "the re-run exits 0"
  assert_has "$out" "already published on both registries, nothing to do" "nothing is republished"
  assert_lacks "$out" "Registry gitlab: pushed" "no push to GitLab"
  assert_lacks "$out" "Registry rubygems: pushed" "no push to rubygems.org"
  assert_eq "$(git -C "$case_dir/origin.git" rev-list --count master)" "3" "master is unchanged"
}

# --- scenario 6: the registry says "already published" -----------------------

scenario_already_published_refusal() {
  banner "6. a registry refuses the push as already published"
  local case_dir="$ROOT/refusal" sha out status
  sha="$(make_fixture "$case_dir")"
  # 0.1.1 is on rubygems.org, but the first probe will not see it.
  touch "$case_dir/registry/rubygems/0.1.1" "$case_dir/registry/rubygems.race"

  out="$(run_release "$case_dir/work" "$case_dir" "$sha")"
  status=$?
  printf '%s\n' "$out"
  printf -- '--- assertions ---\n'
  assert_eq "$status" "0" "the job succeeds"
  assert_has "$out" "Repushing of gem versions is not allowed" "the registry message is in the log"
  assert_has "$out" "refused as already published, re-probing to confirm" "the refusal alone is not trusted"
  assert_has "$out" "0.1.1 confirmed present, treating the refusal as success" "the second probe settles it"
  assert_has "$out" "is published on both registries" "the release completes"
}

printf 'Dry run workspace: %s\n' "$ROOT"
scenario_normal
scenario_retry
scenario_advanced
scenario_refused
scenario_already_everywhere
scenario_already_published_refusal

banner "summary"
if [ "$FAILURES" -eq 0 ]; then
  printf 'all dry-run assertions passed\n'
  exit 0
fi
printf '%s dry-run assertion(s) failed\n' "$FAILURES"
exit 1
