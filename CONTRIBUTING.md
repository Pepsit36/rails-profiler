# Contributing to Rails Profiler

Thank you for helping. This page takes you from a machine without Ruby or Node to a merge request
that the release process accepts. [CLAUDE.md](CLAUDE.md) holds the same rules, written for coding
agents; when the two disagree, `CLAUDE.md` and the CI are right, and this page should be fixed.

## Where things live

Development happens on [GitLab](https://git.duplessy.eu/sebastien/rails-profiler-gem);
[GitHub](https://github.com/Pepsit36/rails-profiler) is a read-only mirror. The project spans
three repositories:

| Repository | Contents |
|---|---|
| `rails-profiler-gem` (this one) | The gem: Ruby code, the dashboard and toolbar front-end, the OpenAPI file, the specs |
| `rails-profiler-extension` | The Chrome DevTools extension |
| `rails-profiler` (superproject) | The two above as git submodules, plus `test_app` (a Rails application to try the gem in, and the rswag specs that generate `swagger/v1/swagger.yaml`), the front-end's Vitest suite and a Docker setup |

Most changes only need this repository. You need the superproject to try the gem in a browser
with `test_app`, to change the API contract, or to run the front-end tests.

## 1. Install the tools

- **Git**
- **Ruby 3.3 or 3.4**, with Bundler. The CI runs every spec on both (`ruby:3.3` and `ruby:3.4`
  images); the gem supports Ruby 3.0 and later. Any version manager works (rbenv, asdf, mise,
  chruby, ruby-install); for example with rbenv: `rbenv install 3.4.6 && rbenv local 3.4.6`.
  Without a version manager or root access, `docs/screenshots/prepare.sh` shows how to unpack a
  prebuilt Ruby in your home directory.
- **Node 22** (the CI's `node:22` image) and **Yarn 1** (classic; `yarn.lock` is a v1 lock file):
  `corepack enable` then `corepack prepare yarn@1.22.22 --activate`, or `npm install -g yarn@1`.
- Optional: **Docker**, only for the superproject's Docker setup; **PostgreSQL**, only for
  `spec/explain_runner_postgresql_spec.rb`, which is skipped without it.

## 2. Bootstrap this repository

```bash
git clone https://git.duplessy.eu/sebastien/rails-profiler-gem.git
cd rails-profiler-gem

bundle install                  # Ruby dependencies, the optional ones used by the specs included
yarn install --frozen-lockfile  # front-end build tools
yarn build:full                 # generates the API client, then builds app/assets/builds/
```

`yarn build:full` is the step people miss. The compiled JavaScript and CSS
(`app/assets/builds/profiler.js`, `profiler-toolbar.js`, `profiler.css`) are not committed, nor is
the API client they import (`app/assets/typescript/profiler/generated/`), which orval generates from
`swagger/v1/swagger.yaml`. Without them the specs still pass, but an application using your
checkout answers `500` on `/_profiler/assets/*` and shows a dashboard without script or style.
`yarn build` alone fails on a fresh checkout with `Could not resolve "../../generated/api"`: run
`yarn build:full` once, then `yarn build` after each front-end change (`yarn watch` rebuilds
`profiler.js` only, not the toolbar).

## 3. Run the tests

```bash
bundle exec rspec
```

The whole suite takes about two minutes. Run it on Ruby 3.3 **and** 3.4 before you propose a
change that touches Ruby code: the gem prepends modules to core classes (`Thread#initialize`
among them), and from Ruby 3.4 on the standard library calls `Thread.new` with arguments, in the
Happy Eyeballs resolution of `Socket.tcp`; a patch can pass on 3.3 and break TCP connections on
3.4. Both CI jobs (`rspec` and `rspec:ruby3.4`) have to be green.

Other checks, depending on what you change:

- `bash script/release-dry-run.sh` after any change to `script/release.sh`, `bin/changelog` or the
  `release` job of `.gitlab-ci.yml`; it needs no network and no credential.
- `ruby bin/changelog check --base origin/master` runs the CI's `changelog:check` locally (see
  [Commits and the changelog](#5-commits-and-the-changelog)).
- `yarn build:full` must succeed after any front-end change: it is the CI's `build` job.
- Front-end unit tests: from the superproject, `yarn install && yarn test` (Vitest).
- `bundle exec ruby script/bench/request_overhead.rb` measures what the profiler adds to a request,
  when you change something on the request path.

## 4. Try your change in an application

**With the superproject's `test_app`** (recommended): clone the superproject, run `make init` to
fetch the submodules, then either `make build && make test-app` (Docker, port 3000) or, without
Docker:

```bash
cd rails-profiler-gem && yarn install --frozen-lockfile && yarn build:full && cd ..
cd test_app && bundle install && bin/rails db:prepare db:seed && bin/rails server
```

`test_app` commits no `Gemfile.lock`: if `bundle install` resolves `json` 3.x, Rails 7.2 fails
with `unknown keyword: quirks_mode`; add `gem "json", "~> 2.9"` to its `Gemfile`. Then open
`http://localhost:3000` and `http://localhost:3000/_profiler`. `docs/screenshots/run.sh`
in this repository is a scripted version of the same thing, with a second instance as a cluster
slave.

**With your own application:** point its `Gemfile` at your checkout, and build the assets in the
checkout as above.

```ruby
gem "rails-profiler", path: "../rails-profiler-gem", require: "profiler"
```

**Changing the API.** `swagger/v1/swagger.yaml` is generated by the rswag specs of the
superproject's `test_app` (`make swaggerize`); describe the endpoint there, regenerate, commit the
YAML here, then run `yarn build:full` to regenerate the client. Never edit `generated/` by hand.
The whole pipeline is described in [ARCHITECTURE.md](ARCHITECTURE.md#openapi-pipeline-single-source-of-truth).

## 5. Commits and the changelog

Merging into `master` can publish the gem, to the GitLab registry and to rubygems.org. The version
is computed from your commits, never chosen by hand, so the commit type matters.

- **Conventional Commits, in English**, with a scope when one applies:
  `fix(instrumentation): keep the request context in Thread.start`.
- **Only three things publish**: `feat:` a minor version, `fix:` a patch, a breaking change
  (`type!:`, or a `BREAKING CHANGE:` or `BREAKING-CHANGE:` footer) a major. The type is read from
  the subject line only: a `fix:` line further down the body publishes nothing. Every other type
  publishes nothing: `docs`, `refactor`, `perf`, `test`, `chore`, `ci`, `build`, `deps`, `style`,
  `security`, `revert`. A revert that users need to receive has to be written as a `fix:`.
- **Never edit `lib/profiler/version.rb`**: it stays at `0.0.0`; the release job computes the
  version with `bin/changelog version`.
- **Never publish from your machine**: the gem is published only by the `release` CI job.
  `rake release` (and its `release:*` subtasks) refuses to run; `rake build` and `rake install`
  still work for a local try.
- **A branch with a `feat:` or `fix:` commit stamps `CHANGELOG.md`**:
  1. describe the change for users under `## [Unreleased]`, in Keep a Changelog form
     (`### Added`, `### Changed`, `### Removed`, `### Fixed`, `### Security`), following the style
     of the entries already there;
  2. run `bin/changelog stamp`, which turns `[Unreleased]` into the version this merge will
     publish, and commit `CHANGELOG.md`;
  3. run it again after every rebase or new commit;
  4. never edit a section that already carries a version: published entries are frozen.

  A branch without a publishable commit (documentation, refactoring) leaves `CHANGELOG.md` alone.
  The CI's `changelog:check` fails when the top section does not carry the version the branch
  publishes, and tells you which command to run.
- **No em dash** anywhere: code, commits, changelog, merge request descriptions. Use a colon or a
  comma.
- **No history rewrite on a shared branch**: add follow-up commits.

`CLAUDE.md` details the edge cases (two merge requests stamping at once, an abandoned version).

## 6. Propose a change

1. Open an issue on GitLab first for anything larger than a fix, to agree on the approach.
2. Create a branch from an up-to-date `master`. Prefixes `feature/`, `bugfix/`, `hotfix/`, `fix/`
   and `breaking/` publish a `canary` pre-release on every push, which is expected; any other
   prefix (`docs/...`, `refactor/...`) works too, without it.
3. Add specs with the change, and documentation when users see it: the [README](README.md) for the
   essentials, the pages under [docs/](docs/) for the details, [ARCHITECTURE.md](ARCHITECTURE.md)
   when the structure changes. A change to the dashboard may need new screenshots:
   [docs/screenshots/README.md](docs/screenshots/README.md) explains how to regenerate them.
4. Open a merge request on GitLab, titled like a commit. The project merges with a merge commit on
   a semi-linear history: rebase on `master` when asked (and stamp again if your branch publishes),
   and do not squash, since a squashed commit would carry the title's type instead of your
   commits'.
5. Both `rspec` jobs, `build` and, on branches, `changelog:check` must be green before the merge.

Contributions are released under the project's [MIT License](LICENSE).
