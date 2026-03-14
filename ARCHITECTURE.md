# Rails Profiler - Architecture

## Overview

This document describes the architecture and implementation details of the Rails Profiler gem, a comprehensive profiling solution.

## Core Components

### 1. Middleware Layer

**ProfilerMiddleware** (`lib/profiler/middleware/profiler_middleware.rb`)
- Positioned at the top of the Rack middleware stack (position 0)
- Intercepts every request before it reaches the application
- Creates a `Profile` object for each request
- Manages collector lifecycle (subscribe → collect → store)
- Measures request duration and memory usage
- Delegates toolbar injection to `ToolbarInjector`

**ToolbarInjector** (`lib/profiler/middleware/toolbar_injector.rb`)
- Injects the debug toolbar HTML before `</body>` tag
- Only processes HTML responses (checks Content-Type)
- Adds inline JavaScript to load toolbar data asynchronously
- Includes minimal inline CSS for initial rendering

### 2. Data Collection System

**BaseCollector** (`lib/profiler/collectors/base_collector.rb`)
- Abstract base class for all collectors
- Defines the collector interface:
  - `subscribe()` - Set up ActiveSupport::Notifications listeners
  - `collect()` - Gather data at request end
  - `toolbar_summary()` - Provide summary for toolbar
  - `panel_content()` - Provide full data for detail view
- Auto-registration via `inherited` hook

**Built-in Collectors:**

1. **RequestCollector** - Request/response metadata
   - Path, method, status code
   - Parameters (sanitized)
   - Headers (filtered)
   - Duration and memory

2. **DatabaseCollector** - SQL query profiling
   - Subscribes to `sql.active_record` notifications
   - Captures query text, duration, binds
   - Records backtrace for each query
   - Identifies slow queries, cached queries, transactions
   - Detects potential N+1 problems

3. **PerformanceCollector** - Timeline events
   - Subscribes to multiple notifications:
     - `process_action.action_controller`
     - `render_template.action_view`
     - `render_partial.action_view`
   - Creates timeline events with duration
   - Builds hierarchical event structure

4. **ViewCollector** - View rendering metrics
   - Tracks template rendering
   - Tracks partial rendering
   - Records duration for each render

5. **CacheCollector** - Cache operations
   - Subscribes to cache notifications:
     - `cache_read.active_support`
     - `cache_write.active_support`
     - `cache_delete.active_support`
   - Calculates hit rate
   - Tracks cache performance

### 3. Storage Layer

**Storage Architecture:**
- Abstract `BaseStore` defines the interface
- Multiple backend implementations
- Pluggable via configuration

**MemoryStore** (`lib/profiler/storage/memory_store.rb`)
- Thread-safe using `Concurrent::Hash`
- Automatic cleanup when max profiles reached
- Best for: Development, single-process apps
- Default in: Development environment

**FileStore** (`lib/profiler/storage/file_store.rb`)
- Writes JSON files to `tmp/profiler/`
- Automatic size-based cleanup
- Survives restarts
- Best for: Production debugging, multi-process apps
- Default in: Production environment

**RedisStore** (`lib/profiler/storage/redis_store.rb`)
- Uses Redis sorted sets for efficient listing
- TTL-based auto-expiration
- Best for: Distributed systems, multiple servers
- Requires: Redis connection

### 4. Rails Integration

**Railtie** (`lib/profiler/railtie.rb`)
- Hooks into Rails initialization
- Sets default configuration based on environment
- Inserts middleware at position 0
- Loads default collectors
- Registers rake tasks

**Engine** (`lib/profiler/engine.rb`)
- Mounts routes at `/_profiler`
- Isolates namespace to avoid conflicts
- Configures asset paths
- Makes helpers available to host app

### 5. Web Interface

**Controllers:**
- `ProfilesController` - List and show profiles
  - `index` - Paginated list with filtering
  - `show` - Profile detail with tabs
  - Tab-specific actions (timeline, database, views, cache)

- `Api::ToolbarController` - AJAX endpoint for toolbar
  - Returns rendered HTML + JSON data
  - Cached per profile token

**Views:**
- ERB templates with inline styles (no external CSS required)
- Dark theme matching VS Code colors
- Responsive layout
- Tab-based navigation
- Lazy loading of panel content

**Routes:**
```
GET  /_profiler              - Profile list
GET  /_profiler/profiles/:id - Profile detail
GET  /_profiler/profiles/:id/:tab - Tab content
GET  /_profiler/api/toolbar/:token - Toolbar data (AJAX)
```

### 6. Frontend Assets

**TypeScript Modules:**
- `main.ts` - Entry point, initialization
- `toolbar.ts` - Toolbar interactions (toggle, keyboard shortcuts)
- `timeline.ts` - SVG timeline visualization
- `sql-formatter.ts` - SQL syntax highlighting
- `api-client.ts` - Type-safe API client

**SCSS Modules:**
- `_variables.scss` - CSS custom properties
- `_toolbar.scss` - Toolbar styles
- `_profiles.scss` - Profile list/detail styles
- `_timeline.scss` - Timeline visualization styles
- `_syntax.scss` - Code syntax highlighting

**Build Process:**
- esbuild for TypeScript → JavaScript
- sass for SCSS → CSS
- Output to `app/assets/builds/`
- Served via Rails asset pipeline

### 7. MCP Server Integration

**MCP Server** (`lib/profiler/mcp/server.rb`)
- JSON-RPC 2.0 over stdio
- Implements MCP protocol version 2024-11-05
- Handles: initialize, tools/list, tools/call, resources/list, resources/read

**MCP Tools:**

1. **query_profiles** - Search/filter profiles
   ```
   Input: { path, method, min_duration, limit }
   Output: Markdown table of matching profiles
   ```

2. **get_profile** - Detailed profile data
   ```
   Input: { token }
   Output: Formatted profile with all collector data
   ```

3. **analyze_queries** - SQL analysis
   ```
   Input: { token }
   Output: N+1 detection, slow queries, duplicates
   ```

**MCP Resources:**

1. **profiler://recent** - Recent requests JSON
2. **profiler://slow-queries** - Slow queries across all profiles

**Claude Desktop Integration:**
```json
{
  "mcpServers": {
    "rails-profiler": {
      "command": "bundle",
      "args": ["exec", "rake", "profiler:mcp"],
      "cwd": "/path/to/rails/app"
    }
  }
}
```

## Data Flow

### Request Lifecycle

```
1. Request arrives
   ↓
2. ProfilerMiddleware intercepts (position 0)
   ↓
3. Create Profile object
   ↓
4. Subscribe all collectors to notifications
   ↓
5. Process request through app
   │ (Collectors listen to events)
   ↓
6. Request completes
   ↓
7. Call collect() on all collectors
   ↓
8. Store profile in backend
   ↓
9. Inject toolbar HTML (if HTML response)
   ↓
10. Return response
```

### Toolbar Loading

```
1. Page loads with toolbar placeholder
   ↓
2. Inline JavaScript executes
   ↓
3. Fetch /_profiler/api/toolbar/:token
   ↓
4. Server renders toolbar partial
   ↓
5. Returns HTML + JSON
   ↓
6. Replace placeholder with real toolbar
```

### Profile Viewing

```
1. Click toolbar or navigate to /_profiler
   ↓
2. Load profile list or detail page
   ↓
3. Click tab (e.g., "Database")
   ↓
4. AJAX request to /profiles/:id/database
   ↓
5. Server returns collector data as JSON
   ↓
6. Frontend renders tab content
```

## Configuration System

**Configuration DSL:**
```ruby
Profiler.configure do |config|
  config.enabled = true
  config.storage = :file
  config.collectors = [...]
  config.slow_query_threshold = 100
  # ... etc
end
```

**Configuration Object** (`lib/profiler/configuration.rb`)
- Holds all settings
- Provides `storage_backend` factory
- Implements authorization logic
- Default values for all options

## Extensibility

### Custom Collectors

```ruby
class MyCollector < Profiler::Collectors::BaseCollector
  def name; 'my_collector'; end
  def icon; '🔧'; end
  def subscribe; ...; end
  def collect; ...; end
  def toolbar_summary; ...; end
  def panel_content; ...; end
end
```

### Custom Views

Convention-based template discovery:
```
app/views/profiler/collectors/my_collector/
├── _toolbar.html.erb
└── _panel.html.erb
```

### Custom Storage Backend

```ruby
class MyStore < Profiler::Storage::BaseStore
  def save(token, profile); ...; end
  def load(token); ...; end
  def list(limit:, offset:); ...; end
  def cleanup(older_than:); ...; end
end
```

## Performance Considerations

### Overhead
- Middleware: ~1ms per request
- Collectors: ~2-3ms total
- Storage: Async, minimal impact
- Total: < 5ms in development mode

### Optimizations
- Lazy loading of panel content
- Async toolbar data fetch
- Memory-bounded storage
- Automatic cleanup
- Skip paths for static assets
- Monotonic time for accurate timing

## Security

### Measures
- Disabled by default in production
- Configurable authorization
- Parameter sanitization (passwords, tokens, secrets)
- Token-based profile access
- XSS protection in views
- CSP-friendly (no eval, inline scripts use nonces)

### Production Safety
- Environment-based defaults
- Authorization callbacks
- Skip paths configuration
- Rate limiting (via max_profiles)

## Testing Strategy

### Unit Tests
- Each collector
- Storage backends
- Models (Profile, SqlQuery, TimelineEvent)
- Configuration

### Integration Tests
- Middleware behavior
- Controller responses
- Toolbar injection
- MCP server protocol

### Manual Testing
- Docker-based test environment
- Example Rails app
- Browser testing
- MCP client testing

## Future Enhancements

1. **Real-time Updates**
   - WebSocket connection for live updates
   - Auto-refresh toolbar

2. **Advanced Visualizations**
   - Flame graphs for performance
   - Query execution plans
   - Memory allocation graphs

3. **Export/Import**
   - Export profiles as JSON/HAR
   - Import for comparison
   - Profile diffing

4. **Background Jobs**
   - Sidekiq/ActiveJob profiling
   - Job timeline integration

5. **HTTP Clients**
   - Track external API calls
   - HTTP request profiling

6. **Enhanced MCP**
   - More analysis tools
   - Real-time notifications
   - Profile subscriptions
