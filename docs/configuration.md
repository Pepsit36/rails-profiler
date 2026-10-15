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
`enabled = false` the profiler inserts no middleware and installs no Sidekiq, ActiveJob, test or
console instrumentation, and with `enabled = true` in production it gets all of them. Setting it
to true on a running process does not insert the middleware nor install the instrumentation. The
patch that carries the profiling context into new threads (`Thread#initialize`) is put in place
when the gem is loaded, whatever `enabled` says.

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
