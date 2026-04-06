# Rails Profiler — MCP Server Guide

The Rails Profiler ships an [MCP (Model Context Protocol)](https://modelcontextprotocol.io) server that lets AI assistants like Claude query profiling data directly from your Rails app. This enables AI-assisted performance debugging, N+1 analysis, and request inspection without switching tools.

## Setup

### 1. Enable MCP in the initializer

```ruby
# config/initializers/profiler.rb
Profiler.configure do |config|
  config.mcp_enabled = true
  config.mcp_transport = :stdio  # default — for Claude Desktop / Claude Code
  # config.mcp_transport = :http  # alternative — exposed at /_profiler/mcp
end
```

### 2. Configure Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

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

### 3. Configure Claude Code

Add to your project's `.claude/settings.json` or run from within Claude Code:

```json
{
  "mcpServers": {
    "rails-profiler": {
      "command": "bundle",
      "args": ["exec", "rake", "profiler:mcp"],
      "cwd": "/path/to/your/rails/app"
    }
  }
}
```

### HTTP transport (alternative)

When `mcp_transport: :http`, the MCP endpoint is available at `/_profiler/mcp` and can be connected from any MCP-compatible client.

---

## Tools

### `query_profiles`

Search and filter profiled HTTP requests.

| Parameter | Type | Description |
|-----------|------|-------------|
| `path` | string | Filter by path substring (e.g. `"/api/users"`) |
| `method` | string | HTTP method (`GET`, `POST`, etc.) |
| `min_duration` | number | Minimum duration in milliseconds |
| `profile_type` | string | `"http"` or `"job"` |
| `limit` | number | Max results (default: 20) |
| `fields` | array | Columns to return: `time`, `type`, `method`, `path`, `duration`, `queries`, `status`, `token` |
| `cursor` | string | ISO8601 timestamp for pagination (returns profiles older than this) |

**Example prompts:**
> "Show me the slowest API requests from the last hour"
> "List all POST requests that took more than 500ms"

---

### `get_profile`

Get the full detail of a specific profile. Use `"latest"` as token to get the most recent request.

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | string | Profile token or `"latest"` **(required)** |
| `sections` | array | Sections to include: `overview`, `exception`, `job`, `request`, `response`, `curl`, `database`, `performance`, `views`, `cache`, `ajax`, `http`, `routes`, `dumps` |
| `save_bodies` | boolean | Save request/response bodies to temp files; return paths instead of inline content |
| `max_body_size` | number | Truncate inline body at N characters |
| `json_path` | string | JSONPath expression to extract from response body (e.g. `$.data.items[0]`) |
| `xml_path` | string | XPath expression to extract from response body |

**Example prompts:**
> "Show me the full details of the latest request"
> "Get the database queries section for token abc123"
> "Get the response body of the latest profile, extract $.users[0]"

---

### `analyze_queries`

Analyze SQL queries for N+1 patterns, duplicates, and slow queries. Use `"latest"` as token.

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | string | Profile token or `"latest"` **(required)** |
| `summary_only` | boolean | Return only summary stats (skip per-query details) |

**Returns:** N+1 patterns detected, slow query list, duplicate query groups, and recommendations.

**Example prompts:**
> "Analyze the SQL queries in the latest request"
> "Are there any N+1 problems in this profile?"

---

### `explain_query`

Run `EXPLAIN ANALYZE` on a specific query from a profile and return the execution plan.

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | string | Profile token or `"latest"` **(required)** |
| `query_index` | integer | Zero-based index of the query in the profile **(required)** |

**Example prompts:**
> "Run EXPLAIN on query #3 from the latest profile"
> "What's the execution plan for the slow query in token abc123?"

---

### `get_profile_ajax`

Get AJAX sub-request breakdown for a profile (requests triggered by JavaScript during the page load).

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | string | Profile token or `"latest"` **(required)** |

---

### `get_profile_dumps`

Get all variable dumps captured via `Profiler.dump()` during a request.

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | string | Profile token or `"latest"` **(required)** |

**Example prompts:**
> "What variables were dumped in the latest request?"
> "Show me the User data dump from profile abc123"

---

### `get_profile_http`

Get outbound HTTP request details for a profile (external API calls made via Net::HTTP).

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | string | Profile token or `"latest"` **(required)** |
| `domain` | string | Filter by domain substring (e.g. `"stripe.com"`) |
| `save_bodies` | boolean | Save bodies to temp files |
| `max_body_size` | number | Truncate inline body at N characters |
| `json_path` | string | JSONPath to extract from response bodies |
| `xml_path` | string | XPath to extract from response bodies |

**Example prompts:**
> "What external APIs were called during the latest request?"
> "Show me the Stripe API response from profile abc123"

---

### `query_jobs`

Search and filter background job profiles (Sidekiq, ActiveJob).

| Parameter | Type | Description |
|-----------|------|-------------|
| `queue` | string | Filter by queue name |
| `status` | string | `"completed"` or `"failed"` |
| `limit` | number | Max results (default: 20) |
| `fields` | array | Columns: `time`, `job_class`, `queue`, `status`, `duration`, `token` |
| `cursor` | string | Pagination cursor |

**Example prompts:**
> "Show me all failed background jobs"
> "List recent DataProcessingJob executions"

---

### `clear_profiles`

Clear profiler history.

| Parameter | Type | Description |
|-----------|------|-------------|
| `type` | string | Optional: `"http"` to clear only requests, `"job"` to clear only jobs. Omit to clear all. |

---

## Resources

MCP resources are read-only data feeds that Claude can subscribe to or read on demand.

| URI | Description |
|-----|-------------|
| `profiler://recent` | Last 50 profiled HTTP requests |
| `profiler://slow-queries` | Slow SQL queries aggregated across all profiles |
| `profiler://n1-patterns` | Cross-profile N+1 query pattern detection (last 100 profiles) |
| `profiler://recent-jobs` | Recently profiled background jobs |

---

## Useful prompt examples

### Debug a slow endpoint
> "The `/api/products` endpoint is slow. Look at the recent profiler data and tell me what's taking the most time."

### Find N+1 queries
> "Check the latest request for N+1 query patterns and suggest how to fix them."

### Inspect an API response
> "Get the response body of the latest request to `/api/users` and extract the first user's email."

### Audit outbound calls
> "Which external APIs are being called during requests to `/checkout`? Are any of them slow?"

### Check background jobs
> "Have any background jobs failed recently? Show me the error details."

### Compare requests
> "Compare the query count between the last 5 requests to `/dashboard`. Is there any variance?"

---

## Rake tasks

```bash
# Start the MCP server (stdio transport — for Claude Desktop / Claude Code)
bundle exec rake profiler:mcp

# List recent profiles
bundle exec rake profiler:list

# Show a specific profile
bundle exec rake profiler:show TOKEN=abc123...

# Clean up old profiles
bundle exec rake profiler:cleanup OLDER_THAN=86400
```
