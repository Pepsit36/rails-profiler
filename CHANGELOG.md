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

- **Logging:** Send the profiler's own errors and warnings to the application's log instead of
  `$stderr`. A profile that could not be saved, a collector that failed, a store that could not be
  read, a cluster node out of reach: about thirty places wrote to `$stderr`, which is not where
  `log/development.log` is, so these errors went unseen. They now go through one entry point,
  `Profiler.log_error`, to `config.logger` when the application sets one (read on each message),
  otherwise `Rails.logger`, otherwise `$stderr`. Every line starts with `[Profiler]` (the cluster's
  lines, `[Profiler Cluster]` before, now start with `[Profiler] Cluster:`), carries the error's
  class and message, cut at 1,000 characters, and has the cluster secret masked. A logger that
  raises never fails a request, a job or the boot: the line then goes to `$stderr`. A slave whose
  `Rails.logger` was still nil raised instead of logging. Several failures that left no trace at
  all are now logged, once per place and error class: a store lookup or broadcast, the Redis
  version read of the toolbar, the MCP body cache, the mailer collector reading a mail, the route
  lookup of the Request tab, the deletion of a file profile. The request middleware saves its
  profiles through `Profiler.save_profile`, like jobs, console commands and tests, so a storage
  error no longer costs the page its toolbar.
- **Outbound HTTP:** Record the calls to services on the same machine. `127.0.0.1`, `localhost`
  and `::1` were always left out, so in development the calls to a neighbouring service never
  showed. `config.http_skip_hosts` is now the whole list, empty by default. The profiler's own
  calls are never recorded, whatever the list says: a slave's registration and heartbeats, and the
  master's requests to its slaves (the slave proxy, the fan-out of the profile pages and the MCP
  tools that query a slave), marked where they are made, and any call to the host and port of
  `config.master_url`.
- **Outbound HTTP:** Keep the bodies of outbound `Net::HTTP` calls to the first
  `config.max_captured_body_bytes`, sent and received, instead of copying them whole; a compressed
  answer is inflated only up to that size. A `body_stream` is read only when it can be put back
  where it was (a `StringIO`, a file), up to that size: a pipe or a socket was read whole and then
  sent empty, it is now sent unread and its body is not captured. The HTTP tab and the
  `get_profile_http` MCP tool say when a body was cut or not captured; each call carries
  `request_body_truncated`, `response_body_truncated` and `request_body_not_captured`.
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
  `[%r{\Ahttp://travel-api-[a-z0-9-]+:3000\z}]`. Until now such a setup had to fall back to
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
