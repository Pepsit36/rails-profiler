#!/usr/bin/env bash
#
# Release driver for the `release` CI job.
#
# Lives here rather than inline in .gitlab-ci.yml so that it can be read, and
# run against a simulated origin and simulated registries (see
# script/release-dry-run.sh) without a GitLab runner.
#
# What it does, in order:
#
#   1. compute NEW_VERSION from the last tag and the conventional commit types
#      (BREAKING CHANGE:/type!: major, feat: minor, fix: patch, nothing else);
#   2. if the tag does not exist yet: stamp CHANGELOG.md, commit it alone, tag
#      that commit, push commit and tag atomically, and only then build and
#      push the gem;
#   3. if the tag already exists: this is a re-run of a release whose gem push
#      failed. Publish from the tag, one registry at a time, and only where the
#      version is actually missing.
#
# Never runs with `set -x`, never echoes $CI_JOB_TOKEN or $RUBYGEMS_API_KEY,
# and pipes git output through `redact` so that no credential embedded in a
# remote URL can reach the job log.

set -euo pipefail

GEM_NAME="rails-profiler"
CHANGELOG_FILE="CHANGELOG.md"
VERSION_FILE="lib/profiler/version.rb"
GEMSPEC_FILE="profiler.gemspec"
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

compute_new_version() {
  local last_tag base_version commits major minor patch
  last_tag="$(git describe --tags --abbrev=0 2>/dev/null || echo "")"
  if [ -z "$last_tag" ]; then
    base_version="0.0.0"
    commits="$(git log --format="%s%n%b")"
  else
    base_version="${last_tag#v}"
    commits="$(git log "${last_tag}..HEAD" --format="%s%n%b")"
  fi

  LAST_TAG="$last_tag"

  if [ -z "$commits" ]; then
    log "No commits since last tag, skipping."
    return 1
  fi

  major="$(echo "$base_version" | cut -d. -f1)"
  minor="$(echo "$base_version" | cut -d. -f2)"
  patch="$(echo "$base_version" | cut -d. -f3)"

  if echo "$commits" | grep -qE "^BREAKING CHANGE:|^[a-z]+(\(.+\))?!:"; then
    NEW_VERSION="$((major + 1)).0.0"
  elif echo "$commits" | grep -qE "^feat(\(.+\))?:"; then
    NEW_VERSION="${major}.$((minor + 1)).0"
  elif echo "$commits" | grep -qE "^fix(\(.+\))?:"; then
    NEW_VERSION="${major}.${minor}.$((patch + 1))"
  else
    log "No releasable commits (chore/docs/style/ci/test), skipping."
    return 1
  fi
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
  body="$(curl -s --header "JOB-TOKEN: ${CI_JOB_TOKEN:-}" \
    "${CI_API_V4_URL:-}/projects/${CI_PROJECT_ID:-}/packages?package_type=rubygems&package_name=${GEM_NAME}&per_page=100" \
    || echo "")"
  if printf '%s' "$body" | grep -q "\"version\":\"${version}\""; then
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

advanced_branch_failure() {
  printf 'ERROR: %s advanced during this pipeline.\n' "$TARGET_BRANCH" >&2
  printf '  this pipeline ran on %s\n' "$1" >&2
  printf '  origin/%s is now     %s\n' "$TARGET_BRANCH" "$2" >&2
  printf 'Not rebasing: the release commit must sit on exactly the tree that was tested.\n' >&2
  printf 'Nothing was published, no tag and no commit were pushed.\n' >&2
  printf 'The next pipeline on %s will publish this change.\n' "$TARGET_BRANCH" >&2
  exit 1
}

push_refused_failure() {
  printf 'ERROR: pushing the release commit and tag to %s was refused.\n' "$TARGET_BRANCH" >&2
  printf 'No gem was published; the release is not done.\n' >&2
  printf 'GitLab settings to check:\n' >&2
  printf '  - Settings > CI/CD > Job token permissions > "Allow Git push requests to the repository"\n' >&2
  printf '  - Settings > Repository > Protected branches > %s > "Allowed to push and merge"\n' "$TARGET_BRANCH" >&2
  printf '    (the identity this job pushes with must be allowed there)\n' >&2
  exit 1
}

push_release() {
  local tag="$1" pipeline_sha="$2" out rc

  set +e
  out="$(git push --atomic origin "HEAD:${TARGET_BRANCH}" "$tag" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out" | redact

  if [ "$rc" -eq 0 ]; then
    log "Pushed the release commit and ${tag} to ${TARGET_BRANCH}."
    return 0
  fi

  if printf '%s' "$out" | grep -qiE 'non-fast-forward|fetch first|stale info'; then
    advanced_branch_failure "$pipeline_sha" "unknown (the push itself came back as non fast-forward)"
  fi

  if printf '%s' "$out" \
    | grep -qiE 'denied|forbidden|unauthorized|not allowed|403|401|protected branch|pre-receive hook declined|read-only|insufficient'; then
    push_refused_failure
  fi

  printf 'ERROR: the push failed for an unrecognised reason (exit %s), see the output above.\n' "$rc" >&2
  printf 'Nothing was published. Check both:\n' >&2
  printf '  - Settings > CI/CD > Job token permissions > "Allow Git push requests to the repository"\n' >&2
  printf '  - Settings > Repository > Protected branches > %s > "Allowed to push and merge"\n' "$TARGET_BRANCH" >&2
  exit 1
}

# --- the two paths ---------------------------------------------------------

normal_release() {
  local version="$1" tag="v$1" pipeline_sha remote_head gemfile

  require_rubygems_key
  pipeline_sha="${CI_COMMIT_SHA:-$(git rev-parse HEAD)}"

  configure_git

  # Fail before touching anything if the branch moved under us.
  git fetch origin "$TARGET_BRANCH" 2>&1 | redact || die "cannot fetch origin/${TARGET_BRANCH}, refusing to release blind."
  remote_head="$(git rev-parse FETCH_HEAD)"
  if [ "$remote_head" != "$pipeline_sha" ]; then
    advanced_branch_failure "$pipeline_sha" "$remote_head"
  fi

  log "Stamping ${CHANGELOG_FILE} for ${version}."
  ruby bin/changelog release --version "$version" --since "${LAST_TAG}"

  # Only CHANGELOG.md goes in: never version.rb, never app/assets/builds.
  git commit -m "chore(release): ${tag} [skip ci]" -- "$CHANGELOG_FILE"
  git tag "$tag"
  log "Release commit $(git rev-parse --short HEAD) carries only: $(git show --format='' --name-only HEAD | tr '\n' ' ')"

  # Commit and tag first, gem second.
  push_release "$tag" "$pipeline_sha"

  set_source_version "$version"
  gemfile="$(build_gem "$version")"
  publish_all "$version" "$gemfile"

  log "Released ${tag}."
}

# The tag is already there, so a previous run of this job pushed the commit and
# the tag but did not finish publishing. `git describe` from the pipeline SHA
# cannot see that tag (it was placed on the release commit, a child of this
# SHA), so NEW_VERSION lands on the same value: that is the case handled here,
# and it must publish instead of skipping.
resume_publish() {
  local version="$1" tag="v$1" gemfile on_gitlab=0 on_rubygems=0

  log "Tag ${tag} already exists on origin: this is a re-run of a release whose publication did not complete."
  log "Checking each registry separately."

  if registry_has_version gitlab "$version"; then on_gitlab=1; fi
  if registry_has_version rubygems "$version"; then on_rubygems=1; fi

  if [ "$on_gitlab" -eq 1 ] && [ "$on_rubygems" -eq 1 ]; then
    log "${GEM_NAME} ${version} is already published on both registries, nothing to do."
    return 0
  fi

  [ "$on_rubygems" -eq 1 ] || require_rubygems_key

  log "Publishing ${version} from the tag ${tag} itself (the CHANGELOG and the history are left untouched)."
  configure_git
  git fetch --no-tags origin "refs/tags/${tag}:refs/tags/${tag}" 2>&1 | redact || true
  git checkout --detach --force "refs/tags/${tag}" 2>&1 | redact

  set_source_version "$version"
  gemfile="$(build_gem "$version")"
  publish_all "$version" "$gemfile"

  log "Finished publishing ${tag}."
}

main() {
  LAST_TAG=""
  NEW_VERSION=""
  compute_new_version || exit 0
  log "Next version: ${NEW_VERSION} (last tag: ${LAST_TAG:-none})."

  if tag_exists_on_remote "v${NEW_VERSION}"; then
    resume_publish "$NEW_VERSION"
  else
    normal_release "$NEW_VERSION"
  fi
}

if [ -n "$STUBS_FILE" ]; then
  # shellcheck source=/dev/null
  . "$STUBS_FILE"
fi

main
