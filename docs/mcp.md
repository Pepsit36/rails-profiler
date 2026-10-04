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

## Cluster (Master/Slave)

When running multiple Rails instances (e.g. git worktrees or microservices), connect them as a cluster so the master MCP server can query any slave.

All tools accept an optional `slave` parameter: pass the slave's name to target it instead of the local profiler.

```
# Local profiler (default)
query_profiles path: "/api/users"

# Slave profiler named "payment"
query_profiles path: "/api/charges", slave: "payment"

# List all connected slaves and their status
list_slaves
```

See [Cluster setup](../README.md#cluster-multi-instance) for configuration details.

---

## Tools

> **Cluster note:** All tools accept an optional `slave: "<name>"` parameter. When provided, the master proxies the request to the named slave profiler and returns its data. Omit `slave` to query the local profiler. Use `list_slaves` to see available slaves and their status.

### `list_slaves`

List all slave profilers connected to this master and their connection status.

Takes no parameters.

**Returns:** table of connected slaves with name, URL, status (`online` / `offline`), registration time, and last heartbeat.

---

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
| `slave` | string | Name of a connected slave profiler to query (omit for local data) |

**Example prompts:**
> "Show me the slowest API requests from the last hour"
> "List all POST requests that took more than 500ms"
> "Show me requests on the payment slave that took more than 200ms"

---

### `get_profile`

Get the full detail of a specific profile. Use `"latest"` as token to get the most recent request.

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | string | Profile token or `"latest"` **(required)** |
| `sections` | array | Sections to include: `overview`, `exception`, `job`, `console`, `request`, `response`, `curl`, `database`, `performance`, `views`, `cache`, `ajax`, `http`, `mailers`, `routes`, `dumps`, `logs`, `env`, `i18n`, `related_jobs` |
| `log_min_level` | string | Minimum log level when using the `logs` section: `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL` |
| `env_filter` | string | Required when using the `env` section — case-insensitive substring filter on ENV key name (e.g. `"RAILS"`, `"DATABASE"`) |
| `save_bodies` | boolean | Save request/response bodies to temp files; return paths instead of inline content |
| `max_body_size` | number | Truncate inline body at N characters |
| `json_path` | string | JSONPath expression to extract from response body (e.g. `$.data.items[0]`) |
| `xml_path` | string | XPath expression to extract from response body |
| `slave` | string | Name of a connected slave profiler to query |

**Example prompts:**
> "Show me the full details of the latest request"
> "Get the database queries section for token abc123"
> "Get the response body of the latest profile, extract $.users[0]"
> "Show me the Rails logs from the latest request (WARN and above)"
> "Which ENV variables starting with REDIS were active during this request?"
> "Are there any missing i18n translations in the latest profile?"

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
Only read-only statements (`SELECT`, `WITH ... SELECT`, `TABLE`, `VALUES`) are explained, in a
transaction always rolled back; any other query returns an error. See
[Explaining a query](../README.md#explaining-a-query).

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

### `get_profile_mailers`

Get detailed mailer activity for a profile: delivered emails (with bodies when `capture_mail_body` is enabled), delivery errors, and emails queued via `deliver_later`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | string | Profile token or `"latest"` **(required)** |
| `mailer_class` | string | Filter by mailer class (partial match, e.g. `"UserMailer"`) |
| `action` | string | Filter by mailer action (partial match, e.g. `"welcome_email"`) |
| `delivery_mode` | string | Filter by mode: `"deliver_now"`, `"deliver_later"`, or `"queued"` |
| `save_bodies` | boolean | Save email bodies to temp files; return paths instead of inline content |
| `max_body_size` | number | Truncate inline body content at N characters |

**Example prompts:**
> "Show me all emails sent during the latest request, including their HTML body"
> "Were there any mailer errors in profile abc123?"
> "Which emails were queued via deliver_later in the latest request?"

---

### `query_test_profiles`

Search and filter test profiles captured by the test profiler (RSpec / Minitest).

| Parameter | Type | Description |
|-----------|------|-------------|
| `test_name` | string | Filter by test name substring (e.g. `"UserSpec"`) |
| `status` | string | `"passed"`, `"failed"`, or `"pending"` |
| `min_duration` | number | Minimum duration in milliseconds |
| `limit` | number | Max results (default: 20) |
| `fields` | array | Columns: `time`, `test_name`, `status`, `duration`, `queries`, `n1`, `token` |
| `cursor` | string | Pagination cursor (ISO8601 timestamp) |

**Example prompts:**
> "Show me all failing tests"
> "Which tests are slowest and have N+1 queries?"

---

### `get_test_profile`

Get full detail for a single test profile. Use `"latest"` to get the most recent test.

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | string | Test profile token or `"latest"` **(required)** |

**Returns:** test metadata (name, framework, file, line, assertions), status, exception message, SQL queries, N+1 patterns, cache operations.

**Example prompts:**
> "Show me the detail of the latest failing test"
> "What SQL queries did this test fire? Are there N+1 patterns?"

---

### `run_tests`

Run test files and wait for results. Synchronous — blocks until tests complete or timeout is reached. Returns output, status, and tokens of test profiles created during the run.

| Parameter | Type | Description |
|-----------|------|-------------|
| `files` | array | Relative paths of discovered test files to run, optionally with a line number (e.g. `["spec/models/user_spec.rb", "spec/models/post_spec.rb:12"]`). Omit to run all discovered tests. A file that is not a discovered test is refused with a tool error, and nothing runs. |
| `framework` | string | `"rspec"` or `"minitest"`. Auto-detected if omitted. |
| `timeout_seconds` | number | Max wait time in seconds (default: 120). |
| `max_output` | number | Max characters of output returned (tail, default: 4000). |

**Returns:** run summary (status, duration, exit code), truncated output, and the token list of test profiles created — use these with `get_test_profile` or `analyze_queries` to drill in.

**Example prompts:**
> "Run spec/models/user_spec.rb and show me the results"
> "Run all the model specs and tell me which ones are slow or have N+1 queries"
> "Run the failing tests and analyze the SQL queries from each one"

---

### `query_mailers`

Search and filter ActionMailer deliveries across profiles. Returns emails sent via `deliver_now` or `deliver_later`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `mailer_class` | string | Filter by mailer class name (partial match, e.g. `"UserMailer"`) |
| `action` | string | Filter by mailer action name (partial match, e.g. `"welcome_email"`) |
| `delivery_mode` | string | `"deliver_now"` or `"deliver_later"` |
| `has_error` | boolean | Only return emails with delivery errors |
| `limit` | number | Max results (default: 20) |
| `fields` | array | Columns: `time`, `mailer`, `action`, `subject`, `to`, `mode`, `duration`, `status`, `token` |
| `cursor` | string | Pagination cursor |

**Example prompts:**
> "Have any emails failed to deliver recently?"
> "Show me all welcome emails sent in the last hour"
> "Which mailer actions are called most often?"

---

### `query_console_profiles`

Search and filter Rails console profiling sessions (IRB / `rails console` executions).

| Parameter | Type | Description |
|-----------|------|-------------|
| `expression` | string | Filter by expression content (partial match, e.g. `"User.find"`) |
| `status` | string | `"completed"` or `"failed"` |
| `min_duration` | number | Minimum duration in milliseconds |
| `limit` | number | Max results (default: 20) |
| `fields` | array | Columns: `time`, `expression`, `return_value`, `status`, `duration`, `queries`, `token` |
| `cursor` | string | Pagination cursor |

**Example prompts:**
> "What console commands have been run recently?"
> "Show me all console expressions that triggered more than 5 SQL queries"
> "Find the console session where I ran User.find_by"

---

### `clear_profiles`

Clear profiler history.

| Parameter | Type | Description |
|-----------|------|-------------|
| `type` | string | Optional: `"http"` to clear only requests, `"job"` to clear only jobs, `"test"` to clear only test profiles, `"console"` to clear only console sessions. Omit to clear all. |

---

## ENV Variables

These tools let you override Rails `ENV` variables at runtime without restarting the app. Overrides are persisted across restarts until explicitly reset.

### `list_env_vars`

List environment variables. By default shows only active overrides.

| Parameter | Type | Description |
|-----------|------|-------------|
| `include_all` | boolean | Return all ENV variables, not just overrides (default: `false`) |
| `filter` | string | Case-insensitive substring filter on key name |

---

### `set_env_var`

Set an environment variable and persist the override across app restarts.

The override reaches the processes started by `run_tests`, except for variables that make them load
or run other code (`RUBYOPT`, `SPEC_OPTS`, `BUNDLE_*`, `PATH`, `BASH_ENV`...): those processes get
the value from before the override. The full list is in the README, section "Test runner".

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Variable name **(required)** |
| `value` | string | New value **(required)** |

**Example prompts:**
> "Set FEATURE_NEW_DASHBOARD to true"
> "Change REDIS_URL to point to my local instance"

---

### `delete_env_var`

Delete an environment variable for this session (persisted across restarts until reset).

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Variable name **(required)** |

---

### `reset_env_var`

Restore a single overridden environment variable to its original value.

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Variable name to restore **(required)** |

---

### `reset_all_env_vars`

Restore all overridden environment variables to their original values. Takes no parameters.

---

## Resources

MCP resources are read-only data feeds that Claude can subscribe to or read on demand.

| URI | Description |
|-----|-------------|
| `profiler://recent` | Last 50 profiled HTTP requests |
| `profiler://slow-queries` | Slow SQL queries aggregated across all profiles |
| `profiler://n1-patterns` | Cross-profile N+1 query pattern detection (last 100 profiles) |
| `profiler://recent-jobs` | Recently profiled background jobs |
| `profiler://slow-tests` | Top 10 slowest test profiles with query counts and N+1 flags |
| `profiler://failing-tests` | Recent failing test profiles with exception messages |
| `profiler://recent-console` | Recently profiled Rails console executions |

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

### Run and analyze tests
> "Run spec/models/user_spec.rb, then show me the SQL queries from each test and flag any N+1 patterns."

### Find slow tests
> "Which tests in the suite are slowest? Read profiler://slow-tests and suggest optimizations."

### Debug a failing test
> "Run the failing spec, then get the full detail of the failed test profile including the exception and SQL queries."

### Inspect console activity
> "Show me all the Rails console commands run in the last hour that touched the database."

### Debug a mailer
> "Has UserMailer#welcome_email been called recently? Did any deliveries fail?"

### Toggle a feature flag via ENV
> "Set FEATURE_DARK_MODE to 'true' so I can test it in this session."

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
