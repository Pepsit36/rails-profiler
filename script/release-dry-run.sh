#!/usr/bin/env bash
#
# Dry run for the branch stamp and for script/release.sh, with a simulated
# origin and simulated registries. No GitLab, no runner, no rubygems.org, no
# credential: the registries are directories, and the two probe functions, the
# two push functions and the gem build are replaced through the --stubs
# injection point of script/release.sh.
#
# Scenarios:
#    1. normal release: the tag alone is pushed, no commit, gem on both registries;
#    2. nothing in the job commits or pushes a branch;
#    3. re-run of a publication that did not complete;
#    4. the tag push is refused;
#    5. re-run while the version is on both registries;
#    6. a registry refuses the push as already published;
#    7. the real GitLab registry probe against a stand-in Packages API;
#    8. app/assets/builds missing or expired;
#    9. a CHANGELOG with no released section;
#   10. the coverage check right after a publication, a stale reference, no tags;
#   11. a version published on master while a branch is open;
#   12. stamp on a fresh branch, then the branch check;
#   13. stamp run again after new commits on the branch;
#   14. the branch check without a stamp, and what its message says;
#   15. the release refuses a section that disagrees with the commits;
#   16. two close merges: the second branch stamps the version after the first;
#   17. two close merges whose pipelines run out of order, then in order;
#   18. a merge titled feat over a branch holding only a fix;
#   19. a squash merge, whose single commit carries the merge request title;
#   20. a branch of tooling commits only: nothing published, nothing tagged;
#   21. a stamped section with nothing publishable behind it.
#
# Usage: script/release-dry-run.sh [work directory]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${1:-$(mktemp -d)}"
FAILURES=0

banner() { printf '\n========== %s ==========\n' "$*"; }
step() { printf -- '--- %s ---\n' "$*"; }
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

# --- a stand-in for the GitLab Packages API ---------------------------------

# Simulates the two behaviours that matter: the collection endpoint is capped at
# 100 entries per page and ordered by created_at ascending, so an old canary
# preversion fills the page; and package_name is a fuzzy filter, so entries for
# other packages come back too.
write_fake_curl() {
  cat > "$1" <<'CURL'
#!/bin/sh
url=""
for arg in "$@"; do
  case "$arg" in http*) url="$arg" ;;
  esac
done

case "${FAKE_API_MODE:-}" in
  paged)
    if printf '%s' "$url" | grep -q 'package_version=0\.1\.1'; then
      printf '[{"id":9,"name":"rails-profiler","version":"0.1.1","package_type":"rubygems"}]'
    else
      printf '['
      i=1
      while [ "$i" -le 100 ]; do
        [ "$i" -gt 1 ] && printf ','
        printf '{"id":%s,"name":"rails-profiler","version":"0.0.9.pre.c%s","package_type":"rubygems"}' "$i" "$i"
        i=$((i + 1))
      done
      printf ']'
    fi
    ;;
  fuzzy)
    printf '[{"id":1,"name":"rails-profiler-extras","version":"0.1.1","package_type":"rubygems"},'
    printf '{"id":2,"name":"rails-profiler","version":"0x1x1","package_type":"rubygems"}]'
    ;;
  *)
    printf '[]'
    ;;
esac
CURL
  chmod +x "$1"
}

# Runs the real gem_present_gitlab on its own, against the fake API.
probe_gitlab() {
  local case_dir="$1" mode="$2"
  (
    cd "$case_dir" || exit 1
    PATH="$case_dir/fakebin:$PATH" \
    FAKE_API_MODE="$mode" \
    RELEASE_SH_SOURCE_ONLY=1 \
    CI_API_V4_URL="https://gitlab.example/api/v4" \
    CI_PROJECT_ID=42 \
    CI_JOB_TOKEN="dry-run-placeholder-not-a-secret" \
      bash -c ". \"$REPO_ROOT/script/release.sh\"
               if gem_present_gitlab 0.1.1; then echo RESULT=present; else echo RESULT=absent; fi" 2>&1
  )
}

# --- fixture ----------------------------------------------------------------

add_unreleased_entry() {
  ruby -e '
    path, heading, entry = ARGV
    text = File.read(path)
    File.write(path, text.sub("## [Unreleased]\n", "## [Unreleased]\n\n### #{heading}\n\n#{entry}\n"))
  ' "$1" "$2" "$3"
}

# Builds <case>/origin.git (bare master holding v0.1.0 and its changelog),
# <case>/work (clone of master) and <case>/registry.
make_fixture() {
  local case_dir="$1" origin="$1/origin.git" work="$1/work"

  mkdir -p "$case_dir" "$1/registry/gitlab" "$1/registry/rubygems"
  git init --quiet --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/master

  git init --quiet "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/master
  git -C "$work" config user.email "dev@example.com"
  git -C "$work" config user.name "A Developer"

  mkdir -p "$work/bin" "$work/script" "$work/lib/profiler"
  cp "$REPO_ROOT/bin/changelog" "$work/bin/changelog"
  cp "$REPO_ROOT/script/release.sh" "$work/script/release.sh"
  printf '# frozen_string_literal: true\n\nmodule Profiler\n  VERSION = "0.0.0"\nend\n' \
    > "$work/lib/profiler/version.rb"
  # Stands in for the artifacts handed over by the `build` job: git ignored
  # here as in the real repository, so a fresh clone does not get them.
  printf 'app/assets/builds/\n' > "$work/.gitignore"
  mkdir -p "$work/app/assets/builds"
  printf 'console.log("built");\n' > "$work/app/assets/builds/profiler.js"
  printf '.profiler{}\n' > "$work/app/assets/builds/profiler.css"
  cat > "$work/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

## [0.1.0] - 2026-01-01

### Added

- The first release
MD

  git -C "$work" add --all
  git -C "$work" commit --quiet -m "chore(release): v0.1.0 [skip ci]"
  git -C "$work" tag v0.1.0
  git -C "$work" remote add origin "$origin"
  git -C "$work" push --quiet origin master v0.1.0
  git -C "$work" update-ref refs/remotes/origin/master master

  write_stubs "$case_dir/stubs.sh"
}

# A branch with one commit, its entry under [Unreleased], and the stamp.
author_branch() {
  local work="$1" branch="$2" subject="$3"
  local entry="${4:-- **Storage:** A missing profile file no longer breaks the list}"

  git -C "$work" checkout --quiet -b "$branch" master
  printf '%s\n' "$subject" >> "$work/touched.txt"
  git -C "$work" add --all
  git -C "$work" commit --quiet -m "$subject"

  add_unreleased_entry "$work/CHANGELOG.md" "Fixed" "$entry"
  git -C "$work" add --all
  git -C "$work" commit --quiet -m "docs: describe the change"
  (cd "$work" && ruby bin/changelog stamp --default-branch master > /dev/null)
  git -C "$work" add --all
  git -C "$work" commit --quiet -m "docs: stamp the changelog"
}

merge_branch() {
  local work="$1" branch="$2" title="${3:-}"
  [ -n "$title" ] || title="Merge branch '${branch}' into 'master'"
  git -C "$work" checkout --quiet master
  git -C "$work" merge --quiet --no-ff -m "$title" "$branch"
  git -C "$work" push --quiet origin master
  git -C "$work" update-ref refs/remotes/origin/master master
}

# Runs script/release.sh on a working copy, as the CI job would.
run_release() {
  local work="$1" case_dir="$2" sha="${3:-}"
  [ -n "$sha" ] || sha="$(git -C "$work" rev-parse HEAD)"
  (
    cd "$work" || exit 1
    REG_DIR="$case_dir/registry" \
    CI_COMMIT_SHA="$sha" \
    RUBYGEMS_API_KEY="dry-run-placeholder-not-a-secret" \
      bash script/release.sh --stubs "$case_dir/stubs.sh" 2>&1
  )
}

# A pipeline runs on a fresh checkout of one commit.
pipeline_checkout() {
  local case_dir="$1" sha="$2" name="$3"
  git clone --quiet "$case_dir/origin.git" "$case_dir/$name"
  git -C "$case_dir/$name" config user.email "ci@gitlab"
  git -C "$case_dir/$name" config user.name "GitLab CI"
  git -C "$case_dir/$name" checkout --quiet --detach "$sha"
  mkdir -p "$case_dir/$name/app/assets/builds"
  printf 'console.log("built");\n' > "$case_dir/$name/app/assets/builds/profiler.js"
  printf '%s\n' "$case_dir/$name"
}

tags_on_origin() { git -C "$1/origin.git" tag -l | tr '\n' ' '; }
top_section() { grep -m1 '^## \[0' "$1"; }

# --- scenarios ---------------------------------------------------------------

scenario_normal() {
  banner "1. normal release"
  local case_dir="$ROOT/normal" out status
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"
  merge_branch "$case_dir/work" "fix/missing-file"

  out="$(run_release "$case_dir/work" "$case_dir")"
  status=$?
  printf '%s\n' "$out"

  step assertions
  assert_eq "$status" "0" "the job succeeds"
  assert_has "$out" "CHANGELOG.md says 0.1.1 at the top" "the stamped version is read from the file"
  assert_has "$out" "compute 0.1.1" "the commits compute the same version"
  assert_has "$out" "Pushed v0.1.1" "the tag is pushed"
  assert_has "$out" "is published on both registries" "both registries got the gem"
  assert_eq "$(tags_on_origin "$case_dir")" "v0.1.0 v0.1.1 " "origin carries both tags"
  assert_eq "$(git -C "$case_dir/origin.git" rev-list -n1 v0.1.1)" \
            "$(git -C "$case_dir/origin.git" rev-parse master)" "the tag sits on the merged commit"
  assert_eq "$(ls "$case_dir/registry/gitlab")" "0.1.1" "GitLab registry holds 0.1.1"
  assert_eq "$(ls "$case_dir/registry/rubygems")" "0.1.1" "rubygems.org holds 0.1.1"
}

scenario_no_commit() {
  banner "2. the job commits nothing and pushes no branch"
  local case_dir="$ROOT/nocommit" before after out
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"
  merge_branch "$case_dir/work" "fix/missing-file"
  before="$(git -C "$case_dir/origin.git" rev-parse master)"

  out="$(run_release "$case_dir/work" "$case_dir")"
  after="$(git -C "$case_dir/origin.git" rev-parse master)"

  step assertions
  assert_eq "$after" "$before" "master is exactly where the merge left it"
  assert_eq "$(git -C "$case_dir/origin.git" log --format='%s' master | grep -c 'chore(release)')" "1" \
            "the only chore(release) commit is the one the fixture made"
  assert_eq "$(grep -cE 'git commit|--atomic|HEAD:master' "$REPO_ROOT/script/release.sh")" "0" \
            "script/release.sh holds no commit and no branch push at all"
}

scenario_retry() {
  banner "3. re-run of a publication that did not complete"
  local case_dir="$ROOT/retry" out status rerun sha
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"
  merge_branch "$case_dir/work" "fix/missing-file"
  sha="$(git -C "$case_dir/work" rev-parse HEAD)"
  touch "$case_dir/registry/rubygems.down"

  step "first run, rubygems.org down"
  out="$(run_release "$case_dir/work" "$case_dir")"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "1" "the first run fails loudly"
  assert_has "$out" "Pushed v0.1.1" "the tag is already pushed"
  assert_eq "$(ls "$case_dir/registry/gitlab")" "0.1.1" "GitLab registry got 0.1.1"
  assert_eq "$(ls "$case_dir/registry/rubygems")" "" "rubygems.org did not"

  rm -f "$case_dir/registry/rubygems.down"
  step "re-run of the same job, fresh checkout of the same commit"
  rerun="$(pipeline_checkout "$case_dir" "$sha" "rerun")"
  printf 'git describe --tags --abbrev=0: %s\n' "$(git -C "$rerun" describe --tags --abbrev=0)"
  printf 'git tag --points-at HEAD:      %s\n' "$(git -C "$rerun" tag --points-at HEAD | tr '\n' ' ')"
  out="$(run_release "$rerun" "$case_dir" "$sha")"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "0" "the re-run succeeds"
  assert_has "$out" "already on HEAD: this is a re-run" "the re-run path is taken before any computation"
  assert_lacks "$out" "Nothing to publish since" "the old silent skip never happens"
  assert_has "$out" "Registry gitlab: 0.1.1 already published" "GitLab is left alone"
  assert_has "$out" "Registry rubygems: pushed" "rubygems.org gets the gem"
  assert_eq "$(ls "$case_dir/registry/rubygems")" "0.1.1" "rubygems.org now holds 0.1.1"
}

scenario_tag_refused() {
  banner "4. the tag push is refused"
  local case_dir="$ROOT/refused" out status hook
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"
  merge_branch "$case_dir/work" "fix/missing-file"

  hook="$case_dir/origin.git/hooks/pre-receive"
  cat > "$hook" <<'HOOK'
#!/bin/sh
echo "GitLab: You are not allowed to create this tag as it is protected." >&2
exit 1
HOOK
  chmod +x "$hook"

  out="$(run_release "$case_dir/work" "$case_dir")"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "1" "the job fails"
  assert_has "$out" "pushing the tag v0.1.1 was refused" "the refusal is reported"
  assert_has "$out" "No gem was published" "the log says the release is not done"
  assert_has "$out" "Protected tags" "the setting to check is named"
  assert_eq "$(tags_on_origin "$case_dir")" "v0.1.0 " "no tag reached origin"
  assert_eq "$(ls "$case_dir/registry/gitlab")" "" "nothing was published"
}

scenario_already_everywhere() {
  banner "5. re-run while 0.1.1 is present on both registries"
  local case_dir="$ROOT/already" out status rerun sha
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"
  merge_branch "$case_dir/work" "fix/missing-file"
  sha="$(git -C "$case_dir/work" rev-parse HEAD)"
  run_release "$case_dir/work" "$case_dir" > /dev/null

  rerun="$(pipeline_checkout "$case_dir" "$sha" "rerun")"
  out="$(run_release "$rerun" "$case_dir" "$sha")"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "0" "the re-run exits 0"
  assert_has "$out" "already published on both registries, nothing to do" "nothing is republished"
  assert_lacks "$out" "Registry gitlab: pushed" "no push to GitLab"
  assert_lacks "$out" "Registry rubygems: pushed" "no push to rubygems.org"
}

scenario_already_published_refusal() {
  banner "6. a registry refuses the push as already published"
  local case_dir="$ROOT/refusal" out status
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"
  merge_branch "$case_dir/work" "fix/missing-file"
  touch "$case_dir/registry/rubygems/0.1.1" "$case_dir/registry/rubygems.race"

  out="$(run_release "$case_dir/work" "$case_dir")"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "0" "the job succeeds"
  assert_has "$out" "Repushing of gem versions is not allowed" "the registry message is in the log"
  assert_has "$out" "refused as already published, re-probing to confirm" "the refusal alone is not trusted"
  assert_has "$out" "0.1.1 confirmed present, treating the refusal as success" "the second probe settles it"
}

scenario_gitlab_probe() {
  banner "7. GitLab registry probe against a simulated Packages API"
  local case_dir="$ROOT/probe" out
  mkdir -p "$case_dir/fakebin"
  write_fake_curl "$case_dir/fakebin/curl"

  step "0.1.1 exists, but page 1 is full of older canary preversions"
  out="$(probe_gitlab "$case_dir" paged)"
  printf '%s\n' "$out"
  assert_has "$out" "RESULT=present" "the probe finds a version that is not on page 1"

  step "only another package has 0.1.1, and this one has 0x1x1"
  out="$(probe_gitlab "$case_dir" fuzzy)"
  printf '%s\n' "$out"
  assert_has "$out" "RESULT=absent" "the probe does not take another package, or 0x1x1, for 0.1.1"
}

scenario_missing_assets() {
  banner "8. app/assets/builds missing or expired"
  local case_dir="$ROOT/assets" out status
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"
  merge_branch "$case_dir/work" "fix/missing-file"
  rm -rf "$case_dir/work/app/assets/builds"

  out="$(run_release "$case_dir/work" "$case_dir")"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "1" "the job fails"
  assert_has "$out" "app/assets/builds is missing or empty" "the reason is explicit"
  assert_has "$out" "they expired" "expired artifacts are named as a cause"
  assert_has "$out" "Re-run the whole pipeline, not just this job" "the fix is spelled out"
  assert_eq "$(tags_on_origin "$case_dir")" "v0.1.0 " "nothing was tagged"
  assert_eq "$(ls "$case_dir/registry/gitlab")" "" "nothing was published"
}

scenario_no_section() {
  banner "9. a CHANGELOG with no released section"
  local case_dir="$ROOT/nosection" out status
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"
  merge_branch "$case_dir/work" "fix/missing-file"
  printf '# Changelog\n\n## [Unreleased]\n' > "$case_dir/work/CHANGELOG.md"

  out="$(run_release "$case_dir/work" "$case_dir")"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "1" "the job fails"
  assert_has "$out" "no released section found" "the reason is explicit"
  assert_eq "$(tags_on_origin "$case_dir")" "v0.1.0 " "nothing was tagged"
}

scenario_coverage_after_release() {
  banner "10. the coverage check, right after a publication"
  local case_dir="$ROOT/coverage" out status
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"
  merge_branch "$case_dir/work" "fix/missing-file"
  run_release "$case_dir/work" "$case_dir" > /dev/null

  step "bin/changelog coverage, on the released tree"
  out="$(cd "$case_dir/work" && ruby bin/changelog coverage 2>&1)"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "0" "coverage passes immediately after the publication"
  assert_has "$out" "changelog coverage: OK" "every commit of both intervals is accounted for"

  step "a sha cited in the wrong interval"
  (cd "$case_dir/work" && sed -i "s|- The first release|- The first release <!-- $(git rev-parse --short=7 HEAD) -->|" CHANGELOG.md)
  out="$(cd "$case_dir/work" && ruby bin/changelog coverage 2>&1)"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "1" "coverage fails"
  assert_has "$out" "does not belong to" "the stale reference is named"

  step "a clone without tags"
  git clone --quiet --no-tags "$case_dir/origin.git" "$case_dir/untagged"
  out="$(cd "$case_dir/untagged" && ruby bin/changelog coverage 2>&1)"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "1" "coverage refuses to pass with no tag"
  assert_has "$out" "no tag reachable from HEAD" "the reason is explicit"
  assert_has "$out" "GIT_DEPTH" "the usual cause is named"
}

scenario_tag_published_during_branch() {
  banner "11. a version is published on master while a branch is open"
  local case_dir="$ROOT/newtag" out status clone
  make_fixture "$case_dir"
  git -C "$case_dir/work" checkout --quiet -b feature/later master
  git -C "$case_dir/work" push --quiet origin feature/later

  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"
  merge_branch "$case_dir/work" "fix/missing-file"
  run_release "$case_dir/work" "$case_dir" > /dev/null
  printf 'origin now carries: %s\n' "$(tags_on_origin "$case_dir")"

  step "what changelog:check does on that branch, in order"
  clone="$case_dir/branchclone"
  git init --quiet "$clone"
  git -C "$clone" remote add origin "$case_dir/origin.git"
  git -C "$clone" fetch --quiet origin feature/later
  git -C "$clone" checkout --quiet -B feature/later FETCH_HEAD
  git -C "$clone" fetch --quiet origin "+refs/heads/master:refs/remotes/origin/master"
  printf 'git tag:               %s\n' "$(git -C "$clone" tag -l | tr '\n' ' ')"
  printf 'git tag --merged HEAD: %s\n' "$(git -C "$clone" tag -l --merged HEAD | tr '\n' ' ')"

  out="$(cd "$clone" && ruby bin/changelog coverage 2>&1)"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_has "$(git -C "$clone" tag -l)" "v0.1.1" "the fetch of master brought the newer tag along"
  assert_eq "$status" "0" "coverage passes on a branch that predates the publication"
  assert_has "$out" "changelog coverage: OK" "only the tags reachable from HEAD are walked"
}

scenario_stamp_fresh() {
  banner "12. stamp on a fresh branch, then the branch check"
  local case_dir="$ROOT/stamp" out status
  make_fixture "$case_dir"
  git -C "$case_dir/work" checkout --quiet -b fix/missing-file master
  printf 'work\n' >> "$case_dir/work/touched.txt"
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "fix(storage): survive a missing profile file"
  add_unreleased_entry "$case_dir/work/CHANGELOG.md" "Fixed" \
    "- **Storage:** A missing profile file no longer breaks the list"
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "docs: describe the change"

  step "bin/changelog stamp"
  out="$(cd "$case_dir/work" && ruby bin/changelog stamp --default-branch master 2>&1)"
  status=$?
  printf '%s\n' "$out"
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "docs: stamp the changelog"
  sed -n '1,20p' "$case_dir/work/CHANGELOG.md"

  step assertions
  assert_eq "$status" "0" "stamp succeeds"
  assert_has "$out" "publishing 0.1.1" "it names the version the merge will publish"
  assert_has "$(cat "$case_dir/work/CHANGELOG.md")" "## [0.1.1] - " "the section carries the number and a date"
  assert_has "$(cat "$case_dir/work/CHANGELOG.md")" "<!-- stamped -->" "the section is marked as stamped"
  assert_lacks "$(sed -n '/## \[0.1.1\]/,/## \[0.1.0\]/p' "$case_dir/work/CHANGELOG.md" | grep -v stamped)" "<!--" \
               "no sha in the stamped section"

  step "bin/changelog check"
  out="$(cd "$case_dir/work" && ruby bin/changelog check --base master 2>&1)"
  status=$?
  printf '%s\n' "$out"
  assert_eq "$status" "0" "the branch check passes"
  assert_has "$out" "this branch publishes 0.1.1" "the check agrees with the stamp"
}

scenario_stamp_again() {
  banner "13. stamp run again after new commits on the branch"
  local case_dir="$ROOT/restamp" out status
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"
  printf 'before: %s\n' "$(top_section "$case_dir/work/CHANGELOG.md")"

  step "a feature lands on the branch, with its entry"
  printf 'more\n' >> "$case_dir/work/touched.txt"
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "feat(api): expose a profiles endpoint"
  add_unreleased_entry "$case_dir/work/CHANGELOG.md" "Added" "- **API:** Expose a profiles endpoint"
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "docs: describe the feature"

  out="$(cd "$case_dir/work" && ruby bin/changelog stamp --default-branch master 2>&1)"
  status=$?
  printf '%s\n' "$out"
  sed -n '1,22p' "$case_dir/work/CHANGELOG.md"

  step assertions
  assert_eq "$status" "0" "stamp succeeds"
  assert_has "$out" "0.1.1 becomes 0.2.0" "it says which number it corrected"
  assert_has "$(top_section "$case_dir/work/CHANGELOG.md")" "## [0.2.0]" "the section now carries 0.2.0"
  assert_lacks "$(cat "$case_dir/work/CHANGELOG.md")" "## [0.1.1]" "the wrong number is gone"
  assert_has "$(cat "$case_dir/work/CHANGELOG.md")" "- **API:** Expose a profiles endpoint" "the new entry was folded in"
  assert_has "$(cat "$case_dir/work/CHANGELOG.md")" "- **Storage:** A missing profile file no longer breaks the list" \
             "the earlier entry is still there"
}

scenario_check_without_stamp() {
  banner "14. the branch check without a stamp"
  local case_dir="$ROOT/nostamp" out status
  make_fixture "$case_dir"
  git -C "$case_dir/work" checkout --quiet -b fix/missing-file master
  printf 'work\n' >> "$case_dir/work/touched.txt"
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "fix(storage): survive a missing profile file"

  out="$(cd "$case_dir/work" && ruby bin/changelog check --base master 2>&1)"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "1" "the check fails"
  assert_has "$out" "This branch publishes 0.1.1" "it names the version"
  assert_has "$out" "bin/changelog stamp" "it names the command to run"
}

scenario_release_disagrees() {
  banner "15. the release refuses a section that disagrees with the commits"
  local case_dir="$ROOT/disagree" out status
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"
  step "the author then adds a feature and forgets to stamp again"
  printf 'more\n' >> "$case_dir/work/touched.txt"
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "feat(api): expose a profiles endpoint"
  merge_branch "$case_dir/work" "fix/missing-file"

  out="$(run_release "$case_dir/work" "$case_dir")"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "1" "the job fails"
  assert_has "$out" "disagree about the version" "the reason is explicit"
  assert_has "$out" "says 0.1.1" "the file version is named"
  assert_has "$out" "compute  0.2.0" "the computed version is named"
  assert_has "$out" "Nothing was tagged and nothing was published" "it says nothing happened"
  assert_has "$out" "bin/changelog stamp" "it says what to run"
  assert_eq "$(tags_on_origin "$case_dir")" "v0.1.0 " "no tag reached origin"
  assert_eq "$(ls "$case_dir/registry/gitlab")" "" "nothing was published"
}

scenario_two_merges_stamp() {
  banner "16. two close merges: the second branch stamps the version after the first"
  local case_dir="$ROOT/twostamp" out
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/first" "fix(first): the first fix"
  merge_branch "$case_dir/work" "fix/first"
  printf 'master holds, untagged: %s\n' "$(top_section "$case_dir/work/CHANGELOG.md")"
  printf 'tags on origin:         %s\n' "$(tags_on_origin "$case_dir")"

  step "the second branch, cut after that merge, stamps"
  git -C "$case_dir/work" checkout --quiet -b fix/second master
  printf 'second\n' >> "$case_dir/work/touched.txt"
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "fix(second): the second fix"
  out="$(cd "$case_dir/work" && ruby bin/changelog stamp --default-branch master 2>&1)"
  printf '%s\n' "$out"

  step assertions
  assert_has "$out" "base 0.1.1, publishing 0.1.2" "the base is the untagged section, not the last tag"
  assert_has "$(top_section "$case_dir/work/CHANGELOG.md")" "## [0.1.2]" "the new section is 0.1.2"
  assert_has "$(cat "$case_dir/work/CHANGELOG.md")" "## [0.1.1]" "the inherited section is untouched"
}

scenario_two_merges_order() {
  banner "17. two close merges whose pipelines run out of order, then in order"
  local case_dir="$ROOT/twoorder" out status first second clone
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/first" "fix(first): the first fix"
  merge_branch "$case_dir/work" "fix/first"
  first="$(git -C "$case_dir/work" rev-parse HEAD)"

  git -C "$case_dir/work" checkout --quiet -b fix/second master
  printf 'second\n' >> "$case_dir/work/touched.txt"
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "fix(second): the second fix"
  (cd "$case_dir/work" && ruby bin/changelog stamp --default-branch master > /dev/null)
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "docs: stamp the changelog"
  merge_branch "$case_dir/work" "fix/second"
  second="$(git -C "$case_dir/work" rev-parse HEAD)"

  step "the pipeline of the second merge runs first"
  clone="$(pipeline_checkout "$case_dir" "$second" "second-first")"
  out="$(run_release "$clone" "$case_dir" "$second")"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "1" "it fails rather than publishing out of order"
  assert_has "$out" "an older stamped version is still waiting to be published: 0.1.1" "the pending version is named"
  assert_has "$out" "process_mode" "the resource group setting is named"
  assert_has "$out" "re-run" "it says a re-run will succeed"
  assert_eq "$(tags_on_origin "$case_dir")" "v0.1.0 " "nothing was tagged"
  assert_eq "$(ls "$case_dir/registry/gitlab")" "" "nothing was published"

  step "oldest first: the pipeline of the first merge"
  clone="$(pipeline_checkout "$case_dir" "$first" "first-run")"
  out="$(run_release "$clone" "$case_dir" "$first")"
  printf '%s\n' "$out"
  assert_has "$out" "Pushed v0.1.1" "the first merge publishes 0.1.1"

  step "then the pipeline of the second merge, re-run"
  clone="$(pipeline_checkout "$case_dir" "$second" "second-rerun")"
  out="$(run_release "$clone" "$case_dir" "$second")"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "0" "it succeeds now"
  assert_has "$out" "Pushed v0.1.2" "the second merge publishes 0.1.2"
  assert_eq "$(tags_on_origin "$case_dir")" "v0.1.0 v0.1.1 v0.1.2 " "origin carries all three tags"
  assert_eq "$(ls "$case_dir/registry/rubygems" | tr '\n' ' ')" "0.1.1 0.1.2 " "both versions are published"
}

scenario_merge_title() {
  banner "18. a merge titled feat over a branch holding only a fix"
  local case_dir="$ROOT/mergetitle" out status
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"
  merge_branch "$case_dir/work" "fix/missing-file" \
    "Merge branch 'fix/missing-file' into 'master'

feat: make the profiler better at everything"
  step "the merge commit, subject and body"
  git -C "$case_dir/work" log -1 --format='%B' | sed 's/^/  /'

  out="$(run_release "$case_dir/work" "$case_dir")"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "0" "the job succeeds"
  assert_has "$out" "compute 0.1.1" "the merge title does not raise the version"
  assert_has "$out" "Pushed v0.1.1" "0.1.1 is published, as stamped"
  assert_eq "$(tags_on_origin "$case_dir")" "v0.1.0 v0.1.1 " "no 0.2.0 was invented"
}

scenario_squash_merge() {
  banner "19. a squash merge, whose single commit carries the merge request title"
  local case_dir="$ROOT/squash" out status
  make_fixture "$case_dir"
  author_branch "$case_dir/work" "fix/missing-file" "fix(storage): survive a missing profile file"

  step "squash: one commit on master, subject taken from the merge request title"
  git -C "$case_dir/work" checkout --quiet master
  git -C "$case_dir/work" merge --quiet --squash fix/missing-file
  git -C "$case_dir/work" commit --quiet -m "feat: make the profiler better at everything"
  git -C "$case_dir/work" push --quiet origin master
  git -C "$case_dir/work" log -1 --format='  %s'

  out="$(run_release "$case_dir/work" "$case_dir")"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "1" "the job fails rather than publishing a wrong number"
  assert_has "$out" "disagree about the version" "the reason is explicit"
  assert_has "$out" "says 0.1.1" "the stamped version is named"
  assert_has "$out" "compute  0.2.0" "the squashed title is what computes 0.2.0"
  assert_has "$out" "squash merge also lands" "the squash case is named in the message"
  assert_eq "$(tags_on_origin "$case_dir")" "v0.1.0 " "nothing was tagged"
  assert_eq "$(ls "$case_dir/registry/gitlab")" "" "nothing was published"
}

scenario_tooling_only() {
  banner "20. a branch of tooling commits only"
  local case_dir="$ROOT/tooling" out status
  make_fixture "$case_dir"
  git -C "$case_dir/work" checkout --quiet -b ci/tooling master
  printf 'tooling\n' >> "$case_dir/work/touched.txt"
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "ci: add a lint job"
  printf 'more tooling\n' >> "$case_dir/work/touched.txt"
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "docs: write the contributor notes"

  step "the branch check"
  out="$(cd "$case_dir/work" && ruby bin/changelog check --base master 2>&1)"
  printf '%s\n' "$out"
  assert_has "$out" "nothing to require" "the check asks for no stamp"

  merge_branch "$case_dir/work" "ci/tooling"
  step "the release job on the merged commit"
  out="$(run_release "$case_dir/work" "$case_dir")"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "0" "the job succeeds without doing anything"
  assert_has "$out" "Nothing to publish since v0.1.0" "it says there is nothing to publish"
  assert_eq "$(tags_on_origin "$case_dir")" "v0.1.0 " "no tag was added"
  assert_eq "$(ls "$case_dir/registry/gitlab")" "" "nothing was published"
  assert_eq "$(ls "$case_dir/registry/rubygems")" "" "nothing was published"
}

scenario_superfluous_stamp() {
  banner "21. a stamped section with nothing publishable behind it"
  local case_dir="$ROOT/superfluous" out status
  make_fixture "$case_dir"
  git -C "$case_dir/work" checkout --quiet -b ci/tooling master
  printf 'tooling\n' >> "$case_dir/work/touched.txt"
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "ci: add a lint job"
  ruby -e '
    path = ARGV[0]
    text = File.read(path)
    File.write(path, text.sub("## [Unreleased]\n",
      "## [Unreleased]\n\n## [0.1.1] - 2026-02-01\n\n<!-- stamped -->\n\n### Fixed\n\n- Something\n"))
  ' "$case_dir/work/CHANGELOG.md"
  git -C "$case_dir/work" add --all
  git -C "$case_dir/work" commit --quiet -m "docs: stamp for nothing"

  out="$(cd "$case_dir/work" && ruby bin/changelog check --base master 2>&1)"
  status=$?
  printf '%s\n' "$out"
  step assertions
  assert_eq "$status" "1" "the check fails"
  assert_has "$out" "no releasable commit, but CHANGELOG.md carries a stamped 0.1.1 section" "the reason is explicit"
  assert_has "$out" "the next branch would take that number as its base" "it says why it matters"
}

printf 'Dry run workspace: %s\n' "$ROOT"
scenario_normal
scenario_no_commit
scenario_retry
scenario_tag_refused
scenario_already_everywhere
scenario_already_published_refusal
scenario_gitlab_probe
scenario_missing_assets
scenario_no_section
scenario_coverage_after_release
scenario_tag_published_during_branch
scenario_stamp_fresh
scenario_stamp_again
scenario_check_without_stamp
scenario_release_disagrees
scenario_two_merges_stamp
scenario_two_merges_order
scenario_merge_title
scenario_squash_merge
scenario_tooling_only
scenario_superfluous_stamp

banner "summary"
if [ "$FAILURES" -eq 0 ]; then
  printf 'all dry-run assertions passed\n'
  exit 0
fi
printf '%s dry-run assertion(s) failed\n' "$FAILURES"
exit 1
