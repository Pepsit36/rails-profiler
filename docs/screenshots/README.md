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
| `toolbar-panel-*.png` | one panel of the toolbar each, hovered on `/orders`, on `/orders/confirmation` (the order of `/checkout` as an HTML page: HTTP, jobs and mails) or on `/orders/broken` (the development error page, for the exception); the same 1280x800 viewport, cut to its bottom 420 px |
| `toolbar-panel-jobs-running.png`, `toolbar-panel-jobs-completed.png` | the JOB panel of `/orders/export`, whose job runs for 3 seconds after the response: while it runs, then once it has ended, in the same page without a reload |
| `toolbar-panel-ajax-turbo.png`, `tab-ajax-turbo.png` | `/orders/turbo`, a page that loads a `<turbo-frame>` and submits a form answered with a Turbo Stream: the AJAX panel of its toolbar, then the AJAX tab of its profile, each request with its `FRAME` or `STREAM` badge. `shoot.mjs` then follows a Turbo Drive link and fails if the visit was linked to the page or if the page's toolbar still polls |
| `profile-list.png`, `profile-list-jobs.png`, `profile-list-console.png`, `profile-list-tests.png`, `profile-list-outbound.png`, `profile-list-env.png` | `/_profiler`, sections HTTP Requests, Background Jobs, Console, Tests, Outbound HTTP and Env (after one variable was switched in the page) |
| `tab-*.png` | one tab each of the profile of `/checkout`, `/orders`, `/orders/turbo`, `/api/n_plus_one`, `/api/cache_intensive` or `/api/raise_named_error`; `tab-function-profiling.png` is the Timeline tab of `/checkout`, scrolled to its function profiling |
| `job-profile.png` | the profile of a `ReportGenerationJob` enqueued by a request |
| `console-profile.png` | the profile of one of the console expressions of `demo_app/script/console_profiles.rb` |
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
   - sends the requests that fill the tabs, evaluates a few console expressions with
     `bin/rails runner script/console_profiles.rb` (the same `Profiler::ConsoleProfiler.profile`
     call as the profiler's IRB hook, so they are listed as console profiles), waits for one
     heartbeat of the slave, then runs `shoot.mjs`, which also starts the demo test run from the
     Test Runner page;
   - optimizes the PNGs with `npx oxipng -o 4 --strip safe` and stops both servers.

   With `SERVE=1`, it stops after seeding and leaves both servers running, to iterate on
   `shoot.mjs` by hand (`cd ~/pw && node shoot.mjs <outdir>`, with `LD_LIBRARY_PATH` and
   `FONTCONFIG_FILE` exported as in `run.sh`).
4. Look at every image before committing it: the profiler shows whatever the application does,
   and a new tab or a new collector can bring a real value into the frame.

## The MCP session of docs/mcp.md

`mcp-session.sh` replays the session shown in [docs/mcp.md](../mcp.md#a-real-session-finding-and-fixing-an-n1)
against the same demo application, and prints the text of every tool response. Start the
application with `SERVE=1 run.sh <test_app dir>`, then run `docs/screenshots/mcp-session.sh`
(about a minute). The client is the MCP Inspector command line, pinned in the script and fetched
by `npx`; the server is `bundle exec rake profiler:mcp`, started by the client in `/tmp/myapp`
with `PROFILER_NAME=myapp-web`, since the demo gives each node its own SQLite store. The script
applies the fix to the demo copy of the controller and puts the original line back when it exits.

## Known quirks

- The version badge reads the top version of `CHANGELOG.md`: a checkout of the gem carries
  `0.0.0`, which the overlay replaces for the demo application only.
- `test_app`'s `config/initializers/dev_env_vars.rb` points `DATABASE_URL` at the development
  database in every environment; the demo specs and `run.sh` use `storage/test.sqlite3`, which
  `run.sh` creates from the schema without the seeds the demo specs do not expect.
- `tab-database.png`, `tab-env.png`, `tab-mailer.png`, `test-profile-database.png` and
  `profile-list-env.png` show a dash that the profiler's UI itself writes (the N+1 banner, the
  Env notices, the subject next to a mailer action), not the demo data.
- The copy icon of the Env tab and section (U+2398) shows as an empty box: none of the fonts
  `prepare.sh` installs has it. Adding one that does (Symbola, FreeFont) changes how the emoji or
  the form controls of every other image are drawn.
- `toolbar-panel-exception.png` hides the web console that the development error page draws at
  its bottom (`#console`), which would otherwise cover the panel.
- The EVT item of the toolbar (and its Events panel) needs data that no collector has written
  since 0.9.1: it never shows, and has no image.
