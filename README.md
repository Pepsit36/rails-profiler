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

  # CORS — restrict to specific origins (default: ['*'])
  config.cors_allowed_origins = ['http://localhost:3001', 'https://myapp.dev']

  # MCP server for AI assistant integration
  config.mcp_enabled = true
  config.mcp_transport = :stdio  # or :http

  # Authorization
  config.authorization_mode = :allow_all  # or :allow_authorized
  config.authorize_with do |request|
    request.session[:admin] == true
  end
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

## Performance

- Only active when enabled (development/test by default)
- Expected overhead: < 5ms per request
- Text bodies > 10 KB compressed automatically (gzip+base64)
- Automatic cleanup of old profiles

## Security

- Disabled by default in production
- Configurable authorization (`authorization_mode: :allow_authorized`)
- Sensitive parameters sanitized automatically (password, token, secret)
- CORS origins configurable (`cors_allowed_origins`)

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
