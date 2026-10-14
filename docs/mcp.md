# MCP Server Guide

The Rails Profiler ships an [MCP (Model Context Protocol)](https://modelcontextprotocol.io) server that lets AI assistants like Claude query profiling data directly from your Rails app. This enables AI-assisted performance debugging, N+1 analysis, and request inspection without switching tools.

It has 21 tools and 7 resources, all listed below; `lib/profiler/mcp/server.rb` registers them.

- [How it works](#how-it-works)
- [Tools at a glance](#tools-at-a-glance)
- [A real session: finding and fixing an N+1](#a-real-session-finding-and-fixing-an-n1)
- [Setup](#setup)
- [Tools](#tools) (reference) and [Resources](#resources)

## How it works

Without it, debugging a slow page with an assistant means copying the SQL tab, the logs or the
response body into the conversation by hand, and choosing what to copy before knowing what
matters. With it, the assistant lists the profiles itself, opens the one you are talking about,
reads the sections it needs and comes back with the next question already answered: which query
repeats, from which line, with which plan.

### Two transports

| | stdio | HTTP |
|---|---|---|
| What runs | a process the MCP client starts: `bundle exec rake profiler:mcp`, in the application's directory | the application itself, which answers at `/_profiler/mcp` |
| Configuration | none | `config.mcp_enabled = true` and `config.mcp_transport = :http` |
| Network | none: the client talks to the process over its standard input and output | an endpoint, behind the [checks below](#http-transport-alternative) |
| Profiles it reads | the profile store, which must be shared with the running application | those of the running application |
| `ENV` changes it makes | written to the store at once, applied by the running server at its next boot | applied at once in the running server |

The stdio process boots your application (it is a rake task with the Rails environment) and
reads the profiles from the configured store, so the store has to be one that other processes can
read: `:file` (the default in development and test), `:sqlite` or `:redis`, configured to the
same location as the server's. With `:memory`, the default outside development and test, it would
see an empty store of its own: use the HTTP transport there. See [Storage](storage.md).

### What the assistant can see and do

- **Read** every profile the profiler stored: requests, background jobs, console expressions and
  tests, section by section (the same data as the dashboard, after the
  [masking](security.md#sensitive-data) applied when the profile was stored).
- **Analyze** the SQL of a profile (N+1 patterns, duplicates, slow queries) and **explain** one of
  its queries.
- **Run** your test files and read the profiles they produce.
- **Change** the application's `ENV` (set, delete, reset an override) and **clear** the stored
  profiles.
- With a [cluster](#cluster-masterslave), do all of this on any connected slave.

### What it cannot do

- **Query your database.** There is no tool that takes SQL. `explain_query` takes a profile token
  and the index of a query that profile recorded, and only explains read-only statements, in a
  transaction always rolled back; a write, or a query whose bind values were masked when captured,
  is refused ([Explaining a query](usage.md#explaining-a-query)).
- **Read or change your code.** It sees what a profile records: file names and line numbers in
  backtraces, template names, logs. It cannot open a file or write one. An assistant that edits
  your code (Claude Code, for example) does so with its own tools, not through this server.
- **Make requests to your application.** It reads what was recorded: you, your browser, your jobs
  or your tests produce the profiles. The only thing it can start is a test run, and `run_tests`
  only accepts the test files the profiler discovered.
- **See masked values.** Parameters matched by `config.filter_parameters` and `ENV` variables
  outside `config.env_allowlist` are stored masked: the assistant gets the mask, not the value.

### Security

Over stdio, the server is only reachable by the client that started it. Over HTTP, every request
goes through the same access control as the dashboard, plus host, origin and content type checks,
listed under [HTTP transport](#http-transport-alternative). Remember that the write tools are part
of the same server: whoever passes these checks can change `ENV`, clear profiles and run
tests. Access control, masking and what is never applied in production are described in
[Security](security.md).

## Tools at a glance

Every tool but `list_slaves` takes an optional `slave` parameter (see
[Cluster](#cluster-masterslave)). The tools marked **write** change something; the others only
read.

| Use | Tools | Resources |
|---|---|---|
| Requests and profiles | [`query_profiles`](#query_profiles), [`get_profile`](#get_profile), [`get_profile_ajax`](#get_profile_ajax), [`get_profile_http`](#get_profile_http), [`get_profile_dumps`](#get_profile_dumps), [`get_profile_mailers`](#get_profile_mailers), [`query_mailers`](#query_mailers), [`clear_profiles`](#clear_profiles) (**write**) | `profiler://recent` |
| SQL | [`analyze_queries`](#analyze_queries), [`explain_query`](#explain_query) | `profiler://slow-queries`, `profiler://n1-patterns` |
| Background jobs | [`query_jobs`](#query_jobs), then `get_profile` on a job's token | `profiler://recent-jobs` |
| Tests | [`query_test_profiles`](#query_test_profiles), [`get_test_profile`](#get_test_profile), [`run_tests`](#run_tests) (**write**: runs your test files) | `profiler://slow-tests`, `profiler://failing-tests` |
| Console | [`query_console_profiles`](#query_console_profiles) | `profiler://recent-console` |
| `ENV` variables | [`list_env_vars`](#list_env_vars), [`set_env_var`](#set_env_var) (**write**), [`delete_env_var`](#delete_env_var) (**write**), [`reset_env_var`](#reset_env_var) (**write**), [`reset_all_env_vars`](#reset_all_env_vars) (**write**) | |
| Cluster | [`list_slaves`](#list_slaves), and the `slave` parameter of every other tool | |

Most tools that take a profile token also accept `"latest"` for the most recent profile;
`explain_query` does not, it needs the token itself.

## A real session: finding and fixing an N+1

Everything below was produced against the demo application of the screenshots
([docs/screenshots](screenshots/README.md)), whose `/api/n_plus_one` endpoint loads ten posts and
then each post's author, one query at a time. The tool calls are the ones an assistant makes for a
question such as *"`/api/n_plus_one` feels slow, can you find out why and fix it?"*. They were
made with the [MCP Inspector](https://github.com/modelcontextprotocol/inspector) command line
client over the stdio transport, so that anyone can replay them:
[`docs/screenshots/mcp-session.sh`](screenshots/mcp-session.sh) does it end to end. The responses
are the text the tools returned, shortened where marked with `[...]`; timings and tokens change
from one run to the next.

**1. Find the request.** `query_profiles` with `path: "/api/n_plus_one"`, `limit: 1`:

~~~text
| Time | Type | Method | Path | Duration | Queries | Status | Token |
|------|------|------|------|------|------|------|------|
| 2026-10-13 22:40:47 | http | GET | /api/n_plus_one | 138.64ms | 11 | 200 | 06285ac8035f1a12f6177649d00b0a63 |
~~~

Eleven queries for one JSON list is the first hint.

**2. Analyze its SQL.** `analyze_queries` with that token:

~~~text
## ⚠️ Duplicate Queries (Potential N+1)
Found 1 query pattern(s) repeated 3+ times:

### Executed 10 times:
```sql
SELECT ?.* FROM ? WHERE ?.? = ? LIMIT ?
```
#### Called from:
  app/controllers/api_test_controller.rb:82:in `block in ApiTestController#n_plus_one`
  app/controllers/api_test_controller.rb:80:in `Array#map`
  app/controllers/api_test_controller.rb:80:in `ApiTestController#n_plus_one`

## Summary Statistics
- **Total Queries:** 11
- **Total Duration:** 3.82ms
[...]
- **N+1 Patterns (≥3×):** 1
~~~

**3. Look at the queries themselves.** `get_profile` with `sections: ["database"]` shows which
query repeats, and that it comes from line 82:

~~~text
**Query 1** (1.76ms):
```sql
SELECT "posts".* FROM "posts"
```
_Backtrace:_
  app/controllers/api_test_controller.rb:78:in `ApiTestController#n_plus_one`

**Query 2** (0.29ms):
```sql
SELECT "authors".* FROM "authors" WHERE "authors"."id" = ? LIMIT ?
```
_Backtrace:_
  app/controllers/api_test_controller.rb:82:in `block in ApiTestController#n_plus_one`
[...]
~~~

**4. Explain the repeated query.** `get_profile` numbers the queries from 1, `explain_query`
counts from 0: "Query 2" is `query_index: 1`. On SQLite the plan is `EXPLAIN QUERY PLAN`'s:

~~~text
Adapter: `sqlite`

```
3	0	33	SEARCH authors USING INTEGER PRIMARY KEY (rowid=?)
```
~~~

Each lookup already uses the primary key: no index is missing, the cost is the number of
round trips. The fix is to load the authors together with the posts.

**5. Fix it.** Line 78 of the controller:

```diff
-    posts = Post.all.to_a
+    posts = Post.includes(:author).to_a
```

**6. Check.** After one more request to `/api/n_plus_one` (Rails reloads the controller in
development), `analyze_queries` with `token: "latest"` and `summary_only: true`:

~~~text
## Summary Statistics
- **Total Queries:** 2
- **Total Duration:** 2.26ms
[...]
- **N+1 Patterns (≥3×):** 0
~~~

and `get_profile` shows the two queries left:

~~~text
**Query 1** (2.07ms):
```sql
SELECT "posts".* FROM "posts"
```
[...]
**Query 2** (0.19ms):
```sql
SELECT "authors".* FROM "authors" WHERE "authors"."id" IN (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
```
~~~

From eleven queries to two. The durations of a demo application with ten rows say little; on a
real page, the number of round trips is what grows with the data.

## Setup

### 1. Pick a transport

The **stdio** transport is a process the MCP client starts itself, `bundle exec rake
profiler:mcp`, in the application's directory. It needs no option, no route and no network
access: prefer it when the client runs on the same machine.

The **HTTP** transport answers at `/_profiler/mcp` on the running application, only once both
options are set (see [HTTP transport](#http-transport-alternative) below):

```ruby
# config/initializers/profiler.rb
Profiler.configure do |config|
  config.mcp_enabled = true
  config.mcp_transport = :http
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

From the root of the Rails application:

```bash
claude mcp add rails-profiler -- bundle exec rake profiler:mcp
```

Or, to share it with the project, in a `.mcp.json` file at the root of the application:

```json
{
  "mcpServers": {
    "rails-profiler": {
      "command": "bundle",
      "args": ["exec", "rake", "profiler:mcp"]
    }
  }
}
```

### HTTP transport (alternative)

The endpoint `/_profiler/mcp` is routed only when **both** `config.mcp_enabled = true` and
`config.mcp_transport = :http` are set; otherwise it answers `404`. The stdio transport does not
depend on it.

Each request goes through the profiler's own checks before the MCP server sees it, and gets a `403`
otherwise (`lib/profiler/mcp/http_guard.rb`):

- the profiler is enabled;
- the `Host` header names a loopback address (`localhost`, `127.0.0.1`, `::1`), a host your
  application lists in `config.hosts`, or an entry of `config.mcp_allowed_hosts` (see
  [Behind a reverse proxy](#behind-a-reverse-proxy)), which keeps a DNS rebinding page from
  reaching the tools;
- the request passes `authorization_mode` (`:allow_local` by default: from this machine only; see
  [Access control](security.md#access-control));
- an `Origin` header, when present, is the profiler's own or one of `cors_allowed_origins`,
  whatever `extension_cors_enabled` and `api_forgery_protection` say;
- a `POST` carries `Content-Type: application/json`. MCP clients send JSON already; a page on
  another site cannot without a CORS preflight. `config.api_forgery_protection = false` turns this
  last check off.

None of the tools (including the ones that write `ENV`, clear profiles or run tests) is reachable
without passing these checks. MCP clients that run inside a web page are not supported:
`cors_allowed_origins = ["*"]` opens the API, not the MCP endpoint, whose `Origin` must be the
profiler's own or listed by name.

A Claude Code entry for a local server:

```json
{
  "mcpServers": {
    "rails-profiler": {
      "type": "http",
      "url": "http://localhost:3000/_profiler/mcp"
    }
  }
}
```

Prefer the stdio transport when the client runs on the same machine: it opens no endpoint at all.

#### Behind a reverse proxy

An application behind Traefik already lists its domain in `config.hosts` (Rails refuses the other
hosts in development), so it usually has nothing to set. An empty `config.hosts`, which turns
Rails' check off, allows nothing more. For hosts outside `config.hosts`:

```ruby
# config/initializers/profiler.rb, for an API reached through Traefik and from other containers
Profiler.configure do |config|
  config.mcp_enabled = true
  config.mcp_transport = :http
  config.mcp_allowed_hosts = ["api.myapp.test", %r{\Amyapp[a-z0-9-]*\z}]
end
```

A String names a host (any port) or a `host:port`, compared without case; `*` is refused. A
`Regexp` must start with `\A` and end with `\z`, and is matched against the whole host name,
without the port; any other `Regexp` raises an `ArgumentError` when it is assigned. Through a proxy
the request also has to pass `authorization_mode`: with the default, `:allow_local`, see
[Access control](security.md#access-control) for Docker and proxies.

#### Upgrading from versions that always routed it

In earlier versions, `/_profiler/mcp` was routed in every application, whatever `mcp_enabled` and
`mcp_transport` said, and answered anyone. An installation that used the HTTP endpoint while
`mcp_transport` was left at its default, `:stdio`, now has to set `config.mcp_enabled = true` and
`config.mcp_transport = :http`. There is no setting that routes it without the checks. Two general
settings loosen them: `config.authorization_mode = :allow_all` (anyone who can reach the
application can then read and change everything the profiler exposes, through the MCP tools as
well as the API) and `config.api_forgery_protection = false`, which drops the `Content-Type`
check only: the `Origin` check stays.

---

## Cluster (Master/Slave)

When running multiple Rails instances (for example git worktrees or microservices), connect them as a cluster so the master MCP server can query any slave.

Every tool but `list_slaves` accepts an optional `slave` parameter: pass the slave's name to target it instead of the local profiler.

```
# Local profiler (default)
query_profiles path: "/api/users"

# Slave profiler named "payment"
query_profiles path: "/api/charges", slave: "payment"

# List all connected slaves and their status
list_slaves
```

The master reaches a slave only if the slave registered with the shared `cluster_secret` and its
URL is allowed by `cluster_allowed_slave_urls`; otherwise the tool returns an error and no request
is sent. See [Cluster](cluster.md) for configuration details.

---

## Tools

> **Cluster note:** Every tool but `list_slaves` accepts an optional `slave: "<name>"` parameter. When provided, the master proxies the request to the named slave profiler and returns its data. Omit `slave` to query the local profiler. Use `list_slaves` to see available slaves and their status.

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
| `env_filter` | string | Required when using the `env` section: case-insensitive substring filter on ENV key name (e.g. `"RAILS"`, `"DATABASE"`) |
| `save_bodies` | boolean | Save request/response bodies to temp files; return paths instead of inline content |
| `max_body_size` | number | Truncate inline body at N characters. Ignored when the body is saved (`save_bodies`) |
| `json_path` | string | JSONPath expression to extract from response body (e.g. `$.data.items[0]`). Only applied with `save_bodies: true` |
| `xml_path` | string | XPath expression to extract from response body. Only applied with `save_bodies: true` |
| `slave` | string | Name of a connected slave profiler to query |

**Example prompts:**
> "Show me the full details of the latest request"
> "Get the database queries section for token abc123"
> "Save the response body of the latest profile and extract $.users[0]"
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
[Explaining a query](usage.md#explaining-a-query).

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | string | Profile token **(required)**. `"latest"` is not accepted: take the token from `query_profiles` |
| `query_index` | integer | Zero-based index of the query in the profile **(required)**. `get_profile` numbers the queries from 1: its "Query 3" is `query_index: 2` |

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
| `max_body_size` | number | Truncate inline body at N characters. Ignored when the body is saved (`save_bodies`) |
| `json_path` | string | JSONPath to extract from response bodies. Only applied with `save_bodies: true` |
| `xml_path` | string | XPath to extract from response bodies. Only applied with `save_bodies: true` |

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

Run test files and wait for results. Synchronous: blocks until tests complete or timeout is reached. Returns output, status, and tokens of test profiles created during the run.

| Parameter | Type | Description |
|-----------|------|-------------|
| `files` | array | Relative paths of discovered test files to run, optionally with a line number (e.g. `["spec/models/user_spec.rb", "spec/models/post_spec.rb:12"]`). Omit to run all discovered tests. A file that is not a discovered test is refused with a tool error, and nothing runs. |
| `framework` | string | `"rspec"` or `"minitest"`. Auto-detected if omitted. |
| `timeout_seconds` | number | Max wait time in seconds (default: 120). |
| `max_output` | number | Max characters of output returned (tail, default: 4000). |

**Returns:** run summary (status, duration, exit code), truncated output, and the token list of test profiles created; use these with `get_test_profile` or `analyze_queries` to drill in.

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
or run other code (`RUBYOPT`, `SPEC_OPTS`, `BUNDLE_*`, `PATH`, `BASH_ENV`...): those processes keep
the value from the shell that started Rails. The full list is in [Tests](testing.md#test-runner).

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
# Start the MCP server (stdio transport, for Claude Desktop and Claude Code)
bundle exec rake profiler:mcp

# List recent profiles
bundle exec rake profiler:list

# Show a specific profile
bundle exec rake profiler:show TOKEN=abc123...

# Clean up old profiles
bundle exec rake profiler:cleanup OLDER_THAN=86400
```
