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


