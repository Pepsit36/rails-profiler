# Regenerating the screenshots

Every PNG in this directory is produced by `run.sh`, from a demo application built out of the
superproject's `test_app` and the overlay in `demo_app/`. All of them share one frame: a
1280x800 viewport, device scale factor 1, the light theme of the profiler, optimized with
`oxipng`. The procedure runs end to end on a bare Debian 12 container, without root, Docker or a
system browser; on a workstation that already has Ruby 3.3 or 3.4, Node and a Chromium that
Playwright can drive, `prepare.sh` only installs what is missing.

This directory is not part of the published gem: the gemspec only packages `lib`, `config`,
`exe`, part of `app` and three top-level files.

## What the images show

Only fictitious data: the browser maps `api.myapp.test` (the application) and
`billing.myapp.test` (a fake billing API that the same application serves under `/upstream/`)
to `127.0.0.1`, customers and sellers are invented, mail addresses use `example.com` or
`myapp.test`, and every Message-ID is rewritten to `@myapp.test`. The servers start with an
empty environment (`env -i`) and `config.env_allowlist` lists a few demo variables only, so no
path, user or machine name of the host reaches the Env tab. The application lives in
`/tmp/myapp` because file paths show in the Dump and Views tabs.

| Image | Page |
|---|---|
| `toolbar.png` | `/orders`, an HTML page of the demo application, with the Database panel of the toolbar open |
| `profile-list.png`, `profile-list-jobs.png`, `profile-list-tests.png` | `/_profiler`, sections HTTP Requests, Background Jobs and Tests |
| `tab-*.png` | one tab each of the profile of `/checkout`, `/orders`, `/api/n_plus_one`, `/api/cache_intensive` or `/api/raise_named_error` |
| `test-runner.png` | the Test Runner section after running `spec/demo/*_spec.rb` |
| `test-profile.png`, `test-profile-database.png` | the profile of one of those examples, Test and Database tabs |
| `cluster-selector.png` | the profile list of the slave `myapp-billing`, read through the master |

## Steps

1. `docs/screenshots/prepare.sh` (once, a few minutes): Ruby 3.4.6 from the `ruby/ruby-builder`
   tarball under `~/rb` with a wrapper that sets `LD_LIBRARY_PATH`, `RUBYLIB`, `GEM_HOME` and a
   `RUBYOPT` loading `rbconfig_fix.rb` (the tarball is compiled for `/opt/hostedtoolcache`; the
   fix re-points `RbConfig` and restores the load path order, without which Prism raises a
   `NameError`), `libyaml` from its Debian package, Playwright with Chromium under `~/pw`, and
   the shared libraries and fonts Chromium needs, extracted from Debian 12 packages under
   `~/chromelibs`. `RB`, `PW` and `LIBS` override the three locations.
2. Get the superproject's `test_app` (any checkout of the superproject, or
   `git archive origin/master test_app | tar -x -C <dir>` from the swarm hub).
3. `docs/screenshots/run.sh <test_app dir> [output dir]` (about 3 minutes; the output defaults
   to this directory). It:
   - builds the front-end assets of this checkout with `yarn build:full` (`generated/api.ts` is
     not committed: `yarn build` alone fails);
   - copies `test_app` to `/tmp/myapp` (`APP` overrides it), adds the overlay, points the
     `Gemfile` at this checkout and pins `json` 2.x (`test_app` commits no `Gemfile.lock`, and
     json 3 breaks Rails 7.2 with `unknown keyword: quirks_mode`);
   - starts a cluster master on port 3000 and a slave on port 3001, sharing a random
     `cluster_secret`, each with its own SQLite profile store;
   - sends the requests that fill the tabs, waits for one heartbeat of the slave, then runs
     `shoot.mjs`, which also starts the demo test run from the Test Runner page;
   - optimizes the PNGs with `npx oxipng -o 4 --strip safe` and stops both servers.

   With `SERVE=1`, it stops after seeding and leaves both servers running, to iterate on
   `shoot.mjs` by hand (`cd ~/pw && node shoot.mjs <outdir>`, with `LD_LIBRARY_PATH` and
   `FONTCONFIG_FILE` exported as in `run.sh`).
4. Look at every image before committing it: the profiler shows whatever the application does,
   and a new tab or a new collector can bring a real value into the frame.

## Known quirks

- The version badge reads the top version of `CHANGELOG.md`: a checkout of the gem carries
  `0.0.0`, which the overlay replaces for the demo application only.
- `spec/demo_helper.rb` sets up the test profiling itself instead of calling
  `Profiler::TestHelpers::RSpecSupport.install`, which, as of 0.32.1, fails every example under
  RSpec 3.13 (`example.line_number` is not defined on the object an `around` hook receives).
  The demo specs all pass: a failing example is recorded as passed by the same integration.
- `test_app`'s `config/initializers/dev_env_vars.rb` points `DATABASE_URL` at the development
  database in every environment; the demo specs and `run.sh` use `storage/test.sqlite3`.
