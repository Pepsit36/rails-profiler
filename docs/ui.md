# UI Guide

The Rails Profiler injects a debug toolbar into every HTML page and provides a web dashboard, at
`/_profiler`, to inspect past requests, background jobs, console expressions and tests in detail.
Every screenshot of this guide comes from the same fictitious application; see
[screenshots/README.md](screenshots/README.md) to regenerate them.

- [Toolbar](#toolbar)
- [Profiler Selector (Cluster)](#profiler-selector-cluster)
- [Profile List](#profile-list)
- [Profile Dashboard](#profile-dashboard): [Request](#request-tab), [Dump](#dump-tab),
  [Database](#database-tab), [AJAX](#ajax-tab), [Outbound HTTP](#outbound-http-tab),
  [Timeline](#timeline-tab-flame-graph), [Views](#views-tab), [Cache](#cache-tab),
  [Logs](#logs-tab), [Routes](#routes-tab), [I18n](#i18n-tab), [Jobs](#jobs-tab),
  [Mailers](#mailers-tab), [Env](#env-tab), [Exception](#exception-tab)
- [Background Jobs](#background-jobs)
- [Console Profiles](#console-profiles)
- [Test Profiles](#test-profiles) and the [Test Runner](#test-runner)
- [Outbound HTTP and Env sections](#outbound-http-and-env-sections)

## Toolbar

![Toolbar](screenshots/toolbar.png)

The toolbar appears as a fixed bar at the bottom of every profiled HTML page. It shows key metrics
for the current request at a glance; hovering an item opens a panel with the details, and
clicking it opens the matching tab of the profile. An item only appears when its collector has
something to show.

| Item | Shows |
|------|-------|
| **Method and status** | Green (2xx) / Yellow (3xx) / Red (4xx and 5xx) |
| **Duration** | Green (under 100 ms) / Yellow (under 500 ms) / Red (500 ms or more); the panel adds allocations and start time |
| **DB** | Query count, slow queries (▲) and total SQL time |
| **XHR** | AJAX requests made by the page after it loaded, and their total time |
| **EVT** | Timeline events |
| **VIEW** | Templates rendered, and partials |
| **CACHE** | Hit rate |
| **HTTP** | Outbound HTTP requests, slow ones flagged |
| **DUMP** | Number of `Profiler.dump()` calls |
| **LOG** | Log lines, red when one is an error, yellow for a warning |
| **💥** | The class of the exception the request raised |
| **ROUTE** | The matched route |
| **I18N** | Translation lookups, missing keys flagged |
| **JOB** | Jobs the request enqueued, red when one failed |
| **MAIL** | Mails sent, queued with `deliver_later`, or failed |
| **ENV** | Number of `ENV` variables |

The **Profiler** link at the right opens the profile list at `/_profiler`; the arrow beside it
collapses the toolbar, which stays collapsed on the next pages (the choice is kept in
`localStorage`).

The toolbar updates itself when its profile is saved again after the page was sent, for instance
when an outgoing HTTP request started in a background thread finishes, or when the page makes
AJAX requests. It checks with short requests, often at first and then every 30 seconds, not while
the tab is hidden, and stops after 10 minutes without a change; see
[Performance](performance.md).

---

## Profiler Selector (Cluster)

![The profile list of a slave, read through the master](screenshots/cluster-selector.png)

When the master profiler has slave instances connected, a **Profiler** dropdown appears at the
top of the `/_profiler` interface.

- **Local (master)**: shows profiles captured by the current instance (default)
- **\<slave name\>**: proxies all data through the master to the selected slave; the rest of the
  UI is identical, and "Viewing slave data via proxy" reminds you of it

Selecting a slave updates all profile lists, detail views, and actions so they operate on the
slave's data. The selection is remembered for the current browser session (sessionStorage).

Slaves appear as `(offline)` and cannot be selected if their last heartbeat is older than
`cluster_offline_threshold` (60 seconds by default). Setting up a cluster: [Cluster](cluster.md).

---

## Profile List

![Profile list](screenshots/profile-list.png)

Navigate to `/_profiler` to see all recorded profiles. The list is split into sections:

- **HTTP Requests**: regular web requests
- **Background Jobs**: Sidekiq and ActiveJob executions (see [Background Jobs](#background-jobs))
- **Console**: expressions evaluated in `rails console` (see [Console Profiles](#console-profiles))
- **Tests**: one profile per RSpec or Minitest example (see [Test Profiles](#test-profiles))
- **Test Runner**: runs your tests from the browser (see [Test Runner](#test-runner))
- **Outbound HTTP** and **Env**: see [Outbound HTTP and Env sections](#outbound-http-and-env-sections)

The section is kept in the URL (`/_profiler?section=jobs`), and so are the filters and the sort.

### Filters

- **Quick presets**: Slow, Many queries, Errors, Has exception
- **Search**: filter by path substring
- **Method**: GET, POST, PUT, PATCH, DELETE
- **Status**: 2xx, 3xx, 4xx, 5xx
- **Duration**: under 100 ms, 100 ms or more, 500 ms or more

### Columns

| Column | Description |
|--------|-------------|
| Time | Request timestamp |
| Method | HTTP verb badge |
| Path | Clickable link to profile detail |
| Duration | Color-coded response time |
| Queries | SQL query count |
| Allocations | Objects allocated while the request ran, by the whole process (other threads included on a multi-threaded server) |
| Status | HTTP status badge |
| Token | Unique profile identifier (click to copy) |

Column headers marked with ⇅ are sortable. **Clear** deletes the profiles of the section, **Clear
All** every profile, and ↺ reloads the list.

---

## Profile Dashboard

Clicking any row opens the **Profile Details** view with a tabbed interface. The header always
shows `METHOD PATH`, duration, status, allocations, start time and the version of the gem that
recorded the profile. Request, Dump, Database, Timeline, Views, Cache and Env are always there;
the other tabs appear only when the request has something to show in them. When the request
raised, the Exception tab comes first and opens by default.

### Request tab

![Request tab](screenshots/tab-request.png)

Shows the full HTTP context:

- **Path, Method, Status, Duration**: core request metadata
- **Controller#Action**: the Rails controller and action that handled it
- **Route Name & Pattern**: matched named route and URL pattern
- **Request Headers**: filtered list of relevant headers
- **Response Headers**: full response header set
- **Response Body**: raw body (compressed bodies are decoded automatically)
- **Copy URL** and **Copy as cURL**: replay the request from a terminal

Sensitive headers and parameters are already masked in the stored profile; see
[Sensitive data](security.md#sensitive-data).

---

### Dump tab

![Dump tab](screenshots/tab-dump.png)

Shows all variables captured via `Profiler.dump()` during the request, in call order.

Each entry displays:
- **Number**: call order (#1, #2, ...)
- **Label**: optional human-readable label
- **File:line**: exact source location
- **Timestamp**: when the dump was captured
- **Value**: pretty-printed Ruby object

**Usage in code:**
```ruby
# Basic dump
Profiler.dump(@user)

# With a label
Profiler.dump(@posts, "Posts for current page")

# Chainable: returns the value
user = Profiler.dump(User.find(params[:id]), "Current user")
```

---

### Database tab

![Database tab](screenshots/tab-database.png)

Displays all SQL queries executed during the request:

- **Summary**: total count, total duration, slow query count, cached query count
- **N+1 detection**: automatic warning when the same parameterized query is repeated 3 times or
  more, with the pattern highlighted and grouped, and the call stack behind ▾ backtrace
- **Query list**: each query shows:
  - Number, model name, execution time (color-coded)
  - SQL, with the bind values replaced by `?`
  - **N+1** badge when part of a detected pattern
  - **Explain** button: shows the query plan inline

Slow queries (above `slow_query_threshold`, default 100 ms) are highlighted in red.

The **Explain** button only explains read-only queries, in a transaction always rolled back; any
other query is refused with the reason. See [Explaining a query](usage.md#explaining-a-query).

---

### AJAX tab

![AJAX tab](screenshots/tab-ajax.png)

Lists the requests the page made with `fetch()` or `XMLHttpRequest` after it loaded. With
`config.track_ajax = true` (the default), the profiler adds a small script to each profiled page;
it reads the `X-Profiler-Token` header of every answer and links that profile to the page
(`POST /_profiler/api/ajax/link`). The profiler's own `/_profiler` requests are left out.

- **Summary**: number of requests, total and average duration
- **By Method** and **By Status**: counts per HTTP verb and per status class
- **Requests**: method, path, status, duration and time of each one, with **View Profile** to
  open its own profile

The tab is computed when the page is shown, from the requests linked to it, so it appears as soon
as one is linked, after the page itself was saved. The jobs a page enqueued are listed in the
[Jobs tab](#jobs-tab), not here. The MCP tool `get_profile_ajax` returns the same list.

---

### Outbound HTTP tab

![Outbound HTTP tab](screenshots/tab-http.png)

Tracks all outbound HTTP calls made via `Net::HTTP` (so Faraday, RestClient, HTTParty and the like):

- **Summary**: total count, total duration, average duration, slow count (above
  `slow_http_threshold`, 500 ms by default), error count
- **By Host**: request count grouped by domain
- **By Status**: count grouped by HTTP status class (2xx, 3xx, 4xx, 5xx)
- **Requests**: a waterfall of the calls on the request's time line, then each call with its
  method, URL, status, duration and sizes; click one to expand its headers and bodies

---

### Timeline tab (Flame Graph)

![Timeline tab](screenshots/tab-flamegraph.png)

A hierarchical flame graph of all instrumented events during the request:

- **Summary chips**: total events, total duration, count per category
- **Legend**: Controller, View, Partial, SQL, Cache, HTTP, Custom, Method
- **Interactive canvas**:
  - Click a block to zoom in
  - Scroll to zoom in/out
  - Drag to pan
  - Hover for tooltip with name, duration, and payload
- **Search** (Ctrl+F): highlight matching events across the graph
- **Breadcrumbs**: navigation trail when zoomed in

**Custom instrumentation** via `Profiler.measure()`:
```ruby
result = Profiler.measure("payment.stripe_charge", metadata: { amount: 1000 }) do
  Stripe::Charge.create(amount: 1000, currency: "usd")
end
```

Custom events appear nested at the correct position in the hierarchy.

**Function profiling**, below the flame graph, shows the Ruby methods the request spent its time
in, as a second flame graph and a table: functions, samples or calls, wall and CPU time, and the
share of garbage collection. Its controls change the settings of the process that serves the
page: **Full** or **Lite** mode, the **Wall**, **CPU** or **Alloc** clock of lite mode, the
maximum number of frames, and on or off. Lite mode needs the `stackprof` gem in the application's
`Gemfile`; without it the section says so. See [Configuration](configuration.md#function-profiling)
and what each mode costs in [Performance](performance.md#function-profiling).

---

### Views tab

![Views tab](screenshots/tab-views.png)

Shows template and partial rendering:

- **Summary**: view count, partial count, total render duration
- **Templates**: each rendered template with its file path and duration
- **Partials**: each rendered partial with its file path and duration

Duration badges are color-coded: green (under 10 ms), yellow (under 50 ms), red (50 ms or more).
A collection rendered with `render partial: ..., collection: ...` is one Action View event of its
own, which this tab does not count as partials.

---

### Cache tab

![Cache tab](screenshots/tab-cache.png)

Monitors all Rails cache operations:

- **Summary**: read count, write count, delete count, hit rate %
- **Cache Reads**: each key with HIT/MISS badge and duration
- **Cache Writes**: each key written with duration
- **Cache Deletes**: each key deleted

Hit rate is color-coded: green (80% or more), yellow (50% or more), red (under 50%).

---

### Logs tab

![Logs tab](screenshots/tab-logs.png)

Captures the log output generated during the request, up to `max_captured_log_bytes` (1 MB by
default; past it, the tab ends with the number of lines left out):

- **Summary**: error count, warning count
- **Level filter**: ALL, DEBUG, INFO, WARN, ERROR, FATAL
- **Search**: filter the messages by substring
- **Log entries**: timestamp, level badge (color-coded), message

---

### Routes tab

![Routes tab](screenshots/tab-routes.png)

Shows the routes registered in the Rails app:

- **Matched route**: verb, pattern, route name and controller#action
- **All routes**: HTTP verb, URL pattern, controller#action, route name

The profile keeps only the route its request matched. The table is the one of the process that
serves the page, as it is now (rebuilt when the routes are reloaded in development).

---

### I18n tab

![I18n tab](screenshots/tab-i18n.png)

Tracks all translation lookups during the request:

- **Summary**: locale, missing key count
- **Filter**: ALL / MISSING only
- **Table**: key, locale, resolved value, status (✓ found / ⚠ missing)

Missing keys are highlighted in red, which helps catch untranslated strings before they reach
production.

---

### Jobs tab

![Jobs tab](screenshots/tab-jobs.png)

Appears when the request enqueued background jobs (ActiveJob, Sidekiq), mails sent with
`deliver_later` included: class, queue, status, duration and time of each job, with **View Job**
to open its own profile (see [Background Jobs](#background-jobs)).

---

### Mailers tab

![Mailers tab](screenshots/tab-mailer.png)

Appears when the request delivered or queued mail through ActionMailer
(`config.track_mailers = true`, the default):

- **Summary**: total, `deliver_now` and `deliver_later` counts, mails queued, multi-part mails,
  errors
- **Send loop warning**: the same mailer action called more than three times in one request
- **Emails**: one row per mail (mailer class, action, subject, delivery mode, render time, sent or
  error); click it to expand subject, recipients (To, From, CC, BCC, Reply-To), template, parts,
  attachments, render and delivery times, Message-ID, the mailer's instance variables and the
  body
- **Body**: HTML preview (in a sandboxed frame, without scripts), HTML source or plain text, only
  with `config.capture_mail_body = true`; otherwise the row says how to turn it on
- **Queued**: mails enqueued with `deliver_later` during the request, sent later by a job
- **Delivery Errors**: mails whose delivery raised

Only the first 50 mails of a request are kept, and the tab says so when there were more.
`config.sanitize_mailer_recipients = true` masks the addresses, and
`config.mailer_skip_actions` leaves mailers or actions out (see [Usage](usage.md#mailers)). The MCP
tools `get_profile_mailers` and `query_mailers` read the same data.

---

### Env tab

![Env tab](screenshots/tab-env.png)

Lists the `ENV` variables, grouped by prefix, with a filter on names and values. Values outside
`config.env_allowlist`, and any value whose name matches the filter of sensitive data, are
`[FILTERED]` on the server; the eye icons only hide or show values on screen. **Export** saves
the variables as a `.env` file.

The Env tab of an HTTP profile shows the current `ENV` of the process that serves the page, not
the `ENV` as it was during the request (the hint above the table says "Snapshot taken at request
time", which is only true of jobs, console expressions and tests). The profile of a job, a console
expression or a test keeps the `ENV` of the process it ran in. To change variables, use the
[Env section](#outbound-http-and-env-sections).

---

### Exception tab

![Exception tab](screenshots/tab-exception.png)

Appears, first and selected, when an exception occurred during the request:

- **Exception class** and message (highlighted in red)
- **Application Frames**: only frames from your application code
- **Full Backtrace**: complete stack trace

---

## Background Jobs

![Background jobs list](screenshots/profile-list-jobs.png)

Background jobs (Sidekiq, ActiveJob) are profiled separately and appear under the **Background
Jobs** section of the profile list, with their class, queue, duration, status and executions,
filters on class, status and duration. A job profile names, in its header, the request or the
job that enqueued it, with a link to it, and opens on a **Job** tab (class, job ID, queue,
executions, status, arguments, error of a failed job), next to Database, Cache, Timeline and Env,
and, when the job has something to show in them, Outbound HTTP, Jobs (the jobs it enqueued in
turn), Dumps, Logs, Mailers and Exception. See [Usage](usage.md#background-jobs).

---

## Console Profiles

Expressions evaluated in `rails console` are profiled automatically when `track_console: true`
(default) and appear under the **Console** section.

### Columns

| Column | Description |
|--------|-------------|
| Time | When the expression was evaluated |
| Expression | The Ruby expression (truncated to 60 chars) |
| Duration | Evaluation time, color-coded |
| SQL | Number of SQL queries executed |
| Status | ✓ OK or ✗ Error |
| Token | Unique profile identifier (click to copy) |

Column headers marked with ⇅ are sortable. The Expression column is filterable by substring; a
Status filter lets you show only errors or successes.

### Env overrides

Environment variable overrides set via the profiler UI or MCP tools are applied before each
expression evaluation, so changes take effect immediately in the open console without a restart.
They are applied only outside production and while the profiler is enabled, unless
`config.apply_env_overrides_when_disabled = true` (never in production); see
[Environment variable overrides](usage.md#environment-variable-overrides).

---

## Test Profiles

![Tests list](screenshots/profile-list-tests.png)

With test profiling set up (see [Tests](testing.md)), every example of a suite run from the
shell or from the [Test Runner](#test-runner) is listed under the **Tests** section: time, test
name, file, duration, query count, status and token, with a search on the test name and a
status filter (Passed, Failed, Pending).

![A test profile](screenshots/test-profile.png)

A test profile opens with its own tabs:

- **Test**: test name, status, file and line, framework, assertions (Minitest), skip reason and
  exception message
- **Database**, **Cache** and **Timeline**: as for a request, so an N+1 in a test shows the same
  way as in a page
- **Dumps** and **Logs**, when the test produced some, **Exception** when it raised, and **Env**

The MCP tools `query_test_profiles` and `get_test_profile`, and the resources
`profiler://slow-tests` and `profiler://failing-tests`, read the same profiles.

### Test Runner

![Test runner](screenshots/test-runner.png)

The **Test Runner** section (also at `/_profiler/test_runner`) runs your tests in the `test`
environment, from the browser:

- **RSpec** or **Minitest**, when the application has both
- **The file tree** of the discovered test files (`spec/**/*_spec.rb`, `test/**/*_test.rb`):
  tick files or whole directories, or **All** / **None**
- **▶ Run Selected** starts the run, **■ Stop** kills it
- **The output** of the run, with its colors, followed by the profiler's report (slowest tests,
  N+1 patterns), and **View in Profiler** to open the Tests section

Only discovered files can be run, and the environment of the test process follows the rules of
[Test runner](testing.md#test-runner). The MCP tool `run_tests` starts the same runs.

---

## Outbound HTTP and Env sections

**Outbound HTTP** lists the outgoing calls of every profile in one place, with a search on the URL
and filters on method and status; click a call to see its headers and bodies.

**Env** lists the `ENV` of the server process and changes it: set, delete or reset a variable,
reset all of them, or import a `.env` file. Changes are saved as overrides under `tmp_path` and
applied again at boot, before each job and before each console expression, with the rules of
[Environment variable overrides](usage.md#environment-variable-overrides). The MCP tools
`list_env_vars`, `set_env_var`, `delete_env_var`, `reset_env_var` and `reset_all_env_vars` do the
same.
