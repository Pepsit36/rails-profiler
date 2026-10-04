# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Write your entry under `[Unreleased]`, for a user of the gem. When your branch is
ready, run `bin/changelog stamp`: it works out the version the merge will publish
and turns `[Unreleased]` into `[X.Y.Z] - <date>`, reopening an empty one above.
Run it again after a rebase or a new commit, it corrects the number and folds the
new entries in. Never edit a section that already carries a tag.

A section written by `stamp` carries `<!-- stamped -->`. In the older sections,
each bullet carries the short sha of the commit it describes, and commits left out
on purpose are listed in that version's `excluded:` comment with the reason; all of
it in HTML comments, invisible once rendered. `bin/changelog coverage` checks that
every commit of every tag interval is accounted for one way or the other.

## [Unreleased]

### Fixed

- **Cluster:** A profile page served by the master now finds profiles held by a slave even before
  the slave proxy has been used once.

### Security

- **MCP:** The HTTP transport at `/_profiler/mcp` is routed only when `mcp_enabled` is true and
  `mcp_transport` is `:http`; it answers `404` otherwise. It used to be routed in every application,
  whatever these options said, and to answer anyone: after the MCP handshake, any client could list
  the tools and call those that write `ENV`, clear profiles or run the test suite. The stdio
  transport (`rake profiler:mcp`) is unchanged.
- **MCP:** When it is routed, each request to `/_profiler/mcp` passes the profiler's own checks
  before the MCP server sees it, and gets a `403` otherwise: the profiler must be enabled, the
  request must pass `authorization_mode`, and a `POST` must carry `Content-Type: application/json`
  with no foreign `Origin`, so that a page on another site cannot call the tools from your browser.
- **Cluster:** The cluster endpoints (`register`, `heartbeat`, `slaves` and the slave proxy) are
  routed only on a node with the new `cluster_master = true`; they answer `404` otherwise. Every
  application used to accept slave registrations.
- **Cluster:** The master and its slaves authenticate each other with the new shared
  `cluster_secret`, sent in an `X-Profiler-Cluster-Secret` header and compared in constant time:
  `register` and `heartbeat` refuse a missing or wrong secret, and everything while no secret is
  configured. On a slave, the master's proxied calls are let in by the secret, so a master on
  another machine no longer needs the slave to admit its address.
- **Cluster:** The master registers, and sends requests to, only the slave URLs allowed by the new
  `cluster_allowed_slave_urls` (scheme, host and port, compared after normalization, and a path
  prefix); the default refuses all. HTTPS is required, except for loopback addresses, for slave URLs
  and for `master_url` (new `cluster_allow_insecure_http` to lift it), and the master no longer
  returns the body of a redirect. Anyone who could register used to make the master fetch any host
  and port it could reach and read the answer (server-side request forgery).
- **Cluster:** A path, profile token or MCP argument sent to a slave can no longer leave the slave's
  `/_profiler/api/`: `?`, `#` and `%` are encoded into the path segment, and a `.`, `..` or `/`
  segment is refused before any request, on the slave proxy, the profile pages and the MCP tools.
  An encoded `..` or `?` used to reach other paths of the slave.
- **Cluster:** A `cluster_secret` shorter than 32 characters, or blank, is ignored as if none were
  configured, with a warning at boot and an explicit error on registration. The master stores slave
  URLs in their normalized form.
- **Cluster:** The `cluster_secret` is masked by value in everything a profile captures (params,
  bodies, headers in and out, URLs, `ENV`, SQL binds, job and mailer arguments, and the free text of
  every collector: log lines, exception messages, dumps, SQL text, console expressions), and in the
  output of the test runner, whatever name it travels under and even with `redact_sensitive_data`
  off, on top of the masking by name.
- **Upgrading:** Nothing to do if you use neither the MCP HTTP endpoint nor the cluster. Otherwise,
  in `config/initializers/profiler.rb`:
  - MCP over HTTP: set `config.mcp_enabled = true` and `config.mcp_transport = :http`. An
    installation that used `/_profiler/mcp` while `mcp_transport` stayed at its default, `:stdio`,
    must now set `:http`. The checks have no MCP-specific switch: `config.authorization_mode =
    :allow_all` lets anybody who can reach the application call every tool, and
    `config.api_forgery_protection = false` lets any website you visit make your browser call them.
  - Cluster master: set `config.cluster_master = true`, `config.cluster_secret` (at least 32
    characters, the same value on every node, from the environment) and
    `config.cluster_allowed_slave_urls`. Slaves: set the same `config.cluster_secret`, and use HTTPS
    URLs unless master and slave share the machine.
  - To go back to the previous behavior: `config.cluster_require_secret = false` (with no
    `cluster_secret`) accepts registrations from any client `authorization_mode` lets in, as in
    0.30.6; `config.cluster_allowed_slave_urls = :any` accepts any slave URL, which reopens the
    server-side request forgery; `config.cluster_allow_insecure_http = true` sends the secret and the
    profiles in clear to remote hosts.

## [0.30.10] - 2026-10-04

<!-- stamped -->

### Security

- **Test runner:** The test runner (the dashboard page and the MCP tool `run_tests`) only runs
  the test files it discovers, `spec/**/*_spec.rb` and `test/**/*_test.rb` under the Rails root,
  optionally with a line number (`spec/models/user_spec.rb:12`). Paths are compared after resolving
  symbolic links. Any other path answers `422` over HTTP, or a tool error over MCP, and nothing is
  started. The HTTP endpoint used to run any file under the Rails root, and `run_tests` any path at all.
- **Test runner:** A selection sent with the wrong framework (a `test/**/*_test.rb` file for
  `rspec`, or a spec for `minitest`) now answers `422` too, and so does a path holding a null byte,
  which used to raise an error.
- **Test runner:** The test process starts from the environment the shell gave Rails, copied when
  the gem is loaded, plus the environment overrides set from the profiler, instead of the current
  environment of the application. Overrides that make the test process, or the rbenv or asdf shim
  that starts it, load or run other code are left out, with a warning naming them once: names
  starting with `RUBY`, `GEM_`, `BUNDLE_`, `LD_`, `BASH_`, `RBENV_` and others, `NODE_OPTIONS`,
  `PATH`, `SPEC_OPTS`, `PS4`, `SHELLOPTS`, any name holding a character other than a letter, a
  digit or `_`, and the rest of the list in the README. Those keep their shell value, and so do
  `DATABASE_URL` and `SECRET_KEY_BASE`, whose overrides were skipped but still reached the test
  process, since an override is also written into the environment of the running application. A
  variable deleted from the profiler is now unset in the test process, where it used to hold the
  text `__profiler_deleted__`. Variables the application writes into `ENV` once loaded (`dotenv`
  for instance) no longer reach the test process, which loads them itself when your test setup does.
  The test process, which boots the same application, no longer replays the overrides on its own:
  the runner marks it with `PROFILER_TEST_RUNNER_CHILD=1`, a name the env tools and the env vars
  endpoint now refuse to set or delete (`422`, or a tool error over MCP).
- **Test runner:** Test files are found when the path of the application holds `[` or `{`.
- **Upgrading:** Nothing to do when you run the specs the profiler lists. To run any file under the
  Rails root again, set `config.test_runner_allow_undiscovered_files = true`. The environment
  overrides left out have no option, the list being a deny list that cannot be complete: set those
  variables in the shell that starts Rails instead, the test process inherits them.

## [0.30.9] - 2026-10-04

<!-- stamped -->

### Security

- **Database:** Explain only read-only queries. The **Explain** button, `POST /_profiler/api/explain`
  and the MCP `explain_query` tool ran `EXPLAIN ANALYZE` on any stored query, and PostgreSQL's
  `EXPLAIN ANALYZE` runs the statement it explains: explaining a `DELETE`, `UPDATE` or `INSERT` the
  application had just run ran it a second time, for real. Only statements starting with `SELECT`,
  `WITH`, `TABLE` or `VALUES` are explained now, and a writing CTE, `SELECT ... INTO`, `FOR UPDATE`
  or a second statement is refused too, with a 422 from the endpoint and an error from the MCP tool.
  The probe also runs in a transaction that is always rolled back, read-only on PostgreSQL.
  Upgrading: nothing to set, and no setting brings back the explaining of writes, since the old
  behaviour was to run them again; to see the plan of a write, run it yourself in `psql` between
  `BEGIN` and `ROLLBACK`, as the README shows.
- **Database:** Run the Explain probe on a connection of its own, opened outside the pool and closed
  afterwards, so that nothing it does to its session outlives it: a `SELECT pg_try_advisory_lock(...)`
  explained from a profile left the lock held by a connection of the pool. On PostgreSQL the probe
  is also limited to 30 seconds (`statement_timeout`), and its EXPLAIN goes by the extended
  protocol, which refuses a second statement.

### Fixed

- **Database:** Put bind values back correctly when explaining a query with ten binds or more
  (`$10` was read as `$1` followed by `0`), and leave alone a `?` or `$1` inside a string literal or
  inside a value already put back.

## [0.30.8] - 2026-10-04

<!-- stamped -->

### Fixed

- **Env overrides:** Keep every override when several are set, deleted or reset at the same
  time, from threads of the web process or from Sidekiq processes. Each writer read the file,
  changed it and saved it over the others' changes, and a reader could see a half-written file as
  no override at all. The file is now changed under a lock (`env_overrides.json.lock`, next to
  it) and replaced in one step.

### Security

- **Env overrides:** Stop applying the environment variable overrides saved from the Env tab or
  the MCP env tools in production, and while the profiler is disabled. They were written into
  `ENV` at every boot whatever `enabled` said and whatever the environment, so an
  `env_overrides.json` left under `tmp/` and shipped with a deployment changed the environment of
  the production application, and an application with `config.enabled = false` still had them
  applied without a word. Sidekiq jobs and console evaluations, which apply them again, follow the
  same rules. When overrides are left out, the boot logs one warning to `Rails.logger` with the
  file, the number of overrides and the reason, never a name or a value.
- **Env overrides:** Apply them at boot once the application's `config/initializers` have run,
  where `enabled` is decided, instead of before. An initializer of the application that reads
  `ENV` while it runs no longer sees them; requests, jobs, eager loading and `after_initialize`
  still do.
- **Env overrides:** Resetting one override, or all of them, from the Env tab or the MCP env
  tools no longer writes into `ENV` the "original" values saved in `env_overrides.json` in
  production, nor while the profiler is disabled: those values come from the machine that wrote
  the file, so a reset could put a development value into a production variable, or delete it.
  There, a reset restores only the variables the running process changed itself, to the values
  they had before.
- **Env overrides:** In production, or with the profiler disabled, typing back in the Env tab the
  original value the overrides file shows for a variable now records the running value first, so
  a later reset puts it back instead of keeping the file's value. A reset also restores a variable
  this process changed even when its entry has gone from the file. The `reset_env_var` MCP tool
  now says whether the original value was restored in the process or `ENV` was left unchanged,
  and no longer prints a value, masked or not.
- **Upgrading:** to apply the env overrides while the profiler is disabled outside production,
  as before, set `config.apply_env_overrides_when_disabled = true`. Nothing applies them in
  production. If an initializer of yours needs them, call `Profiler.env_override_store.apply!` at
  the end of `config/initializers/profiler.rb`; initializers loaded after it then see them, under
  the same rules.

## [0.30.7] - 2026-10-04

<!-- stamped -->

### Security

- **Sensitive data:** Mask sensitive values with `[FILTERED]` before a profile is stored. Until
  now `Authorization`, `Cookie` and `Set-Cookie` headers, raw request and response bodies
  (passwords included), outbound request headers and bodies, and the whole of `ENV` were stored in
  clear, and params lost only four exact root keys. The profiler now builds one filter from your
  `Rails.application.config.filter_parameters` plus its own `config.filter_parameters`, with Rails
  semantics (nested keys, any case, regexps, procs), and applies it to params and route params,
  JSON, NDJSON and form bodies, incoming, response and outbound headers (the query string of
  `Referer`, `Location` and `Content-Location` included), outbound URLs, SQL binds of filtered
  columns, job arguments and mailer arguments. `multipart` bodies, and JSON bodies that cannot be
  parsed and in which a filter matches, are masked entirely; HTML and other unstructured bodies are
  kept. A params key that matches the filter is now kept with a masked value instead of being
  removed.
- **Sensitive data:** `ENV` values are shown only for the variables in `config.env_allowlist`, in
  the Env tab, the `env_vars` endpoint and the `list_env_vars`, `reset_env_var` and `get_profile`
  MCP tools alike. `[FILTERED]` is refused as a value by the `env_vars` endpoint (422), the
  `set_env_var` MCP tool and the Env tab import, so re-importing an export cannot overwrite a
  secret. EXPLAIN is refused, with a message, for a query whose bind values were masked.
- **Sensitive data:** Procs of `filter_parameters` run once per string value, with the original
  params for a proc of three arguments, as in Rails; other objects, Active Record models included,
  are neither copied nor passed to them. When the filter fails, the value is masked rather than
  the error reaching the application, and the error class is logged once, without the value. A
  JSON body in whose text no filter matches is not parsed.
- **Upgrade note:** To get the previous behaviour back, set `config.redact_sensitive_data = false`
  (no masking) and `config.env_allowlist = :all` (every `ENV` value); `config.filter_parameters = []`
  keeps masking but relies on your application's list alone. Profiles stored before the upgrade
  are not rewritten and keep their values in clear until they rotate out: clear them after
  upgrading with `bin/rails runner 'Profiler.storage.clear'` (every storage backend), the
  `clear_profiles` MCP tool or the dashboard; the memory store is emptied by a restart. Update
  every node of a cluster: a node still on an older version returns its data in clear to the
  master.

## [0.30.6] - 2026-10-03

<!-- stamped -->

### Security

- **Access control:** Check `authorization_mode` on every page and endpoint of the profiler (UI,
  API, server-sent events, test runner, toolbar), answering `403` otherwise. It used to decide only
  which requests were captured: with `:allow_authorized` and a block that refused everybody, the API
  still listed and deleted profiles and wrote `ENV`. The gem's static JS and CSS stay public.
- **Access control:** The new default `authorization_mode`, `:allow_local`, only lets in requests
  made from this machine: a loopback `REMOTE_ADDR`, no forwarding header naming a remote client, and
  a local `Host` (or one listed in `config.hosts`), against DNS rebinding; the test environment
  also accepts the reserved hosts `www.example.com`, `example.com` and `example.org`, so the
  application's request specs are still captured. It also decides
  which requests are captured, and logs the reason for a refusal once per process. The previous
  default, `:allow_all`, let anybody who could reach the application read and change everything.
- **Access control:** API requests that change something (including a form `POST` turned into
  another verb by `_method`) must carry an `X-Profiler-Request` header or a CSRF token, so that a
  page on another site can no longer trigger them, even when the application turns
  `allow_forgery_protection` off. The dashboard, the toolbar and the cluster send the header.
- **Access control:** CORS is off by default (`extension_cors_enabled = false`,
  `cors_allowed_origins = []`), and `Access-Control-Allow-Origin: *` is never sent to a request
  carrying a cookie or an `Authorization` header. It used to be `*` for everybody.
- **Access control:** Profiler pages may only be framed by the profiler itself and by the Chrome
  extension's DevTools panel (`frame-ancestors 'self' chrome-extension: devtools:`, configurable
  with the new `frame_ancestors` option), and send `X-Frame-Options: SAMEORIGIN`. Any website could
  frame them, and with `?embed=true` a profile page carried no framing protection at all.
- **Upgrading:** Nothing to do when you browse the profiler from the machine that runs Rails. Each
  previous behavior can be restored in `config/initializers/profiler.rb`:
  - Docker, a VM or a remote proxy: admit your network with `config.authorization_mode =
    :allow_authorized` and an `authorize_with` block reading `REMOTE_ADDR` (example in the README), or
    go back to `config.authorization_mode = :allow_all`, which offers no protection.
  - A cluster whose master and slaves run on different machines: each side admits the other's address
    the same way.
  - Your own scripts calling the API: send `X-Profiler-Request: 1`, or set
    `config.api_forgery_protection = false`.
  - Cross-origin clients: `config.extension_cors_enabled = true` and
    `config.cors_allowed_origins = ["https://your.origin"]`. `["*"]` restores the behavior before
    0.30.6 and reopens the profiler to every website you visit: under `:allow_local` or `:allow_all`,
    any page open in your browser can read its data and change it.
  - Framing by other sites: `config.frame_ancestors = ["'self'", "http:", "https:"]`.

## [0.30.5] - 2026-10-03

<!-- stamped -->

### Fixed

- **Instrumentation:** Pass the arguments of `Thread.new` on to its block, and keep keyword
  arguments as keywords. While a profile was being collected the block got none at all, which on
  Ruby 3.4 broke the Happy Eyeballs hostname resolution of `Socket.tcp`: connections by hostname
  timed out, for example as `Redis::CannotConnectError`. Keyword arguments were flattened at all
  times, on every Ruby. Affects v0.22.1 through v0.30.4.
- **Instrumentation:** Raise `ThreadError` on a `Thread.new` with no block during a profiled
  request, as Ruby does.

## [0.30.4] - 2026-07-01

### Fixed

- **Cluster:** Resolve profiles across slaves from the master `ProfilesController` <!-- 9236c4c -->

## [0.30.3] - 2026-06-29

### Fixed

- Wrap the profile dashboards and `TestRunnerPage` with `QueryClientProvider` <!-- 420ae2f -->

## [0.30.2] - 2026-06-29

### Fixed

- **Middleware:** Duplicate downstream headers before mutating them <!-- 3efb20c -->

## [0.30.1] - 2026-06-29

### Fixed

- **Cluster:** Fix sentinel mismatch, profile list pagination, nil safety in MCP tools and HTTPS slave URLs <!-- 4b5fb1c -->

## [0.30.0] - 2026-06-28

### Added

- **Cluster:** Add master/slave profiler clustering <!-- 1435f22 -->

## [0.29.0] - 2026-06-28

### Added

- **SSE:** Push live profile updates over server-sent events <!-- fa0ae2e -->

## [0.28.0] - 2026-06-06

### Added

- **HTTP:** Add the `http_backtrace_depth` configuration option <!-- 25b4f99 -->

## [0.27.1] - 2026-06-06

### Changed

- **API:** Replace manual `fetch()` calls with `orval` generated TanStack Query hooks <!-- e33341e -->

### Fixed

- **File store:** Prevent `ENOENT` errors on concurrent profile file deletion <!-- 8898f0e -->

## [0.27.0] - 2026-06-02

### Added

- **MCP:** Add console profiling, mailer detail, logs/env/i18n sections and full documentation <!-- ca362a1 -->

## [0.26.0] - 2026-06-02

### Added

- **Test profiler:** Add the `run_tests` MCP tool, the `track_tests` option, specs and docs <!-- 265ce03 -->
- **Test profiler:** Enrich reporter, add SSE streaming, MCP tools and env safety <!-- a410c4b -->
- **Test profiler:** Add test profiling, test runner UI and MCP tool <!-- a116fcb -->

## [0.25.0] - 2026-06-01

### Added

- **Console:** Add a console profiling tab with IRB instrumentation <!-- f29937a -->

### Changed

- **Docs:** Document the console profiling tab and the env override behaviour <!-- 031cac6 -->

<!-- excluded:
  bd55e9b specs only, no visible change
-->

## [0.24.0] - 2026-06-01

### Added

- **MCP:** Add tools to manage `ENV` variables <!-- 9126194 -->

## [0.23.0] - 2026-05-27

### Added

- **Profile list:** Add a global clear-all button and auto-refresh on tab switch <!-- 460a110 -->

## [0.22.1] - 2026-05-26

### Fixed

- **HTTP:** Propagate collector to child threads, add fire-and-forget support, fix deep backtrace capture <!-- 9d0bd61 -->

## [0.22.0] - 2026-05-04

### Added

- **Mailer:** Add a body preview, a variables display, a queued badge and design alignment <!-- b7d608f -->
- **Collector:** Implement `MailerCollector`, tracking ActionMailer deliveries <!-- e59dd72 -->

### Changed

- **Toolbar:** Remove the emoji from the mailer toolbar item and the dashboard tab <!-- 55df9bb -->

### Fixed

- **Mailer:** Add the Mailers tab to `JobProfileDashboard` <!-- 4ce145d -->
- **Mailer:** Fix thread isolation and `deliver_later` mode detection <!-- 6e76a99 -->
- **Mailer:** Add `MailerCollector` to the job profiler and align the toolbar item design <!-- 915be28 -->
- **Mailer:** Handle the Rails 7 encoded mail string in the `deliver.action_mailer` payload <!-- 5479dcf -->
- **Mailer:** Replace `Thread.current.delete` with a read and nil write for fiber local variables <!-- 8787201 -->
- **Version:** Remove the pre-release suffix, which broke Bundler resolution <!-- 98caecd -->
- **Mailer:** Address code review findings from MR !32 <!-- b46d3d2 -->

## [0.21.0] - 2026-05-02

### Added

- **Toolbar:** Add a collapse/expand toggle <!-- 8f0669a -->

## [0.20.0] - 2026-05-01

### Added

- **UI:** Display the gem version and warn on a mismatch <!-- 64ff6eb -->

## [0.19.2] - 2026-04-24

### Fixed

- **HTTP:** Capture `RestClient` `body_stream`, remove body size limits, show bodies in MCP tool results <!-- 89fb0e5 -->

<!-- excluded:
  4527e12 release plumbing, version placeholder reset
-->

## [0.19.1] - 2026-04-17

### Fixed

- **Env vars:** Fix revert restoring wrong value, SQLite busy errors, middleware rescue handling and UI refresh <!-- 55c8661 -->

<!-- excluded:
  4637391 pipeline only
  b53b4d7 pipeline only
  7b33bf6 pipeline only
-->

## [0.19.0] - 2026-04-15

### Added

- **Env:** Propagate env var overrides to Sidekiq workers <!-- e75a883 -->

## [0.18.0] - 2026-04-14

### Changed

- **UI:** Extract shared tab utilities and redesign the Request tab <!-- 7aa8adb -->

### Fixed

- **HTTP:** Capture outbound request body passed as second argument to `http.request()` <!-- 5a59665 -->

## [0.17.0] - 2026-04-13

### Added

- **Dashboard:** Add env tab on the home page and env/job toolbar items <!-- d0277ab -->

## [0.16.0] - 2026-04-13

### Added

- **Function profiler:** Add `stackprof` sampling mode with multi-clock support and GC visibility <!-- 5f73512 -->

### Fixed

- **Function profiler:** Fix `stackprof` bugs, remove minimal mode, improve performance <!-- 76c6197 -->

## [0.15.0] - 2026-04-11

### Added

- **Env:** Add environment variables tab <!-- 0e85f18 -->

## [0.14.0] - 2026-04-09

### Added

- **Profiler:** Link jobs to their triggering request or parent job <!-- 74ba5e3 -->

## [0.13.0] - 2026-04-09

### Added

- **UI:** Add copy/download buttons on HTTP bodies, waterfall view, date sort, and other UX improvements <!-- 5afd003 -->
- **UI:** Always show waterfall above the HTTP request list <!-- 32c6b6d -->
- **UI:** Use `SmartBodyPreview` in RequestTab for copy/download on request and response bodies <!-- aef4c0c -->

### Fixed

- **UI:** Derive download file extension from actual MIME type instead of body category <!-- 1dc0bc8 -->
- **UI:** Move `sortedJobs` after `filteredJobs` to fix TDZ error <!-- d4de7bc -->

## [0.12.0] - 2026-04-09

### Added

- **Profiler:** Add function-level profiling with flamegraph and stats table <!-- fcb04a6 -->

## [0.11.1] - 2026-04-09

### Added

- **Config:** Add `tmp_path` option to centralize the storage directory <!-- 5e77944 -->

### Fixed

- **MCP:** Decompress gzip+base64 bodies before returning to UI and MCP tool results <!-- 8f5ac47 -->

## [0.11.0] - 2026-04-06

### Added

- **UI:** Add load-more pagination to the profile list <!-- 9f8458b -->

## [0.10.1] - 2026-04-06

### Changed

- **Docs:** Add full user documentation, with a UI guide, an MCP guide and screenshots <!-- 80a9198 -->

## [0.10.0] - 2026-04-06

### Added

- **Middleware:** Add configurable CORS origins, CSP nonce support and body compression <!-- 3a42188 -->

## [0.9.1] - 2026-04-06

### Removed

- **Collectors:** Remove `PerformanceCollector`, replaced by `FlameGraphCollector` <!-- 212e155 -->

## [0.9.0] - 2026-04-06

### Added

- **Profiler:** Add the `Profiler.measure` custom instrumentation API <!-- 0a3044e -->

## [0.8.0] - 2026-04-05

### Added

- **UI:** Add sortable columns, quick filter presets and flamegraph search <!-- ffd2e6f -->

## [0.7.0] - 2026-04-05

### Added

- **Database:** Add N+1 visual detection and `EXPLAIN ANALYZE` integration <!-- a22902d -->

## [0.6.0] - 2026-04-05

### Added

- **MCP:** Reduce token usage with filtering, body file saving and pagination <!-- 834251d -->

## [0.5.0] - 2026-04-04

### Added

- **MCP:** Add outbound IDs, a domain filter, datetimes, a latest token, exceptions and copy helpers <!-- 9330545 -->

## [0.4.0] - 2026-04-03

### Added

- **Collector:** Add an I18n panel tracking translation lookups per request <!-- 3032a15 -->

<!-- excluded:
  b50d1eb pipeline only
-->

## [0.3.0] - 2026-04-02

### Added

- **Collector:** Add a routes panel and enrich the request collector <!-- bdf0e3c -->

## [0.2.0] - 2026-03-29

### Added

- **Collector:** Add a Logs panel, capturing `Rails.logger` messages per request <!-- 0e0e7ce -->
- Publish the gem to RubyGems.org <!-- f292a21 -->

<!-- excluded:
  10c1314 pipeline only, despite the fix: type
  3f97b1d pipeline only
  a8c2044 pipeline only
  27cc550 pipeline only
-->

## [0.1.4] - 2026-03-29

### Added

- **Profiler:** Capture the full request and response, and add an MCP history clear <!-- 9922c8a -->

## [0.1.3] - 2026-03-29

### Changed

- **Assets:** Migrate Sass `@import` to `@use`, which removes the build deprecation warnings <!-- 1a67e48 -->

## [0.1.2] - 2026-03-25

This tag holds nothing but the release commit the pipeline wrote. The interval
carries no change to the gem, so there is nothing to report for this version.

## [0.1.1] - 2026-03-25

### Added

- **HTTP:** Decompress gzip and deflate response bodies before storing them <!-- f71a5c7 -->
- **Flamegraph:** Add an interactive flame graph tab <!-- 63c4b67 -->
- **Config:** Add `.well-known` and `favicon.ico` to the default `skip_paths` <!-- 1286447 -->
- **Storage:** Add an SQLite backend, a blob store and delete/clear APIs <!-- 544015b -->
- **UI:** Add filters to the profile list action bar and fix the badge colours <!-- 40d4081 -->
- **HTTP:** Add binary download, inline preview and smart text formatting <!-- b09eab8 -->
- Rename the HTTP tab, add the outbound HTTP list and extend MCP coverage <!-- 71bc537 -->
- **Jobs:** Add background job profiling for Sidekiq and ActiveJob <!-- 27b87db -->
- Add an outbound HTTP request collector <!-- e5f2ac9 -->
- **MCP:** Migrate to the official Ruby SDK, over HTTP transport <!-- 3fc2d45 -->
- Implement the dashboard UI, with a tab system and a design system <!-- beb83f7 -->
- Add the AJAX and dump collectors, and the CORS middleware <!-- 08bad9f -->
- First implementation of the gem <!-- 360c6fa -->

### Changed

- **Docs:** Document installation from the GitLab Package Registry <!-- 527c32b -->
- **Assets:** Serve every gem asset exclusively under `/_profiler/` <!-- e8ae1ae -->
- **Config:** Add `manifest.json` to the default `skip_paths` <!-- 350f16c -->
- **Docs:** Correct the installation instructions in the README and remove the dashboard README <!-- e44c8a2 -->

### Fixed

- **Packaging:** Fix the gemspec metadata and file glob, and exclude source assets <!-- 195b609 -->
- **Packaging:** Switch to the yarn build scripts and update dependencies <!-- b62f2d8 -->
- **Packaging:** Fix the `http_collector` require, the collectors option override and asset serving in API only applications <!-- 729f20f -->
- **Packaging:** Exclude `.gem` build artifacts from the file list <!-- 9b97f60 -->
- **Profiler:** Improve memory tracking and profile deserialisation <!-- a0af47e -->

<!-- excluded:
  e27cdae pipeline only
  02d63c9 pipeline only
  9f598d9 subject is not conventional, tooling only
  7d1d823 tests only
  c0d46e6 licence file, not a change to the gem
-->
