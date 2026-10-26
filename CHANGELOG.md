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

## [0.44.24] - 2026-10-26

<!-- stamped -->

### Security

- **Secrets:** Refuse cluster secrets and peer tokens surrounded by spaces or newlines at boot, which break HTTP requests. `trailing` newlines cause `ArgumentError` in `Net::HTTP` and trailing spaces cause systematic 403 errors. Refs #74
- **Redaction:** Mask `peer_token` by value in captured data (headers, bodies, params) alongside `cluster_secret`, preventing credential leakage across profiles and logs. Refs #74. A secret or token padded with spaces stays masked.
- **Environment:** Protect additional environment variables from override via the Env tab and MCP tools: `LOCALDOMAIN`, `RES_OPTIONS`, `HOSTALIASES`, `NODE_EXTRA_CA_CERTS` and `TMPDIR`. These variables control hostname resolution and certificate store location. Refs #74
- **CORS:** Warn at boot when `cors_allowed_origins` contains wildcard `"*"`, which allows any website to access the profiler if a visitor browses it. Recommend using specific origins instead. Refs #74

## [0.44.23] - 2026-10-25

<!-- stamped -->

### Fixed

- **MCP:** `get_profile` and `get_profile_http` tools no longer crash when rendering in-flight HTTP requests with `nil` duration, safely converting to 0.0ms for comparison and display, and a `nil` status is shown as an error.
- **Cluster:** `SlaveProxy#request` now catches `SocketError`, `SystemCallError`, `Net::OpenTimeout`, `Net::ReadTimeout`, `OpenSSL::SSL::SSLError` and `IOError` and re-raises a `Profiler::Error` naming the slave, so a tool reading from an unreachable slave gets a normal error response instead of an internal `json-rpc` failure (matching `Peers::PeerProxy#get_json`).
- **Tasks:** `rake profiler:mcp` now defaults to `:stdio` transport instead of configuration-dependent behavior, aligning with the documented interface; `MCP_TRANSPORT` environment variable still overrides.

## [0.44.22] - 2026-10-25

<!-- stamped -->

### Fixed

- **Test Runner:** test output now streams to the browser in real time instead of waiting for 256 bytes to accumulate.
- **Test Runner:** a rejected SSE stream (e.g. a 404 on the fallback poll) no longer leaves the page blank; the response is validated before replacing the current run.

## [0.44.21] - 2026-10-25

<!-- stamped -->

### Fixed

- **HTTP and Flame Graph collectors:** threads spawned during a profiled request but surviving
  afterwards (a `Timeout.timeout` watcher, a Honeybadger or Bugsnag worker,
  a `Concurrent::ScheduledTask`) no longer indefinitely pollute the profile with unbounded
  entries and repeated re-saves. Collectors now refuse new entries after a grace period
  (0.5 seconds) or when entry count exceeds 100, whichever comes first.

## [0.44.20] - 2026-10-25

<!-- stamped -->

### Fixed

- **MCP:** Clamp negative, zero, and oversized `limit` parameters in `query_profiles`, `query_jobs`, `query_mailers`, `query_console_profiles`, and `query_test_profiles` tools to the valid range `[1, 500]` to prevent invalid queries and unexpected behavior.
- **MCP:** Implement `'latest'` token support in `explain_query` tool, matching the behavior of `analyze_queries` and `get_profile` tools.
- **MCP:** Fix `related_jobs` section in `get_profile_detail` to read parent and child jobs from the correct storage (slave or local) instead of always reading from master storage.
- **MCP:** Return JSON-RPC error -32002 for unknown resource URIs instead of returning a success response with "Resource not found" text.
- **MCP:** Add `error: true` flag consistently to all validation error responses in `clear_profiles`, `explain_query`, and other tools for proper error handling by clients.
- **MCP:** Align `set_env_var` empty value handling with `EnvVarsController#update`: empty values now delete the environment variable and override, consistent between local and slave operations.

## [0.44.19] - 2026-10-25

<!-- stamped -->

### Fixed

- **Changelog:** Detect and reject duplicate version sections that can result from poorly-resolved merge conflicts on `CHANGELOG.md`.
- **Release:** Verify that version tags do not already exist before creating them; exit with a clear error if a tag exists on a different commit, improving diagnostics for out-of-order pipelines.
- **Changelog:** Fix commit-type regex patterns to use non-greedy scope matching (`[^)]*` instead of `.+`), preventing parentheses in commit descriptions from being misparsed as scope delimiters.
- **Release:** Ensure UTF-8 encoding in all release scripts (bin/changelog, script/release.sh, script/canary-version) to prevent "invalid byte sequence" errors when running under `LANG=C` or non-UTF-8 locales.
- **Release:** Filter version tags by pattern (`v[0-9]*`) to prevent non-version tags (e.g., `staging-2026`) from interfering with version computation and release workflow.

## [0.44.18] - 2026-10-25

<!-- stamped -->

### Fixed

- **AJAX interceptor:** Retry `/_profiler/api/ajax/link` with exponential backoff (100ms, 200ms, 400ms) on 404 errors, bounded to 3 attempts, to handle streaming response profiles not yet persisted when the client attachment request arrives. Refs #70

## [0.44.17] - 2026-10-25

<!-- stamped -->

### Security

- **EnvOverrides:** the profiler now refuses to restore environment variables blocked by `EnvKeyPolicy` when a reset is requested, closing a bypass where protected keys (DATABASE_URL, RUBYOPT, etc.) could be restored from persisted overrides.
- **Authorization:** the profiler now validates the Host header against local names, `config.hosts` and `config.mcp_allowed_hosts` in all authorization modes, including `:allow_authorized`, preventing DNS rebinding attacks when using custom authorization blocks.

## [0.44.16] - 2026-10-23

<!-- stamped -->

### Fixed

- **LogCollector:** Prevent `BroadcastLogger` level from forcing `DEBUG` globally across all threads during profiling.
- **Middleware:** Skip toolbar injection for HTML downloads (`Content-Disposition: attachment`) and compressed responses (`Content-Encoding` present) to prevent file corruption.
- **Middleware:** Remove `ETag` and `Last-Modified` headers when toolbar is injected to prevent stale cached responses on 304 Not Modified.
- **Profiler:** Catch `Exception` (not just `StandardError`) to properly handle `Interrupt`, `SignalException`, and `Sidekiq::Shutdown`, marking profiles as failed instead of completed.

## [0.44.15] - 2026-10-23

<!-- stamped -->

### Fixed

- **Replay:** Include `Content-Type` header from captured request when replaying. Previously, only `HTTP_*` Rack env vars were captured, missing `CONTENT_TYPE` which is stored separately. Replayed JSON POST requests were incorrectly treated as form data. Refs #64
- **Replay:** Reject stored request bodies containing redaction masks (`[FILTERED]` or `[FILTERED: ...]` markers) and note them in the result instead of sending them as real data, including when the captured params would otherwise have been re-encoded into a replacement body. Refs #64
- **Replay:** Validate that the `headers` override parameter is a Hash or nil; previously passing a string or other type caused `NoMethodError` resulting in a 500 error. Now raises `Replay::Invalid` with a clear message. Refs #64

## [0.44.14] - 2026-10-23

<!-- stamped -->

### Fixed

- **SqliteStore:** discard the memoized storage instance after a fork so a fresh connection is built lazily on the next access, instead of reusing the parent's connection, which sqlite3 closes in the child (`preload_app!`, prefork scenarios).

## [0.44.13] - 2026-10-23

<!-- stamped -->

### Fixed

- **Compare:** a collector absent from the second profile being compared is now neutral too, like one absent from the first, instead of being classified as an improvement or a regression.

## [0.44.12] - 2026-10-23

<!-- stamped -->

### Fixed

- **Compare:** metric diff now correctly distinguishes between absent collectors (no measurement to compare) and zero baselines (measured at zero), ensuring absent collectors remain neutral instead of incorrectly classified as improvements or regressions.

## [0.44.11] - 2026-10-22

<!-- stamped -->

### Fixed

- **Compare:** metric status now correctly identifies improvements and regressions when baseline values are zero, classifying direction-aligned changes as improvements without requiring a percentage threshold.

## [0.44.10] - 2026-10-22

<!-- stamped -->

### Fixed

- **Cluster:** the master now logs a warning when a process with `cluster_master=true` forks, and
  when a heartbeat is received for a slave not seen in the current worker, to help detect the
  misconfiguration of running multiple master workers without a shared registry.
- **Documentation:** `DECISIONS.md` now correctly states that the gem provides shared storage
  backends (file, SQLite, Redis); the decision to keep the slave registry single-process is based
  on avoiding per-heartbeat writes, not on the lack of storage options.

## [0.44.9] - 2026-10-22

<!-- stamped -->

### Fixed

- **File storage:** profile paths containing non-ASCII characters (e.g., `/café`) are now correctly saved and loaded even when the system's default encoding is not UTF-8 (e.g., `LANG=C`).

## [0.44.8] - 2026-10-22

<!-- stamped -->

### Fixed

- **Tests:** Consolidate api-fetcher test files
- **Decisions:** Update slave prefix exemption documentation

## [0.44.7] - 2026-10-22

<!-- stamped -->

### Fixed

- **Cluster:** the `post` method of `MasterClient` now includes `write_timeout` alongside `open_timeout`
  and `read_timeout`, preventing extended waits when the master server stops responding mid-write.
- **Cluster:** configuration errors in the heartbeat loop (invalid `master_url` or missing secret) are
  now logged once instead of on every heartbeat cycle, eliminating log noise from unrecoverable
  configuration problems.

## [0.44.6] - 2026-10-21

<!-- stamped -->

### Fixed

- **Toolbar:** the toolbar's own requests (`/api/toolbar/` and `/api/events/`) no longer receive
  the slave prefix, fixing a "Profiler data could not be loaded" error on every profiled page of
  a tab where a slave was selected.

## [0.44.5] - 2026-10-21

<!-- stamped -->

### Fixed

- **Cluster:** `docs/cluster.md` now says that the master must run as a single process. Its registry
  of slaves is kept in memory, so with several workers each heartbeat reaches one of them and a
  slave appears `offline` on the others.

## [0.44.4] - 2026-10-21

<!-- stamped -->

### Fixed

- **Cluster:** a slave no longer delays the boot of the server, of `rails console` or of a rake task when its master is unreachable. The first registration now runs in the heartbeat thread instead of `after_initialize`, and calls to the master time out after 3 seconds to connect and 5 seconds to read, instead of 60 seconds each.

## [0.44.3] - 2026-10-21

<!-- stamped -->

### Fixed

- **Cluster:** The children of a profile read on a slave (child jobs, AJAX sub-requests) are no longer cut at the slave's first 50: the master reads every page until the slave reports no more, and returns them oldest first like the local storages do.
- **Cluster:** The master no longer takes any answer of a slave for data. A `401` or `403` (a wrong `config.cluster_secret`) raises an error that names the secret instead of showing an empty slave, a `404` is no profile for `load` and an error elsewhere, and any other status outside 2xx raises a `Profiler::Error` carrying the slave's message. The `set_env_var`, `delete_env_var`, `reset_env_var`, `reset_all_env_vars` and `clear_profiles` MCP tools on a slave report that error instead of announcing a success, and the dashboard's slave proxy answers a slave's `404` with a `404`.
- **Cluster:** `DELETE /_profiler/api/profiles/clear` now honours its `type` parameter (`http`, `job`, `test` or `console`, anything else is a 422; `http` when it is absent, as before). The `clear_profiles` MCP tool on a slave used to delete the slave's HTTP profiles whatever the type asked, and answered that it had cleared the jobs; with no type it now clears every type of the slave.

## [0.44.2] - 2026-10-21

<!-- stamped -->

### Fixed

- **Database:** A real query that contains a line starting with `COMMIT`, `BEGIN`, `ROLLBACK`,
  `SAVEPOINT` or `RELEASE` is no longer hidden from the database and flamegraph collectors: only a
  statement that is itself a transaction instruction is skipped, whatever the leading whitespace.

## [0.44.1] - 2026-10-21

<!-- stamped -->

### Fixed

- **I18n:** `I18n.t(default: "Fallback")` and `I18n.translate(default: "Fallback")`, called without a
  positional key, return their default again once the profiler is installed. They raised
  `ArgumentError (given 0, expected 1)` in the whole process, even outside a profiled request.

## [0.44.0] - 2026-10-20

<!-- stamped -->

### Added

- **Replay:** A profiled HTTP request can be sent again, for real, from the new **Replay request**
  button of the dashboard's Request tab, `POST /_profiler/api/profiles/:token/replay` and the MCP
  `replay_request` tool, with `count` replays in a row (at most `config.replay_max_count`, 10 by
  default) and variations of the method, path, query, params, body, headers and cookies. Each replay
  is a new profile whose `replay_of` is the original's token, read with the new
  `find_by_replay_of` of every storage backend. It is off by default
  (`config.replay_enabled = false`). A replay always goes to the host name of the original
  request, on the port the application really listens on: `config.replay_port` when set, otherwise
  the port of the Puma socket captured with the profile (`env["puma.socket"]`, kept as `server_port`).
  Never the port written in the `Host` header and never `SERVER_PORT`, which Puma derives from that
  header. No option can name another host, port or URL, a `Host` or `X-Forwarded-*` header override
  is ignored, and a captured host that is neither a loopback name (`localhost`, `127.0.0.1`, `::1`) nor listed
  literally in `config.hosts` is refused: a wildcard, IP range, `Regexp` or `Proc` entry does not count,
  so Rails' permissive development default (`0.0.0.0/0`, `::/0`) lets no address through. Under a
  server other than Puma, or for a profile captured without a port, the replay is refused until
  `config.replay_port` is set. Every method is allowed; the dashboard asks for a confirmation,
  the MCP tool does not, its caller answers for the request, which is why `replay_request` is a
  **write** tool: a read-only MCP server (`config.mcp_read_only` or `PROFILER_MCP_READ_ONLY`) neither
  lists nor runs it. The replay is synchronous and needs a server with more than one thread (Puma
  `threads 2, 5`). The replay call is never profiled itself.

## [0.43.0] - 2026-10-20

<!-- stamped -->

### Added

- **Alerts:** The new `config.alerts_enabled` (default `false`) turns on threshold alerts. Each profile
  saved that crosses `slow_query_threshold`, `max_queries_warning` or
  `allocated_objects_warning_threshold`, or that repeats a normalized SQL statement (an N+1), is handed to
  the `config.on_detection` block and, when `config.alert_webhook_url` is set, POSTed there as generic JSON
  (see `docs/configuration.md` for the payload). The checks run on one worker thread with a bounded queue (a full queue drops and logs the check), never delay the
  request, and their failures are logged. A profile saved again is not alerted again for a type already delivered,
  and the `path` of a console profile is `null` in the payload. `config.alert_webhook_url=` raises `ArgumentError`
  for a URL that is not http(s) with a host, or that carries credentials. An alert carries the normalized SQL and a fingerprint, never a body
  or a parameter; SQL literals (quoted strings with a backslash or a doubled quote, double quoted text,
  comments, dollar-quoted bodies) are removed from the statement, and a statement whose literals cannot be
  read with certainty is cut before the first one.

## [0.42.0] - 2026-10-20

<!-- stamped -->

### Added

- **Compare:** `compare_profiles` (MCP) and the dashboard's Compare page diff two profiles: total duration, allocations, cache hit rate, rendered views, and SQL queries grouped by normalized statement into new, gone and slower blocks.
- **Compare:** each of the two profiles can come from another instance: `config.peers = [{ name:, url: }]` is an explicit allow list (empty by default, so no outgoing call), `config.peer_token` is sent in the `X-Profiler-Peer-Token` header and, on the serving instance, opens `GET /_profiler/api/profiles/:token` only. A URL from a request or a tool argument is never called, and an unknown node is refused with an error. `node_a` and `node_b` pick the node, in the MCP tool and with a selector per profile in the dashboard.

## [0.41.0] - 2026-10-20

<!-- stamped -->

### Added

- **Dashboard:** Every file and line the dashboard shows is now a link that opens in your editor:
  the backtraces of the Database, Http and Exception tabs, the Dumps tab and toolbar panel, the
  function table of the flame graph tab, and the file of the Test tab. Set the editor with
  `config.editor_url_scheme` (`"vscode"` by default, `"idea"` or `"cursor"`; any other value gives
  no link). For a server running in a container while the editor runs on the host, translate the
  paths with `config.editor_path_map`, for example `{ "/app" => "/home/me/project" }`; the longest
  matching prefix wins. Paths are escaped in the generated URLs.
- **API:** `GET /_profiler/api/config` is read-only and returns `editor_url_scheme` (`null` when
  the configured scheme is not allowed) and `editor_path_map`, for the dashboard and for the browser
  extension, which uses them when it has no setting of its own.

## [0.40.0] - 2026-10-19

<!-- stamped -->

### Added

- **OpenTelemetry:** with the same `config.otel_enabled = true`, each profiled request also records metrics: duration histograms (request, SQL query, view, cache operation, outbound `Net::HTTP` call) and counters for allocated objects and for requests that ran an N+1. Attributes are low-cardinality on purpose: `controller#action`, HTTP method and status, SQL verb and cache operation, never a token, URL or SQL text. **Experimental:** it needs `opentelemetry-metrics-api`, `opentelemetry-metrics-sdk` and `opentelemetry-exporter-otlp-metrics` in the application's `Gemfile`, pinned to an exact version because the metrics SDK is alpha; without them one message is logged and traces are unaffected.

## [0.39.0] - 2026-10-19

<!-- stamped -->

### Added

- **OpenTelemetry:** with `config.otel_enabled = true`, each profiled request is exported as a trace: a root span carrying the profile's own `trace_id` and `span_id`, and a child span for each SQL query, view or partial render, cache operation and outbound `Net::HTTP` call. An application that already initialised OpenTelemetry keeps its own tracer provider; otherwise the gem sends the spans itself over OTLP `http/protobuf` to `config.otel_otlp_endpoint`, with `config.otel_service_name` (the application's name by default).
- **OpenTelemetry:** the gem does not depend on OpenTelemetry. Add `opentelemetry-sdk` and `opentelemetry-exporter-otlp` to the application's `Gemfile` to use it; without them, `otel_enabled = true` writes one message to the log and exports nothing. With `otel_enabled` at `false` (the default) nothing of OpenTelemetry is loaded.
- **Collectors:** the SQL, view and cache events now record their `started_at` (epoch seconds), which the trace export uses to place their spans.

## [0.38.0] - 2026-10-19

<!-- stamped -->

### Added

- **Tracing:** a request carrying a valid W3C `traceparent` header continues that trace: the profile records its `trace_id`, a `span_id` of its own and the caller's span as `parent_span_id`. Without a header, or with an invalid one, the request starts a new trace.
- **Instrumentation:** an outgoing `Net::HTTP` call made while a profiled request runs carries a `traceparent` header with that request's `trace_id`, unless the application set one itself or the host is listed in `http_skip_hosts`.
- **Storage:** every backend answers `find_by_trace(trace_id)`; the SQLite database gains `trace_id`, `span_id` and `parent_span_id` columns on its own.
- **API:** `GET /_profiler/api/profiles?trace_id=...` lists the profiles sharing a trace.
- **Dashboard:** a `Trace` tab shows the trace, span and parent span ids of a profile and links to the other profiles of the trace.

## [0.37.0] - 2026-10-18

<!-- stamped -->

### Added

- **Collectors:** a collector whose `subscribe` or `collect` raises `collector_circuit_breaker_threshold` times in a row (`3` by default) is no longer run: its circuit opens and the profiles leave it out. After 60 seconds one request tries it again; a success closes the circuit, a failure opens it for another 60 seconds. `collector_circuit_breaker_enabled = false` turns the counting and the blocking off.
- **API:** `GET /_profiler/health` (a page, or JSON with `/_profiler/health.json`) shows the circuit state (`closed`, `open`, `half_open`) and the consecutive failures of each configured collector. It always answers `200`.
- **Toolbar:** a `Health` link next to the `Profiler` link opens that page.

### Fixed

- **Collectors:** a collector whose `subscribe` raises no longer stops the profiler for the whole request, job, console expression or test: only that collector is left out and the others keep profiling.

## [0.36.2] - 2026-10-18

<!-- stamped -->

### Fixed

- **Cluster:** the heartbeat thread of a worker no longer keeps the collectors of the request that was running when it was started (a worker forked or restarted mid-request), and no longer records its own HTTP calls into them.

## [0.36.1] - 2026-10-17

<!-- stamped -->

### Changed

- **Compatibility:** The gem now declares `rails >= 7.1` instead of `rails >= 7.0`. This is a
  correction announced, not a new restriction: the gem already relied on
  `ActiveSupport::BroadcastLogger` and `Rack::Headers`, which Rails 7.0 does not provide, and
  the suite fails on 7.0 (271 failures out of 1904). Bundler now refuses to install the gem on
  Rails 7.0 instead of installing a version that cannot work.

## [0.36.0] - 2026-10-17

<!-- stamped -->

### Changed

- **Dashboard:** The profiler selector now uses the generated `useListClusterSlaves` client
  instead of a hand-written `fetch`; the cluster endpoints are always asked of the master, also
  while a slave is being viewed.

### Fixed

- **Toolbar:** The toolbar keeps rendering and working when `localStorage` is refused (strict
  private mode, storage disabled by a policy): the collapsed state and the theme are kept in
  memory for the page instead of failing silently.
- **Toolbar:** After a Turbo Drive visit to a page the profiler leaves alone, AJAX requests are no
  longer linked to the profile of the last profiled page.
- **Toolbar:** When the toolbar data cannot be loaded (network error, 500, timeout), the bar shows
  an error with a Retry button instead of staying empty, and a component that throws shows a
  minimal error, with a Retry button, instead of blanking the whole toolbar.
- **Toolbar:** `Alt+P` (`Option+P` on macOS) now toggles the toolbar on every platform, as the
  shortcut is matched on the physical key (`event.code`) and not on the character it produces.
- **Dashboard:** The copy buttons work over plain HTTP on a non-local address, where
  `navigator.clipboard` does not exist, through a `document.execCommand('copy')` fallback, and
  say so when copying is not available.
- **Toolbar:** The last rule of the toolbar CSS that was not scoped to the toolbar elements
  (`.profiler-toggle-icon`) is now scoped, so that no style of the toolbar reaches the host page.

## [0.35.3] - 2026-10-17

<!-- stamped -->

### Changed

- **Assets:** The JavaScript and CSS bundles are minified: the toolbar script goes from 177 KB to
  81 KB, the dashboard script from 447 KB to 222 KB and the stylesheet from 91 KB to 79 KB.
- **Toolbar:** The page interceptor script and the toolbar CSS are read and built once per
  process instead of on every profiled page.

### Fixed

- **Toolbar:** The toolbar style and the embedded profile layout now carry the request's CSP
  nonce. An application whose policy has `style-src 'nonce-...'` and no `'unsafe-inline'` no
  longer blocks them; without a CSP, no nonce is added.
- **Assets:** The toolbar and dashboard files (`profiler.js`, `profiler.css`,
  `profiler-toolbar.js`) are now requested as `?v=<digest of the content>` and served for a year
  as immutable, so a browser keeps them between visits and still loads the new ones after an
  upgrade of the gem. The URL without `?v=` still works and is cached for an hour, and an
  asset that is not built still answers the 404 that names `yarn build:full`.

## [0.35.2] - 2026-10-17

<!-- stamped -->

### Changed

- **Performance:** The patch on `Thread#initialize` that carries the profiling context into new
  threads is now installed by the railtie, only when the profiler is `enabled`; a disabled profiler
  no longer touches `Thread`.

### Fixed

- **Cluster:** A worker forked from a process that had already started the cluster client (Puma in
  cluster mode with `preload_app!`, a preloaded Unicorn) now gets its own heartbeat thread and
  registers again with the master, through a `Process._fork` hook (Ruby 3.1 and later). Where the
  hook is not available, call `Profiler::Cluster::MasterClient.restart_after_fork` from Puma's
  `on_worker_boot`; see `docs/cluster.md`.
- **HTTP and request bodies:** A body is now kept as base64 when its bytes are binary (a NUL byte,
  invalid UTF-8, mostly control characters), whatever `Content-Type` it was served with, and `font/`,
  `application/x-protobuf` and `application/gzip` are recognized as binary types. A binary string
  is no longer turned into `?` characters. A body whose `Content-Type` declares a charset other than UTF-8 (`ISO-8859-1`...) stays text, decoded from that charset. A `Net::HTTP` response read as a stream (`read_body`
  with a block) is recorded with no body and `response_body_not_captured`, instead of the `inspect`
  of the stream adapter.
- **Version:** `Profiler.version`, the version recorded in profiles and announced by the MCP server,
  comes from `git describe` when the gem is mounted by path from a git checkout, so
  `gem_version` is no longer always `0.0.0` there. A published gem keeps the version it was built
  with, and `0.0.0` remains the fallback.
- **MCP:** The `profiler-mcp` executable reads the profiles the application's file storage wrote
  under `tmp/rails-profiler` in the current directory; it read an empty memory store of its own and
  always answered that there were no profiles.
- **Profile pages:** the `profiler-version` meta tag of the page layouts now reports `Profiler.version`, the same value the API returns, instead of the raw `Profiler::VERSION` constant. When the gem is mounted from a git checkout, every profile no longer shows a false "different version" warning.

## [0.35.1] - 2026-10-17

<!-- stamped -->

### Fixed

- **Release:** The version a merge publishes is now read from the subject line of each commit only,
  never from its body, and `BREAKING-CHANGE:` (with a hyphen) publishes a major version just as
  `BREAKING CHANGE:` already did.
- **Canary:** A prerelease is now numbered after the version its branch is going to publish, not
  after the last release, so RubyGems no longer sorts a recent canary as older than the release it
  precedes.

### Security

- **Release:** `rake release` and its subtasks now refuse to run from a developer machine and point
  to the `release` CI job, the only publisher. `rake build` and `rake install` keep working.
- **CI:** The `canary` job no longer publishes a prerelease on every push to a `feature/`,
  `bugfix/`, `hotfix/`, `fix/` or `breaking/` branch; it is now manual and publishes only when
  someone plays it.

## [0.35.0] - 2026-10-17

<!-- stamped -->

### Added

- The dashboard pages now carry the Chrome extension's icon as their favicon, served at `/_profiler/assets/icon.png`.

## [0.34.6] - 2026-10-16

<!-- stamped -->

### Added

- **Test runner:** `config.test_runner_kill_grace_seconds` (5 by default),
  `config.test_runner_max_output_bytes` (5 MB by default) and `config.test_runner_max_active_runs`
  (2 by default), described under the fixes below. `nil` lifts either limit.

### Fixed

- **Test runner:** A test process ended by a signal (killed for lack of memory, crashed, stopped by
  another program) is no longer reported `passed` with exit code 0. The run ends `signaled`, with no
  exit code, the name of the signal in a new `signal` field of the API, a `Signal` line in the MCP
  tool `run_tests`, a `[Profiler]` line at the end of its output, and "Ended by a signal" in the page.
- **Test runner:** **Stop** now stops the whole test run. The test process runs in a process group
  of its own: `TERM` goes to the whole group, the processes rspec or rails started included, and
  `KILL` follows after `config.test_runner_kill_grace_seconds` for whatever ignored it. A stopped
  run used to leave those processes, and a process ignoring `TERM`, running.
- **Test runner:** The output a run keeps is limited to `config.test_runner_max_output_bytes`: its
  beginning, a `[Profiler] Output truncated` line, and its last quarter once the run ends, with the
  number of bytes left out. It used to be kept whole, however large. At most 20 finished runs are
  kept, on top of the one hour they were already kept.
- **Test runner:** Starting a run while `config.test_runner_max_active_runs` runs still have their
  test process is refused, with a `429` from the API, the reason in the page, and a tool error from
  `run_tests`. Any number of runs could be started at once.
- **Test runner:** A run is only known to the server process that started it. With Puma in cluster
  mode, a request reaching another worker gets a `404` that now gives this reason; the
  [test runner documentation](docs/testing.md#several-server-processes) describes the limit.

## [0.34.5] - 2026-10-16

<!-- stamped -->

### Fixed

- **Request capture:** the parameters of a request are now read once the application has returned, so
  route parameters are present and `param_encoding` is applied, and they are converted to UTF-8. They
  used to be read in the outermost middleware, before the router ran.
- **Request capture:** a text body keeps its accents. It is now read in the `charset` of its
  `Content-Type`, UTF-8 when it declares none, and invalid bytes are replaced, instead of every
  accent being turned into a replacement character.
- **Request capture:** a request whose `Content-Type` declares a charset Ruby cannot convert from
  (`charset=utf-7`, `charset=internal`) no longer loses its profile; the body is read as UTF-8 with
  invalid bytes replaced.


## [0.34.4] - 2026-10-16

<!-- stamped -->

### Fixed

- **Sidekiq:** A job run through the ActiveJob adapter is no longer profiled twice. It reaches the
  Sidekiq middleware wrapped (`job["wrapped"]`) and is already profiled by the ActiveJob
  `around_perform` callback, so the middleware now leaves it alone when ActiveJob is instrumented
  and the same work is recorded once.
- **Logs:** The log buffer behind `CaptureLogger` is now guarded by a `Mutex`, so lines recorded
  from several threads at once (a streamed body iterated by another thread, work handed the buffer)
  keep the byte count and the stored lines consistent.
- **Flame graph and views:** Nested durations are counted once. The total of the flame graph and
  the total of the views and partials now cover each moment a single time, so a template that
  renders partials, or a controller action that runs queries, is no longer added to what it
  contains.

## [0.34.3] - 2026-10-15

<!-- stamped -->

### Changed

- **Test suite:** `bundle exec rspec` now measures the line coverage of the gem's Ruby code with
  SimpleCov, and the CI fails below 92.0%, the level measured on Ruby 3.3 once the MCP
  tools, the function profiler, the storage base class and the cluster client got specs of their
  own. A run of a few spec files is held to no floor outside the CI.
- **Test suite:** The suite loads and passes under any locale, `LANG=C` included: `spec_helper.rb`
  reads files as UTF-8 whatever the locale, and a `.rspec` file loads it for every spec. The specs
  of the masking of sensitive data now live together under `spec/redaction/`.

### Fixed

- **Middleware:** The default `skip_paths` are now anchored to the whole path, so a page such as `/users/favicon.ico.html` is no longer skipped by mistake, and the Sprockets assets (`/assets`) and Action Cable (`/cable`) requests are no longer profiled. A `skip_paths` list you set yourself is used as given.
- **Mailers:** Visiting the mailer previews (`/rails/mailers`) no longer records phantom delivered emails in the profile.
- **Security:** An `authorize_with` block that raises is now treated as a denial: the error is logged server side and the request is served unprofiled, instead of breaking every request of the application.

## [0.34.2] - 2026-10-15

<!-- stamped -->

### Changed

- **Dependencies:** The gem now requires `mcp` below 2.0 (`>= 0.3, < 2`). The upper bound keeps
  a future major of `mcp` from being picked up by `bundle update` and breaking the MCP server; the
  test suite passes on both ends of the range, `mcp` 0.3.0 and 1.7.0. An application already on
  `mcp` 2.x would have to stay on an earlier version of the gem until it supports it.

### Fixed

- **MCP:** `explain_query` called against an unknown, offline or refused slave profiler now answers the dedicated message (`Error: Unknown slave profiler: ...`) instead of the generic `EXPLAIN failed`.
- **Assets:** The toolbar assets endpoints now answer a 404 that names the command to run (`yarn build:full` in the gem) when `app/assets/builds/` is empty or incomplete, instead of a 500.

### Security

- **Build:** The client the dashboard is built from is now generated with `orval` 8
  (`^8.41.0`, locked at 8.41.0) instead of 7.21.0, which carried eleven critical advisories of
  code execution while generating from an OpenAPI document. `orval` only runs when the assets are
  built, never in an application using the gem, and the generated client calls the same URLs with
  the same methods and cache keys as before. Building the assets now needs Node.js 22.18 or later.
- **CI:** A `yarn:audit` job reports the advisories at level high and above on the JavaScript
  build dependencies. It is informational: a finding shows as a warning and does not hold back a
  publication.

## [0.34.1] - 2026-10-15

<!-- stamped -->

### Security

- **Explain:** The Explain button, `POST /_profiler/api/explain` and the MCP `explain_query` tool
  now only run in the `development` and `test` environments, even where an application sets
  `enabled = true`. Elsewhere, `production` and `staging` included, they are refused before
  anything reaches the database: a `403` from the endpoint, an error from the tool. PostgreSQL's
  `EXPLAIN ANALYZE` runs the query it explains, so a costly `SELECT` used to run for real on the
  production database. Set `config.allow_explain_outside_development = true` to allow it there
  anyway (false by default). The description of `explain_query` given to MCP clients now says so;
  it claimed the tool was limited to development and test, which nothing enforced.
- **API:** An unexpected error no longer sends its message to the client. `POST
  /_profiler/api/explain` answers `500` with `Explain failed`, `POST /_profiler/api/ajax/link`
  with `Could not link the Ajax request`, the slave proxy (`/_profiler/api/slaves/:name/...`)
  `502` with `Proxy error`, and `explain_query` with `EXPLAIN failed`. The message, which could
  hold the SQL of the query, an internal file path or the address of a slave, goes to the
  application log instead. The profiler's own refusals (a query that is not read-only, an index
  out of range, an unknown or offline slave) still give their reason.

## [0.34.0] - 2026-10-15

<!-- stamped -->

### Added

- **MCP:** `config.mcp_read_only = true` leaves out the tools that change something:
  `run_tests`, `clear_profiles`, `set_env_var`, `delete_env_var`, `reset_env_var` and
  `reset_all_env_vars`. They are not listed by `tools/list`, and a client that calls one by name
  gets a "tool not found" error; the tools that only read stay. False by default. The gem's
  `profiler-mcp` executable does not boot the application, so it never reads the option: set
  `PROFILER_MCP_READ_ONLY=1` in the environment the MCP client starts it with. The variable works
  with `rake profiler:mcp` and the HTTP transport too, and never turns read-only off.

### Changed

- **Env overrides:** An override saved by an earlier version for a name the profiler now refuses,
  such as `DATABASE_URL`, `PRIMARY_DATABASE_URL`, `LD_PRELOAD` or `HTTPS_PROXY`, is no longer
  applied: not at boot, not before a Sidekiq job, not in the test runner. It stays in the file
  until reset, and a warning gives how many were left out, never their names. Set such a variable
  in the shell that starts the application instead.

### Fixed

- **Env overrides:** The Env tab, `set_env_var` and `delete_env_var` refuse a name that is not
  made of letters, digits and underscores (`A=B`, `MY-VAR`), and the variables that select the
  database, the secrets or the network of the application, or make a process load other code:
  `DATABASE_URL` and every name ending in `_DATABASE_URL`, every name starting with `PG` or
  `MYSQL_`, `RAILS_MASTER_KEY`, every proxy variable in any case (`http_proxy`, `HTTPS_PROXY`),
  `SSL_CERT_FILE`, `SSL_CERT_DIR`, `OPENSSL_CONF`, `GCONV_PATH`, `IRBRC`, `PRYRC`, `ZDOTDIR`,
  `LD_PRELOAD`, `RUBYOPT` and the others listed in the docs. Before, any of these could be set,
  `DATABASE_URL` included. The refusal comes before anything is written: a 422 from the endpoint,
  an error from the tool. The list cannot be complete: a gem may read a variable of its own.
- **Env overrides:** A value holding a NUL byte is refused the same way. Before, it was written to
  the file, then the tool failed with an internal error, and every process logged the same error
  again before each Sidekiq job.
- **Env overrides:** A reset now reaches every process that applied the override, each Sidekiq
  process and Puma worker, not only the first one to read the file: each puts back the value it
  had before. A process that never applied the override is left alone.
- **Env overrides:** The overrides file is no longer read and parsed again before every Sidekiq
  job while it does not change. A change written within two seconds of the previous one is never
  missed, on ext4 too, where the file system reuses the inode and the modification time can stay
  the same.

## [0.33.3] - 2026-10-14

<!-- stamped -->

### Fixed

- **Rake tasks:** `rake profiler:cleanup` with an empty or non-numeric `OLDER_THAN` (`""`,
  `abc`) no longer removes every profile, and `OLDER_THAN=1h` is no longer read as one second.
  `OLDER_THAN` and `LIMIT` take a whole number only; any other value stops the task with an error
  and removes nothing. `OLDER_THAN=0` still removes every profile, when written so.
- **Storage:** The SQLite store compares the start times of the profiles in UTC. Outside UTC,
  `rake profiler:cleanup` and `cleanup` removed recent profiles (America/New_York) or kept old
  ones (Asia/Tokyo), and the lists were out of order across a clock change. The profiles already
  in the database are converted once, when the store opens it; the API shows the same times.
- **Storage:** The Redis store takes expired profiles out of its lists at each save, and its list
  keys now expire a TTL after the last save. Without `max_profiles`, or between two evictions,
  the tokens of expired profiles stayed listed until a manual cleanup, and a page of the list
  came back with fewer profiles than asked.
- **Storage:** With the SQLite store, a profile saved again without a response body no longer
  shows the response body of its previous save. The response bodies left on disk by profiles
  removed outside the store are removed by `cleanup` and when the oldest profiles are evicted.

### Limitations

- **Storage:** Two SQLite stores that share a `blob_path` remove each other's response bodies:
  give each `database` its own `blob_path` (see `docs/storage.md`).
- **Storage:** On the first save after an upgrade, the Redis store can drop from its lists a job
  that started more than a TTL ago and was saved recently. It happens once.

## [0.33.2] - 2026-10-14

<!-- stamped -->

### Changed

- **Configuration:** A String in `config.http_skip_hosts` is now a host name, compared whole and
  ignoring case, instead of a pattern: `"example.com"` no longer leaves out `notexample.com`,
  `exampleXcom` or `example.com.attacker.net`. A String that starts with a dot is a domain whose
  subdomains are left out (`".internal"` leaves out `api.internal`). A Regexp is matched as
  before. An entry that is not a host name, a wildcard String (`"*.internal"`), an empty one, or
  anything that is neither a String nor a Regexp (`nil`), is left out when the list is set, with
  a warning in the log that says what to write, and the other entries are kept. It does not
  raise: the gem is loaded in production too, where a mistake in this list must not stop the
  application from booting, even with the profiler disabled.
- **Dumps:** A dump is stored as its formatted text only: the raw `value` field, which no tab
  read and the API did not document, is no longer part of the dump data.

### Fixed

- **Configuration:** A String in `config.skip_paths` no longer fails every request with a
  `TypeError`: it skips the path equal to it, and a Regexp is matched as before. A single
  pattern, a String or a Regexp, set without a list is read as a list of one.
- **Outbound HTTP:** A String in `config.http_skip_hosts` that is not a valid Regexp, such as
  `"*.internal"` added with `<<`, no longer fails every `Net::HTTP` call of a profiled request
  with a `RegexpError`.
- **Database:** A query that binds bytes, a `blob` or `bytea` column such as an image, no longer
  loses the profile of its request when it is saved: the bind shows as text when its bytes are
  valid UTF-8, and as `[binary data, N bytes]` otherwise.
- **Logs:** A line logged with bytes that are not valid UTF-8 no longer raises an
  `Encoding::CompatibilityError` in the application's own logger call (Rails 7.1 and later), and
  a binary line no longer loses the profile when it is saved: the line is kept as UTF-8, what
  cannot be read replaced with U+FFFD, and a line in another encoding is converted.
- **Dumps:** `Profiler.dump` of an object that refers to itself, directly or through an instance
  variable, no longer fails the request with a `SystemStackError` (a 500 with the file store), and
  an Array or a Hash holding itself no longer loses the profile. An object whose own `inspect`
  recurses without end shows `[Error formatting value: stack level too deep]`.
- **Middleware:** A page whose body is made of fragments of different encodings, a binary one
  among UTF-8 ones, no longer fails with an `Encoding::CompatibilityError` once profiled: its
  bytes are joined as the application gave them, and it gets its toolbar.

## [0.33.1] - 2026-10-14

<!-- stamped -->

### Fixed

- **Packaging:** The published gem now contains `app/assets/javascript/profiler-ajax-interceptor.js`,
  the script the toolbar injects to link the `fetch`, `XMLHttpRequest` and Turbo requests of a page
  to that page. It was missing from every published version: with the gem installed from a
  registry, those requests were never linked to their page, and the only trace was the log line
  `ToolbarInjector: could not load the AJAX interceptor script`. A gem used from a git checkout or
  a local path was not affected.
- **Release:** A version is now published only once both test suites (Ruby 3.3 and 3.4) have
  passed, as written in the `needs` of the `release` and `canary` jobs, and once the built gem
  has been installed and found to carry every file it reads at run time. The suites already held
  publication back before, but only through the order of the pipeline stages.

## [0.33.0] - 2026-10-14

<!-- stamped -->

### Added

- **AJAX:** Requests made by Turbo (Hotwire) for a `<turbo-frame>`, and requests answered with
  Turbo Stream actions, carry a `FRAME` or `STREAM` badge in the AJAX panel of the toolbar and in
  the AJAX tab of the dashboard. The AJAX data of a page in the API gives each request a `turbo`
  field: `frame`, `stream` or `null`. The MCP tool `get_profile_ajax` gives the same kind on a
  `Turbo` line of each Turbo request, and none for a plain fetch. The Request tab of a frame
  request shows its `Turbo-Frame` header.

### Fixed

- **AJAX:** A Turbo Drive visit is no longer listed as an AJAX request of the page it leaves,
  and neither is a link Turbo prefetches on hover: they are the next page, with their own
  profile. The requests a page reached by a Drive visit makes are linked to that page instead of
  to the first page of the session.
- **Toolbar:** After a Turbo Drive visit, the toolbar of the previous page is taken down: it no
  longer keeps checking for updates of the previous profile, and `Alt+P` toggles the toolbar
  once instead of once per page visited.

### Limitations

- **Toolbar:** A Turbo 8 page refresh with morphing (`turbo_refreshes_with method: :morph`, or
  a `broadcasts_refreshes` model) is not handled: it empties the toolbar, which keeps checking
  for updates of the profile of the page as first loaded, and the requests made after it stay
  linked to that profile. This predates this release and is left for a later one.
- **Toolbar:** After going back in the browser history, two toolbar containers are left in the
  page, only one of them visible. This predates this release too.

## [0.32.3] - 2026-10-14

<!-- stamped -->

### Fixed

- **Jobs:** the toolbar of a request now sees the jobs it enqueued start and end after its
  response, without a page reload. A job enqueued by a request is saved as `running` as soon as
  it starts, so it appears in the `child_jobs` of that request while it runs, and every save of
  the job tells the request's toolbar that its profile changed, so it reads the job again when it
  ends, `completed` or `failed`. Without Redis storage, this reaches the toolbar only when the job
  runs in a process serving the profiler's pages (the `async` or `inline` adapters); a job run by
  another process is still listed on the next reload.
  With several Puma workers and no Redis, the toolbar sees a job start and end only when its
  polling happens to reach the worker that ran the job.
- **Jobs:** a job that is still running is shown as running, in the JOB panel of the toolbar and
  in the Background Jobs list of `/_profiler`: a turning ◐ with `running` and no duration, a blue
  **Running** badge in the list, instead of a green check mark and a duration of 0 ms that read as
  an instant success. The page of the job itself and the Jobs tab of a profile do the same: a blue
  **Running** badge and no duration. The JOB item of the toolbar is blue while one of its jobs runs, the list has
  a **Running** status filter, and its **Completed** filter no longer includes running jobs. The
  `status` filter of the MCP tool `query_jobs` accepts `running`. A job killed while it performs
  (`SIGKILL`, out of memory, container stopped) never records its end, so it stays `running` in the
  toolbar and the list for good.

## [0.32.2] - 2026-10-13

<!-- stamped -->

### Fixed

- **Test profiling:** `Profiler::TestHelpers::RSpecSupport.install` no longer makes every RSpec
  example fail with `NoMethodError: undefined method 'line_number'`. The workaround documented
  for 0.32.1, a hand-written `around` hook, can be replaced by `install` again.
- **Test profiling:** Failing and pending RSpec examples are recorded with their real status,
  `failed` or `pending`, instead of `passed`, in the test profiles and in the report printed
  after the suite. A failure keeps its message, and an example marked `pending` or `skip` in its
  body keeps its reason. This holds for an example tagged `:aggregate_failures` and for a failure
  raised by an `around` hook of the suite, which the profiler now wraps.
- **Test profiling:** With Minitest, an error raised by the profiler no longer runs the test a
  second time, unprofiled, while hiding the error. The test fails with that error, once, and the
  run goes on with the next tests.

## [0.32.1] - 2026-10-13

<!-- stamped -->

### Fixed

- **Packaging:** The published gem now contains its `LICENSE` file, which the MIT license asks
  every copy to carry and which was missing from the gem up to 0.32.0, and a new
  `THIRD-PARTY-NOTICES.md` that reproduces the copyright and license notices of the three MIT
  packages compiled into the dashboard and toolbar JavaScript: `preact`, `@tanstack/preact-query`
  and `@tanstack/query-core`. The license of the gem does not change, it stays MIT.

## [0.32.0] - 2026-10-06

<!-- stamped -->

### Added

- **MCP:** The HTTP endpoint at `/_profiler/mcp` accepts the `Host` headers of a reverse proxy
  without a monkey-patch: besides the loopback names, it now accepts the hosts the application lists
  in `config.hosts` (when that list is not empty), so an application behind Traefik usually has
  nothing to set, and the entries of the new `config.mcp_allowed_hosts` (default `[]`): a host name
  or `host:port`, or a `Regexp` anchored with `\A` and `\z`, matched against the whole host name,
  for example `["api.myapp.test", %r{\Amyapp[a-z0-9-]*\z}]`. With mcp 1.x the
  transport only accepted the loopback names and answered `Forbidden: Invalid Host header` behind
  a proxy. The profiler now makes the check itself, before the transport, for every kind of entry,
  and keeps the transport's `Origin` check (same origin or `cors_allowed_origins`), whatever
  `api_forgery_protection` says; the transport's own check, which only knows exact names, is turned
  off. A `Regexp` that is not anchored, or that cannot match a whole host name, and a String
  holding `*` raise an `ArgumentError` when assigned. The defaults keep the previous behaviour.

## [0.31.6] - 2026-10-05

<!-- stamped -->

### Fixed

- **Storage:** With `config.compress_bodies` (on by default), a text body larger than
  `config.compress_body_threshold` (10 KB) is now stored gzip+base64, as the README said: the
  profile was decompressed again before every save, so the file, Redis and memory stores kept the
  body as text, next to the compressed copy the request collector keeps, and the compression only
  cost time. A 132 KB HTML page now takes 86 KB in those stores instead of 171 KB (273 KB without
  compression); SQLite, which only keeps that copy, 44 KB instead of 36 KB at the faster level.
  Compressing it costs 1.6 ms on the request instead of 4.1 ms (the fastest zlib level), saving
  the profile 0.2 ms instead of 1.2 ms; the bodies are decompressed only when a profile is shown,
  about 0.7 ms. The profile page, its API, the job, console and test APIs, the lists the cluster
  proxy reads and the MCP tools still give the bodies as text; the toolbar, which shows no body,
  gets them as stored (86 KB instead of 171 KB for that page).
- **Storage:** The profile list summaries kept by the file, SQLite and Redis stores no longer
  carry the first 500 characters of the request and response bodies. Summaries written by 0.31.4
  and 0.31.5 keep them until their profiles are evicted; no list shows them.
- **MCP:** The `curl` command of `get_profile_detail` carries the request body as it was sent: a
  body larger than `compress_body_threshold` came out as its compressed base64 form, and a binary
  body as base64 text. A binary body is now left out of the command.
- **Upgrading:** the profiles already stored, all as text, are read as before, with no migration.
  An earlier version reading a store written by this one shows the compressed bodies as text too,
  and a cluster master and its slaves may run either version: the profile API they read still
  gives the bodies as text. A body that cannot be decompressed is shown as it is stored, never as
  an error. To keep the bodies readable as text in the stored files or Redis keys, set
  `config.compress_bodies = false`.

## [0.31.5] - 2026-10-05

<!-- stamped -->

### Fixed

- **Logging:** Send the profiler's own errors and warnings to the application's log instead of
  `$stderr`. A profile that could not be saved, a collector that failed, a store that could not be
  read, a cluster node out of reach: about thirty places wrote to `$stderr`, which is not where
  `log/development.log` is, so these errors went unseen. They now go through one entry point,
  `Profiler.log_error`, to `config.logger` when the application sets one (read on each message),
  otherwise `Rails.logger`, otherwise `$stderr`. Every line starts with `[Profiler]` (the cluster's
  lines, `[Profiler Cluster]` before, now start with `[Profiler] Cluster:`), carries the error's
  class and message, masked then cut at 1,000 bytes, and has the cluster secret masked. A logger that
  raises never fails a request, a job or the boot: the line then goes to `$stderr`. A slave whose
  `Rails.logger` was still nil raised instead of logging. Several failures that left no trace at
  all are now logged, once per place and error class for the life of the process: a store lookup or broadcast, the Redis
  version read of the toolbar, the MCP body cache, the mailer collector reading a mail, the route
  lookup of the Request tab, a file profile that cannot be read to rebuild the index. The request middleware saves its
  profiles through `Profiler.save_profile`, like jobs, console commands and tests; a page whose
  profile could not be saved gets neither the `X-Profiler-Token` header nor the toolbar, which
  would point to a missing profile. The profiler's own lines no longer appear in the Logs tab of
  the request during which they are written, nor count as its errors. The same holds while the store is
  unavailable, for pages and for streamed responses, which no longer send `X-Profiler-Token` for a
  profile that will be dropped. The storage warnings (a store that cannot be created, said once
  per cause; a Redis profile that cannot be indexed; a SQLite summary that cannot be read) go to
  the application's log too, and the `run_tests` MCP tool answers an unavailable store as an error
  instead of a run without profiles.
- **Outbound HTTP:** Record the calls to services on the same machine. `127.0.0.1`, `localhost`
  and `::1` were always left out, so in development the calls to a neighbouring service never
  showed. `config.http_skip_hosts` is now the whole list, empty by default. The profiler's own
  calls are never recorded, whatever the list says: a slave's registration and heartbeats, and the
  master's requests to its slaves (the slave proxy, the fan-out of the profile pages and the MCP
  tools that query a slave), marked where they are made, and any call to the host and port of
  `config.master_url`. `NetHttpInstrumentation::SKIP_HOSTS` stays, deprecated, with its former value
  (`%w[127.0.0.1 localhost ::1]`); nothing reads it any more.
- **Outbound HTTP:** Keep the bodies of outbound `Net::HTTP` calls to the first
  `config.max_captured_body_bytes`, sent and received, instead of copying them whole; a compressed
  answer is inflated only up to that size, give or take one 16 KB buffer. A `body_stream` is read
  only when it can be put back where it was (a `StringIO`, a file), up to that size and no further
  than its `Content-Length`: a pipe or a socket was read whole and then sent empty, it is now sent
  unread and its body is not captured. A `body_stream` without `pos`, such as a Faraday multipart
  body or a `RestClient::Payload`, is not captured either, where earlier versions replaced it with
  a copy read whole. The size is the `Content-Length` or the stream's own size, otherwise a
  minimum. The HTTP tab and the `get_profile_http` MCP tool say when a body was cut or not
  captured; each call carries `request_body_truncated`, `response_body_truncated`,
  `request_body_not_captured` and `request_size_is_minimum`. Text bodies read in part stay UTF-8.
- **Middleware:** Cap the `params` a profile keeps at `config.max_captured_body_bytes`: long values
  are cut and the entries past it left out, with a `"[profiler]"` key saying so, and the profile
  carries `params_truncated`. The application still gets all of its params. With the log line
  capped below, a 5 MB JSON request no longer takes about 15 MB in its profile.
- **Logs:** Cap what a profile keeps of its request's log lines at the new
  `config.max_captured_log_bytes` (1 MB by default). A request, or a stream held open, that logged
  without end grew its thread's buffer without bound; a single line, such as the
  `Parameters: ...` line of a large request, is cut at the cap. The Logs tab ends with the number
  of lines left out, and the collected data carries `truncated` and `dropped`.
- **Dump:** `Profiler.dump` returns its argument when the profiler is disabled too; it returned
  `nil`, so a call left in the code changed the value of the expression in production.
- **Engine:** Stop failing the boot of an application that loads `ActionController::API` (an
  `api_only` application, or a single API controller): the engine called `helper` on it, which
  `ActionController::API` does not have (`NoMethodError`).
- **Toolbar:** Find where the toolbar goes about four times faster on a page of many tags (0.8 ms
  instead of 4 ms for a page of 20 KB and 4,000 tags, 10 ms instead of 25 ms for 320 KB of tags
  with attributes): ordinary text and tags are skipped in one pass. The place is the same, and a
  `</body>` in an attribute, a comment, a script or a CDATA section, an unclosed quote or a
  `<plaintext>` are handled as before.
- **Upgrading:** to get the previous behaviour back, in `config/initializers/profiler.rb`:
  - the profiler's messages on `$stderr`: `config.logger = Logger.new($stderr)`;
  - the local hosts left out of the HTTP tab:
    `config.http_skip_hosts += Profiler::Configuration::LOCAL_HTTP_HOSTS`;
  - whole outbound bodies and params: `config.max_captured_body_bytes = nil` (also keeps the
    incoming bodies whole); every log line: `config.max_captured_log_bytes = nil`.

## [0.31.4] - 2026-10-05

<!-- stamped -->

### Fixed

- **Storage:** A save into the file store costs the same whatever the number of profiles on disk:
  it listed the directory and read the size of every file on each save, about 5 ms with 500
  profiles and 100 ms with 10,000, now under 1 ms. The store keeps an index next to the profiles
  (`.profiles-index.jsonl`, with its lock `.profiles-index.lock`), which the processes writing to
  the directory share; a missing or damaged one is rebuilt from the profile files, so the profiles
  already saved are found without any migration. Temporary files left by a killed process are now
  removed. The index relies on `flock`: a file store shared between hosts over NFS is not
  supported, use Redis there.
- **Storage:** `config.max_profiles` (100) is honoured by every backend, the first saved profiles
  evicted first (a job saved when it ends counts as new, whenever it started): only the memory
  store applied it, so the file store grew to `max_size` (100 MB,
  tens of thousands of profiles), SQLite without limit and Redis up to its TTL. In the test
  environment, where every example saves a profile, there is no cap on the count unless the
  application sets one.
- **Storage:** Finding the children of a page (its AJAX sub-requests and its jobs) reads only
  them, through an index of their parent, instead of reading and parsing every stored profile
  (about 260 ms with 1,500 profiles of 17 KB in the file store, now under 1 ms). Every profile page
  and toolbar paid it, once for the child jobs and once more for the AJAX tab; they now read the
  children once.
- **Dashboard:** The HTTP, job, console and test lists are filtered and paged by the storage, and
  list summaries of the profiles (without the bodies, params, headers and nested collector data):
  they loaded the 1,000 newest profiles in full on every page (about 200 ms with 1,500 profiles of
  17 KB, now under 10 ms), showed nothing past the thousandth, said there was no next page there,
  and missed the profiles of one type behind 1,000 newer ones of another. The MCP tools and
  resources that list one type of profile (jobs, console, tests) and the test report ask the
  storage for that type too, and found nothing behind 500 newer profiles of another type.
- **AJAX:** The AJAX tab shows the sub-requests of a page whatever `config.collectors` holds: it
  only appeared with `AjaxCollector` in the list, which the default list does not have. The jobs a
  page enqueued are no longer counted as AJAX requests: they stay under its child jobs. The MCP
  tool `get_profile_ajax` finds the sub-requests too: it read the AJAX data saved with the page,
  before any sub-request.
- **Storage:** The storage is created once, under a lock: the first requests of a threaded server
  could each create their own store (16 for 16 threads in the spec), and with the memory store the
  profiles saved in all but one were lost. Several file, SQLite or Redis stores share their data
  and lost nothing.
- **Storage:** A store that cannot be created (its index or lock replaced by a symbolic link, say)
  is reported once per process instead of with a backtrace on every request: the profiles are not
  saved and no toolbar is added, the dashboard and its API answer `503` with the cause in one line
  (no path) instead of a `500`, the MCP tools an error with it, and the store is created again
  once the cause is gone.
- **Upgrading:** the file, SQLite and Redis stores now keep 100 profiles outside the test
  environment, and **the first save after the upgrade removes the profiles past the cap**, the
  first saved first: of 3,000 profiles written by 0.31.1 in the file store, about 80 remain, and
  that first save takes about a second, during which the other processes writing to the store
  wait. To keep them, set `config.max_profiles` (or `storage_options[:max_profiles]`) **before**
  upgrading: to a higher number, or to `nil` for the earlier behaviour, no cap on the count (the
  file store then keeps up to `max_size`, Redis up to its TTL). The memory store keeps 100 with
  `nil`, as before. A Redis store written by an earlier version is indexed once, by one process,
  on first use, which also removes the profiles past the cap then (about 0.4 s for 20,000).

## [0.31.3] - 2026-10-05

<!-- stamped -->

### Fixed

- **Collectors:** a profile no longer records the SQL queries, views, cache operations, timeline
  events, exceptions and mails of other requests. The collectors subscribed to the process-wide
  `ActiveSupport::Notifications` bus without looking at the thread, so on a multi-threaded server
  (Puma, Sidekiq) a profile could show the queries of a concurrent request, another user's
  included. Each collector now records the events of its own request: its thread, the threads it
  starts with `Thread.new`, the thread `ActionController::Live` runs the action in, the fibers
  it creates (Ruby 3.2+, the layout of `render stream: true` under Falcon), the server thread
  iterating a streamed body, and the queries of `load_async`, which Rails reports on the
  request's thread. The process holds one subscriber per event instead of one per profiled request,
  so an SQL event costs the same however many requests are profiled at once (6 us with 8 requests
  profiled, 260 us before, measured). A job performed inline still shows in both profiles; one
  performed by ActiveJob's `:async` adapter is profiled apart from the request that enqueued it,
  even while that request still runs. A test profile no longer shows the queries the application
  server runs for a system test in its own thread: they are in the profile of that HTTP request.
- **Instrumentation:** a thread created by a pool while a request ran (a concurrent-ruby worker
  behind `Concurrent::Promises`, ActiveJob's `:async` adapter or `ActionController::Live`, or the
  thread Puma starts for a request marked as IO bound) no longer keeps that request's HTTP and
  timeline collectors for good, which put the outgoing HTTP calls of other requests' tasks in its
  profile. A task posted to a concurrent-ruby executor now runs in the context of the request that
  posted it, and a pool thread inherits nothing. On Puma with 8 threads, 40 concurrent requests
  each running a query and an HTTP call in a `Concurrent::Promises.future`: 0 queries and 0 HTTP
  calls of another request in a profile, none lost, against 560 foreign queries, 35 misattributed
  and 36 lost HTTP calls before (measured, `script/bench/puma_attribution.rb`).
- **Function profiler:** without the `stackprof` gem, which the gem does not depend on, the
  function profiler stays off instead of falling back to a `TracePoint` enabled on every thread of
  the process, which called `GC.stat` four times per method and tripled the cost of a request, for
  a tab that is not shown. To trace again, set `Profiler.function_profiling_tracepoint_fallback =
  true`; the `TracePoint`, like the one of the `full` mode chosen from the dashboard, is now
  enabled on the request's thread only. The Timeline tab now says that stackprof is missing and
  how to add it, instead of a button to enable function profiling that changed nothing, and no
  longer says that sampling is on by default whatever the Gemfile.
- **Database:** the caller of a query is captured the first time a statement runs in the request
  (values left out, as the N+1 detection groups them) and for every slow query, instead of for
  every query, at about 0.1 ms each. The N+1 groups of the Database tab and of the MCP
  `n1-patterns` resource keep their location. The backtrace now starts at the application's code
  that ran the query, cleaned by `Rails.backtrace_cleaner` as in the Exception tab, or without
  Rails, past the frames of gems and of Ruby; it often started inside Active Support, with the
  application's first frame too far down for the three frames `n1-patterns` shows.
  `config.sql_backtrace = :all` captures every query again, `:none` none.
- **Routes and Env tabs:** a profile no longer stores the whole route table and `ENV`, rebuilt and
  sorted on every request (the route table alone cost 7.7 ms per request with 210 routes, and 29 KB
  per profile, measured). It keeps the route its request matched, the one of the request's verb
  (a `PUT` showed the `PATCH` route of the same action). The Routes tab, the toolbar and the MCP
  `get_profile` tool list the route table of the process that serves them, rebuilt when the
  routes are reloaded in development; the Env tab of an HTTP profile shows the current `ENV` of that
  process, not the `ENV` as it was during the request, masked as before. The profiles of jobs,
  console expressions and tests, which run in another process, keep that process's `ENV`, masked,
  as before. Profiles saved by an earlier version keep
  showing their own table and variables. With both changes, the profiler adds about 10 to 13 ms to
  the reference page of `script/bench/request_overhead.rb` instead of 21 to 22 ms with stackprof
  and 26 ms without it in 0.31.2 (Ruby 3.3, measured); the README gives this measured cost instead
  of "< 5ms per request".
- **Upgrading:** to get the previous behaviours back, set `config.sql_backtrace = :all` and
  `Profiler.function_profiling_tracepoint_fallback = true` in `config/initializers/profiler.rb`.
  The Routes and Env tabs cannot show the table and the variables of the request's time any more:
  they show the process's current ones.

## [0.31.2] - 2026-10-05

<!-- stamped -->

### Fixed

- **Middleware:** Stream responses through instead of buffering them. The profiler read every
  response body to the end before handing it to the server, so an `ActionController::Live`,
  `response.stream` or enumerator response, or a server-sent events stream, left only once it was
  over (a stream of 5 chunks 200 ms apart sent its first chunk after 1 s instead of 0.2 s, and an
  endless event stream never answered), and a file sent with `send_file` lost `to_path`, so the
  server could no longer send it by its path. A body that does not answer `to_ary`, a
  `text/event-stream` or a body sent by its path now goes to the server chunk by chunk, keeps
  `to_path` and `close`, and its profile is saved when the server closes it, also when the client
  went away, with the body seen so far and the full duration. The collectors that only gather
  what notifications and the logger hand them (SQL, views, cache, exceptions, timeline, logs,
  outbound HTTP) stay subscribed until then, so the queries and views of a `render stream: true`
  page or of an enumerator are still recorded; dumps, mailers, I18n and function profiling are
  read when the application returns. While the server iterates the body, the log lines, outbound
  HTTP calls and `Profiler.measure` blocks it runs are recorded as well. Until it is saved, a
  streamed profile is not listed and its token answers 404: an endless event stream is never
  listed. A body the server never closes is finished when the fiber that started it starts its
  next profiled request, never cutting a stream that a fiber-based server such as Falcon runs
  alongside, and its subscriptions are dropped after 5 minutes at the latest, which the profile
  and the Request tab then say; the server still closes the application's body. Rails 7.0 pages, whose body has no `to_ary`, and pages a `Live`
  controller renders whole still get the toolbar. The toolbar is only injected in pages returned
  whole, so a `render stream: true` page has none.
- **Middleware:** Stop turning an error raised while a response body is iterated (a stream that
  fails part way, a file sent with `send_file` that disappeared) into an empty `200`. The error now
  reaches the server, as it does without the profiler, and the profile keeps it.
- **Middleware:** Keep the request and response bodies of a profile to the first
  `config.max_captured_body_bytes` (256 KB by default) instead of copying them whole: a 2 MB upload
  took 2.8 MB in its profile, plus transient copies. `rack.input` is read only up to that size, then
  rewound for the application, and an input that cannot be rewound is no longer read at all. The
  Request tab and the MCP profile detail say when a body was cut, with its whole size, or "at
  least" that size when it is not known; the profile carries `request_body_truncated`,
  `request_body_size`, `response_body_truncated`, `response_body_size` and their
  `*_size_is_minimum`. Only the raw bodies are capped: the parsed `params` and the
  `Parameters:` log line keep their full size, so a 5 MB JSON request still takes about 15 MB in
  its profile. To keep whole bodies, as before, set `config.max_captured_body_bytes = nil`.
- **Profiles:** Report the number of objects allocated (`allocated_objects`) instead of a figure
  shown as memory. `GC.stat` has no `:total_allocated_size` on the supported Rubies, so `memory`
  was always that number times 40, never a measured byte count. The toolbar, the dashboards, the
  profile list and the MCP tools show "Allocations". The counter belongs to the process: on a
  multi-threaded server it includes what other threads allocated meanwhile. Nothing to change on
  upgrade: the API and the stored profiles still carry `memory` (deprecated, the count times 40),
  and profiles saved by earlier versions are read back with their count. The option
  `memory_warning_threshold`, which nothing ever compared with, is deprecated for
  `allocated_objects_warning_threshold`, a number of objects, still without effect; setting the
  old one warns and converts it.
- **Toolbar:** Leave a response already framed with `Transfer-Encoding` untouched. Under Rails
  7.0, a `render stream: true` page arrives chunked, and the toolbar was put among the chunks,
  which broke the framing: the browser got an empty or cut page.
- **Toolbar:** Correct the `Content-Length` of a page the toolbar is injected into. It kept the
  length of the page without the toolbar, so a server that honours it cut the page short.
- **Toolbar:** Inject the toolbar into a page whose headers are a plain `Hash` with a lower-case
  `content-type`, the form Rack 3 requires; only `Content-Type` was looked up. Every response
  header the profiler reads or writes now ignores the case.

## [0.31.1] - 2026-10-05

<!-- stamped -->

### Fixed

- **Storage:** Keep the file store's profiles in `tmp_path/profiles` by default, and take only the
  files named after a profile token for profiles. Profiles shared `tmp_path` with
  `env_overrides.json`, which the store listed as a profile with no token and deleted when the
  profiles were cleared. An application that sets `storage_options[:path]` keeps its directory,
  used as given (no subdirectory is added).
- **MCP:** Keep the bodies saved by the MCP tools in `tmp_path/mcp-cache`, and let their hourly
  cleanup remove only the token directories it wrote there. It removed every directory of
  `tmp_path` older than an hour, the SQLite store's blobs included, at random (one save in
  twenty), which lost the stored HTTP response bodies.
- **Configuration:** `config.tmp_path` is always a `Pathname`: it was a `String` outside Rails, and
  kept a `String` assigned to it, which made every env override operation fail with only a
  warning. A failure to read or write the env overrides now reaches the Env tab (`500` with the
  error, `ENV` left unchanged) and the MCP env tools (an error answer) instead of reporting a
  success; at boot, before a Sidekiq job and before a console evaluation it is still a warning,
  so an override never makes the application fail.
- **Jobs:** A storage error while saving a profile no longer makes the application fail: a job,
  a console command, a test, or an outbound HTTP call that ends after its profile was collected
  now goes on, with its own result or its own exception, and the error is printed as a warning.
  The save of a job, console or test profile ran with nothing to catch it, so a full disk, a
  Redis that went away or, from this version, a symbolic link refused in place of the SQLite
  database made the job fail, or replaced the job's own exception. The HTTP middleware already
  kept requests going.
- **Upgrading:** for the default `tmp_path`; adapt the paths if you set one.
  - Profiles saved by the file store in `tmp/rails-profiler` itself are no longer listed, and are
    not moved. To remove them, with the old MCP body cache, run from the application root:
    ```sh
    LC_ALL=C find tmp/rails-profiler -maxdepth 1 -type f -name '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].json' -delete
    LC_ALL=C find tmp/rails-profiler -mindepth 1 -maxdepth 1 -type d -name '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]' -exec rm -rf {} +
    ```
    Both only match names made of 32 lower-case hexadecimal digits, a profile token (`LC_ALL=C`
    keeps `[0-9a-f]` from matching upper-case letters in some locales): `env_overrides.json`, the
    SQLite database, `blobs`, `profiles` and `mcp-cache` are left alone.
  - To keep reading the old profiles instead, set
    `config.storage_options = { path: Rails.root.join("tmp", "rails-profiler") }`, and then do
    **not** run the first command: it would delete the current profiles.
  - The directory `tmp/rails-profiler` created by an earlier version keeps its mode: run
    `chmod 700 tmp/rails-profiler` to restrict it.
  - If the web process and the workers reading the env overrides or a shared file or SQLite store
    run as two different users, set `config.restrict_storage_permissions = false` to create new
    files with the modes of the umask, as before. It does not reopen what was already created
    `0700` and `0600`: run `chmod -R u=rwX,go=rX tmp/rails-profiler` for the modes earlier
    versions created with the usual umask (`0755` and `0644`). A worker under another user that
    also writes there (it opens `env_overrides.json.lock` for writing) needs the
    files belonging to a group of both users (the same primary group for both, or
    `chgrp -R <group> tmp/rails-profiler` then `find tmp/rails-profiler -type d -exec chmod g+s {} +`
    so that new files inherit it), a umask of `002` for both processes, and
    `chmod -R ug=rwX,o=rX tmp/rails-profiler`. The option also follows a symbolic link in place
    of the SQLite database, its `-wal` or `-shm` file or the lock of the env overrides, and drops
    the warning about a shared `tmp_path`, as before.

### Security

- **Storage:** Check every profile token against the format the profiler issues (32 hexadecimal
  characters) in every storage backend (file, memory, Redis, SQLite and its blobs), before it
  becomes a file name, a directory or a key. A token such as `../../config/important` reached the
  file store as a path: `DELETE /_profiler/api/profiles/:id` deleted, and
  `POST /_profiler/api/ajax/link` overwrote, a `.json` file outside the storage directory. A
  malformed token is now not found (`404` from the API, `nil` from the storage, no exception),
  whoever asks: the controllers, the cluster proxy, which no longer forwards it to a slave, or the
  MCP tools. Saving under one raises an `ArgumentError`. `POST /_profiler/api/ajax/link` answers
  `400` for a malformed `parent_token` instead of storing it. The MCP tools no longer save a body
  (`save_bodies`) under a token sent by a slave that is not a profile token. There is no option to
  accept other tokens: the profiler never issues them, and accepting them would reopen the path.
- **Storage:** Create the profiler's directories `0700` and its files `0600`, whatever the umask:
  the file store's profiles, the SQLite database and its `-wal` and `-shm` files, the blobs, the
  env overrides with their lock and temporary files, and the MCP body cache. They were created
  with the process defaults, usually `0755` and `0644`, readable by every local user although
  profiles hold cookies, tokens and environment values. A file the profiler writes again (a
  profile, the SQLite database at startup) is brought back to `0600`; a directory that already
  exists keeps its mode. Writing a profile now goes through a temporary file renamed over it. A
  symbolic link placed where the profiler keeps its SQLite database, its `-wal` or `-shm` file or
  the lock of the env overrides is refused instead of followed, and an existing `tmp_path` that
  belongs to another user or that group or others can write to is reported once with a warning.

## [0.31.0] - 2026-10-05

<!-- stamped -->

### Added

- **Cluster:** `config.cluster_allowed_slave_urls` accepts `Regexp` entries next to URLs, for
  slaves whose names are not known in advance, such as one container per git worktree:
  `[%r{\Ahttp://myapp-[a-z0-9-]+:3000\z}]`. Until now such a setup had to fall back to
  `:any`, which reopens the server-side request forgery closed in 0.30.11. A pattern must start
  with `\A` and end with `\z`, and compile once wrapped to match the whole URL; any other `Regexp`
  raises an `ArgumentError` when assigned. It is matched as a whole against the URL as the master
  keeps it (lower-case scheme and host, no default port, no trailing slash), after the existing
  checks, which it cannot lift: user info, a query, a fragment or a `.` or `..` segment are still
  refused, and plain HTTP to a host that is not a loopback address still needs
  `cluster_allow_insecure_http`. A `String` entry is always a URL, never a pattern. The default,
  `[]`, still refuses every URL. A slave URL whose path segment decodes to a `\` is now refused
  like one that decodes to a `/`.

## [0.30.15] - 2026-10-05

<!-- stamped -->

### Fixed

- **Toolbar:** Stop the toolbar from holding a server thread for as long as its page stays open.
  Every page kept a server-sent events stream open on `/_profiler/api/events/:token`, and the
  server waited on it in one of its threads, 30 seconds at a time; a closed page was only noticed
  at the next 30-second heartbeat. With as many open (or recently closed) pages as the server has
  threads (3 in the Puma configuration Rails generates), the application stopped answering. The toolbar now asks whether
  its profile was saved again with short requests the server answers at once: after 1 s, then
  less and less often (10 in the first minute, 2 a minute after that), none while the tab is
  hidden, and none after 10 minutes without a save. `GET /_profiler/api/events/:token` now
  answers JSON (`cursor`, `updated`) for a `since` version, and the toolbar data carries the
  version it reflects as `events_cursor`. With Redis storage, saves are counted in Redis: the
  bus no longer keeps a listening thread and a dedicated Redis connection in each process, and a
  failing Redis no longer leaves every toolbar without updates until the next page.
- **Test runner:** Follow the output of a run live again on `/_profiler/test_runner`. The output
  stream answered `500` on every request since server-sent events were added for the toolbar
  (its controller picked up the wrong `SSE` class), so the page showed the output as it was when
  it started following and then stopped. The stream now answers at once with the output there
  is and the browser asks again every second, with the position it reached, while the run is in
  progress: following a run holds no server thread either.
- **Test runner:** Show the output of a run as UTF-8 text. The process is read 256 bytes at a
  time, so a character could be cut between two pieces: the output stream then failed on every
  request, the run's JSON (`GET /_profiler/api/test_runner/runs/:id`, which `run_tests` reads on a
  slave) warned or failed, and non-ASCII output was labelled binary. The first bytes of a cut
  character now wait for the next piece, and bytes that are not UTF-8 show as `U+FFFD`.
- **Test runner:** Keep a killed run `killed`, and send its end to the page only with its last
  output. The status of a killed run became `passed` or `failed` once the process exited, and the
  page following a killed run, or a run whose test command failed to start, could stop before
  the summary or the `[Profiler] Error:` line.
- **MCP:** `run_tests` with a `slave` (FAB-20) returns as soon as the run on the slave is over, with
  its output. It waited for statuses the test runner never gives (`completed`, `cancelled`), so a
  run that passed was reported as timed out after `timeout_seconds` (120 by default), holding a
  server thread of the master all that time, and it read the output from a field the slave does
  not send, so the output was always empty.

## [0.30.14] - 2026-10-05

<!-- stamped -->

### Fixed

- **Railtie:** Honor `config.enabled` set in `config/initializers/profiler.rb`. The profiler
  decided before the application's initializers had run, so `enabled = false` there still put its
  middlewares in the stack, configured Sidekiq, included its ActiveJob instrumentation and, in
  the test environment, loaded the test profiler, and `enabled = true` in production got none of
  them. Those decisions are now taken once the application's initializers have run. An active
  profiler keeps its place in the middleware stack, and its Sidekiq middlewares and ActiveJob
  callbacks stay ahead of the ones the application installs. The profiler is now the outermost
  layer around a job: it runs before every other Sidekiq middleware, including those of gems
  loaded before it and those the application prepends (such as `Sidekiq::CurrentAttributes`),
  and before the callbacks Rails adds to ActiveJob (logging, instrumentation, and on Rails 7.0
  time zone and locale), so the duration of a profiled job now includes them.
- **Railtie:** Keep the `enabled`, `storage` and `track_tests` values set with
  `Profiler.configure` in `config/application.rb`, which the Rails defaults overwrote at boot, and
  apply `config.profiler` (`config.profiler.enabled = false` in `config/application.rb`), which was
  accepted and never read. A `config.profiler` key that is not a profiler option logs a warning.
  `config/initializers/profiler.rb` still has the last word. Check these places when upgrading:
  an `enabled` set with `Profiler.configure` in `config/application.rb` or in a
  `config/environments` file, or with `config.profiler.enabled`, now takes effect, in production
  too, where it was overwritten or ignored before.

## [0.30.13] - 2026-10-04

<!-- stamped -->

### Fixed

- **Middleware:** A request that raises below the profiler no longer runs your application a
  second time, and no longer leaves the collectors installed. Until now the exception made the
  profiler call the application again, duplicating its side effects (two emails sent, two
  records written), and every SQL, view, cache, mailer and controller subscriber, the log sink on
  `Rails.logger`, the StackProf sampler or the `TracePoint` of the function profiler stayed active
  for the life of the process: memory and request time grew with each failed request until the
  process was killed. Any exception between the profiler and `ShowExceptions` triggers it, for
  example `ActionDispatch::RemoteIp::IpSpoofAttackError` on contradictory `Client-IP` and
  `X-Forwarded-For` headers, and in tests every exception a controller raises. The exception now
  goes on to the server unchanged, and the profile of the failed request is kept, with status 500
  and the exception in the Exception tab.
- **Collectors:** Collectors gain `unsubscribe`, which releases what `subscribe` installed and runs
  after `collect` and on every error path, for requests, jobs, console commands and tests alike.
  A collector that fails to subscribe no longer leaves the others installed: the work runs once,
  unprofiled. A custom collector that subscribes to something should implement `unsubscribe`, as
  the README example now does.
- **Logs:** On Rails 7.0, the log collector no longer extends `Rails.logger` with a new module on
  every request; one shared sink is attached once, and only records while a profile runs on the
  thread.
- **Collectors:** A job performed inline during a profiled request (`perform_now`, or the
  `:inline` adapter) no longer takes the request's records with it. The job's collectors now hand
  back the thread-local slots they borrow, so the request keeps its logs, dumps, outbound HTTP
  calls and timeline events from before and after the job, and the job's profile gets only what
  the job did. Until now the job erased the request's logs and dumps recorded before it, and the
  request lost its HTTP calls and timeline events from after it.
- **Middleware:** A request cut short by a timeout (`Timeout::ExitException`,
  `Rack::Timeout::RequestTimeoutException`) keeps its profile too, with status 500. A request
  stopped by a signal or by `exit` keeps none. An exception outside `StandardError` raised while
  the collectors are being set up no longer leaves them installed.
- **Function profiler:** In sampling (`lite`) mode, a request no longer stops the StackProf
  sampler that a concurrent request started, nor takes its samples: its profile says the sampler
  was busy instead.
- **Dumps:** `Profiler.dump` called outside a profile that collects dumps (a request the profiler
  skips, a test profile) no longer keeps the value on the thread. Nothing ever read those dumps,
  and the thread held on to them, and to everything they referenced, for good.

## [0.30.12] - 2026-10-04

<!-- stamped -->

### Security

- **Toolbar:** The toolbar endpoint (`/_profiler/api/toolbar/:token`) now answers `403` when the
  profiler is disabled, like the rest of the API. It used to keep serving any profile left in
  storage, request headers and environment included, after `enabled = false`. The toolbar is only
  injected while the profiler is enabled, so it is not affected.
- **Profile page:** The profile embedded as JSON in the profile page is now escaped explicitly
  (`<`, `>`, `&`, U+2028 and U+2029), whatever the application sets for
  `ActiveSupport.escape_html_entities_in_json`. An application that turned that setting off let a
  captured value (a parameter, a header, a body) close the `<script>` element and run JavaScript
  in the application's origin. The token and the CSP nonce written into the application's pages
  by the toolbar injector are escaped too.
- **Dashboard:** Captured bodies offered for download are no longer typed with their captured
  content type: opened in a tab, a `text/html` or `image/svg+xml` body ran its scripts in the
  application's origin. Previews keep their type for raster images and PDF only. Email previews
  are rendered in a fully sandboxed iframe, with an opaque origin. The unused SQL highlighter,
  which wrote captured SQL into the page as HTML, is removed.
- **Access control:** A disabled profiler now answers its API requests with a JSON error, like
  any other refusal of the API, instead of plain text.
- **Toolbar:** The toolbar is now injected before the `</body>` that closes the page, looked for
  outside comments, tags (attributes read as the browser reads them, quoted values included) and
  the elements whose content is not markup (`<script>`, `<style>`, `<textarea>`, `<title>`,
  `<xmp>`, `<iframe>`, `<noembed>`, `<noframes>`, `<noscript>`), instead of the first `</body>`
  found. A `</body>` inside a script string of the page used to receive it, and the toolbar's own
  `</script>` then turned the rest of that string into live markup. A page whose only `</body>`
  sits in one of those, that leaves a comment, a tag, a quoted value or one of those elements
  open, or that holds a `<plaintext>`, a double-escaped script or a CDATA section with a `>`
  before its end, gets no toolbar.

## [0.30.11] - 2026-10-04

<!-- stamped -->

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
- **Cluster:** The `cluster_secret` is masked before text is shortened (flame graph names, I18n
  values, console expressions and results, mail bodies and assigns, job arguments), so no prefix of
  it is left, and the output of the test runner is masked across the pieces it is read in, so the
  secret no longer comes back whole once they are joined. Only a secret the cluster accepts (32
  characters or more) is masked by value.
- **Cluster:** The output of the test runner holds back an end that could start the secret until
  the process has finished printing, a killed run included, and holds back nothing else, so
  progress output is shown as it comes. Binary bodies stored in base64, incoming, response and
  outbound, are masked on their raw bytes before they are encoded.
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

- **Cluster:** Resolve profiles across slaves from the master `ProfilesController` <!-- 57d379f -->

## [0.30.3] - 2026-06-29

### Fixed

- Wrap the profile dashboards and `TestRunnerPage` with `QueryClientProvider` <!-- e5ad047 -->

## [0.30.2] - 2026-06-29

### Fixed

- **Middleware:** Duplicate downstream headers before mutating them <!-- 01cea9c -->

## [0.30.1] - 2026-06-29

### Fixed

- **Cluster:** Fix sentinel mismatch, profile list pagination, nil safety in MCP tools and HTTPS slave URLs <!-- a8a508b -->

## [0.30.0] - 2026-06-28

### Added

- **Cluster:** Add master/slave profiler clustering <!-- 8109047 -->

## [0.29.0] - 2026-06-28

### Added

- **SSE:** Push live profile updates over server-sent events <!-- ff431f6 -->

## [0.28.0] - 2026-06-06

### Added

- **HTTP:** Add the `http_backtrace_depth` configuration option <!-- e15864c -->

## [0.27.1] - 2026-06-06

### Changed

- **API:** Replace manual `fetch()` calls with `orval` generated TanStack Query hooks <!-- cc3e2ca -->

### Fixed

- **File store:** Prevent `ENOENT` errors on concurrent profile file deletion <!-- d1dd476 -->

## [0.27.0] - 2026-06-02

### Added

- **MCP:** Add console profiling, mailer detail, logs/env/i18n sections and full documentation <!-- 9f97a3f -->

## [0.26.0] - 2026-06-02

### Added

- **Test profiler:** Add the `run_tests` MCP tool, the `track_tests` option, specs and docs <!-- 5c63fc0 -->
- **Test profiler:** Enrich reporter, add SSE streaming, MCP tools and env safety <!-- 58b2d8b -->
- **Test profiler:** Add test profiling, test runner UI and MCP tool <!-- 4c50149 -->

## [0.25.0] - 2026-06-01

### Added

- **Console:** Add a console profiling tab with IRB instrumentation <!-- c6ce1b7 -->

### Changed

- **Docs:** Document the console profiling tab and the env override behaviour <!-- e4f6fe9 -->

<!-- excluded:
  e8941a4 specs only, no visible change
-->

## [0.24.0] - 2026-06-01

### Added

- **MCP:** Add tools to manage `ENV` variables <!-- 52f43ce -->

## [0.23.0] - 2026-05-27

### Added

- **Profile list:** Add a global clear-all button and auto-refresh on tab switch <!-- b85fc97 -->

## [0.22.1] - 2026-05-26

### Fixed

- **HTTP:** Propagate collector to child threads, add fire-and-forget support, fix deep backtrace capture <!-- 8fd3f63 -->

## [0.22.0] - 2026-05-04

### Added

- **Mailer:** Add a body preview, a variables display, a queued badge and design alignment <!-- d016698 -->
- **Collector:** Implement `MailerCollector`, tracking ActionMailer deliveries <!-- b1705c9 -->

### Changed

- **Toolbar:** Remove the emoji from the mailer toolbar item and the dashboard tab <!-- f18e615 -->

### Fixed

- **Mailer:** Add the Mailers tab to `JobProfileDashboard` <!-- 05f0549 -->
- **Mailer:** Fix thread isolation and `deliver_later` mode detection <!-- 35c9de3 -->
- **Mailer:** Add `MailerCollector` to the job profiler and align the toolbar item design <!-- e566a77 -->
- **Mailer:** Handle the Rails 7 encoded mail string in the `deliver.action_mailer` payload <!-- c5519ce -->
- **Mailer:** Replace `Thread.current.delete` with a read and nil write for fiber local variables <!-- 2828c44 -->
- **Version:** Remove the pre-release suffix, which broke Bundler resolution <!-- eba7e9f -->
- **Mailer:** Address code review findings from MR !32 <!-- 655d090 -->

## [0.21.0] - 2026-05-02

### Added

- **Toolbar:** Add a collapse/expand toggle <!-- 7bc637a -->

## [0.20.0] - 2026-05-01

### Added

- **UI:** Display the gem version and warn on a mismatch <!-- a2509c2 -->

## [0.19.2] - 2026-04-24

### Fixed

- **HTTP:** Capture `RestClient` `body_stream`, remove body size limits, show bodies in MCP tool results <!-- 20654f5 -->

<!-- excluded:
  a9f2cd3 release plumbing, version placeholder reset
-->

## [0.19.1] - 2026-04-17

### Fixed

- **Env vars:** Fix revert restoring wrong value, SQLite busy errors, middleware rescue handling and UI refresh <!-- 33bd079 -->

<!-- excluded:
  9da240b pipeline only
  09748d1 pipeline only
  4e8500b pipeline only
-->

## [0.19.0] - 2026-04-15

### Added

- **Env:** Propagate env var overrides to Sidekiq workers <!-- c404799 -->

## [0.18.0] - 2026-04-14

### Changed

- **UI:** Extract shared tab utilities and redesign the Request tab <!-- 47e6269 -->

### Fixed

- **HTTP:** Capture outbound request body passed as second argument to `http.request()` <!-- 2dda00f -->

## [0.17.0] - 2026-04-13

### Added

- **Dashboard:** Add env tab on the home page and env/job toolbar items <!-- c623c40 -->

## [0.16.0] - 2026-04-13

### Added

- **Function profiler:** Add `stackprof` sampling mode with multi-clock support and GC visibility <!-- 5f461d9 -->

### Fixed

- **Function profiler:** Fix `stackprof` bugs, remove minimal mode, improve performance <!-- 8adc3ca -->

## [0.15.0] - 2026-04-11

### Added

- **Env:** Add environment variables tab <!-- fa3bcec -->

## [0.14.0] - 2026-04-09

### Added

- **Profiler:** Link jobs to their triggering request or parent job <!-- 5d598f6 -->

## [0.13.0] - 2026-04-09

### Added

- **UI:** Add copy/download buttons on HTTP bodies, waterfall view, date sort, and other UX improvements <!-- e7b430b -->
- **UI:** Always show waterfall above the HTTP request list <!-- bec6cb0 -->
- **UI:** Use `SmartBodyPreview` in RequestTab for copy/download on request and response bodies <!-- 439a9ac -->

### Fixed

- **UI:** Derive download file extension from actual MIME type instead of body category <!-- 987a65e -->
- **UI:** Move `sortedJobs` after `filteredJobs` to fix TDZ error <!-- 235d492 -->

## [0.12.0] - 2026-04-09

### Added

- **Profiler:** Add function-level profiling with flamegraph and stats table <!-- 2781cff -->

## [0.11.1] - 2026-04-09

### Added

- **Config:** Add `tmp_path` option to centralize the storage directory <!-- d68a4c7 -->

### Fixed

- **MCP:** Decompress gzip+base64 bodies before returning to UI and MCP tool results <!-- c551773 -->

## [0.11.0] - 2026-04-06

### Added

- **UI:** Add load-more pagination to the profile list <!-- ef49a2a -->

## [0.10.1] - 2026-04-06

### Changed

- **Docs:** Add full user documentation, with a UI guide, an MCP guide and screenshots <!-- 2e34dc1 -->

## [0.10.0] - 2026-04-06

### Added

- **Middleware:** Add configurable CORS origins, CSP nonce support and body compression <!-- bb13049 -->

## [0.9.1] - 2026-04-06

### Removed

- **Collectors:** Remove `PerformanceCollector`, replaced by `FlameGraphCollector` <!-- fd03ac6 -->

## [0.9.0] - 2026-04-06

### Added

- **Profiler:** Add the `Profiler.measure` custom instrumentation API <!-- a3ab553 -->

## [0.8.0] - 2026-04-05

### Added

- **UI:** Add sortable columns, quick filter presets and flamegraph search <!-- 5bfb511 -->

## [0.7.0] - 2026-04-05

### Added

- **Database:** Add N+1 visual detection and `EXPLAIN ANALYZE` integration <!-- af266fc -->

## [0.6.0] - 2026-04-05

### Added

- **MCP:** Reduce token usage with filtering, body file saving and pagination <!-- fa67dc8 -->

## [0.5.0] - 2026-04-04

### Added

- **MCP:** Add outbound IDs, a domain filter, datetimes, a latest token, exceptions and copy helpers <!-- b36bc24 -->

## [0.4.0] - 2026-04-03

### Added

- **Collector:** Add an I18n panel tracking translation lookups per request <!-- ef4a672 -->

<!-- excluded:
  ad4fea1 pipeline only
-->

## [0.3.0] - 2026-04-02

### Added

- **Collector:** Add a routes panel and enrich the request collector <!-- febed69 -->

## [0.2.0] - 2026-03-29

### Added

- **Collector:** Add a Logs panel, capturing `Rails.logger` messages per request <!-- 3f1d906 -->
- Publish the gem to RubyGems.org <!-- a63e6b4 -->

<!-- excluded:
  17feea9 pipeline only, despite the fix: type
  86fcb3f pipeline only
  5891bfa pipeline only
  81150a3 pipeline only
-->

## [0.1.4] - 2026-03-29

### Added

- **Profiler:** Capture the full request and response, and add an MCP history clear <!-- 7d54262 -->

## [0.1.3] - 2026-03-29

### Changed

- **Assets:** Migrate Sass `@import` to `@use`, which removes the build deprecation warnings <!-- a0ac9b5 -->

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
  d797be5 pipeline only
  02d63c9 pipeline only
  9f598d9 subject is not conventional, tooling only
  7d1d823 tests only
  c0d46e6 licence file, not a change to the gem
-->
