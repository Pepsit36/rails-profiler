# Rails Profiler

A comprehensive Rails profiler similar, featuring a web debug toolbar, profiling interface, SQL analysis, performance timeline, and MCP server integration for AI assistants.

## Features

- **Web Debug Toolbar** - Bottom-of-page toolbar showing real-time metrics
- **Profiler Web UI** - Complete interface to explore past requests with detailed metrics
- **Database Query Profiling** - Capture and analyze SQL queries with execution time and backtrace
- **Performance Timeline** - Temporal visualization of events via ActiveSupport::Notifications
- **View Rendering Metrics** - Track template and partial rendering
- **Cache Operations** - Monitor cache hits, misses, and operations
- **Extensible Collectors** - Easy addition of custom profiling tabs
- **MCP Server** - Expose profiler data to AI assistants via Model Context Protocol

## Requirements

- Ruby >= 3.0
- Rails >= 7.0

## Installation

Add the GitLab Package Registry source to your `Gemfile`:

```ruby
source "https://git.duplessy.eu/api/v4/projects/sebastien%2Frails-profiler-gem/packages/rubygems" do
  gem "profiler"
end
```

Then run:

```bash
bundle install
```

Mount the engine in your `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  # ... your routes ...

  mount Profiler::Engine, at: '/_profiler' if Rails.env.development?
end
```

## Configuration

Create an initializer `config/initializers/profiler.rb`:

```ruby
Profiler.configure do |config|
  # Enable/disable profiler
  config.enabled = Rails.env.development?

  # Storage backend (:memory, :file, :redis)
  config.storage = :file
  config.storage_options = {
    path: Rails.root.join('tmp', 'profiler'),
    max_size: 100.megabytes
  }

  # Collectors to use
  config.collectors = [
    Profiler::Collectors::RequestCollector,
    Profiler::Collectors::DatabaseCollector,
    Profiler::Collectors::PerformanceCollector,
    Profiler::Collectors::ViewCollector,
    Profiler::Collectors::CacheCollector
  ]

  # Skip profiling for certain paths
  config.skip_paths = [/_profiler/, /\.js$/, /\.css$/]

  # Database query thresholds
  config.slow_query_threshold = 100 # milliseconds
  config.max_queries_warning = 50

  # Memory tracking
  config.track_memory = true
  config.memory_warning_threshold = 100.megabytes

  # MCP Server
  config.mcp_enabled = true
  config.mcp_transport = :stdio

  # Authorization
  config.authorization_mode = :allow_all # or :allow_authorized
  config.authorize_with do |request|
    # Custom authorization logic
    request.session[:admin] == true
  end
end
```

## Usage

### Web Interface

Once installed, the profiler automatically:

1. **Adds a toolbar** at the bottom of every HTML page showing request metrics
2. **Stores profile data** for each request
3. **Provides a web UI** at `http://localhost:3000/_profiler` to browse all profiles

Click the toolbar or navigate to `/_profiler` to see:
- List of recent requests
- Detailed profile view with tabs for:
  - Request information
  - Dumped variables
  - Database queries
  - Performance timeline
  - View rendering
  - Cache operations

### Dumping Variables

You can dump variables anywhere in your code to inspect them in the profiler:

```ruby
# Basic usage
Profiler.dump(@user)

# With a label
Profiler.dump(@posts, "Posts for current page")

# Dump multiple variables
Profiler.dump(params)
Profiler.dump(session[:user_id], "Current user ID")
Profiler.dump({ request: request.path, method: request.method })
```

Dumped variables appear in:
- The profiler toolbar (showing count)
- A dedicated "Dump" tab in the profile details
- Each dump shows:
  - The formatted value
  - Optional label
  - File and line number where it was called
  - Timestamp

### Rake Tasks

```bash
# List recent profiles
rake profiler:list

# Show specific profile details
rake profiler:show TOKEN=abc123...

# Clean up old profiles
rake profiler:cleanup OLDER_THAN=86400 # seconds

# Start MCP server
rake profiler:mcp
```

### MCP Server Integration

The profiler includes an MCP (Model Context Protocol) server that allows AI assistants like Claude to query profiling data.

#### Starting the MCP Server

```bash
bundle exec rake profiler:mcp
```

#### Claude Desktop Configuration

Add to your Claude Desktop config (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "rails-profiler": {
      "command": "bundle",
      "args": ["exec", "rake", "profiler:mcp"],
      "cwd": "/path/to/your/rails/app",
      "env": {
        "RAILS_ENV": "development"
      }
    }
  }
}
```

#### Available MCP Tools

- **query_profiles** - Search and filter profiled requests
  ```
  path: Filter by request path
  method: Filter by HTTP method
  min_duration: Minimum duration in ms
  limit: Max results (default: 20)
  ```

- **get_profile** - Get detailed profile data by token
  ```
  token: Profile token (required)
  ```

- **analyze_queries** - Analyze SQL queries for N+1, duplicates, slow queries
  ```
  token: Profile token (required)
  ```

#### Available MCP Resources

- **profiler://recent** - List of recently profiled requests
- **profiler://slow-queries** - List of slow database queries across all profiles

## Creating Custom Collectors

Extend the profiler with custom data collectors:

```ruby
class MyCustomCollector < Profiler::Collectors::BaseCollector
  def name
    'my_custom'
  end

  def icon
    '🔧'
  end

  def priority
    100 # Lower = earlier in list
  end

  def subscribe
    # Subscribe to ActiveSupport::Notifications
    ActiveSupport::Notifications.monotonic_subscribe('my.event') do |name, started, finished, id, payload|
      @events ||= []
      @events << { name: name, duration: (finished - started) * 1000 }
    end
  end

  def collect
    # Collect data at end of request
    store_data({
      event_count: @events&.size || 0,
      events: @events || []
    })
  end

  def toolbar_summary
    # Summary for toolbar
    {
      text: "#{@events&.size || 0} custom events",
      color: "blue"
    }
  end

  def panel_content
    # Full panel content for UI
    @data
  end
end

# Register the collector
Profiler.configure do |config|
  config.collectors << MyCustomCollector
end
```

### Custom Collector Views

Create custom templates at:

```
app/views/profiler/collectors/my_custom/
├── _toolbar.html.erb    # Toolbar partial
└── _panel.html.erb      # Full panel content
```

## Development

### Local Development Setup

The project has two separate bundles:

1. **Gem bundle** (root directory) - For gem development and testing
2. **Test app bundle** (`test_app/`) - For testing the gem in a real Rails app

```bash
# Install gem dependencies
bundle install

# Install test app dependencies (separate bundle)
cd test_app
bundle install
cd ..
```

The test app has its own `.bundle/config` to ensure dependencies are installed in `test_app/vendor/bundle`, keeping it isolated from the gem's bundle.

### Running the Test App

```bash
cd test_app
bundle exec rails server
```

Then visit `http://localhost:3000` to see the profiler in action.

### Development with Docker

The gem includes Docker support for development:

```bash
# Build containers
make build

# Start services
make up

# Open shell
make shell

# Run tests
make test

# Start test Rails app
make test-app
```

## Storage Backends

### Memory Store (Development)

Fast, in-memory storage. Data is lost on restart.

```ruby
config.storage = :memory
config.storage_options = { max_profiles: 100 }
```

### File Store (Production)

Persistent file-based storage in `tmp/profiler/`.

```ruby
config.storage = :file
config.storage_options = {
  path: Rails.root.join('tmp', 'profiler'),
  max_size: 100.megabytes
}
```

### Redis Store (Distributed)

Redis-based storage for multi-server deployments.

```ruby
config.storage = :redis
config.storage_options = {
  url: ENV['REDIS_URL'],
  ttl: 24.hours,
  key_prefix: 'profiler'
}
```

## Performance Impact

The profiler is designed for minimal overhead:

- Only active when enabled (defaults to development only)
- Async storage writes
- Lazy loading of panel content
- Automatic cleanup of old profiles
- Configurable skip paths for static assets

Expected overhead: < 5ms per request in development mode.

## Security

- Disabled by default in production
- Configurable authorization
- Sensitive parameter sanitization (passwords, tokens, secrets)
- Token-based profile access
- XSS protection in UI

## Testing

```bash
# Run all tests
bundle exec rspec

# Run specific test
bundle exec rspec spec/collectors/database_collector_spec.rb
```

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](MIT-LICENSE).
