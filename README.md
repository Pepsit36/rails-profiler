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
gem "rails-profiler"
```

Then run:

```bash
bundle install
```

> The gem is published on [RubyGems.org](https://rubygems.org/gems/rails-profiler). Pre-release (canary) versions are available via the [GitLab Package Registry](https://git.duplessy.eu/sebastien/rails-profiler-gem/-/packages):
>
> ```ruby
> source "https://git.duplessy.eu/api/v4/projects/sebastien%2Frails-profiler-gem/packages/rubygems" do
>   gem "rails-profiler", "~> 0.1.0.pre"
> end
> ```

Mount the engine in `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount Profiler::Engine, at: '/_profiler' if Rails.env.development?
end
```

## Configuration

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

  # Outbound HTTP tracking
  config.track_http = true
  config.slow_http_threshold = 500  # ms
  config.http_skip_hosts = []

  # AJAX tracking
  config.track_ajax = true

  # Background job tracking
  config.track_jobs = true

  # Console profiling (rails console expressions)
  config.track_console = true

  # Test profiling — capture SQL, cache, exceptions per test (RSpec / Minitest)
  # Defaults to true in test env, false elsewhere
  config.track_tests = Rails.env.test?

  # CORS for cross-origin clients (default: off, no origin; see "Access control")
  config.extension_cors_enabled = false
  config.cors_allowed_origins = []

  # MCP server for AI assistant integration
  config.mcp_enabled = true
  config.mcp_transport = :stdio  # or :http

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

Env overrides set via the profiler UI or MCP tools are applied before each console evaluation — no need to restart the console to pick up changes.

To disable console profiling:

```ruby
Profiler.configure do |config|
  config.track_console = false
end
```

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

### Cluster (Multi-instance)

Connect multiple Rails profiler instances so a single **master** dashboard and MCP server can query any **slave**.

**On the master** (no extra config needed — it accepts slave connections automatically):
```ruby
Profiler.configure do |config|
  config.name = "main"  # optional display name
end
```

**On each slave**, add to `config/initializers/profiler.rb`:
```ruby
Profiler.configure do |config|
  config.name       = "payment-service"           # display name
  config.master_url = "http://master-host:3000"   # master's URL
  config.self_url   = "http://this-host:3001"     # this instance's URL (reachable from master)

  # Optional tuning (defaults shown)
  config.cluster_heartbeat_interval = 15  # seconds between heartbeats
  config.cluster_offline_threshold  = 60  # seconds without heartbeat → offline
end
```

The slave registers automatically at boot and sends periodic heartbeats. No code changes required in the master.

**In the UI** (`/_profiler` on the master): a **Profiler** dropdown appears in the header listing all connected slaves. Selecting one proxies all data through the master — the rest of the interface is unchanged.

**In MCP**: all tools accept an optional `slave: "<name>"` parameter:
```
query_profiles slave: "payment-service", path: "/api/charges"
list_slaves  # → shows connected slaves and their status
```

> ⚠️ **Security — trusted networks only.** The cluster has **no authentication**: any client that can reach the master's `/_profiler/api/cluster/register` endpoint can register an arbitrary `url`, and the master will then issue proxied HTTP requests to that URL (a server-side request forgery vector). Only enable the cluster on trusted development networks, keep `/_profiler` behind your `authorization_mode`, and never expose a cluster master to untrusted traffic. The profiler is disabled in production by default — keep it that way for clustered setups.

---

### MCP Server (AI assistant integration)

Connect Claude (or any MCP-compatible AI assistant) to your profiler data:

```bash
bundle exec rake profiler:mcp
```

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
    ActiveSupport::Notifications.monotonic_subscribe('my.event') do |name, started, finished, id, payload|
      @events ||= []
      @events << { name: name, duration: (finished - started) * 1000 }
    end
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
server-sent events, test runner, toolbar) goes through the same check, and answers `403` when it
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

In the test environment, `:allow_local` does not check the `Host`: your application's request
specs send `Host: www.example.com` and are still captured. DNS rebinding needs a browser visiting
the server, which a test run does not have; `REMOTE_ADDR` and the forwarding headers are still
checked.

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

A cluster master and its slaves call each other's `/_profiler/api`: when they do not run on the
same machine, each side has to admit the other's address the same way.

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

- Only active when enabled (development/test by default)
- Expected overhead: < 5ms per request
- Text bodies > 10 KB compressed automatically (gzip+base64)
- Automatic cleanup of old profiles

## Security

- Disabled by default in production
- Only requests from this machine get in by default (`authorization_mode: :allow_local`), on every page and endpoint; see [Access control](#access-control)
- API mutations require the `X-Profiler-Request` header or a CSRF token
- No CORS and no framing by other sites by default
- Sensitive parameters sanitized automatically (password, token, secret)

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
