# Configuration

Every option of the profiler, where to set it and when it is read. The
[README](../README.md#configuration) has the short version.

- [Where options are set](#where-options-are-set)
- [Defaults that depend on the Rails environment](#defaults-that-depend-on-the-rails-environment)
- [All options](#all-options)
- [The profiler's own log messages](#the-profilers-own-log-messages)
- [Collectors](#collectors)
- [Function profiling](#function-profiling)
- [Custom collectors](#custom-collectors)
- [Rake tasks](#rake-tasks)
- [Clickable file:line links](#clickable-fileline-links)
- [Threshold alerts](#threshold-alerts)

## Where options are set

Most applications only need `config/initializers/profiler.rb`:

```ruby
Profiler.configure do |config|
  config.enabled = Rails.env.development?
end
```

Options can also be set with `Profiler.configure` in `config/application.rb` or in
`config/environments/*.rb`, or with `config.profiler.<option> = value` in
`config/application.rb`. From lowest to highest priority: the default, `Profiler.configure` in
`config/application.rb` or `config/environments`, `config.profiler`, then
`config/initializers`. A `config.profiler.<option>` that is not a profiler option is ignored,
with a warning in the log.

`enabled` is read once, at boot, after the application's `config/initializers` have run: with
`enabled = false` the profiler inserts no middleware and installs no Sidekiq, ActiveJob, test,
console or thread instrumentation, and with `enabled = true` in production it gets all of them. Setting it
to true on a running process does not insert the middleware nor install the instrumentation. That
includes the patch that carries the profiling context into new threads (`Thread#initialize`): the
railtie puts it in place at boot, only when `enabled`, so a disabled profiler leaves
`Thread#initialize` as Ruby defines it.

The engine routes the application mounts stay: while disabled, the API, the MCP mount and the
cluster endpoints answer `403`, or `404` when the MCP HTTP transport or `cluster_master` is off.
The engine's static assets (`/_profiler/assets/profiler-toolbar.js`, `profiler.js` and
`profiler.css`) are still served, to anyone: they hold no application data.

## Defaults that depend on the Rails environment

The railtie sets four options only when the application has not assigned them itself
(`lib/profiler/railtie.rb`, `Profiler::Configuration::RAILS_DEFAULTED`):

| Option | development, test | other environments |
|---|---|---|
| `enabled` | `true` | `false` |
| `storage` | `:file` | `:memory` |
| `track_tests` | `true` in test only | `false` |
| `max_profiles` | `nil` (no cap) in test, `100` in development | `100` |

## All options

The values shown are the defaults, unless the comment says otherwise.

```ruby
Profiler.configure do |config|
  # Master toggle: true in development and test, false elsewhere (see above).
  config.enabled = Rails.env.development?

  # Storage backend: :file in development and test, :memory elsewhere; also :redis and
  # :sqlite. Each backend has its own options: see docs/storage.md.
  config.storage = :file
  config.storage_options = {}
  # How many profiles a store keeps, the oldest evicted first (nil: no cap on the count).
  config.max_profiles = 100
  # Where the file store, the SQLite store, the MCP cache and the env overrides live.
  config.tmp_path = Rails.root.join("tmp", "rails-profiler")
  # Directories 0700 and files 0600 under tmp_path, whatever the umask.
  config.restrict_storage_permissions = true

  # Requests that are not profiled: a Regexp is matched against the path, a String is compared
  # with the whole path ("/up" skips /up, not /up/details). A single pattern is a list of one.
  config.skip_paths = [%r{^/_profiler}, /\.well-known/, /favicon\.ico/, /manifest\.json/]

  # Database
  config.slow_query_threshold = 100  # ms
  config.max_queries_warning = 50
  # Where each query comes from: the first run of each statement and every slow query
  # (:first_and_slow), every query (:all, about 0.1 ms each, as earlier versions did), or none (:none).
  config.sql_backtrace = :first_and_slow

  # Objects allocated while the request, job, command or test ran (see docs/performance.md).
  config.track_memory = true
  # No effect yet: nothing compares a profile with it. Replaces memory_warning_threshold,
  # still accepted (deprecated) and read as this number times 40.
  config.allocated_objects_warning_threshold = 2_621_440

  # Request and response bodies kept in a profile stop at this size; the application still
  # reads and sends every byte. nil keeps whole bodies, as earlier versions did.
  config.max_captured_body_bytes = 256.kilobytes
  # What a profile keeps of the lines its request logs; past it, the Logs tab says how many
  # lines were left out. nil keeps every line, as earlier versions did.
  config.max_captured_log_bytes = 1.megabyte
  # Text bodies larger than the threshold are stored gzip+base64 and decompressed only when a
  # profile is shown. false stores them as text.
  config.compress_bodies = true
  config.compress_body_threshold = 10.kilobytes

  # Sensitive data, masked before a profile is stored (see docs/security.md#sensitive-data).
  config.redact_sensitive_data = true
  config.filter_parameters += [:iban]       # added to Rails' config.filter_parameters
  config.env_allowlist += %w[APP_VERSION]   # ENV variables whose values are shown

  # Outbound HTTP (Net::HTTP, so Faraday, RestClient, HTTParty...)
  config.track_http = true
  config.slow_http_threshold = 500  # ms
  config.http_backtrace_depth = 40
  # Hosts whose calls are left out. A String is a host name, compared whole and ignoring case
  # ("example.com" leaves out example.com, not api.example.com nor notexample.com); one that
  # starts with a dot is a domain, whose subdomains are left out (".internal" leaves out
  # api.internal, not internal itself). A Regexp is matched against the host name. An entry
  # that is none of these (a wildcard "*.internal", an empty String, nil) is left out with a
  # warning in the log; the application still boots. Empty by default: calls to services on the
  # same machine are recorded. Earlier versions always left out 127.0.0.1, localhost and ::1; to
  # do so again:
  #   config.http_skip_hosts += Profiler::Configuration::LOCAL_HTTP_HOSTS
  # The profiler's own calls (a slave's registration and heartbeats, the master's requests to
  # its slaves) are never recorded, whatever this list says.
  config.http_skip_hosts = []

  # OpenTelemetry export (traces). Off by default: with false nothing of OpenTelemetry is loaded.
  # The gem does not depend on it. To turn it on, add the SDK to the application's own Gemfile
  # (`gem "opentelemetry-sdk"` and `gem "opentelemetry-exporter-otlp"`), then:
  #   config.otel_enabled = true
  # Each profiled request becomes a trace: a root span carrying the profile's trace_id and span_id,
  # and a child span per SQL query, view or partial, cache operation and outbound Net::HTTP call.
  # If the application already initialised OpenTelemetry (OpenTelemetry::SDK.configure), its tracer
  # provider is reused and nothing else is needed; sampling and the exporter are then its own.
  # Otherwise the gem sends the spans itself, over OTLP http/protobuf, to otel_otlp_endpoint (or
  # the standard OTEL_EXPORTER_OTLP_(TRACES_)ENDPOINT variable). The gem has no sampling option:
  # leave it to the SDK or the collector.
  # Enabled without the opentelemetry gems, or without an endpoint when the gem has to send the
  # spans itself: one message in the log, no export, and the application is not affected.
  #
  # OpenTelemetry metrics, same opt-in (there is no separate option). EXPERIMENTAL: the metrics
  # SDK (opentelemetry-metrics-sdk) is alpha, its API changes from one release to the next, and
  # its maintainers recommend pinning an exact version. Turning metrics on means depending on an
  # alpha package: add `opentelemetry-metrics-api`, `opentelemetry-metrics-sdk` and
  # `opentelemetry-exporter-otlp-metrics` to the application's Gemfile, each with an exact
  # version (`gem "opentelemetry-metrics-sdk", "= 0.21.0"`, no `~>`), and review them on every
  # upgrade. This gem's specs run against metrics-api 0.10.0, metrics-sdk 0.21.0 and
  # exporter-otlp-metrics 0.14.0; no other version is tested. Without these gems, traces still
  # work and one message in the log says the metrics are off.
  # Each profiled request records, in milliseconds: histograms `profiler.request.duration`,
  # `profiler.db.query.duration`, `profiler.view.render.duration`,
  # `profiler.cache.operation.duration` and `profiler.http.client.request.duration` (outbound
  # Net::HTTP), and counters `profiler.request.allocations` (objects allocated, only when
  # config.track_memory is on) and `profiler.request.n_plus_one` (requests that ran an N+1: one
  # SQL query, constants normalized, repeated within the request; +1 per such request). Attributes
  # are few on purpose: `profiler.controller_action` ("unknown" when no route matched),
  # `http.request.method`, `http.response.status_code` (request duration only), `db.operation.name`
  # (SELECT, INSERT, UPDATE, DELETE or OTHER) and `cache.operation`. Never a profile token, URL,
  # SQL text or cache key. The application's own MeterProvider is reused when it has one;
  # otherwise the gem exports over OTLP http/protobuf to otel_otlp_endpoint (a `/v1/traces` path
  # is read as `/v1/metrics`) or the OTEL_EXPORTER_OTLP_(METRICS_)ENDPOINT variable, every 60 s
  # (OTEL_METRIC_EXPORT_INTERVAL).
  config.otel_enabled = false
  config.otel_service_name = nil     # default: the application's name
  config.otel_otlp_endpoint = nil    # e.g. "http://localhost:4318/v1/traces"; no default

  # Collector circuit breaker: a collector class whose subscribe or collect raises this many
  # times in a row is no longer run. After 60 seconds one request tries it again: a success
  # closes the circuit, a failure opens it for another 60 seconds. The state of each collector
  # is at /_profiler/health (HTML, or JSON with /_profiler/health.json). With false, nothing is
  # counted and no collector is stopped. A collector whose subscribe raises is left out of the
  # request whatever this says, the others keep profiling it.
  config.collector_circuit_breaker_enabled = true
  config.collector_circuit_breaker_threshold = 3

  # AJAX: a script in each profiled page links its fetch() and XMLHttpRequest calls to it.
  config.track_ajax = true

  # Background jobs (ActiveJob, Sidekiq), rails console expressions
  config.track_jobs = true
  config.track_console = true

  # Mailers
  config.track_mailers = true
  config.capture_mail_body = false          # HTML and text bodies, cut at 100 KB each
  config.sanitize_mailer_recipients = false # mask the recipients in the Mailers tab
  config.mailer_skip_actions = []           # "UserMailer#welcome" or "UserMailer"

  # Tests (see docs/testing.md): true in the test environment, false elsewhere.
  config.track_tests = Rails.env.test?
  # The test runner only runs the discovered test files; true allows any file under Rails.root.
  config.test_runner_allow_undiscovered_files = false
  # Stop sends TERM to the test process group, then KILL this many seconds later.
  config.test_runner_kill_grace_seconds = 5
  # Output kept per run (beginning and end, with a marker), and runs at a time. nil for no limit.
  config.test_runner_max_output_bytes = 5 * 1024 * 1024
  config.test_runner_max_active_runs = 2

  # Explain only runs in the development and test environments, even with enabled = true
  # elsewhere; true allows it in every environment. See docs/usage.md#explaining-a-query.
  config.allow_explain_outside_development = false

  # Apply the env overrides saved from the UI or MCP even while `enabled` is false
  # (never in production, whatever this says). See docs/usage.md#environment-variable-overrides.
  config.apply_env_overrides_when_disabled = false

  # Access control (see docs/security.md)
  config.authorization_mode = :allow_local  # or :allow_authorized, or :allow_all
  config.authorize_with do |request|        # used by :allow_authorized
    request.session[:admin] == true
  end
  config.api_forgery_protection = true
  config.extension_cors_enabled = false     # CORS headers on profiler responses
  config.cors_allowed_origins = []          # origins named in them, when enabled
  config.frame_ancestors = ["'self'", "chrome-extension:", "devtools:"]

  # MCP server (see docs/mcp.md). The stdio transport (rake profiler:mcp) needs neither
  # option; :http routes /_profiler/mcp, only when mcp_enabled is true as well.
  config.mcp_enabled = false
  config.mcp_transport = :stdio
  config.mcp_allowed_hosts = []             # Host names the HTTP transport accepts, beyond config.hosts
  config.mcp_read_only = false              # true leaves out the write tools (run_tests, clear_profiles,
                                            # set/delete/reset_env_var, reset_all_env_vars); see docs/mcp.md#read-only-mode

  # Cluster (see docs/cluster.md)
  config.name = nil                         # display name; the application's name by default
  config.cluster_master = false
  config.cluster_secret = nil
  config.cluster_allowed_slave_urls = []
  config.master_url = nil                   # set on a slave only
  config.self_url = nil                     # set on a slave only
  config.cluster_heartbeat_interval = 15    # seconds
  config.cluster_offline_threshold = 60     # seconds
  config.cluster_require_secret = true
  config.cluster_allow_insecure_http = false

  # Replaying a profiled request (see "Replaying a request" in the README). Off by default: a
  # replay sends a real request. It goes to the captured host name on the port the application
  # server really listened on (SERVER_PORT), never to the port written in the Host header.
  config.replay_enabled = false
  config.replay_max_count = 10              # most replays one call may ask for
  config.replay_timeout = 30                # seconds to wait for each replay

  # Where the profiler's own errors and warnings go (see below).
  config.logger = nil
end
```

Two options are still accepted and stored, but nothing reads them as of 0.32.1:
`config.mcp_port` (3001; the HTTP transport answers on the application's own port, under
`/_profiler/mcp`) and `config.ajax_skip_paths` (the AJAX script skips the profiler's own
`/_profiler` requests, and no other path).

## The profiler's own log messages

The profiler's own messages (a profile it could not save, a collector that failed, a cluster
node it cannot reach) go to the application's log: `config.logger` when it is set, read on each
message, otherwise `Rails.logger`, otherwise `$stderr` when there is no logger yet (early in the
boot, or outside Rails). Each line starts with `[Profiler]`, the cluster secret is masked in it,
and an error message is cut at 1,000 bytes after masking. A failure the profiler meets again and
again (a store read on every poll) is logged once per place and error class for the life of the
process. These lines are not recorded in the Logs tab of the request during which they are
written. A logger that raises never fails a request, a job or the boot: the line then goes to
`$stderr`. Earlier versions wrote most of these messages to `$stderr`; to keep them there, set
`config.logger = Logger.new($stderr)`.

## Collectors

Each tab of a profile is filled by a collector, a class under `lib/profiler/collectors/`. The
railtie gives an HTTP request these 14, in this order, unless the application sets
`config.collectors` itself (`lib/profiler/railtie.rb`):

`ExceptionCollector`, `RequestCollector`, `DumpCollector`, `DatabaseCollector`,
`ViewCollector`, `CacheCollector`, `HttpCollector`, `FlameGraphCollector`,
`FunctionProfilerCollector`, `LogCollector`, `RoutesCollector`, `I18nCollector`,
`EnvCollector`, `MailerCollector`.

To keep fewer of them:

```ruby
config.collectors = [
  Profiler::Collectors::RequestCollector,
  Profiler::Collectors::DatabaseCollector,
  Profiler::Collectors::FlameGraphCollector,
  Profiler::Collectors::ViewCollector,
  Profiler::Collectors::CacheCollector,
  Profiler::Collectors::LogCollector,
]
```

Four more collectors do not belong to that list:

- `AjaxCollector`: the sub-requests of a page are saved after it, so the AJAX tab is computed
  when the page is shown, from the requests linked to it, and appears when there is at least
  one. The jobs a page enqueued are listed under its child jobs, not counted as AJAX requests.
- `JobCollector`, `ConsoleCollector` and `TestCollector` describe a job, a console expression
  and a test. The job, console and test profilers run them with a fixed set of the collectors
  above (`lib/profiler/job_profiler.rb`, `console_profiler.rb`, `test_profiler.rb`), whatever
  `config.collectors` says.

## Function profiling

`FunctionProfilerCollector` records which Ruby methods the request spent its time in, shown under
the flame graph of the Timeline tab. It is set on the `Profiler` module rather than in
`Profiler.configure`, and the Timeline tab changes the same settings at runtime, for the process
that serves it (`PATCH /_profiler/api/function_profiling`):

```ruby
# config/initializers/profiler.rb, the defaults
Profiler.function_profiling_enabled = true
Profiler.function_profiling_mode = "lite"   # "lite": sampling with stackprof; "full": TracePoint
Profiler.function_profiling_clock = "wall"  # lite mode: "wall", "cpu" or "object"
Profiler.function_profiling_max_frames = 2000
Profiler.function_profiling_tracepoint_fallback = false
```

Lite mode needs the `stackprof` gem, which the profiler does not depend on: add it to the
application's `Gemfile` (`gem "stackprof", require: false` is enough, the collector requires it
itself). Without it, lite mode stays off and the tab says why, unless
`function_profiling_tracepoint_fallback` is true, which traces every method call of the request's
thread instead. Full mode always traces every method call of the request's thread with a `TracePoint`, and adds
allocations and memory bytes per method. What each mode costs: see [Performance](performance.md#function-profiling).

## Custom collectors

A collector subclasses `Profiler::Collectors::BaseCollector`, subscribes to the events it needs,
stores its data in the profile and releases what it installed:

```ruby
class MyCollector < Profiler::Collectors::BaseCollector
  def icon = "🔧"
  def priority = 100  # lower = earlier in tab list

  def subscribe
    @subscription = ActiveSupport::Notifications.monotonic_subscribe("my.event") do |name, started, finished, id, payload|
      @events ||= []
      @events << { name: name, duration: (finished - started) * 1000 }
    end
  end

  # Called after collect, and also when the request raises before collect runs.
  # Release everything subscribe installed; calling it twice must be harmless.
  def unsubscribe
    ActiveSupport::Notifications.unsubscribe(@subscription) if @subscription
    @subscription = nil
  end

  def collect
    store_data({ event_count: @events&.size || 0, events: @events || [] })
  end

  def toolbar_summary
    { text: "#{@events&.size || 0} events", color: "blue" }
  end
end

Profiler.configure do |config|
  config.collectors << MyCollector
end
```

What it stores is saved with the profile, under `collectors_data["my"]` (the class name without
`Collector`, lower case), and returned by `GET /_profiler/api/profiles/:id`. As of 0.32.1 the
dashboard and the toolbar have a fixed set of tabs and items: they show no tab for a custom
collector.

## Rake tasks

```bash
bundle exec rake profiler:list                      # recent profiles (LIMIT=20)
bundle exec rake profiler:show TOKEN=abc123...      # one profile
bundle exec rake profiler:cleanup OLDER_THAN=86400  # remove profiles older than this, in seconds
bundle exec rake profiler:mcp                       # MCP server, stdio transport (MCP_TRANSPORT overrides it)
```

`OLDER_THAN` and `LIMIT` take a whole number (seconds for `OLDER_THAN`, 86400 when it is not set).
Any other value, an empty one included, stops the task with an error and removes nothing:
`OLDER_THAN=0` removes every profile, and only when written so.

## Clickable `file:line` links

Wherever the dashboard shows a file and a line, it is a link that opens the file in your editor
at that line.

```ruby
Profiler.configure do |config|
  config.editor_url_scheme = :vscode            # :vscode (default), :idea or :cursor
  config.editor_path_map   = { "/app" => "/home/me/project" }  # container path => host path
end
```

### `editor_url_scheme`

| Value    | URL built for `/home/me/project/app/models/user.rb`, line 12                |
|----------|-----------------------------------------------------------------------------|
| `vscode` | `vscode://file/home/me/project/app/models/user.rb:12`                        |
| `cursor` | `cursor://file/home/me/project/app/models/user.rb:12`                        |
| `idea`   | `idea://open?file=%2Fhome%2Fme%2Fproject%2Fapp%2Fmodels%2Fuser.rb&line=12`   |

Only these three schemes exist. Any other value (a typo, `javascript`, a custom scheme) is kept in
the configuration but produces no link: the file and line stay plain text. `nil` turns the links
off. Paths are escaped in the URLs (`encodeURIComponent`, per segment for `vscode` and `cursor`).
A relative path, or a line below 1, is never linked.

### `editor_path_map`

For a server running in a container while the editor runs on the host. Keys are path prefixes as
the server sees them, values the same prefixes on the host. The longest matching prefix is replaced,
on a path segment boundary (`/app` matches `/app/x.rb`, not `/application/x.rb`), before the URL is
built. A path no entry matches is used as it is. With `{ "/app" => "/home/me/project" }`,
`/app/models/user.rb` opens `/home/me/project/models/user.rb`.

### Where the links appear

- Database tab: backtrace of each N+1 group
- Http tab: backtrace of an outbound request, and the first frame in the card header
- Exception tab: application frames and the full backtrace
- Dumps tab (dashboard) and Dumps panel (toolbar): where each variable was dumped
- Flame graph tab: file and line of each function in the function profiling table
- Test tab: test file and line

### Reading the settings from the API

`GET /_profiler/api/config` (same access rules as the rest of the API) returns:

```json
{ "editor_url_scheme": "vscode", "editor_path_map": { "/app": "/home/me/project" } }
```

`editor_url_scheme` is `null` when the configured scheme is not in the allow list.

## Threshold alerts

Off by default. Nothing is checked, called or sent unless `config.alerts_enabled` is `true`.

```ruby
Profiler.configure do |config|
  config.alerts_enabled = true

  # Optional: a block called for each detection with the alert (a Hash, shape below).
  config.on_detection do |alert|
    Rails.logger.warn("[alert] #{alert[:type]} #{alert[:path]} #{alert[:value]}#{alert[:unit]}")
  end

  # Optional: a generic JSON webhook, off while no URL is set.
  # An absolute http(s) URL with a host; anything else raises ArgumentError at assignment. Credentials in
  # the URL (https://user:pass@...) are refused too: they are never sent, so put the secret in the path
  # or a query parameter of the receiver.
  config.alert_webhook_url = "https://alerts.example.com/profiler"
  config.alert_webhook_timeout = 3 # seconds, connection and answer (default 3)
end
```

Every profile saved is compared with thresholds the profiler already has:

| Alert `type`            | Fires when                                                              | Threshold option                          |
|-------------------------|-------------------------------------------------------------------------|-------------------------------------------|
| `slow_query`            | a query lasts more than the threshold (ms)                              | `slow_query_threshold`                    |
| `too_many_queries`      | the request runs more queries than the threshold                        | `max_queries_warning`                     |
| `excessive_allocations` | the request allocates more objects than the threshold                   | `allocated_objects_warning_threshold`     |
| `n_plus_one`            | at least one normalized SQL statement appears more than once            | none (`threshold` is always `1`)          |

The allocation alert reads `allocated_objects_warning_threshold`, not `memory_warning_threshold`:
the latter is deprecated (it is the former times 40, a figure that was never a byte count) and
logs a warning when assigned. A threshold set to `nil` disables its alert.

An N+1 uses the definition of `Profiler::MCP::Resources::N1Patterns.normalize_sql`: statements are
grouped once their literals are replaced with `?`.

### Alert payload

The hook receives this Hash (symbol keys); the webhook POSTs it as `application/json`
(`Content-Type: application/json`, string keys). One alert per type and per profile.

```json
{
  "type": "slow_query",
  "threshold": 100,
  "unit": "ms",
  "value": 250.5,
  "profile_token": "3f2c...32 hex characters",
  "method": "GET",
  "path": "/orders",
  "controller_action": "OrdersController#index",
  "status": 200,
  "detected_at": "2026-10-20T09:15:00Z"
}
```

- `type`: `slow_query`, `too_many_queries`, `excessive_allocations` or `n_plus_one`.
- `threshold`, `unit`, `value`: the limit crossed and the measured figure. Units: `ms` (value is
  the slowest query), `queries`, `objects`, `repeats` (value is the largest repeat count).
- `profile_token`: opens the profile in the dashboard (`/_profiler/profiles/<token>`).
- `controller_action`: `null` when the route is unknown. `path` carries no query string, and is `null`
  for a console profile: its path is the expression typed, which may hold a secret passed as a literal.
- `slow_query` adds `count` (number of slow queries) and `query`: `{ "sql", "fingerprint" }` for the slowest.
- `n_plus_one` adds `patterns`: up to 10 of `{ "sql", "fingerprint", "count" }`, the most repeated first.
- `sql` is the **normalized** statement (literals replaced with `?`, cut at 200 characters) and
  `fingerprint` the first 12 hex characters of its SHA-256.

No request or response body, no parameter and no header is ever in an alert. SQL literals are removed
before the statement is added: numbers, quoted strings (including a backslash escape or a doubled
quote), double quoted text, `/* */` and `--` comments and dollar-quoted bodies. When a statement cannot
be read with certainty (an unclosed quote, a backslash that standard SQL and MySQL read differently) it
is cut before the first quote or comment. A literal in a vendor syntax not listed here may still
remain, so do not treat the `sql` field as a guarantee for a database that has its own quoting forms;
`fingerprint` alone never carries text.

### Delivery

The detection itself, `on_detection` and the webhook all run on one worker thread, started with
`Profiler::Instrumentation::RequestContext.detached`, so it holds neither the request's
collectors nor its notification scope and its own HTTP call is not recorded in a profile. The
request never waits for it. Checks are queued (100 at most) and run one after the other: when the
queue is full, for instance behind a webhook that is slow or down, the check is dropped and logged
instead of starting more threads. A profile saved again later (a background outbound call that
finishes after the response) is not alerted again for a type already delivered. A hook that raises, an unreachable host, a timeout or a non 2xx answer
is logged with `Profiler.log_error` and never reaches the request. There is no retry.
To reach Slack or another service, point the URL at a relay that turns this JSON into the format
it expects.
