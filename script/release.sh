#!/usr/bin/env bash
#
# Release driver for the `release` CI job.
#
# Lives here rather than inline in .gitlab-ci.yml so that it can be read, and
# run against a simulated origin and simulated registries (see
# script/release-dry-run.sh) without a GitLab runner.
#
# The CHANGELOG is stamped by the author, in the branch, before the merge. This
# job never commits and never pushes a branch: it checks that the file agrees
# with the version it computes, tags the merged commit, pushes that tag alone,
# and publishes the gem.
#
# What it does, in order:
#
#   1. fetch the tags, so the decision does not depend on when the runner cloned;
#   2. if HEAD already carries the tag of the section at the top of the file,
#      this is a re-run of a publication that did not complete: publish what is
#      missing and stop. This comes first on purpose, before any version
#      computation, because `git describe` would answer with that very tag and
#      the job would conclude there was nothing to publish;
#   3. refuse to go on if an older stamped section is still waiting for its own
#      pipeline: that means the pipelines of this resource group ran out of order;
#   4. compute the version with `bin/changelog version`, the one implementation,
#      shared with the stamp and the branch check;
#   5. refuse to publish if the file and the computation disagree;
#   6. tag CI_COMMIT_SHA, push the tag alone, then build and push the gem.
#
# Never runs with `set -x`, never echoes $CI_JOB_TOKEN or $RUBYGEMS_API_KEY,
# and pipes git output through `redact` so that no credential embedded in a
# remote URL can reach the job log.

set -euo pipefail

GEM_NAME="rails-profiler"
CHANGELOG_FILE="CHANGELOG.md"
VERSION_FILE="lib/profiler/version.rb"
GEMSPEC_FILE="profiler.gemspec"
BUILT_ASSETS_DIR="app/assets/builds"
TARGET_BRANCH="${CI_DEFAULT_BRANCH:-master}"

# Test-only injection point: the file is sourced after every function below is
# defined, so a test can replace the registry probes and the gem build/push.
# The CI job never passes it.
STUBS_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stubs) STUBS_FILE="${2:?--stubs needs a file}"; shift 2 ;;
    *) printf 'release: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Strips any user:password embedded in a URL before it reaches the log.
redact() { sed -e 's#://[^/@[:space:]]*@#://***@#g'; }

# --- version computation ---------------------------------------------------

# The version is not computed here: `bin/changelog version` is the one
# implementation, shared with the stamp and the branch check, so the number the
# author stamped and the number published can never come from two rules.
compute_new_version() {
  local out rc
  LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo "")"

  set +e
  out="$(ruby bin/changelog version --since "$LAST_TAG")"
  rc=$?
  set -e

  case "$rc" in
    0) NEW_VERSION="$out" ;;
    3) log "Nothing to publish since ${LAST_TAG:-the start of the history}, skipping."; return 1 ;;
    *) die "bin/changelog version failed with exit ${rc}" ;;
  esac
}

tag_exists_on_remote() {
  git ls-remote --tags origin 2>/dev/null | grep -q "refs/tags/$1$"
}

# --- registry probes -------------------------------------------------------
#
# rubygems.org is probed through its public API: no credential involved.
#
# The GitLab registry is probed through the project Packages API, authenticated
# with the `JOB-TOKEN` header. $CI_JOB_TOKEN is only handed to curl through the
# environment: it is never printed, never written to a file, and the response
# body is matched against a pattern rather than dumped.
#
# An undecidable probe (network error, 5xx) counts as "absent": we would rather
# attempt a push and let the already-published tolerance settle it than skip a
# publication that never happened.

gem_present_rubygems() {
  local version="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    "https://rubygems.org/api/v2/rubygems/${GEM_NAME}/versions/${version}.json" || echo "000")"
  log "  probe rubygems.org for ${GEM_NAME} ${version}: HTTP ${code}"
  [ "$code" = "200" ]
}

gem_present_gitlab() {
  local version="$1" body
  # package_version is what makes this reliable: the collection endpoint is
  # capped at 100 entries per page and ordered by created_at ascending, so the
  # canary preversions of this gem would otherwise fill page 1 and the version
  # looked for would never appear.
  body="$(curl -s --header "JOB-TOKEN: ${CI_JOB_TOKEN:-}" \
    "${CI_API_V4_URL:-}/projects/${CI_PROJECT_ID:-}/packages?package_type=rubygems&package_name=${GEM_NAME}&package_version=${version}&per_page=100" \
    || echo "")"
  # package_name is a fuzzy filter on GitLab's side, so the fields are compared
  # exactly here instead of grepped (a grep would also read the dots of a
  # version as wildcards). The body is parsed, never printed.
  if printf '%s' "$body" | WANTED_NAME="$GEM_NAME" WANTED_VERSION="$version" ruby -rjson -e '
        packages = begin
          JSON.parse($stdin.read)
        rescue JSON::ParserError
          []
        end
        packages = [] unless packages.is_a?(Array)
        found = packages.any? do |package|
          package.is_a?(Hash) &&
            package["name"] == ENV.fetch("WANTED_NAME") &&
            package["version"] == ENV.fetch("WANTED_VERSION")
        end
        exit(found ? 0 : 1)
      '; then
    log "  probe GitLab registry for ${GEM_NAME} ${version}: present"
    return 0
  fi
  log "  probe GitLab registry for ${GEM_NAME} ${version}: absent"
  return 1
}

registry_has_version() {
  case "$1" in
    gitlab) gem_present_gitlab "$2" ;;
    rubygems) gem_present_rubygems "$2" ;;
    *) die "unknown registry $1" ;;
  esac
}

# --- gem build and push ----------------------------------------------------

set_source_version() {
  sed -i "s/VERSION = .*/VERSION = \"$1\"/" "$VERSION_FILE"
  log "Set ${VERSION_FILE} to $1 for the build (never committed)."
}

# `gem build` happily produces a gem without any compiled JS or CSS, since
# app/assets/builds is git ignored and only filled by the `build` job. On a
# re-run those artifacts may have expired, so this is checked rather than
# assumed, on both publication paths.
require_built_assets() {
  if [ ! -d "$BUILT_ASSETS_DIR" ] || [ -z "$(ls -A "$BUILT_ASSETS_DIR" 2>/dev/null)" ]; then
    printf 'ERROR: %s is missing or empty.\n' "$BUILT_ASSETS_DIR" >&2
    printf 'Refusing to build a gem without its compiled JS and CSS.\n' >&2
    printf 'The artifacts of the `build` job are not here: either they were never produced,\n' >&2
    printf 'or they expired (artifacts have a lifetime, a re-run of an old pipeline outlives them).\n' >&2
    printf 'Re-run the whole pipeline, not just this job, so that `build` runs again and hands\n' >&2
    printf 'its artifacts over to this one.\n' >&2
    exit 1
  fi
  log "Found $(find "$BUILT_ASSETS_DIR" -type f | wc -l) compiled asset file(s) in ${BUILT_ASSETS_DIR}."
}

# Prints the path of the built gem on stdout.
build_gem() {
  gem build "$GEMSPEC_FILE" >&2
  printf '%s\n' "${GEM_NAME}-$1.gem"
}

gem_push_gitlab() {
  local gemfile="$2"
  mkdir -p ~/.gem
  printf -- "---\n:gitlab: ${CI_JOB_TOKEN}\n" > ~/.gem/credentials
  chmod 0600 ~/.gem/credentials
  gem push "$gemfile" --key gitlab \
    --host "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/rubygems" --verbose
}

gem_push_rubygems() {
  local gemfile="$2"
  GEM_HOST_API_KEY="${RUBYGEMS_API_KEY}" gem push "$gemfile" --host https://rubygems.org --verbose
}

# A registry that answers "this version is already there" is not a failure, but
# only if the registry itself confirms it: the explicit message alone is not
# enough, so the probe is run again after the refusal.
publish_to_registry() {
  local registry="$1" version="$2" gemfile="$3" out rc

  log "Registry ${registry}: checking whether ${GEM_NAME} ${version} is already published."
  if registry_has_version "$registry" "$version"; then
    log "Registry ${registry}: ${version} already published, nothing to push."
    return 0
  fi

  set +e
  out="$("gem_push_${registry}" "$version" "$gemfile" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out" | redact

  if [ "$rc" -eq 0 ]; then
    log "Registry ${registry}: pushed ${GEM_NAME} ${version}."
    return 0
  fi

  if printf '%s' "$out" \
    | grep -qiE 'repushing of gem versions is not allowed|has already been pushed|version already exists|409 conflict'; then
    log "Registry ${registry}: the push was refused as already published, re-probing to confirm."
    if registry_has_version "$registry" "$version"; then
      log "Registry ${registry}: ${version} confirmed present, treating the refusal as success."
      return 0
    fi
    log "ERROR: registry ${registry} refused the push as already published, but the registry does not report ${version}."
    return 1
  fi

  log "ERROR: push to registry ${registry} failed (exit ${rc}) and ${version} is not published there."
  return 1
}

# Each registry is handled on its own: a failure on one still lets the other be
# attempted, and the overall exit status is non-zero if any of them really failed.
publish_all() {
  local version="$1" gemfile="$2" failed=0

  publish_to_registry gitlab "$version" "$gemfile" || failed=1
  publish_to_registry rubygems "$version" "$gemfile" || failed=1

  if [ "$failed" -ne 0 ]; then
    die "At least one registry did not get ${GEM_NAME} ${version}. The tag v${version} is already pushed, so re-running this job will publish from the tag to the registries that are still missing it."
  fi
  log "${GEM_NAME} ${version} is published on both registries."
}

require_rubygems_key() {
  [ -n "${RUBYGEMS_API_KEY:-}" ] || die "RUBYGEMS_API_KEY is not set."
}

# --- git side of the release ----------------------------------------------

configure_git() {
  git config user.email "ci@gitlab"
  git config user.name "GitLab CI"
  if [ -n "${CI_SERVER_HOST:-}" ] && [ -n "${CI_PROJECT_PATH:-}" ]; then
    git remote set-url origin \
      "https://gitlab-ci-token:${CI_JOB_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
  fi
}

# The version of the section at the top of CHANGELOG.md, the one the author
# stamped in the branch.
file_version() {
  ruby -e '
    text = File.read(ARGV[0])
    match = text[/^##\s*\[(\d+\.\d+\.\d+)\]/, 1]
    abort "no released section found in #{ARGV[0]}" if match.nil?
    puts match
  ' "$CHANGELOG_FILE"
}

# Versions stamped in the file, below the top section, that carry no tag yet.
pending_versions() {
  ruby -e '
    text = File.read(ARGV[0])
    sections = text.scan(/^##\s*\[(\d+\.\d+\.\d+)\][^\n]*\n(.*?)(?=^##\s|\z)/m)
    sections.drop(1).each do |version, body|
      next unless body.include?("<!-- stamped -->")
      next if system("git", "rev-parse", "--verify", "--quiet", "refs/tags/v#{version}",
                     out: File::NULL, err: File::NULL)

      puts version
    end
  ' "$CHANGELOG_FILE"
}

head_is_tagged_as() {
  local tag="$1"
  [ "$(git tag --points-at HEAD 2>/dev/null | grep -Fx "$tag" || true)" = "$tag" ]
}

push_tag() {
  local tag="$1" out rc

  set +e
  out="$(git push origin "refs/tags/${tag}" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out" | redact

  if [ "$rc" -eq 0 ]; then
    log "Pushed ${tag}."
    return 0
  fi

  printf 'ERROR: pushing the tag %s was refused (exit %s).\n' "$tag" "$rc" >&2
  printf 'No gem was published; the release is not done.\n' >&2
  printf 'This job only ever pushes a tag, never a branch. If the refusal is about rights,\n' >&2
  printf 'check Settings > CI/CD > Job token permissions > "Allow Git push requests to the\n' >&2
  printf 'repository", and Settings > Repository > Protected tags for the v* pattern.\n' >&2
  exit 1
}

# --- the two paths ---------------------------------------------------------

publish_release() {
  local version="$1" tag="v$1" gemfile

  require_rubygems_key
  require_built_assets
  configure_git

  log "Tagging $(git rev-parse --short HEAD) as ${tag}."
  git tag "$tag"
  push_tag "$tag"

  set_source_version "$version"
  gemfile="$(build_gem "$version")"
  publish_all "$version" "$gemfile"

  log "Released ${tag}."
}

# HEAD already carries the tag, so a previous run of this job tagged and then
# failed to finish publishing. Nothing is tagged or committed again: each
# registry is looked at on its own, and only the missing ones are pushed.
resume_publish() {
  local version="$1" tag="v$1" gemfile on_gitlab=0 on_rubygems=0

  log "${tag} is already on HEAD: this is a re-run of a release whose publication did not complete."
  log "Checking each registry separately."

  if registry_has_version gitlab "$version"; then on_gitlab=1; fi
  if registry_has_version rubygems "$version"; then on_rubygems=1; fi

  if [ "$on_gitlab" -eq 1 ] && [ "$on_rubygems" -eq 1 ]; then
    log "${GEM_NAME} ${version} is already published on both registries, nothing to do."
    return 0
  fi

  [ "$on_rubygems" -eq 1 ] || require_rubygems_key
  require_built_assets

  log "Publishing ${version} from ${tag}, which is this very commit. The history is left untouched."
  set_source_version "$version"
  gemfile="$(build_gem "$version")"
  publish_all "$version" "$gemfile"

  log "Finished publishing ${tag}."
}

out_of_order_failure() {
  local pending="$1"
  printf 'ERROR: an older stamped version is still waiting to be published: %s\n' "$pending" >&2
  printf 'CHANGELOG.md carries it below the top section, and no tag matches it, so the\n' >&2
  printf 'pipeline that should publish it has not run yet. Publishing this one first would\n' >&2
  printf 'put the versions out of order, so nothing is tagged and nothing is published.\n' >&2
  printf '\n' >&2
  printf 'The release resource group must process its pipelines oldest first. Check\n' >&2
  printf 'process_mode on the `release` resource group of this project; the default,\n' >&2
  printf 'unordered, allows exactly this.\n' >&2
  printf '\n' >&2
  printf 'What to do, in order of likelihood:\n' >&2
  printf '  1. the older pipeline simply has not run yet, or failed on something fixable such as\n' >&2
  printf '     the right to push a tag: fix that, re-run the older pipeline, then re-run this one.\n' >&2
  printf '     This is the normal case;\n' >&2
  printf '  2. that version is abandoned, which is the exception. On a branch carrying no\n' >&2
  printf '     publishable commit, take its section out of CHANGELOG.md and renumber the section\n' >&2
  printf '     above it to the version this history will publish, so that exactly one untagged\n' >&2
  printf '     section is left. `bin/changelog check` says which number that is, and refuses any\n' >&2
  printf '     other. A section that carries a tag is never touched.\n' >&2
  exit 1
}

disagreement_failure() {
  local file_version="$1" computed="$2"
  printf 'ERROR: CHANGELOG.md and the commits disagree about the version.\n' >&2
  printf '  the top section of CHANGELOG.md says %s\n' "$file_version" >&2
  printf '  the commits since the last tag compute  %s\n' "$computed" >&2
  printf 'Nothing was tagged and nothing was published.\n' >&2
  printf '\n' >&2
  printf 'The version is stamped in the branch, before the merge. Run `bin/changelog stamp`\n' >&2
  printf 'on the branch, commit CHANGELOG.md, and merge again. A squash merge also lands\n' >&2
  printf 'here: the squashed commit carries the merge request title, which may not be the\n' >&2
  printf 'type the branch commits had. This project merges with a merge commit.\n' >&2
  exit 1
}

main() {
  local file_version computed pending

  # The pipeline may have been created before another one pushed its tag.
  git fetch --tags --quiet origin 2>&1 | redact || log "WARNING: could not fetch the tags from origin."

  file_version="$(file_version)"
  log "CHANGELOG.md says ${file_version} at the top."

  # Re-run of an incomplete publication, decided before any computation.
  if head_is_tagged_as "v${file_version}"; then
    resume_publish "$file_version"
    return 0
  fi

  pending="$(pending_versions | head -1)"
  [ -z "$pending" ] || out_of_order_failure "$pending"

  LAST_TAG=""
  NEW_VERSION=""
  compute_new_version || exit 0
  computed="$NEW_VERSION"
  log "The commits since ${LAST_TAG:-the start of the history} compute ${computed}."

  [ "$file_version" = "$computed" ] || disagreement_failure "$file_version" "$computed"

  publish_release "$computed"
}

if [ -n "$STUBS_FILE" ]; then
  # shellcheck source=/dev/null
  . "$STUBS_FILE"
fi

# Test-only: lets a test source this file to exercise one function on its own.
# The CI job never sets it.
if [ -z "${RELEASE_SH_SOURCE_ONLY:-}" ]; then
  main
fi
