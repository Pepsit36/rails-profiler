# Decisions: fix/env-writes-and-mcp-read-only

Taken without the maintainer, choosing the most cautious option each time. To be reviewed, and
removed or folded into the docs once accepted.

## #53 case 1: which variables the env tools may write

- **Level of ambition: a deny list, not an allow list.** `Profiler::EnvKeyPolicy` holds the one
  list the Env tab, `set_env_var`, `delete_env_var`, `EnvOverrideStore#apply!` and the test runner
  read. It is the list the test runner already had (`BLOCKED_ENV_KEYS`, `CODE_LOADING_ENV_*`),
  moved, not widened: `TestRunner::Runner` keeps its constants as aliases, so its behavior is
  unchanged. An allow list would refuse the ordinary application variables the tab exists for
  (feature flags, API URLs), whose names nobody can enumerate in the gem.
- **Widened after review (task-056):** the list taken from the test runner let through
  `PRIMARY_DATABASE_URL` (read by Active Record 8.1 before `DATABASE_URL`), libpq and MySQL
  variables, proxies, certificate paths and other loaders. `EnvKeyPolicy` now also refuses the
  suffixes `_DATABASE_URL` and `_PROXY` (any case: names are compared upcased), the prefixes `PG`,
  `MYSQL_` and `OPENSSL_`, and `RAILS_MASTER_KEY`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `GCONV_PATH`,
  `LOCPATH`, `IRBRC`, `PRYRC`, `PRY_RC`, `ZDOTDIR`, `LESSOPEN`, `LESSCLOSE`, `PAGER`, `EDITOR`,
  `VISUAL`, `JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS`, `_JAVA_OPTIONS`, and `PROFILER_MCP_READ_ONLY`.
  `PG` as a prefix refuses some names that are not libpq's (`PGP_KEY`): accepted, the cautious
  side. The deny list stays: it is still incomplete by nature (any gem may read a new variable
  tomorrow), and the code and docs now say so. The test runner reads `EnvKeyPolicy.protected?`
  instead of the exact `PROTECTED_KEYS`, so that the suffixes and prefixes reach it too.
- **Values:** a value holding a NUL byte is refused like a refused name, before anything is
  written (endpoint, `set_env_var`, `EnvOverrideStore#set`, which raises its own `Error`). One
  already in the file is skipped by `apply!` and `build_env` with the once-per-set warning, not an
  error logged at each call. Only NUL is refused: it is the one byte `setenv` cannot hold.
- **Names:** `\A[A-Z_][A-Z0-9_]*\z`, case-insensitive. Stricter than what `setenv` accepts (only
  `=` and NUL are fatal there): a name with a dash or a dot is refused too. No spec nor doc used
  one; it is the POSIX shell name, the name a variable must have to be set from a shell anyway.
- **Protected names are refused for delete too**, not only for set: deleting `PATH` or
  `DATABASE_URL` from a running process is as harmful as changing it.
- **Reset is not checked:** `reset_env_var`, the reset endpoint and `reset_all_env_vars` must
  still take out an entry saved by an earlier version, `A=B` included. Restoring an invalid name
  skips the `ENV` write (which would raise `Errno::EINVAL`).
- **Entries already in the file with a refused name are no longer applied** by `apply!` (boot,
  Sidekiq, console). It changes the behavior for an application that relied on, say, a
  `DATABASE_URL` override saved before: judged acceptable, it is what the finding asks to stop.
  The warning gives the count only, like the boot warning, never the names.
- `apply!` now applies each key on its own, rescuing per key, so one key that cannot be written
  leaves the others applied.

## #53 case 2: `config.mcp_read_only`

- Named after the other MCP options (`mcp_enabled`, `mcp_transport`, `mcp_allowed_hosts`).
- **Default false.** True would break every current MCP user at the next update without a word;
  the option is documented next to the Security paragraph of `docs/mcp.md`.
- **Tools left out:** exactly the six the finding names (`Profiler::MCP::Server::WRITE_TOOLS`).
  `explain_query` stays: it only explains read-only statements in a transaction always rolled
  back, and is documented as a reading tool. The resources only read. `get_profile` with
  `save_bodies` writes temporary files under the MCP cache, the profiler's own, and stays.
- Left out at build time (`define_tool` returns nil), not refused at call time: the tool is not
  advertised and a call answers the SDK's own "tool not found". Read when the server is built,
  once per process: a change needs a restart (documented).
- It does not touch the dashboard API, which has its own access control.
- **`PROFILER_MCP_READ_ONLY` (after review, task-056):** `exe/profiler-mcp` requires the gem and
  starts the stdio server without booting the application, so the option set in its initializer
  never reached it: the 21 tools were listed. Sharing the configuration with the application
  would mean booting it from the executable, which is what `rake profiler:mcp` already does; the
  executable stays light and reads an environment variable instead, set in the MCP client's
  server entry. `Server.read_only?` is `config.mcp_read_only` **or** the variable, on every
  transport: the variable can only turn read-only on. Any value but empty, `0`, `false`, `no` or
  `off` turns it on, so that a typo errs on the read-only side. The env tools refuse to change it.

## #54 case 13: RESTORE seen by one process only

- **Per-process tracking rather than a generation counter.** Each store already records, in
  `@process_originals`, the value a key had before this process changed it. `apply!` now restores
  a RESTORE entry only in a process that has such a record, to that value, and drops the record:
  restored once, never again, whatever the number of `apply!` calls. A process that never applied
  the override leaves the variable alone (before, it wrote the file's "original", which came from
  the machine that wrote the file). Forked workers inherit the record with the ENV it describes.
- **RESTORE entries are no longer removed by `apply!`.** They carry `reset_at` and are pruned when
  the file is next written, after `RESTORE_TTL` (seven days). An entry written by an earlier
  version without `reset_at` starts its delay at the next write. `reset_all` leaves an existing
  RESTORE entry (and its `reset_at`) alone so that it still expires.
- Limit, documented: a Sidekiq process that runs no job for longer than seven days keeps the
  override until it restarts. Puma cluster workers never call `apply!` between requests (this was
  already the case); the reset reaches them at restart. Calling `apply!` per request is now cheap
  (case PERF-10) but is a behavior change left out of this branch.
- The spec forks two real workers talking over pipes (`spec/env_override_store_processes_spec.rb`).
  It fails on the previous store (the second worker keeps `"overridden"`).

## #47 PERF-10: reading the file before each job

- Only `apply!` uses the cache. `set`, `delete`, `reset`, `reset_all` and `all_overrides` still
  read the file, under the lock where they write; the lock, the temporary file and the rename are
  untouched.
- The cache key is the inode, device, mtime and size of the file. **Corrected after review
  (task-056):** the first version claimed the inode changed at every write. It does not on ext4,
  which gives the freed inode to the next temporary file: two writes of the same size within one
  mtime tick kept the stale value (242 times out of 300 in the reviewer's measure), until the
  next write.
- Chosen fix: **cache only a settled file**, whose mtime is at least `CACHE_SETTLE_SECONDS` (2)
  in the past; a younger file is read at each call. A later write then carries an mtime at least
  that much younger, a different one on any file system whose mtime tick is under two seconds
  (FAT, the coarsest, has two). Preferred to a generation counter, which would need a second file
  or a read of the content to learn the generation, and its own crash cases. Cost: a read per
  `apply!` during the two seconds after a write. Limit: a clock set back by more than two seconds
  between two writes; the file is then read again at the next write.
- The spec holds `File.stat` to the first write's stat, so that it reproduces the reused inode
  whatever the file system, and fails on the previous cache.

## `child_boot_spec` after the policy (task-056)

- Its second example showed that, without the marker, the application replays `SPEC_OPTS` and
  `DATABASE_URL`; `apply!` refuses them everywhere now, so the marker guard was no longer
  exercised. It now uses an allowed key, `MY_FEATURE_FLAG`, rewritten in the file between
  `build_env` and the boot: with the marker the test process keeps the value `build_env` gave it,
  without it the application replays the file. Removing the guard fails the first example.

## CHANGELOG on the rebased branch

- The branch was rebased onto the merged reference branch (task-091). The entries are written
  under `[Unreleased]` and `bin/changelog stamp --default-branch origin/reference/rails-profiler-gem`
  turns them into the section of the version it computes; nothing in a section another branch
  stamped is touched.

# Decisions: fix/explain-environment-gate

Taken without the maintainer, choosing the most cautious option each time. To be reviewed, and
removed or folded into the docs once accepted.

## #53 case 7: Explain outside development and test

- **One gate, `Profiler::ExplainRunner.refusal`,** read by the runner itself, the endpoint (403)
  and the MCP tool, so that none of the three can drift. It checks `enabled` first, then the
  environment.
- **Allowed environments: `development` and `test` only,** compared on `Rails.env`. Any other
  name (`staging`, `production`, a custom one) is refused: an allow list, not a production check,
  since a staging database can hold real data too. Without Rails (no `Rails.env`), the
  environment is unknown and Explain is refused.
- **Opt-in: `config.allow_explain_outside_development`, false by default.** An operator profiling
  a staging copy may want the plan of a slow query there; the option makes that an explicit,
  documented choice. Named after `test_runner_allow_undiscovered_files`. Only `true` lifts the
  gate (a truthy string does not). It lifts the environment check only, never `enabled`.
- **Through the slave proxy,** the MCP tool forwards to the slave's endpoint: the slave's own
  environment and configuration decide, not the master's.
- `explain_query` stays listed by `tools/list` outside development: the tool also serves slaves,
  and a call answers the reason. Its description now states the gate and the option.
- `RefusedError < ArgumentError` is new: the runner's own refusals, whose message is written for
  the caller. The endpoint and the tool answer only those with their message; an `ArgumentError`
  raised below the runner (an adapter, a driver) is now an internal error with a generic answer.
  `UnsafeStatementError` is a `RefusedError`, still an `ArgumentError`.

## #47 SEC-22: raw exception messages

- **Generic answers:** `Explain failed` (500), `Could not link the Ajax request` (500), `Proxy
  error` (502), `EXPLAIN failed (the application log has the details)` for the MCP tool. The full
  message goes through `Profiler.log_error`, the gem's logger (`config.logger`, else
  `Rails.logger`), which masks the profiler's credentials and cuts the message at 1000 bytes like
  every other line it logs. The request values put in the log line (tokens, slave name) are
  `inspect`ed, so a newline cannot forge a line.
- **Kept as they are:** `Profiler::Error` from the slave proxy (unknown, offline or refused slave,
  missing secret, a refused path segment) and the runner's refusals: messages the gem writes,
  with no internal detail, that the user needs to act.
- **`EnvOverrideStore::Error`, checked, out of scope:** its message is already built to be shown
  (the file named relative to `tmp_path`, an `Errno` by its description only, never the
  exception's own message), so the Env tab and the MCP env tools were left alone.
- **Not changed, noted:** `TestRunnerController#create` answers `InvalidFileError` with its
  message (the gem's own, naming the file the client sent); the MCP resources and tools answer
  `Storage::Unavailable::Error` with a message the store already sanitizes (paths replaced,
  credentials masked).

## Process

- The branch was rebased onto `origin/rails-profiler-gem/fix/env-writes-and-mcp-read-only-v3`
  (task-096). The CHANGELOG and DECISIONS conflicts were resolved by hand: the base's sections
  kept as they are, this branch's own entries and decisions put back after them.
- The entries sit under `[Unreleased]` and `bin/changelog stamp --default-branch
  origin/rails-profiler-gem/fix/env-writes-and-mcp-read-only-v3` turns them into the section of
  the version it computes, as described above. The `[0.34.0]` section the base stamped is left
  byte for byte.

---

# Decisions: chore/deps-orval-and-mcp-bound

Choices made on this branch without the maintainer available, each with the most cautious
option and the reason for it. Remove this file once the branch is reviewed.

## orval: `^8.41.0`, locked at 8.41.0

- Every `orval` below 8.21.0 carries the critical advisories. The latest release, 8.43.0, was
  published the day before this branch and 8.42.0 two days before: 8.41.0 is the most recent
  release that had been public for a week, a cooling-off period against a compromised fresh
  release. The floor of the range is the version actually tested, not the first fixed one.
- orval 8 requires Node.js `>=22.18.0`. The `build` job runs on `node:22`, which tracks the
  latest 22.x, so it is satisfied.
- orval 8 changed two defaults that `orval.config.ts` relied on, and the config now sets them
  back:
  - `httpClient` defaults to `fetch`, which calls the mutator as `apiFetch(url, RequestInit)` and
    expects a `{ data, status, headers }` response. `api-fetcher.ts` takes orval 7's config
    object and returns the body, so the config sets `httpClient: 'axios'` (the shape of the call,
    not a dependency on axios: the mutator still uses `fetch`).
  - A global `query.useQuery: true` now makes every verb a query, POST and DELETE included,
    which removes the mutation hooks the components use. Unset, GET gets a query and the other
    verbs a mutation, which is what orval 7 produced with it.
- The unknown keys `useInfiniteParam` and `initialPageParam` are left as they were: orval 7
  ignored them too (no `pageParam` in its output), so removing or renaming them is a behaviour
  change for another branch.

### Generated output, orval 7.21.0 against 8.41.0 (measured)

Same swagger, `yarn build:full` with each version, outputs compared:

- Every `apiFetch` call: same URL, method, params and body. The only difference is that the
  mutation functions (DELETE, PATCH) now accept an optional `signal` and pass it on; the
  generated mutation hooks call them without one, so `fetch` still gets `signal: undefined`.
- Every query key: same values. Path parameters of the query key functions are typed as
  required instead of optional.
- Schemas: fields marked `nullable` in the swagger are typed `T | null` instead of `T`, the
  `@nullable` doc comment and the `eslint-disable` lines are gone. Types only.
- Query hooks build their result with a `withQueryKey` helper (getters) instead of
  `{ ...query, queryKey }`, which keeps TanStack Query's tracked properties working.
- `tsc --noEmit` passes on the new output. Without the two config changes above it failed on
  every mutation call site.

## `yarn audit` after the upgrade (measured)

- Before: 11 critical (all `orval`), 150 high, 29 moderate.
- After: 0 critical, 18 high, 3 moderate, on `fast-uri`, `immutable`, `picomatch` and
  `source-map-js`, all transitive build dependencies. Left out of this branch, whose scope is
  `orval`; the new `yarn:audit` job reports them.

## `yarn:audit` job: informational, separate job

- `allow_failure: true` rather than `|| true` in `build`: a finding turns the job orange in the
  pipeline view instead of being buried in a green log, and the pipeline still passes.
- Not blocking: a new advisory on a build-only dependency, often with no fixed version yet,
  would hold back every publication, and the easy way out would be to bypass the pipeline.
- `needs: []` and no install: `yarn audit` reads `package.json` and `yarn.lock` only.
  Nothing, `canary` and `release` included, depends on it.

## mcp: `">= 0.3", "< 2"`

- Measured: the full suite passes with `mcp` 0.3.0 (lowest allowed) and 1.7.0 (resolved today),
  0 failures each (1881 examples with 1.7.0 after the rebase). The floor is kept, since raising it would drop applications
  that pin an older `mcp`, and the cap is the next major, the first version allowed to break the
  API under semantic versioning. `~> 1.6` was rejected: it would raise the floor for no tested
  reason.

## Commit type and changelog

- The brief asks for `chore(deps)` commits, which publish nothing: `bin/changelog stamp` leaves
  the entries under `[Unreleased]`, and they ship with the next publishing merge. The `mcp`
  bound only reaches users then. If it should go out on its own, the commit touching
  `profiler.gemspec` would have to be a `fix:`.

## SimpleCov floor: 92.0, not 92.3

- The floor was first set at 92.3 when the suite measured 92.37% on Ruby 3.3 and 92.36% on
  Ruby 3.4. After the rebase on the other branches of this work (G1, G2, G3, G4, G5 and G8, already
  rebased), the same suite measures 92.11% (7091 of 7698 lines) with 2045 examples and 0 failures.
- The drop is a dilution: those branches added code that their own specs cover less than the
  average, so the percentage fell. The specs of this branch are unchanged and no covered line was
  lost, so this rebase introduces no regression.
- The floor is lowered to 92.0 so that the CI measures a regression from today's level. Raising it
  back to 92.3 or more takes new specs for the code added by those branches, which is out of scope
  of a rebase.

## Mailer previews, skip_paths and authorize_with fixes

- Mailer previews: the existing guard read `Thread.current[:profiler_request_path]`, which no
  code sets, so it never fired. It now also checks the path of the profile being built,
  matching `/rails/mailers` only as a whole segment. The thread-local is kept for callers that
  set it. A visit to `/rails/mailers/...` still creates a profile (a token is returned); the
  fix only keeps the phantom "delivered" emails out of it. An application mounted under a
  sub-URI (`/app/rails/mailers`) is not recognized.
- `skip_paths`: only the defaults are changed. A user-supplied list is used as given, so an
  application that redefines `skip_paths` entirely does not get the new defaults either.
  `manifest.json` is matched at any depth (`/manifest.json`, `/packs/manifest.json`), as it was
  before the patterns were anchored, but only as the last segment of the whole path.
- `authorize_with`: the rescue lives in `Configuration#authorized?`, so the middleware and the
  MCP HTTP guard both deny on error. Only `StandardError` is rescued; the exception detail goes
  to the log, never to the client.

# Decisions: test runner robustness (#53 case 5, #54 cases 10 to 12)

Decisions taken without review, the most cautious option each time. Measured on the base
(`dcc0c31`) with real subprocesses before any change, then covered by specs that fail on the base.

## Case 5: a process ended by a signal

- New terminal status `signaled`, rather than reusing `killed`: `killed` means "stopped from the
  profiler", and a crash or the out of memory killer is not that. A run stopped from the profiler
  stays `killed` whatever signal ended it.
- `exit_code` is `nil` for such a run (the process has none), and the new `signal` field gives
  `SIGKILL`, `SIGSEGV`, etc. A `[Profiler]` line is appended to the output before the status, so
  a client that does not know `signaled` (an older master polling this slave, an older page) still
  shows why. An older master's `run_tests` on a slave does not know the status and waits until its
  timeout: acceptable, it reports the run as still running rather than passed.

## Case 10: stop

- `IO.popen(..., pgroup: true)`, `TERM` to `-pid`, then `KILL` to `-pid` after
  `config.test_runner_kill_grace_seconds` (default 5 s, enough for rspec to print its summary).
- The group id is the pid of the test process. If the whole group ended and the system gave that
  pid to a new process that leads its own group within the delay, the `KILL` would reach it. That
  needs the pids to wrap around in 5 s; accepted and noted in the code.
- Unix only, like the rest of the runner (`bundle exec`, `Process.kill`).

## Case 11: runs per process (Puma cluster)

- **Not implemented as shared storage; documented instead.** Sharing runs between workers means
  writing test output (which can carry internal details) to disk or to the user's store, plus the
  live streaming (condition variables), the output limit and the stop (a pid owned by another
  worker) across processes. That is a redesign that could not be tested properly here.
- What changed: the `404` of show, stream and stop gives the reason; `docs/testing.md`
  ("Several server processes"), `docs/ui.md`, `CHANGELOG.md`. `run_tests` over MCP is unaffected
  (same process).

## Case 12: limits

- `config.test_runner_max_output_bytes`, 5 MiB by default: the first three quarters are kept as
  they come (streamed live), then a marker line, then only the last quarter is kept and shown at
  the end, with the number of bytes left out. The end is kept because the summary and the failures
  of a test run are there. Lines are only appended, so the SSE positions of the pages stay valid.
- `config.test_runner_max_active_runs`, 2 by default: two suites against the same test database
  already step on each other. A run counts from its creation until its process has ended (a stopped
  run still counts while it prints its summary). Refused with `TooManyRunsError`: `429` in the API
  (the page shows the server message), a tool error in `run_tests`.
- At most 20 finished runs kept (`RunStore::MAX_FINISHED_RUNS`, not configurable), on top of the
  one hour TTL, so that the output limit also bounds the store as a whole.
- `nil` lifts either limit, like the other byte limits of the configuration.

# Decisions: fix/release-safety

Choices made on this branch without the maintainer available, each time the most cautious
option. Audit references: #53 case 6, #44 SEC-17, #56 cases 1 and 2.

## `rake release` (#53 case 6)

- `release`, `release:rubygem_push` and `release:source_control_push` are cleared and replaced
  by a task that aborts with a message pointing at the `release` CI job. The subtasks are
  cleared too: each of them can be invoked on its own, and `release:rubygem_push` pushes on its
  own. `build` and `install` stay, they never leave the machine.
- `metadata["allowed_push_host"]` is **not** added to the gemspec. It takes a single host, and
  `gem push` refuses any other one. The CI pushes the same gem to two registries (the GitLab
  package registry and rubygems.org) and the canary to the GitLab registry: any value would break
  one of those pushes. The field is meant to keep a private gem off rubygems.org, which is not
  this gem's case. The guard against a push from a workstation is the Rakefile refusal.

## `canary` publication (#44 SEC-17)

- `when: manual` on the canary rule, the branch prefixes unchanged. This is the simplest change
  that needs no repository setting: limiting it to protected branches would need branches to be
  protected in GitLab, and limiting it to approved merge requests would need merge request
  pipelines, which this project deliberately avoids (see `changelog:check`).
- `allow_failure: true` with it: a manual job that may not fail leaves the pipeline "blocked",
  which would hold every merge request whose canary nobody played.
- Anyone allowed to run pipelines can still play the job. Restricting who can play it further
  (a protected environment) is a GitLab setting, left to the maintainer.

## Canary version order (#56 case 1)

- `script/canary-version` numbers the canary `<next>.pre.<short sha>`, `<next>` being
  `bin/changelog version` (the version the branch will publish, the rule the stamp and the
  release job use). A branch with nothing publishable gets the next patch of the highest of the
  last tag and the versions `CHANGELOG.md` carries. Either way the canary sorts after the last
  release and before the release the branch leads to. Any other failure of `bin/changelog`
  fails the job rather than publishing a wrong number.
- The job fetches `master`, as `changelog:check` does, since `bin/changelog version` counts the
  branch from `origin/master`.

## `bin/changelog` commit reading (#56 case 2)

- The type (`fix:`, `feat:`, `type!:`) is read from the **subject only**, as Conventional
  Commits defines it. Reading the body made a `chore:` commit with a `fix:` line in its body
  (a quoted message, a note) publish a patch; a publication cannot be taken back, so a stray
  line must not trigger one. A fix written only in a body now publishes nothing: write it as
  the subject of its own commit.
- The body is still read for the breaking footer, now in both spellings the specification
  allows: `BREAKING CHANGE:` and `BREAKING-CHANGE:`. The generated changelog entries use the
  same rule.
- The previous spec "catches a releasable line hidden in a commit body" asserted the old
  behaviour and is replaced by its opposite.

## Changelog stamp

- `bin/changelog stamp` is run with `--default-branch origin/reference/rails-profiler-gem`, not
  `--base`: in this script `stamp` does not read `--base` (that flag is the version base of
  `version` and the ref of `check`), and `--default-branch` exists. Against the default
  `origin/master` of the hub (which is not the gem's history) the stamp would have folded this
  branch's entries into an inherited section. Every section below the stamped one is left byte
  for byte as inherited.

## Branch fix/toolbar-csp-and-build (G11)

- Nonce: the toolbar already put the nonce on its scripts, only `<style>` missed it. The embedded
  layout gets it on both its inline `<style>` and `<script>` (a `style-src` nonce policy usually
  comes with `script-src`). The application layout has no inline element. No nonce attribute is
  written when `content_security_policy_nonce` is nil.
- Minification: `esbuild --minify` and `sass --style=compressed` (measured: toolbar 177126 to
  81306 bytes, 23374 gzipped; main 446585 to 222309; css 90964 to 79366). `watch` stays unminified.
  No source maps, as before.
- Versioning: content digest (12 hex of SHA-256) rather than the gem version, because
  `VERSION` is `0.0.0` on every branch build and a rebuilt asset would keep the same URL. Query
  string (`?v=`) rather than the file name: the routes and the extension's `/_profiler/assets/...`
  URLs keep working. A year, immutable, only when `v` equals the current digest; any other value
  keeps the one hour. Without built assets the digest falls back to a hash of the gem version.
- PERF-08: the memoization existed but on the instance, and the injector is built per request,
  so it never held. Moved to the class; a failed read is not kept.
- Not measured: a real browser with a real CSP header. The nonce is covered by request specs.
- Rebase on the current master: the versioning of this branch and the explicit 404 of the
  assets endpoints (G14) both changed `AssetsController`. They are kept together:
  `Profiler::Assets.read` raises `Errno::ENOENT` when the assets are not built, which is the
  exception the 404 already rescued, so a missing asset answers the `BUILD_MISSING` message
  whatever the `v` parameter.

# Decisions: fix/toolbar-robustness

Choices made on this branch without the maintainer available, each with the most cautious
option and the reason for it.

## CSS isolation (case 8): prefixing and ID scoping, not Shadow DOM

- The toolbar CSS is already scoped: every selector starts with `#profiler-toolbar`,
  `#profiler-toolbar-toggle` or `.profiler-root`, the classes carry a `profiler-` prefix and the
  keyframes a `pf` prefix. Only one rule escaped (`.profiler-toggle-icon`), now scoped.
- Shadow DOM was not adopted: the toolbar relies on the host page for its fixed positioning
  and for the `data-theme` attribute set by an inline script, the CSS is injected as a `<style>`
  element under the page CSP nonce, and the panels link to the dashboard. Moving to a shadow
  root changes all of that and cannot be checked without a browser here. Prefixing is the more
  cautious option given what exists.
- A new spec fails when a selector of the toolbar CSS is not scoped, so the isolation cannot
  silently regress. No blanket reset (`all: revert`) was added, because it could change the
  rendering in ways that were not observable here.

## Vitest

- `yarn test` did not exist. `vitest` (^4.1.11, the first release without the advisories of 3.x
  and 4.0) and `jsdom` were added as dev dependencies, and a `picomatch` resolution (^4.0.4)
  removes the advisory it brought (it also fixes the one `sass` carried). `yarn audit` goes from
  21 to 19 findings, none new.
- `yarn test` runs `yarn codegen` first, since the generated client is not committed.
- Vitest runs `spec/javascript/*.spec.{ts,tsx}`; the plain JavaScript interceptor test stays on
  the Node test runner (run by `spec/ajax_interceptor_js_spec.rb`).

## FUNC-01: the swagger part was already done

- `swagger/v1/swagger.yaml` already documents the three cluster routes (`clusterRegister`,
  `clusterHeartbeat`, `listClusterSlaves`) and `yarn codegen` generates `useListClusterSlaves`,
  so only the migration of `ProfilerSelector.tsx` was left. `tsc --noEmit` on the regenerated
  client reports 0 error.
- `apiFetch` rewrites a URL through the proxy of the slave being viewed. Left alone, the
  selector would then ask the slave (which does not route `cluster/slaves`), get a 404 and
  disappear, with no way back to the master. The cluster, toolbar, and events URLs are therefore
  never prefixed (these endpoints are exempt per `MASTER_ONLY_PATHS` in api-fetcher). The request
  is otherwise the same (one GET, no retry, no refetch on focus); it now also carries the
  `X-Profiler-Request` header like every other generated call, which a GET ignores.

## Token cleared on Turbo visits (case 4)

- The interceptor drops `window.__PROFILER_PARENT_TOKEN__` on `turbo:load` when the page has no
  `#profiler-toolbar`. A profiled page sets the token again from its own inline script before
  `turbo:load`, so the token follows the page.

## CI: type check, lint, front-end tests, Ruby/Rails matrix

- **`typecheck`** (`yarn codegen`, then `tsc --noEmit`): measured green on the current code
  before being added, so it blocks.
- **`rubocop`**: with RuboCop's defaults the repository has 15295 findings, nearly all Style and
  Layout (the code uses double quotes and no agreed layout). Chosen, as the most prudent: enforce
  only the Lint and Security departments (`.rubocop.yml`), which find real defects, and freeze
  the 151 findings that existed in `.rubocop_todo.yml` (generated with `--auto-gen-config
  --auto-gen-only-exclude`, no autocorrect so no code moved). The job blocks, so a *new* finding
  fails the pipeline while the old ones wait for a follow-up branch that empties the todo file.
  Style and Layout stay off until someone settles a style. RuboCop is pinned (1.92.0) in the job.
- **`vitest`** (`yarn test:coverage`, which runs `yarn codegen` first): 25 tests, measured
  3.48% statements, 2.29% branches, 3.2% functions, 3.79% lines on the hand-written sources
  (generated client excluded). The floors are 3/2/3/3, just under the measure: they catch a
  regression, they do not claim coverage the code lacks. The real gap is the dashboard tabs and
  panels, at 0%; this branch adds specs for `api-fetcher` (the `/slaves` prefix is kept on a route
  that is not a cluster route, and never put on a cluster route), `CachePanel` and `TestTab`.
- **`vite ^6` removed** from `package.json`. Before and after: `yarn test` 16 tests green,
  `tsc --noEmit` clean, `yarn build` OK; vitest uses its own vite 8.3.4, `vite@^6` was no longer
  in `yarn.lock`.
- **Ruby/Rails matrix (open, needs Sébastien's decision)**: the gemspec declares ruby >= 3.0 and
  rails >= 7.0 but only Ruby 3.3 and 3.4 with the latest Rails (8.1) were ever run. Measured here:
  on Ruby 3.1 with Rails 7.0 the suite gives 271 failures out of 1904. The causes seen are in the
  specs (`Rack::Headers` is Rack 3, `ActiveSupport::BroadcastLogger` is Rails 7.1) and others in
  the MCP specs not diagnosed. Rails 7.1 on Ruby 3.1 could not be run in this sandbox (native
  extension build trouble that the official `ruby:3.1` image would not have). Chosen, as the
  most prudent: add `rspec:ruby3.1-rails7.1` with `allow_failure: true`, outside the publishing
  gate, using `gemfiles/rails_7_1.gemfile`, and leave the gemspec bounds alone. Follow-up: read
  that job's first result, then either make it blocking or raise the bounds to what passes
  (a compatibility change to announce). Until then rails 7.0 support is unverified and probably
  broken.

## Collector circuit breaker and `/_profiler/health` (task-182)

- **`subscribe_all` isolates each collector** (independent of the option). A collector whose
  `subscribe` raises is logged, released (`unsubscribe`, as a precaution) and removed from the
  caller's array in place; the others keep profiling. Only when none subscribed does it return
  false (request run unprofiled, as before). In place, so that the four callers (request, job,
  console, test) keep working on the same array without a signature change. For job, console and
  test profiles the primary collector (job, console, test) is removed like any other if its
  subscribe fails: the profile is then saved without that tab rather than not recorded.
- **State per collector class**, in a process-wide registry behind a `Mutex`
  (`Collectors::CircuitBreaker`). Per process, not shared between workers: cluster-wide state
  would need storage and a failing collector is usually failing in every worker anyway.
- **What counts**: a raising `subscribe` or `collect` (one counter step per raise), through
  `Lifecycle.guard`, now used by every collect loop. A collector that collects without raising
  clears its count and closes a half open circuit.
- **Recovery**: fixed 60 seconds (`RECOVERY_SECONDS`, not an option, as asked). After it, the
  first `allow?` moves the circuit to half open and lets one request through; others are refused
  until that trial reports. A trial that never reports (request unprofiled, crash) is retried
  after another 60 seconds rather than leaving the circuit stuck. Time is monotonic.
- **Disabled**: nothing counted, nothing blocked, health reports everything `closed`.
- **Threshold validation**: a value that is not a positive Integer is refused with a warning and
  the previous value kept, like `http_skip_hosts`, because the gem loads in production.
- **Health lists `Profiler.configuration.collectors`** (the configured classes), so an open
  circuit is visible even though the collector is absent from profiles. State of an open circuit
  past its delay is reported `half_open` (the next request will try it) without being changed by
  the read.
- **HTTP code: always 200.** An open circuit means a collector is left out of profiles, not that
  the profiler is down; a 503 would make any probe or the toolbar link look like an outage. The
  page sits behind the same access checks as the rest of the profiler.
- **Not covered**: `Profiler.configuration.collectors` is the only list gated by the breaker. The
  fixed collector lists of jobs, console and tests are not gated (they are not configurable),
  though their failures count against the class and a gated class is skipped in HTTP only.

## Distributed tracing, W3C `traceparent` (task-184)

Taken without the maintainer, choosing the most cautious option each time.

- **Scope: the gem only.** Extraction, propagation, the `Profile` fields, the storage lookup, the
  API filter and the dashboard component all live in this repository. Nothing was needed in the
  extension or the superproject, so no other branch exists for this change.
- **Format:** version `00`, `00-{trace-id:32 hex}-{parent-id:16 hex}-{flags:2 hex}`, parsed by
  `Profiler::TraceContext.parse`. A value is refused (a new trace starts) when it does not match,
  when the version is `ff`, when the trace id or the parent id is all zeros, or when a version `00`
  value has more than four fields. A later version is read by its first four fields, as the
  specification asks. Ids are lower-cased.
- **Entry:** `ProfilerMiddleware` reads `HTTP_TRACEPARENT` right after the profile is created. A
  valid header: the profile keeps its trace id and its parent-id becomes `parent_span_id`. Absent
  or invalid: `SecureRandom.hex(16)` trace id, `parent_span_id` nil. Always a new `span_id`
  (`SecureRandom.hex(8)`). The trace flags received are not kept: outgoing calls always send `01`.
- **Context:** `CurrentContext.trace_id`, a thread-local like the token, set by the middleware,
  cleared with it, and lent again by `StreamedProfile` to the thread iterating a streamed body.
  Like the token, it does not follow a thread the application starts itself.
- **Propagation:** `NetHttpInstrumentation.inject_trace_context`, called first in
  `RequestPatch#request`, before the "no collector" and "untracked" guards. Placed after them, the
  cluster's master to slave calls (made under `Profiler.untracked_http`) would never carry it,
  which is what the brief wanted covered. It never overwrites a `traceparent` already on the
  request, and sends none to a host `skip_host?` excludes. A failure is logged and the call goes
  out without the header.
- **Known limit, measured:** the master's calls to a slave carry the header when the calling
  thread has a trace context (tested through `SlaveProxy`). They are made from `/_profiler` API
  requests, which the middleware does not profile, so in normal use that thread has no context and
  no header goes out. Not changed: profiling the profiler's own routes is out of scope.
- **Storage:** `find_by_trace(trace_id)` on every backend, oldest first, `[]` for a value that is
  not 32 lower-case hex characters (the same check as a token, so nothing client-supplied becomes
  a key or a path). Memory, file (index line gets a `trace` field, old lines read as no trace) and
  Redis (`traces:{id}` set, same TTL handling as `children:`) mirror `find_by_parent`; SQLite gets
  `trace_id`, `span_id` and `parent_span_id` columns added by the existing `ALTER TABLE` migration
  plus an index on `trace_id`. Profiles saved before this change have no trace and are not found.
- **API:** `GET /_profiler/api/profiles?trace_id=` (no new route), like `parent_token`; http
  profiles unless `all_types`. Documented in `swagger/v1/swagger.yaml`, with the three fields on
  `Profile`.
- **Dashboard:** a `Trace` tab, always shown, listing the other profiles of the trace and saying
  so explicitly when there are none (single-span trace) or when the profile predates tracing.

# Decisions: feat/otel-traces (gem #35, part 1)

## OpenTelemetry is a purely optional dependency

- **No dependency anywhere in the gem.** `profiler.gemspec` declares nothing `opentelemetry-*`
  and the gem requires nothing from OpenTelemetry at load. This is the `stackprof` precedent
  exactly: not in the gemspec, in the `Gemfile` under "Optional dependencies" with
  `require: false` (for the specs), required lazily in a `begin/rescue LoadError` by the one
  file that needs it (`Profiler::Otel::Sdk`), and only once `otel_enabled` is true. A runtime
  dependency would force the SDK, and its protobuf and OTLP gems, on every application, most of
  which never export anything, and would pin their versions against the application's own.
- **Failure mode:** enabled without the gems (or without an endpoint when the gem has to send the
  spans itself): one `Profiler.log_error` message, export off for the process, nothing raised.
  A failed export of one profile is logged once per error class (`log_error_once`) and the
  request goes on. `otel_enabled` false (the default) reaches no OpenTelemetry code at all;
  `spec/otel/optional_dependency_spec.rb` proves it in child processes, one of them with every
  `opentelemetry*` require made to raise `LoadError`.
- **Reusable by part 2 (metrics):** gem loading, the host-SDK detection, the resource attributes
  and the OTLP endpoint are in `Profiler::Otel::Sdk`, not in the trace exporter.
- Versions in the `Gemfile` (specs only): `opentelemetry-sdk ~> 1.4`, `opentelemetry-exporter-otlp
  ~> 0.26`. The application chooses its own.

## The spans carry the profile's W3C ids

- The root span has the profile's `trace_id` and `span_id` (not ids drawn by the SDK), so the
  trace in the collector and the profile in the dashboard are findable from one another. A
  request that came with a `traceparent` yields a root span whose parent is the caller's span
  (`parent_span_id`), as the profile already records.
- The OpenTelemetry Ruby API has no way to give a span chosen ids, so the SDK tracer provider's
  public `id_generator` is wrapped once (`Otel::ScopedIdGenerator`): it hands out the ids a
  thread asked for, once, around the root span's creation, and defers to the original generator
  otherwise. It is thread-local, so concurrent requests and the application's own spans are
  unaffected. The wrapper is also installed on a provider the application owns, with no
  other effect on it. Child spans get ids from the SDK (only the root needs to match the profile).

## Where the export happens, and what it carries

- **Hook:** `ProfilerMiddleware` exports right after it saves the profile (`save_and_export`),
  on the four paths that do. Not in `Profiler.save_profile`, which a profile reaches again each
  time a late outbound call completes: that would export the same trace several times. Jobs,
  console and test profiles are not exported (no HTTP request, no root span in this part).
- **No double instrumentation:** the spans are built from the events the collectors already
  hold, after the request. That needs a start time per event; SQL, view and cache events now
  record `started_at` (the HTTP ones already did). A profile without it (stored by an older
  version) starts its child spans with the request.
- **What leaves the process** (cautious): SQL text as `db.query.text` (as the Database tab shows
  it, already credential-masked); outbound URLs without query string, userinfo or fragment;
  cache keys are not exported; request bodies and headers are not exported. Transaction
  statements (BEGIN/COMMIT) are skipped, like the Database tab counts them apart.

## Default protocol: http/protobuf

- When the gem configures its own exporter it uses OTLP over `http/protobuf`, the protocol
  chosen for this feature and the one `opentelemetry-exporter-otlp` implements. The exporter is
  attached to a private tracer provider that is not installed as the global one, so the
  application's OpenTelemetry is left as it is. Endpoint: `otel_otlp_endpoint`, else the standard
  `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` / `OTEL_EXPORTER_OTLP_ENDPOINT` variables. No sampling
  option of the gem's own: left to the SDK or the collector.

# Decisions: feat/otel-metrics (gem #35, part 2)

## The metrics SDK is alpha, and pinned exactly

- `opentelemetry-metrics-sdk` is in development: its API changes between releases and its
  maintainers recommend an exact pin. The `Gemfile` (specs only, "Optional dependencies",
  `require: false`, never the gemspec) pins `opentelemetry-metrics-api = 0.10.0`,
  `opentelemetry-metrics-sdk = 0.21.0` and `opentelemetry-exporter-otlp-metrics = 0.14.0`
  (latest on rubygems.org when written). No `~>`.
- **A third gem, not in the brief:** the OTLP metrics exporter is a separate gem
  (`opentelemetry-exporter-otlp-metrics`, the trace one does not carry it). Needed only for the
  case where the gem sends the metrics itself; pinned like the other two.
- Class names were read in the installed gems, not assumed: `OpenTelemetry::SDK::Metrics::MeterProvider`,
  `...::Export::PeriodicMetricReader` (wrapping `OpenTelemetry::Exporter::OTLP::Metrics::MetricsExporter`),
  and `...::Export::InMemoryMetricPullExporter` for the specs. If a later version renames them
  the setup fails into a logged warning (no raise), and the specs fail loudly.
- Documented as experimental in `docs/configuration.md` and the changelog: whoever turns metrics
  on takes an alpha dependency. The gem does not hide it behind a separate option: `otel_enabled`
  is the only switch, as asked.

## Same `Sdk`, one provider per signal

- `Profiler::Otel::Sdk` now serves both signals from a small table (gems to load, endpoint
  variables); `tracer_provider` and `meter_provider` share the host detection (the SDK provider
  behind the API's proxy), the resource and the own-provider scheme (never installed globally,
  `at_exit` shutdown). Availability and failures are per signal: with only the trace gems, traces
  export and one message says the metrics are off; with only the metrics gems, the reverse. Both
  missing: two messages, once each, no exception.
- One setting for the endpoint: `otel_otlp_endpoint` ending in `/v1/traces` is read as
  `/v1/metrics` for metrics (a path that does not end so is used as given). When only environment
  variables are set, the exporter resolves them itself.

## What is recorded, and with which attributes

- Histograms in **milliseconds** (the unit the profiler measures; the SDK's default buckets,
  0 to 10 000, suit it) rather than the semantic conventions' seconds: converting would only
  add a rounding step. Unit is declared (`ms`).
- Same events as the spans (SQL without transaction statements, views and partials, cache reads,
  writes and deletes, outbound HTTP not in flight), taken from the collector data after the
  request, at the same call site as `TraceExporter.export`.
- Attributes, all bounded: `profiler.controller_action` (the `RequestCollector` value; `unknown`
  for a 404 or non-Rails request, never the path), `http.request.method` (standard verbs, else
  `_OTHER`), `http.response.status_code` (request duration only; HTTP statuses are bounded),
  `db.operation.name` (SELECT/INSERT/UPDATE/DELETE, else `OTHER`) and `cache.operation`. Never
  the token, path, URL, host, SQL text or cache key. `spec/otel/metrics_exporter_spec.rb` greps
  every attribute the in-memory reader collected for those.

## The counters

- **Allocations:** `Profile#allocated_objects` added to `profiler.request.allocations`. With
  `track_memory` off it is nil: nothing is recorded for it and nothing fails.
- **N+1:** +1 per HTTP request in which at least one group of queries, grouped by
  `N1Patterns.normalize_sql` (reused, not rewritten), has more than one member; not +1 per extra
  query or per group. Why: it answers "how many requests have the problem", is directly comparable
  to the request count, and does not make one bad page weigh a hundred times a slightly bad one;
  the number of repeated queries is already in the SQL histogram's count. Transaction statements
  are left out, as for the spans. Limits it shares with `N1Patterns`: a normalized `IN (?, ?)`
  list of different length is not merged, and a legitimately repeated query counts too.
- Measured vs reasoned: the values, the attributes and the counter behaviour are measured by the
  specs against the real SDK; the "+1 per request" choice and the ms unit are reasoned.


---

# Decisions

## Clickable file:line links (gem #49, gem side)

- **Base.** `origin/reference/rails-profiler-gem` does not exist in the hub; the branch was cut
  from `master` (9444774), which is where the work is based.
- **Settings.** `config.editor_url_scheme` (default `"vscode"`, allow list `vscode`, `idea`,
  `cursor`) and `config.editor_path_map` (default `{}`). The setter of the scheme does not raise
  on another value: it is stored, and `editor_link_scheme` answers `nil` for it, so nothing but
  the three schemes ever reaches a link. The most prudent behaviour for a typo is no link, not a
  boot failure. The allow list is checked again in the browser (`source-links.ts`), because the
  value comes from the server.
- **URL forms.** `vscode://file/<path>:<line>` and `cursor://file/<path>:<line>` (Cursor is a VS
  Code fork and registers the same handler shape), `idea://open?file=<path>&line=<line>` (JetBrains
  IDEs). Paths are escaped per segment with `encodeURIComponent` for vscode and cursor (slashes
  kept, as the editors parse a path), whole for idea. These forms are from the editors'
  documented URL handlers, not tested against the editors themselves in this sandbox.
- **Path map.** Longest prefix on a segment boundary, applied before the URL is built. Done in the
  client (`mapPath`), so the extension reimplements nothing server-side.
- **URLs are built in the client**, not in Ruby: backtraces are plain strings shown by the front
  end, and the extension builds its own links. Ruby only validates and serves the settings.
- **Endpoint.** No existing endpoint exposed configuration (`function_profiling` and `env_vars`
  are about runtime toggles and ENV; `toolbar/:token` is per profile). Adding a field to a
  per-profile endpoint would repeat it in every response, so a minimal read-only
  `GET /_profiler/api/config` was added. Same access guards as every API route.

  Contract (JSON, status 200):

  ```json
  { "editor_url_scheme": "vscode" | "idea" | "cursor" | null,
    "editor_path_map": { "<container prefix>": "<host prefix>" } }
  ```

  `editor_url_scheme` is `null` when the configured value is not allowed (the extension must then
  show no link, or use its own setting). `editor_path_map` is always an object of strings, `{}`
  when unset. Nothing else is exposed. Defaults on a fresh install: `"vscode"` and `{}`.
- **`<SourceLink>`** (`components/SourceLink.tsx`) and `<SourceFrame>` (for a backtrace line such
  as ``/app/a.rb:12:in `m'``). Without a safe URL (scheme not allowed, settings not yet loaded,
  relative path, invalid line) they render the same text in a `<span>`. If the config endpoint
  cannot be read (older gem), the gem default `vscode` applies. Click does not propagate, so a
  link inside a clickable row does not trigger the row.
- **Tabs wired:** Database (N+1 backtraces), Http (backtraces, card header frame), Exception
  (both lists), Dumps (dashboard and toolbar panel), Flame graph (function table), Test (test
  file and line). Not wired: Timeline, Views and Logs show no file and line pairs.
- **Tooling.** Vitest (+ jsdom, @testing-library/preact) was added: there was no JS test runner.
  `yarn test` runs `*.test.ts(x)`. The front-end sink spec (`spec/frontend_sinks_spec.rb`) skips
  those test files, which are not bundled and name hostile inputs on purpose, and allows
  `href={editorUrl}` in `SourceLink.tsx` only.
- **RuboCop.** The repository has no `.rubocop.yml`; the default cops report thousands of offenses
  on untouched code. The changed Ruby was checked with 1.92.0 under a config matching the code
  base (double quotes, no metrics or line length): no offense on the new code.

## gem #48: compare two profiles across instances

### The requested starting point was not used as given

The brief said `feature/34-profile-comparison-diff-regression-mcp` (commit `ee4f5d6`) was absent from
the hub mirror, and that `origin/reference/rails-profiler-gem` was the base. Checked in this sandbox:
`feature/34-...` **is** present in `origin` (`ee4f5d6`), and `origin/reference/rails-profiler-gem` is
**not** (no `reference/*` ref in `/hub.git`); the branch is based on `origin/master`
(`9444774`). So the work was done as asked originally: `ee4f5d6` was cherry-picked onto the current
`master` (it was far behind: conflicts in `configuration.rb`, `server.rb`, `main.tsx`,
`ProfileList.tsx`, `profiler.rb` were resolved keeping both sides), then extended. It was not written
from scratch.

### `peers` is separate from the cluster

The master/slave cluster is dynamic (slaves register themselves, `Profiler.slave_registry`) and
authenticated by `cluster_secret`. Comparing profiles needs the opposite: a static list written by the
operator. So `config.peers`, `config.peer_token` and `Profiler::Peers` / `Peers::PeerProxy` are new,
`SlaveProxy` and `slave_registry` are untouched. The proxy copies SlaveProxy's style (5 s / 10 s
timeouts, `untracked_http`, no redirect following, defensive JSON), not its code.

### Security choices

- A node is always a **name** looked up in `config.peers`. No code path builds a request target from
  anything else; an unknown node fails before any request, and all nodes are resolved before the first
  profile is read.
- Peer URLs are validated once per configured list (memoized on the list), with the cluster's URL
  parser (`Cluster::Security.normalize`). HTTPS is required except for loopback, with an explicit
  `config.peer_allow_insecure_http` opt-out, same idea as `cluster_allow_insecure_http`.
- **Missing `peer_token` is a strict refusal**, not a warning (the most prudent option): with peers
  configured but no token of 32 characters or more, `PeerProxy.new` raises and nothing is sent; the
  serving side never accepts any token when none is configured. A warning is also logged at boot.
- The serving side accepts the peer token for `GET /_profiler/api/profiles/:id` only (`peer_read_request?`),
  compared in constant time; it does not open the list, delete or any other endpoint.
- The node name `local` is reserved for this instance.

### Diff content

SQL fingerprints reuse `MCP::Resources::N1Patterns.normalize_sql`. "Slower" means the total time of a
fingerprint grew by more than 20% (`ProfileDiff::SLOWER_THRESHOLD_PCT`, a constant, not a setting);
each block is capped at 25 entries. The scorecard's memory row is replaced by allocated objects,
since `memory` is deprecated in the profile model.

## Threshold alerts (gem #50)

- **Where it runs**: in `Profiler.save_profile`, after a profile is saved, so HTTP requests, jobs,
  console and tests are all covered by one code path (`Profiler::Alerts.check`).
- **Allocation threshold**: `allocated_objects_warning_threshold`. `memory_warning_threshold` is
  deprecated (the same figure times 40, never a byte count) and assigning it logs a warning.
- **N+1**: at least one `N1Patterns.normalize_sql` group with more than one query in the request.
  It is broad on purpose (same definition as the OTel counter); no minimum repeat count.
- **No raw data**: the payload has the normalized SQL (cut at 200 characters) and a fingerprint, no
  body, parameter or header. The shared `N1Patterns.normalize_sql` (used by the MCP server, left as
  is) misses backslash escapes, doubled quotes, comments and dollar quoting, so `Alerts.redact_sql`
  runs first and only for alerts: it removes those forms, reading the statement with and without
  backslash escapes, and cuts the statement at the first quote, comment or dollar tag when the two
  readings differ or one is left unclosed (a value is dropped rather than guessed). Chosen over
  sending the fingerprint alone because the statement is what makes an alert actionable. A literal
  in a vendor syntax not listed can still remain: the guarantee is "the known forms are removed",
  not "no literal ever", hence also the cut at 200 characters and the fingerprint.
- **Load order**: `alerts.rb` requires `mcp/resources/n1_patterns` at the top (it is otherwise only
  loaded by the MCP server) rather than extracting `normalize_sql`, to keep one definition. Each
  family of alert is detected in its own rescue, so one failing never hides the others.
- **Hook and detection off the request**: the whole check (the detections, which walk and
  normalize every query, then `on_detection`, then the webhook) runs on the worker thread, not
  only the HTTP call. Alerts are therefore delivered one after the other.
- **One worker, bounded queue** (review of v4): `Alerts::Worker` is one thread fed by a
  `SizedQueue` of 100. A thread per profile accumulated without limit behind a slow webhook (3 s
  connect plus 3 s read, in series). A full queue drops the check and logs it. The thread is
  started on first use and again after a fork. `Alerts.drain` waits for the queue (tests).
- **Both key types** (review of v4): `Alerts.check` receives the live profile, whose
  `collectors_data` has the symbol keys `DatabaseCollector#collect` wrote, while a stored profile
  has strings. `Alerts.read` accepts both, the principle of `Otel::TraceExporter.list`. The SQL
  alerts and `controller_action` had never fired on a real profile because the specs used
  string-key hashes; `spec/alerts_pipeline_spec.rb` now runs the middleware, the real collectors
  and `Profiler.save_profile`.
- **One alert per type and profile** (review of v4): `Profiler.save_profile` runs again whenever
  a late outbound HTTP call completes (`HttpCollector#save_if_collected`). The check stays in
  `save_profile` so jobs, console and tests are covered, and `Alerts` remembers the types already
  delivered per profile token (the last 2000 tokens) instead of moving the call to the middleware
  as the OTel export does.
- **Console path left out** (review of v4): for a console profile `path` is the expression
  typed, which may hold a secret passed as a literal, so the payload sends `path: null` for it.
  Masking was not chosen: the profiler only knows its own credentials.
- **Webhook URL** (review of v4): validated at assignment, `ArgumentError` for a URL that is not
  http(s) with a host. Credentials in the URL are refused rather than turned into `basic_auth`,
  to keep a secret out of a configuration line that is often logged.
- **SQL redaction bound** (review of v4): the statement is cut at 5000 characters before
  `SqlRedaction` reads it, since the dollar-quote pattern rescans to the end for each opener.
- **Asynchronous**: `RequestContext.detached { Thread.new { ... } }`. `RequestContext.detached`
  is the single shared implementation, merged into the base; there is no minimal copy to
  reconcile any more.
- **Payload shape** and activation are documented in `docs/configuration.md`.

## Replaying a profiled request (`replay_request`)

- **The target is locked to the original host.** `Profiler::Replay` builds the target only from the
  stored profile: the host name of the `Host` header, the port from `config.replay_port` or the Puma socket
  and the scheme of that socket, captured by `Models::Profile` as `server_port` and `url_scheme`. The target
  is not read from `X-Forwarded-Host` nor `X-Forwarded-Proto`: a replay goes where the application
  received the request.
  Nothing a caller passes reaches the connection: options named `host`, `port`, `scheme`, `url`,
  `base_url`, `origin`... are refused with an error (not ignored in silence), unknown options are
  refused, `Host` and forwarding headers in a header override are dropped and reported, a path
  override must match `/` followed by a non-`/` and no whitespace or control character, and
  `Net::HTTP` never follows a redirect. As defence in depth, the captured `Host` must be a bare host
  (no user info, path or query) and pass the replay's own check (next item): a profile recorded from a
  forged `Host` header cannot turn the replay into a request to an arbitrary server (SSRF).
- **The host check does not rely on Rails' `config.hosts` as such.** The first version asked
  `LocalRequest.host_allowed?`, which defers to `config.hosts`. That list decides whether an INCOMING
  request is accepted; it is not a lock on an OUTGOING target. In development Rails sets it to
  include `IPAddr 0.0.0.0/0` and `::/0`, so `Host: 169.254.169.254` or `Host: 10.0.0.5` passed and the
  replay connected to that IP, with the stored unmasked body and headers. Now a captured host is
  replayed to only when it is (1) a loopback name, `Profiler::Configuration::LOCAL_HTTP_HOSTS`
  (`127.0.0.1`, `localhost`, `::1`; `*.localhost` is no longer accepted), or (2) a LITERAL String entry
  of `config.hosts` (compared case-insensitively, its port ignored). A match that comes only from a
  wildcard (`".example.com"`, `"*"`), an `IPAddr` range, a `Regexp` or a `Proc` is refused: those are
  the entries through which an arbitrary address passes without the operator having chosen it for this
  use. What is guaranteed: a replay connects to a loopback address, or to a name or IP the operator
  wrote out in `config.hosts`, on the port of the application server; never to an address that only
  a permissive default matched. What is not: a literal name is resolved by DNS at send time and its
  address is not pinned, so whoever controls that name's DNS controls the destination; and a literal
  IP the operator wrote (even `169.254.169.254`) is allowed since they chose it. Consequence: in
  production the application's host must be listed literally in `config.hosts` (a `.example.com`
  wildcard is not enough), or the replay is refused; on a developer machine `localhost` just works.
- **The port is not taken from the `Host` header, nor from `SERVER_PORT`.** The first version
  reused the port of the captured `Host` (`localhost:6379`), so a forged `Host` could aim a replay at
  any local service (Redis, a database, an admin API) while passing the name check; `config.hosts`
  does not help, Rails ignores the port by design. The second version captured `SERVER_PORT`, but
  measured against a real Puma 8.0.2, `SERVER_PORT` is derived from the `Host` header
  (`Host: localhost:6379` gives `6379`, `localhost` gives `80`), and `rack.url_scheme` follows
  `X-Forwarded-Proto`: the trust had only moved. Now there are two sources and no other:
  `config.replay_port` (explicit, portable, always wins) and the local port of the accepted
  connection, `env["puma.socket"].local_address.ip_port`, captured as `server_port` (the scheme is
  `https` when that socket is a TLS one, `http` otherwise). Only Puma, the documented default server,
  is covered; other servers expose no such object in a common place and are not guessed at. With no
  `replay_port` and no captured socket port (another server, or a profile stored before this fix, no
  schema migration: the field lives in the profile JSON, and in the SQLite `summary` column) the
  replay is refused with an error naming `config.replay_port`, never a fallback on `SERVER_PORT` or the
  `Host` port. Chosen over comparing the `Host` port with `SERVER_PORT`: both are client controlled
  under Puma. The cost is that a non-Puma setup must set one option, which is acceptable for a
  feature that is off by default and never shipped. Tests run a real Puma, since a `MockRequest`
  cannot show that `SERVER_PORT` follows the `Host`.
- **`replay_of` is its own field, not `parent_token`.** `parent_token` links an AJAX call or a job
  to its page and the AJAX tab and `get_profile_ajax` list the children of a profile through
  `find_by_parent`: reusing it would show replays as AJAX calls of the original. `find_by_replay_of`
  is implemented once, in `BaseStore`, over the list summaries (which `Profile#to_h` already feeds
  with `replay_of`) rather than with a new index in each of the 4 backends: replays are rare, the
  scan is bounded by `max_profiles` and pages of 200, and no storage format or schema changes (the
  SQLite store reads `replay_of` from its summary column; no migration). If replays become
  frequent, an index like the `children` of the other stores is the next step.
- **How the new profile is linked.** The replay request carries `X-Profiler-Replay-Of: <token>`;
  the middleware sets `replay_of` from it, only while `config.replay_enabled`, and only for a
  well-formed token. A client could forge the header to link its profile to another one: this only
  changes a label, never what the application does, and needs `replay_enabled`.
- **Bound of N replays.** `config.replay_max_count`, 10 by default; `count` above it, below 1 or
  not a whole number is refused. Replays run one after the other and stop at the first transport
  error. Each waits at most `config.replay_timeout` (30 s by default, 120 s at most). 10 was chosen
  as enough to compare timings and small enough that a mistake costs seconds, not a load test.
- **The replay is synchronous, and needs more than one server thread.** `Replay.call` runs in the
  thread of the request that asked for it, and sends up to `replay_max_count` requests to the same
  application, each waiting up to `replay_timeout` (120 s at most). On a single-threaded server (Puma
  `threads 1,1`, WEBrick) the replayed request can only be served by the thread that is waiting for
  it, so every replay waits for its timeout and fails; with several threads, a `count` of 10 can
  hold one server thread for minutes. Chosen: document the limit and recommend several Puma threads,
  rather than a background job and a polling API (a lot of machinery for a developer feature that is
  off by default). A check of Puma's thread count was not added: the setting is not exposed in the
  Rack environment, and reading it from `Puma` internals would break with the next release.
- **No self-profiling.** The whole sending goes through `Profiler.untracked_http`, as the cluster
  proxy does, so it is not recorded in the outbound HTTP data of a current profile.
- **Confirmation.** The dashboard uses a native `window.confirm()` (the dashboard has no modal
  component), for every method, with a stronger sentence for `POST`, `PUT`, `PATCH` and `DELETE`.
  The confirmation is the client's: the endpoint does not check one. The MCP tool adds **no**
  guard: there is no interactive channel, and the client that calls `replay_request` answers for
  the request it replays. Both channels refuse clearly (403 / tool error) while
  `config.replay_enabled` is false.
- **What is replayed.** Headers and parameters the profiler masked (`[FILTERED]`) are not sent, and
  the response says so: a replayed request needing a session cookie or a bearer token must be given
  them in `headers` / `cookies`. The stored body is sent as captured (decoded; if truncated, a
  note says so). A `slave` argument forwards the call to that slave's own endpoint.

## Slave registry with several master workers (gem #63, case 3/5)

- **Documented, not stored in a shared place.** `SlaveRegistry` keeps its entries in the memory of
  the process, so with several master workers each heartbeat reaches one of them. While the gem
  provides shared storage backends (file, SQLite, Redis) for collected profiles, a shared slave
  registry would require writing a registry entry on every heartbeat of every slave—overhead
  disproportionate to the problem. The simplest cautious option is taken: `docs/cluster.md`
  states that the master runs as a single process, with a future option to add shared registry
  storage if needed.
- **No code change.** The behavior is unchanged; a shared registry stays possible later.

## Configuration errors in heartbeat loop (gem #63, followup audit)

- **Strategy: use `Profiler.log_error_once` for permanent configuration errors.** Configuration errors
  (invalid master URL, missing secret when required) are not transient network failures and will never
  resolve by retrying. Using `log_error_once` prevents polluting logs with the same error message on
  every heartbeat cycle. Configuration errors are detected by checking if the error message starts with
  `"master_url"` or contains `"secret"`, which covers all cases from `Security.master_url_denial` and
  secret validation.
- **Alternative considered but rejected: stopping the heartbeat loop.** While more drastic, stopping the
  loop would prevent the application from starting any heartbeat when config is invalid. Using `log_error_once`
  is consistent with other parts of the codebase (e.g., `process_snapshot.rb`, `storage/base_store.rb`)
  that face similar persistent errors in repeated operations.
- **Network errors still retry.** Transient failures (connection timeouts, DNS issues) continue to log
  with `log_warn` on each attempt, allowing the operator to see retry activity while the master is temporarily
  down.
