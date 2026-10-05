# Rails Profiler

A comprehensive Rails profiler featuring a web debug toolbar, full profiling dashboard, SQL analysis, flame graph timeline, and an MCP server for AI-assisted debugging.

## Features

- **Web Debug Toolbar** — bottom-of-page bar showing real-time metrics on every HTML page
- **Profiler Dashboard** — full interface to inspect past requests with detailed per-tab analysis
- **Database Profiling** — SQL queries, execution time, N+1 detection, EXPLAIN ANALYZE
- **Flame Graph** — hierarchical timeline of all instrumented events (controller, view, SQL, cache, HTTP, custom)
- **View Rendering** — template and partial rendering times
- **Cache Monitoring** — hit/miss rates, reads, writes, deletes
- **Outbound HTTP Tracking** — external API calls via Net::HTTP
- **Log Capture** — Rails logger output per request with level filtering
- **I18n Tracking** — translation lookups and missing key detection
- **Background Jobs** — Sidekiq and ActiveJob profiling
- **Console Profiling** — profile expressions evaluated in `rails console` with env overrides applied before each evaluation
- **Test Profiling** — per-test SQL, cache, and exception capture for RSpec and Minitest
- **MCP Server** — exposes profiling data to AI assistants; includes `run_tests` to trigger test runs from the AI
- **Cluster (Master/Slave)** — connect multiple profiler instances; query any slave from the master UI or MCP
- **Extensible Collectors** — add custom profiling tabs with a simple API

## Requirements

- Ruby >= 3.0
- Rails >= 7.0

## Installation

Add to your `Gemfile`:

```ruby
gem "rails-profiler", require: "profiler"
```

The library is `profiler`, not `rails-profiler`: without `require: "profiler"`, Bundler loads
nothing of the gem.

Then run:

```bash
bundle install
```

> The gem is published on [RubyGems.org](https://rubygems.org/gems/rails-profiler). Pre-release (canary) versions are available via the [GitLab Package Registry](https://git.duplessy.eu/sebastien/rails-profiler-gem/-/packages):
>
> ```ruby
> source "https://git.duplessy.eu/api/v4/projects/sebastien%2Frails-profiler-gem/packages/rubygems" do
>   gem "rails-profiler", "~> 0.1.0.pre", require: "profiler"
> end
> ```

Mount the engine in `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount Profiler::Engine, at: '/_profiler' if Rails.env.development?
end
```

## Configuration

`enabled` defaults to true in development and test, false elsewhere. The profiler reads it once
the application's `config/initializers` have run: with `enabled = false` it inserts no middleware
and installs no Sidekiq, ActiveJob, test or console instrumentation, and with `enabled = true` in
production it gets all of them. The patch that carries the profiling context into new threads
(`Thread#initialize`) is put in place when the gem is loaded, whatever `enabled` says. The engine
routes the application mounts stay: while disabled, the API, the MCP mount and the cluster
endpoints answer `403`, or `404` when the MCP HTTP transport or `cluster_master` is off. The
engine's static assets (`/_profiler/assets/profiler-toolbar.js`, `profiler.js` and
`profiler.css`) are still served, to anyone: they hold no application data.

`enabled` is read once, at boot: setting it to true on a running process does not insert the
middleware nor install the instrumentation. Options can also be set with `Profiler.configure` in
`config/application.rb` or in `config/environments/*.rb`, or with
`config.profiler.<option> = value` in `config/application.rb`; from lowest to highest priority:
the default, `Profiler.configure` in `config/application.rb` or `config/environments`,
`config.profiler`, then `config/initializers`.

Create `config/initializers/profiler.rb`:

```ruby
Profiler.configure do |config|
  # Master toggle — defaults to true in development and test
  config.enabled = Rails.env.development?

  # Storage backend: :memory (default), :file, :redis, :sqlite
  config.storage = :file
  config.storage_options = {
    path: Rails.root.join('tmp', 'profiler'),
    max_size: 100.megabytes
  }

  # Paths to skip (regex array)
  config.skip_paths = [%r{^/_profiler}, /\.well-known/, /favicon\.ico/]

  # Database query thresholds
  config.slow_query_threshold = 100  # ms
  config.max_queries_warning = 50

  # Memory tracking
  config.track_memory = true
  config.memory_warning_threshold = 100.megabytes

  # Body compression (text bodies larger than threshold are stored gzip+base64)
  config.compress_bodies = true
  config.compress_body_threshold = 10.kilobytes

  # Sensitive data (see "Sensitive data" under Security)
  config.redact_sensitive_data = true
  config.filter_parameters += [:iban]      # added to Rails' config.filter_parameters
  config.env_allowlist += %w[APP_VERSION] # ENV variables whose values are shown

  # Outbound HTTP tracking
  config.track_http = true
  config.slow_http_threshold = 500  # ms
  config.http_skip_hosts = []

  # AJAX tracking
  config.track_ajax = true

  # Background job tracking
  config.track_jobs = true

  # Apply the env overrides saved from the UI or MCP even while `enabled` is false
  # (never in production, whatever this says). See "Environment variable overrides".
  config.apply_env_overrides_when_disabled = false

  # Console profiling (rails console expressions)
  config.track_console = true

  # Test profiling — capture SQL, cache, exceptions per test (RSpec / Minitest)
  # Defaults to true in test env, false elsewhere
  config.track_tests = Rails.env.test?

  # Test runner: only the discovered test files can be run (default: false; see "Test runner")
  config.test_runner_allow_undiscovered_files = false

  # CORS for cross-origin clients (default: off, no origin; see "Access control")
  config.extension_cors_enabled = false
  config.cors_allowed_origins = []

  # MCP server for AI assistant integration (see "MCP Server")
  config.mcp_enabled = true
  config.mcp_transport = :stdio  # or :http, which routes /_profiler/mcp

  # Authorization (default: :allow_local; see "Access control")
  config.authorization_mode = :allow_local  # or :allow_authorized, or :allow_all
  config.authorize_with do |request|
    request.session[:admin] == true
  end

  # Forgery protection of the API (default: true; see "Access control")
  config.api_forgery_protection = true

  # Who may frame the profiler (default: itself, the Chrome extension and DevTools)
  config.frame_ancestors = ["'self'", "chrome-extension:", "devtools:"]
end
```

### Default collectors

All collectors are enabled by default. To restrict to a specific set:

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

## Usage

### Toolbar and Dashboard

Once installed, the profiler automatically:

1. **Injects a toolbar** at the bottom of every HTML page showing request metrics
2. **Stores a profile** for each request
3. **Provides a web dashboard** at `/_profiler`

See the **[UI Guide](docs/ui.md)** for a full walkthrough of the toolbar, profile list, and all dashboard tabs (Request, Dump, Database, Timeline, Views, Cache, Logs, I18n, Routes, Exception).

### Explaining a query

The **Explain** button of the Database tab, the `POST /_profiler/api/explain` endpoint and the MCP
`explain_query` tool all show the plan of a query the application already ran, with its bind values
put back. They run `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` on PostgreSQL, `EXPLAIN FORMAT=JSON`
on MySQL and `EXPLAIN QUERY PLAN` on SQLite.

A query whose bind values were masked when captured is refused first, since it cannot be rebuilt
(see [Sensitive data](#sensitive-data)). Then only read-only statements are explained: those that
start, after comments and parentheses, with `SELECT`, `WITH`, `TABLE` or `VALUES`, and contain none
of `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `TRUNCATE`, `DROP`, `ALTER`, `CREATE`, `INTO`, `LOCK` or
`SHARE` outside literals, quoted identifiers and comments, in a single statement. Anything else is
refused with a message saying why: a 422 from the endpoint, an error from the MCP tool. PostgreSQL's
`EXPLAIN ANALYZE` runs the statement it explains, so explaining a `DELETE` would delete the rows
again. This refuses a writing CTE (`WITH d AS (DELETE ... RETURNING id) SELECT ...`), `SELECT ...
INTO`, `INTO OUTFILE`, `FOR UPDATE`, `FOR SHARE` and `LOCK IN SHARE MODE`. It can also refuse a
read: an unquoted column named `share`, for example.

The probe then runs on a connection of its own, closed afterwards, in a transaction that is always
rolled back. Nothing it does to its session outlives it, and the application's own connection and
transaction are never touched. The connection is opened from the database configuration, outside the
pool: a pool of one, or a full one, does not keep Explain waiting.

- **PostgreSQL:** the transaction is also `READ ONLY`, so a function with a side effect called from
  a `SELECT` fails instead of writing (`nextval()` included), and limited by `SET LOCAL
  statement_timeout = '30s'`, since `EXPLAIN ANALYZE` runs the query. The EXPLAIN goes by the
  extended protocol, so the server itself refuses more than one statement.
- **MySQL:** rolled back, not read-only, no timeout: `EXPLAIN` without `ANALYZE` plans the query
  without running it. (`max_execution_time`, or `max_statement_time` on MariaDB, would only bound
  a `SELECT` that runs.)
- **SQLite:** rolled back. `EXPLAIN QUERY PLAN` does not run the statement. The probe's transaction
  waits for a write transaction open on another connection, and fails with `database is locked`
  after the busy timeout.

What this does not cover: effects outside the database. Anything a function called from a
`SELECT` does through `dblink` or on the file system stays done. A session-level advisory lock taken
by `pg_advisory_lock()` is released when the probe's connection closes.

There is no setting to explain a write. To see the plan of a slow `UPDATE` or `DELETE` on
PostgreSQL, run it yourself in `psql`, in a transaction you roll back, knowing that sequences still
advance, row locks are held until the rollback and triggers with outside effects still fire:

```sql
BEGIN;
EXPLAIN (ANALYZE, BUFFERS) DELETE FROM orders WHERE customer_id = 42;
ROLLBACK;
```

### Dumping variables

Inspect any value in the **Dump** tab:

```ruby
# Basic dump — shows value, file, and line number
Profiler.dump(@user)

# With a label
Profiler.dump(@posts, "Posts for current page")

# Chainable — returns the original value
user = Profiler.dump(User.find(params[:id]), "Current user")

# Dump anything
Profiler.dump(params)
Profiler.dump(session[:user_id], "Current user ID")
```

### Custom instrumentation

Add custom events to the flame graph:

```ruby
result = Profiler.measure("payment.stripe_charge", metadata: { amount: 1000 }) do
  Stripe::Charge.create(amount: 1000, currency: 'usd')
end
```

Custom events appear as pink blocks in the **Timeline** tab, nested at the correct position in the call hierarchy.

### Console profiling

When `track_console: true` (default), every expression evaluated in `rails console` is automatically profiled:

```ruby
# In rails console — all of these are profiled automatically
User.where(active: true).count
Post.includes(:comments).limit(10).to_a
```

Results appear in the **Console** tab at `/_profiler`. Each entry shows the expression, duration, SQL query count, and whether it raised an error.

Env overrides set via the profiler UI or MCP tools are applied before each console evaluation, so there is no need to restart the console to pick up changes. They follow the rules of [Environment variable overrides](#environment-variable-overrides): never in production, and not while the profiler is disabled.

To disable console profiling:

```ruby
Profiler.configure do |config|
  config.track_console = false
end
```

### Environment variable overrides

Values set, deleted or reset from the **Env** tab or the MCP env tools are saved in
`env_overrides.json` under `tmp_path` (`tmp/rails-profiler` by default) and applied to `ENV` at
boot, before each Sidekiq job and before each console evaluation. They are applied only when both
hold:

- the application is not running in production (`Rails.env.production?`), with no option to
  change that: an overrides file deployed with the application is never read into `ENV`;
- the profiler is enabled, as the application sets it (`config.enabled` in
  `config/initializers/profiler.rb`). Set `config.apply_env_overrides_when_disabled = true` to
  apply them while the profiler is disabled, as versions before 0.30.8 did.

Where they are left out, resetting an override from the UI or MCP still updates the file, but
puts back in `ENV` only a variable this process changed itself, to the value it had before; it
never writes the "original" values the file carries, which come from the machine that wrote it.

When the file holds overrides that are left out, the boot logs one warning to `Rails.logger` with
the file, the number of overrides and the reason, never a name or a value.

At boot the overrides are applied once the application's `config/initializers` have run, since
that is where `enabled` is decided. Code that reads `ENV` later (requests, jobs, eager loading,
`after_initialize`) sees them; an initializer of the application that reads `ENV` while it runs
does not. If one needs them, apply them at the end of `config/initializers/profiler.rb`, with the
same rules:

```ruby
Profiler.configure do |config|
  config.enabled = Rails.env.development?
end
Profiler.env_override_store.apply!
```

Initializers that sort after `profiler.rb` then see the overrides.

---

### Test Profiling

When `config.track_tests = true` (default in `test` env), the profiler wraps every RSpec or Minitest test and captures SQL queries, cache operations, exceptions, and timing.

**RSpec** — add to `spec/spec_helper.rb` or `spec/rails_helper.rb`:

```ruby
require 'profiler/test_helpers/rspec_support'

RSpec.configure do |config|
  Profiler::TestHelpers::RSpecSupport.install(config)
end
```

**Minitest** — add to `test/test_helper.rb`:

```ruby
require 'profiler/test_helpers/minitest_support'
Profiler::TestHelpers::MinitestSupport.install
```

After the suite runs, a summary is printed to stdout:

```
┌─ Profiler Test Report ────────────────────────────────────────┐
│ 42 tests · 40 passed · 1 failed · 1 pending                   │
│ Total: 3420ms · 187 queries · 2 N+1 detected                  │
├─ Slowest tests ────────────────────────────────────────────────┤
│  1. UserSpec#creates a user with associations   820ms  12q ⚠ N+1 │
...
```

Test profiles are stored like HTTP profiles and can be viewed in the dashboard at `/_profiler` or queried via the MCP tools `query_test_profiles`, `get_test_profile`, and `run_tests`.

### Test runner

The dashboard page `/_profiler/test_runner` and the MCP tool `run_tests` run your tests with
`bundle exec rspec` (or `rails test`), in the `test` environment. They only run the files the
profiler discovers, `spec/**/*_spec.rb` and `test/**/*_test.rb` under the Rails root, optionally
with a line number (`spec/models/user_spec.rb:12`). Paths are compared after resolving symbolic
links, so a link to any other file is refused, and so is a discovered link whose target leaves the
Rails root. A refused selection answers `422` with the refused paths, or a tool error over MCP,
and nothing is started.

The test process starts from the environment the shell gave Rails, copied when the gem is
loaded, with the `test` environment. Environment overrides set from the profiler (the env vars
page, the MCP tool `set_env_var`) are applied on top, except those that would make the test process,
or the shell shims that start it (rbenv, asdf), load or run other code: for those, the test process
keeps the shell value, or none, and a warning names them once. They are: any name that is not
made of letters, digits and `_`; every name starting with `RUBY`, `GEM_`, `BUNDLE_`, `BUNDLER_`,
`LD_`, `DYLD_`, `BASH_`, `RBENV_`, `ASDF_`, `RVM_`, `CHRUBY`, `GIT_`, `BOOTSNAP_`, `PYTHON` or
`PERL5`; and `GEMRC`, `NODE_OPTIONS`, `NODE_PATH`, `SPEC_OPTS`, `TESTOPTS`, `TEST`, `PATH`, `HOME`,
`XDG_CONFIG_HOME`, `SHELLOPTS`, `BASHOPTS`, `PS4`, `ENV`, `CDPATH` and `IFS`. `DATABASE_URL` and
`SECRET_KEY_BASE` keep their shell value too, and `RAILS_ENV` and `RACK_ENV` are always `test`.
This is a deny list, so it cannot be complete. When your tests need one of these variables, set it
in the shell that starts Rails: the test process inherits it. Variables the application itself
writes into `ENV` once loaded (`dotenv` for instance) do not reach the test process, which loads
them on its own when your test setup does.

The test process boots your application too: the runner sets `PROFILER_TEST_RUNNER_CHILD=1` in
its environment so that it does not replay the overrides itself, and the env tools refuse that name.

The copy of the environment is taken once, when the gem is loaded. Two cases keep an older copy:

- After a hot restart of Puma (`pumactl restart`, `SIGUSR2`), the new server inherits the
  environment of the old one, overrides included, and copies that. Stop the server and start it
  again from the shell.
- Under Spring, the copy is taken when Spring preloads the application. Run `bin/spring stop`
  after changing the shell environment.

To run any file under the Rails root again, as the test runner did before:

```ruby
config.test_runner_allow_undiscovered_files = true
```

### Cluster (Multi-instance)

Connect multiple Rails profiler instances so a single **master** dashboard and MCP server can query any **slave**.

The master and its slaves authenticate each other with a **shared secret**, and the master only
sends requests to slave URLs you allow. Nothing is routed or accepted until you configure it.

**On the master**:
```ruby
Profiler.configure do |config|
  config.name = "main"  # optional display name
  config.cluster_master = true                                  # routes the cluster endpoints
  config.cluster_secret = ENV.fetch("PROFILER_CLUSTER_SECRET")  # same value on every node
  config.cluster_allowed_slave_urls = [
    "https://payment.internal:3001",  # a slave URL must match one entry
    "http://localhost:3002"           # plain HTTP is accepted for loopback addresses only
  ]
end
```

**On each slave**, add to `config/initializers/profiler.rb`:
```ruby
Profiler.configure do |config|
  config.name       = "payment-service"                         # display name
  config.master_url = "https://master-host:3000"                # master's URL
  config.self_url   = "https://payment.internal:3001"           # this instance's URL (reachable from master)
  config.cluster_secret = ENV.fetch("PROFILER_CLUSTER_SECRET")  # same value as the master

  # Optional tuning (defaults shown)
  config.cluster_heartbeat_interval = 15  # seconds between heartbeats
  config.cluster_offline_threshold  = 60  # seconds without heartbeat → offline
end
```

Generate the secret once, for example with `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`,
and give it to every node through the environment, never in the repository. A secret shorter than
32 characters, or blank, is ignored as if none were configured: the node logs a warning at boot,
and every cluster request is refused with a message saying why.

The slave registers automatically at boot and sends periodic heartbeats.

**Two applications on one machine** (for example two git worktrees on ports 3000 and 3001) need
no HTTPS: loopback addresses are accepted over plain HTTP.

```ruby
# master, on port 3000
config.cluster_master = true
config.cluster_secret = ENV.fetch("PROFILER_CLUSTER_SECRET")
config.cluster_allowed_slave_urls = ["http://localhost:3001"]

# slave, on port 3001
config.master_url = "http://localhost:3000"
config.self_url = "http://localhost:3001"
config.cluster_secret = ENV.fetch("PROFILER_CLUSTER_SECRET")
```

**Slaves whose names are not known in advance** (for example one container per git worktree in a
Docker network): an entry of `cluster_allowed_slave_urls` can be a `Regexp` instead of a URL.

```ruby
# master
config.cluster_master = true
config.cluster_secret = ENV.fetch("PROFILER_CLUSTER_SECRET")
config.cluster_allowed_slave_urls = [%r{\Ahttp://travel-api-[a-z0-9-]+:3000\z}]
config.cluster_allow_insecure_http = true  # plain HTTP to a non-loopback host, inside the Docker network only
```

- The pattern must start with `\A` and end with `\z`, so that it matches the whole URL: any other
  `Regexp` (unanchored, anchored with `^`, `$` or `\Z`, or whose `x`-mode comment hides the `\z`)
  raises an `ArgumentError` when it is assigned. It is matched as a whole even if it alternates at
  the top level, and its options (`i`, `x`) apply.
- It is matched against the URL as the master keeps it: lower-case scheme and host, no default port
  (`:80` for `http`, `:443` for `https`), no trailing slash, and path segments percent-encoded again
  (`~` becomes `%7E`, `:` becomes `%3A`). Write the pattern for that form, and keep the port in it
  if the slaves use a non-default one.
- The checks on the URL come first and the pattern cannot lift them: user info, a query, a fragment
  or a `.` or `..` segment are refused, and plain HTTP to a host that is not a loopback address
  still needs `cluster_allow_insecure_http`.
- Only a `Regexp` object is a pattern: a `String` is always a URL, even if it looks like a pattern.
- URLs and patterns can be mixed in one list. As with listed names, the pattern is matched against
  the name, not the address it resolves to: keep the character classes tight (`[a-z0-9-]+`, never
  `.*` for a host).

**In the UI** (`/_profiler` on the master): a **Profiler** dropdown appears in the header listing all connected slaves. Selecting one proxies all data through the master — the rest of the interface is unchanged.

**In MCP**: all tools accept an optional `slave: "<name>"` parameter:
```
query_profiles slave: "payment-service", path: "/api/charges"
list_slaves  # → shows connected slaves and their status
```

#### How the cluster is protected

- **Routes.** `POST /_profiler/api/cluster/register`, `POST /_profiler/api/cluster/heartbeat`,
  `GET /_profiler/api/cluster/slaves` and the proxy `/_profiler/api/slaves/<name>/...` exist only
  on a node with `cluster_master = true`; elsewhere they answer `404`. A slave needs no route of its
  own: `master_url` is what makes it register.
- **Shared secret.** A slave sends `X-Profiler-Cluster-Secret` on `register` and `heartbeat`, and
  the master sends it on every proxied call. It is compared in constant time. `register` and
  `heartbeat` are authenticated by the secret alone, from any address (a slave is a server, not a
  browser); they are refused when it is missing or wrong, and refused altogether while no
  `cluster_secret` is configured. On a slave (a node with `master_url`), a request carrying the
  right secret is let in as the master's, in place of `authorization_mode` and the forgery header;
  a wrong or missing secret changes nothing.
- **Slave URLs.** The master registers, and sends requests to, a slave URL only if it matches an
  entry of `cluster_allowed_slave_urls`: same scheme, host and port, compared after normalization
  (case of the host, default port, IPv6 between brackets), and a path under the entry's path,
  segment by segment. A URL with user info, a query, a fragment or a `.` or `..` segment is refused.
  An entry can also be an anchored `Regexp` (see *Slaves whose names are not known in advance*
  above). The default, `[]`, refuses every URL. The check runs again on each proxied call, so removing an
  entry cuts off a slave already registered.
- **HTTPS.** Slave URLs and `master_url` must use HTTPS, except for `localhost`, `127.0.0.0/8` and
  `::1`, so that the secret and the profiles do not cross the network in clear.
- **Redirects.** The master never follows a redirect from a slave: a `3xx` answer is reported as an
  error, without its body.
- **Paths.** Whatever a client puts in a proxied path, a profile token or an MCP argument stays
  inside one path segment under the slave's `/_profiler/api/`: `?`, `#` and `%` are encoded, and a
  `.`, `..` or `/` segment is refused before any request is sent.
- **What the allow list does not cover.** Entries are compared by name, not by the address the name
  resolves to: a listed name whose DNS points at an internal address, or is rebound to one after
  the check, is reached all the same. List only names whose DNS zone you control, or IP addresses.
- **One secret for the whole cluster.** Every node holds the same secret, so whoever compromises one
  node, or reads its environment, can register slaves on the master and call every slave as the
  master. Profiles and test runs mask it by value (see [Sensitive data](#sensitive-data)), but
  your own log files and error trackers do not: keep it out of them, and change it on every node if
  one is exposed.
- The proxy route itself is called by your browser, so it stays behind `authorization_mode` and the
  forgery protection, like the rest of `/_profiler`.

#### Restoring the behaviour of earlier versions

Each of these brings back a risk the defaults remove; set only the ones you need.

| Setting | Behaviour | Risk |
|---|---|---|
| `config.cluster_master = true` | Routes the cluster endpoints, which every application had in earlier versions | None by itself: the other checks still apply |
| `config.cluster_require_secret = false` (and no `cluster_secret`) | `register` and `heartbeat` accept any client that `authorization_mode` and the forgery header let in, as in 0.30.6, and the master proxies without a secret | Whoever passes `authorization_mode` can register a slave URL; a slave across the network has to admit the master's address itself |
| `config.cluster_allowed_slave_urls = :any` | Any slave URL is accepted, as in earlier versions | Server-side request forgery: whoever can register makes the master fetch any host and port it can reach, internal services and cloud metadata included, and read the answer |
| `config.cluster_allow_insecure_http = true` | Plain HTTP to any host | The secret and every proxied profile cross the network in clear |

---

### MCP Server (AI assistant integration)

Connect Claude (or any MCP-compatible AI assistant) to your profiler data:

```bash
bundle exec rake profiler:mcp
```

The stdio transport above needs no route and no network access. The HTTP transport is routed at
`/_profiler/mcp` only when both `config.mcp_enabled = true` and `config.mcp_transport = :http` are
set; otherwise `/_profiler/mcp` answers `404`. When it is routed, each request goes through the same
checks as the rest of the profiler before the MCP server sees it: the profiler must be enabled, the
request must pass `authorization_mode`, and, for forgery protection, a `POST` must carry
`Content-Type: application/json` and any `Origin` header must be the profiler's own or one of
`cors_allowed_origins`. MCP clients running inside a web page are not supported: a browser cannot
pass these checks from another origin, and `cors_allowed_origins = ["*"]` opens the API to every
origin, not the MCP endpoint. MCP clients already send JSON; a page on another site cannot without a CORS
preflight, which the profiler does not grant. A refused request gets a `403` before any MCP
handshake, so none of the tools (including the ones that write `ENV`, clear profiles or run tests)
is reachable without passing these checks.

In earlier versions, `/_profiler/mcp` was routed in every application, whatever `mcp_enabled` and
`mcp_transport` said, and answered anyone. An installation that used the HTTP endpoint while
`mcp_transport` was left at its default, `:stdio`, now has to set `config.mcp_enabled = true` and
`config.mcp_transport = :http`. There is no setting that routes it without the checks: the general
ones apply, `config.authorization_mode = :allow_all` (anyone who can reach the application can then
read and change everything the profiler exposes, through the MCP tools as well as the API) and
`config.api_forgery_protection = false` (any website you visit can then make your browser call the
tools).

See the **[MCP Guide](docs/mcp.md)** for Claude Desktop and Claude Code setup, all available tools (`query_profiles`, `analyze_queries`, `run_tests`, `query_test_profiles`, etc.), and example prompts.

### Rake tasks

```bash
# List recent profiles
rake profiler:list

# Show a specific profile
rake profiler:show TOKEN=abc123...

# Clean up old profiles
rake profiler:cleanup OLDER_THAN=86400  # seconds

# Start MCP server
rake profiler:mcp
```

## Storage Backends

### Memory (default)

Fast, no persistence. Data lost on restart. Good for CI/test.

```ruby
config.storage = :memory
config.storage_options = { max_profiles: 100 }
```

### File (recommended for development)

Persistent, stored in `tmp/profiler/`. Survives restarts.

```ruby
config.storage = :file
config.storage_options = {
  path: Rails.root.join('tmp', 'profiler'),
  max_size: 100.megabytes
}
```

### Redis (recommended for multi-server)

Shared across servers, TTL-based expiry.

```ruby
config.storage = :redis
config.storage_options = {
  url: ENV['REDIS_URL'],
  ttl: 24.hours,
  key_prefix: 'profiler'
}
```

### SQLite

Single-server persistence, no external dependency.

```ruby
config.storage = :sqlite
config.storage_options = {
  path: Rails.root.join('db', 'profiler.db')
}
```

## Creating Custom Collectors

```ruby
class MyCollector < Profiler::Collectors::BaseCollector
  def icon = '🔧'
  def priority = 100  # lower = earlier in tab list

  def subscribe
    @subscription = ActiveSupport::Notifications.monotonic_subscribe('my.event') do |name, started, finished, id, payload|
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

## Access control

The profiler shows everything your application does: parameters, SQL, headers, logs, `ENV`, and
it can change `ENV` and run your tests. Every page and endpoint under `/_profiler` (UI, API,
toolbar update checks, test runner, toolbar) goes through the same check, and answers `403` when it
fails. The gem's static JS and CSS are the only exception: they hold no application data. The
same check decides which requests the profiler captures.

### Authorization modes

| `authorization_mode` | Who gets in |
|---|---|
| `:allow_local` (default) | Requests made from this machine only |
| `:allow_authorized` | Requests for which your `authorize_with` block returns true (nobody without a block) |
| `:allow_all` | **Everybody who can reach the application. No protection at all.** |

`:allow_local` accepts a request when all of these hold:

- `REMOTE_ADDR` is a loopback address (`127.0.0.0/8` or `::1`). `X-Forwarded-For` and the like are
  never used to let a request in, since anyone can send them.
- If a forwarding header is present (`X-Forwarded-For`, `X-Real-IP`, `Forwarded`), every address
  in it is a loopback address too. This refuses a remote client relayed by a reverse proxy running
  on the same machine, where `REMOTE_ADDR` is always `127.0.0.1`.
- The `Host` header (and `X-Forwarded-Host`, when present) is `localhost`, a `*.localhost` name, a
  loopback IP, or a host your application lists in `config.hosts`. This defeats DNS rebinding, where
  a page from another site reaches `127.0.0.1` under its own domain name. Rails already refuses
  such hosts in development through `config.hosts`; the profiler checks them itself because
  `config.hosts` is empty in the other environments and often cleared in Docker setups.

In the test environment, `:allow_local` also accepts `www.example.com`, `example.com` and
`example.org`, the default hosts of rack-test and of Rails integration tests, so that your
application's request specs are still captured. These names are reserved (RFC 2606): nobody can
point them at a server of their own. Any other `Host` is still checked, as are `REMOTE_ADDR` and the
forwarding headers, since a server started in the test environment (system tests, Cypress,
`rails s -e test`) can be reached by a browser.

`:allow_local` trusts the machine, not the person: anything that reaches Rails from the machine
itself is local. That includes a relay that adds no forwarding header (`ssh -R`, `socat`,
`kubectl port-forward`), and a request the application itself makes to `localhost` on behalf of a
user (server-side request forgery). Use `:allow_authorized` when such paths exist.

When `:allow_local` refuses a request, or does not profile it, the profiler logs the cause once
per process in `Rails.logger`.

**Docker, a VM, or a remote proxy.** The browser's request then reaches Rails from the bridge or
proxy address (for example `172.17.0.1`), which is not local: the profiler refuses it and stops
capturing. Admit your own network explicitly:

```ruby
require "ipaddr"

Profiler.configure do |config|
  config.authorization_mode = :allow_authorized
  docker = IPAddr.new("172.16.0.0/12")  # narrow it to your own network
  config.authorize_with do |request|
    docker.include?(request.get_header("REMOTE_ADDR"))
  end
end
```

Read `REMOTE_ADDR` there, not `request.remote_ip`, which trusts `X-Forwarded-For`. You can also go
back to `config.authorization_mode = :allow_all`, the default before 0.30.6, which lets anybody who
can reach the application read and change everything the profiler exposes.

A cluster master and its slaves do not need this: they authenticate each other with
`cluster_secret` (see [Cluster](#cluster-multi-instance)).

### Forgery protection

Requests that change something (`POST`, `PATCH`, `PUT`, `DELETE`, including a form `POST` turned
into another verb by `_method`) must carry an `X-Profiler-Request` header, or Rails' CSRF token.
The dashboard, the toolbar and the cluster send the header. A page on another site cannot add it
without a CORS preflight, which the profiler does not grant. Your own scripts that call the API
should send `X-Profiler-Request: 1`. To accept mutations without it, as before 0.30.6, set
`config.api_forgery_protection = false`.

### CORS

CORS is off by default: no `Access-Control-Allow-Origin` header, so a page on another origin cannot
read profiler responses. The Chrome extension does not need it. To let a known origin call the API,
enable it and name that origin:

```ruby
config.extension_cors_enabled = true
config.cors_allowed_origins = ["https://myapp.dev"]
```

`"*"` (the default before 0.30.6, with `extension_cors_enabled = true`) is still accepted, and it
**reopens the profiler to every website you visit, as before 0.30.6**: any page open in your browser
can then read the profiler's data and, since a preflight is granted, change it (delete profiles,
write `ENV`, run tests). Under `:allow_local` the check rests on the address and the `Host`, not on
a cookie, so it does not stop such a page. `"*"` is never sent in answer to a request carrying a
cookie or an `Authorization` header, which only helps when `authorize_with` relies on them.

### Framing

Profiler pages may only be framed by the profiler itself and by the Chrome extension's DevTools
panel (`Content-Security-Policy: frame-ancestors 'self' chrome-extension: devtools:`, plus
`X-Frame-Options: SAMEORIGIN` for older browsers). Chrome checks every ancestor of a frame: the
panel's page is a `chrome-extension:` page, itself shown inside the `devtools:` front end, so both
are needed. `chrome-extension:` lets **any** installed extension frame the profiler; to admit only the profiler's
own extension, name it: `config.frame_ancestors = ["'self'", "chrome-extension://<extension id>",
"devtools:"]`. To change the list, set `config.frame_ancestors`; the value before 0.30.6 was
`["'self'", "http:", "https:"]`, which lets any website frame the profiler.

## Performance

- Only active when enabled (development/test by default); when disabled, nothing is left in the
  middleware stack and no Sidekiq, ActiveJob, test or console instrumentation is installed
- Expected overhead: < 5ms per request
- Text bodies > 10 KB compressed automatically (gzip+base64)
- Masking sensitive data adds well under 1 ms to a typical profile. A JSON body in whose text no
  filter matches is not parsed: about 10 ms per megabyte for ASCII text, 50 ms when it holds other
  characters. A body where a filter matches, in a key or only in a value (`"title": "reset your
  password"`), is parsed and filtered: about 100 to 300 ms per megabyte depending on the machine,
  in the request. Procs and regexps with anchors or lookarounds in `filter_parameters` send every
  JSON body to the parser
- Automatic cleanup of old profiles
- The profiler's pages, the toolbar and the test runner, keep no server thread waiting, however
  many are open. The toolbar learns that its profile was saved again (an outgoing HTTP request finished after the
  page, say) by asking the server, which answers at once: after 1 s, then less and less often,
  10 requests in the first minute and 2 a minute after that, none while the tab is hidden, and
  none after 10 minutes without a save (reload the page to follow it again). The test runner page
  asks for the new output once a second while a run is in progress. With several worker
  processes and no Redis storage, each worker only knows the saves it made: the toolbar sees a
  save when one of its requests reaches the worker that made it
- Known limits: three requests still hold a server thread for as long as they wait. The MCP tool
  `run_tests` waits for a local run up to its `timeout_seconds` (120 by default, with no upper
  bound); with a `slave`, it asks the slave every 2 seconds for as long. The cluster proxy
  (`/_profiler/api/slaves/:name/...`) waits for the slave with a read timeout that applies to each
  read, not to the whole answer

## Security

- Disabled by default in production
- Only requests from this machine get in by default (`authorization_mode: :allow_local`), on every page and endpoint; see [Access control](#access-control)
- API mutations require the `X-Profiler-Request` header or a CSRF token
- The test runner only runs discovered test files; see [Test runner](#test-runner)
- The MCP HTTP endpoint is routed only when enabled, and goes through the same checks
- The cluster is off by default; when on, nodes authenticate with a shared secret and the master only reaches allowed slave URLs
- No CORS and no framing by other sites by default
- Sensitive data masked before it is stored, using your `config.filter_parameters`; see [Sensitive data](#sensitive-data)
- Env overrides saved from the UI or MCP are never applied in production, nor while the profiler
  is disabled (`apply_env_overrides_when_disabled`)
- EXPLAIN runs read-only statements only, in a transaction always rolled back (see [Explaining a query](#explaining-a-query))

### Sensitive data

The profiler masks sensitive values with `[FILTERED]` **before** a profile is stored, with one
filter built by `ActiveSupport::ParameterFilter` from your application's
`Rails.application.config.filter_parameters` plus the profiler's own `config.filter_parameters`.
Rails semantics apply: a symbol or string matches any key that contains it, case-insensitively, at
any nesting depth (`password` masks `user[password]` and `PASSWORD`); a regexp is used as is; a
proc rewrites the value, in bodies and params as in named values (SQL binds, headers, `ENV`,
mailer arguments). Procs see string values only, once each, and a proc of arity 3 receives the original params as in
Rails (for a named value, the single name and value); any other object (an Active Record
model, say) is neither copied nor passed to them, and is stored through its `inspect`. When the filter raises (a proc that expects a string and gets a number, say),
the profiler masks the value rather than let the error reach your application, and logs the error
class once, without the value.

The profiler's own list defaults to
`[:passw, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc]` (the
Rails 7.1 template without `:email`), so an application with an empty or short
`filter_parameters` is still covered, and the gem is covered outside Rails. To lighten it, assign
a shorter list (`config.filter_parameters = %i[passw secret]`), or `[]` to rely on your
application's list alone; an entry of your application's `config.filter_parameters` always
applies, the profiler cannot take it out.

What is masked:

| Data | Rule |
|---|---|
| Request params | values of filtered keys, nested included |
| Route params | values of filtered keys (the path itself is kept: `/confirm/abc` still shows `abc`) |
| Request and response bodies, incoming and outbound | JSON (`application/json`, `text/json`, `*+json`), NDJSON (`*/x-ndjson`, line by line) and `application/x-www-form-urlencoded`: values of filtered keys; a JSON body that cannot be parsed and in whose text a filter matches (`{password: "x"}`), and any `multipart/*` body: masked entirely; binary bodies and other text types (HTML, XML, plain text...) are kept as they are, the filter cannot read them |
| Headers, incoming, response and outbound (Net::HTTP, so Faraday, RestClient, HTTParty...) | `Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie`, and any header whose name matches the filter (`X-Api-Key` matches `_key`); the query string of `Referer`, `Location` and `Content-Location` goes through the filter (`reset_password_token=[FILTERED]`) |
| Outbound URLs | values of filtered query string parameters |
| `ENV` (Env tab, `/_profiler/api/env_vars`, MCP `list_env_vars` and `get_profile` env section) | values of variables outside `config.env_allowlist`, and of any variable whose name matches the filter; names stay listed |
| SQL binds | values bound to a column whose name matches the filter, as Active Record does in its logs; EXPLAIN is then refused for that query, since it cannot be rebuilt |
| Job arguments (Active Job, Sidekiq) | values of filtered keys inside hash arguments |
| Mailer arguments (`assigns`) | arguments whose parameter name matches the filter, and values of filtered keys inside hash arguments |

The cluster's `cluster_secret` is also masked **by value**, whatever name it travels under, and
even with `config.redact_sensitive_data = false`: a value equal to it becomes `[FILTERED]`, and the
secret inside a longer string is replaced by `[FILTERED]`. This covers what the table above lists
(params, bodies, headers, URLs, `ENV`, SQL binds, job and mailer arguments), the data of every
collector, free text included (log lines, exception messages, `dump()` values, SQL text, console
expressions and results), and the output of the test runner. Text the profiler shortens (flame
graph names, I18n values, console expressions and results, mail bodies and assigns, job
arguments) is masked before it is cut, so no prefix of the secret is left; the output of the test
runner, read in pieces, is masked on the text joined across pieces, and an end of a piece that
could be the start of the secret waits for the next piece, or for the process to finish printing
(after a kill too), before it is shown. Binary bodies stored in base64 (`application/octet-stream`,
images, PDF, zip, audio, video) are masked on their raw bytes before they are encoded. The exceptions of the next paragraph
do not apply to it. Only a secret the cluster accepts (32 characters or more) is masked: a shorter
one is ignored by the cluster anyway, and masking a value such as `true` or `/` everywhere would
hide the data being profiled. What it does not cover: a `dump()` value that is neither a string, a
hash nor an array (it is stored as the object gives it), a compressed or encoded format in which
the secret does not appear as it is (zip, PNG, gzip, a PDF stream, base64 inside a body...), and
anything the profiler does not store, such as your log files.

Not filtered, because the profiler cannot tell what they contain: log lines (Rails already filters
its `Parameters:` line and request paths), console expressions and their results, `dump()`
values, exception messages, SQL literals written into the query text, and positional job
arguments that are plain strings. On MySQL, where Active Record does not use prepared statements by
default (`prepared_statements: false`), bound values are written into the SQL text and are
therefore not masked. Any other object (an Active Record model passed to a job or a mailer, say)
is stored through its `inspect`: Active Record masks attributes there with its
`filter_attributes`, which follow your application's `config.filter_parameters` only, not the
profiler's own list.

A masked `ENV` value exported from the Env tab is exported as `[FILTERED]`. The import skips such
lines, and the server refuses `[FILTERED]` as a value (422 from `/_profiler/api/env_vars`, an
error from the `set_env_var` MCP tool), so a round trip cannot overwrite the real value.

`config.env_allowlist` defaults to `Profiler::Configuration::DEFAULT_ENV_ALLOWLIST` (`RAILS_ENV`,
`RACK_ENV`, `PORT`, `LANG`, `TZ`, `PATH`, `RUBY_VERSION`, `BUNDLE_GEMFILE`...); it accepts
strings and regexps.

To restore the previous behaviour, all or part of it:

```ruby
Profiler.configure do |config|
  config.redact_sensitive_data = false # no masking at all (params lose only password,
                                       # password_confirmation, token and secret, as before)
  config.env_allowlist = :all          # capture every ENV value
  config.filter_parameters = []        # rely on Rails' config.filter_parameters alone
end
```

With `env_allowlist = :all` and `redact_sensitive_data` left on, variables whose name matches the
filter (`SECRET_KEY_BASE`, `DATABASE_PASSWORD`...) are still masked.

## Development

```bash
# Run tests
bundle exec rspec

# Start the test app
cd test_app && bundle exec rails server

# Docker
make build && make test-app
```

## Contributing

Bug reports and pull requests are welcome on [GitLab](https://git.duplessy.eu/sebastien/rails-profiler-gem).

## License

MIT License. See [MIT-LICENSE](MIT-LICENSE).
