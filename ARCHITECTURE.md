# Rails Profiler - Architecture

## Overview

This document describes how the Rails Profiler gem is built: what runs in the host application's
requests, where profiles are stored, how the dashboard, the toolbar, the MCP server and the
cluster read them, and how the front-end is built from the API contract. It is written for
contributors; users will find what they need in the [README](README.md) and under [docs/](docs/).

Paths are relative to the root of this repository. Lists that change often (collectors, MCP
tools, configuration options) are not copied here: each section points to the directory or the
page that is kept up to date with the code.

## Core Components

### 1. Middleware Layer

Two Rack middlewares are inserted at the top of the host application's stack by the railtie
(`lib/profiler/railtie.rb`), before the application's own initializers run, and taken out again
once they have run if `enabled` is false:

**ProfilerMiddleware** (`lib/profiler/middleware/profiler_middleware.rb`)
- First in the stack: sees every request before the application does
- Skips `skip_paths` and requests that `authorization_mode` does not let in
- Creates a `Profile` (`lib/profiler/models/profile.rb`) and subscribes its collectors
  (`Collectors::Lifecycle`), runs the application, collects, saves, and releases the collectors
  on every path, error paths included
- Adds the `X-Profiler-Token` header to the response, which the AJAX script and the browser
  extension read
- Captures request and response bodies up to `max_captured_body_bytes`; a streamed response
  (`ActionController::Live`, `render stream: true`, `send_file`, an enumerator) is handed to the
  server chunk by chunk through `CapturingBody`, and `StreamedProfile` keeps its collectors
  subscribed until the server closes the body
- Delegates toolbar injection to `ToolbarInjector`

**CorsMiddleware** (`lib/profiler/middleware/cors_middleware.rb`)
- Sets `Content-Security-Policy: frame-ancestors` and `X-Frame-Options` on every `/_profiler`
  response, and the CORS headers only when `extension_cors_enabled` is set

**ToolbarInjector** (`lib/profiler/middleware/toolbar_injector.rb`)
- Injects the toolbar before the `</body>` tag that closes the page, found outside scripts, style
  sheets and comments (no toolbar when there is none); only in HTML responses returned whole
- Adds a placeholder element carrying the profile token, inline styles, a small inline script that
  applies the theme and the collapsed state before the first paint, the AJAX interceptor
  (`app/assets/javascript/profiler-ajax-interceptor.js`, when `track_ajax` is on), and
  `/_profiler/assets/profiler-toolbar.js`, which loads the toolbar data asynchronously
- Uses the request's CSP nonce when the application sets one

### 2. Data Collection System

**BaseCollector** (`lib/profiler/collectors/base_collector.rb`)
- Base class of every collector
- Defines the collector interface:
  - `subscribe` / `unsubscribe`: install and release listeners (`unsubscribe` runs on every path
    and must be idempotent)
  - `collect`: gather data at the end of the request, stored with `store_data`
  - `toolbar_summary`, `panel_content`, `tab_config`: metadata kept with the profile
- `ScopedNotifications` (`lib/profiler/collectors/scoped_notifications.rb`) holds one
  `ActiveSupport::Notifications` subscriber per event name for the whole process and hands each
  event to the collectors of the execution context that emitted it, so that concurrent requests
  never see each other's SQL
- `Lifecycle` (`lib/profiler/collectors/lifecycle.rb`) subscribes and releases the collectors of
  one profile, for every entry point (requests, jobs, console, tests)

**Built-in collectors:** one file per collector in
[`lib/profiler/collectors/`](lib/profiler/collectors/), every `*_collector.rb` there except
`base_collector.rb` (18 as of 0.32.1). Which ones an HTTP request runs by default, and which ones
only jobs, console expressions and tests use, is listed in
[docs/configuration.md](docs/configuration.md#collectors); the default list itself is in
`lib/profiler/railtie.rb` (`profiler.load_collectors`). Several of them capture data that can be
sensitive (request bodies and headers, `ENV`, exceptions, dumps, mail bodies): everything they
store goes through `Profiler::Redaction` first (see [Security](#security)).

**Instrumentation outside notifications** (`lib/profiler/instrumentation/`):
- `NetHttpInstrumentation`: outbound `Net::HTTP` calls, for `HttpCollector`
- `ThreadContextPropagation` (prepended to `Thread#initialize` when the gem is loaded, whatever
  `enabled` says) and `ExecutorContextPropagation` (concurrent-ruby): hand the request's context to
  the threads and tasks it starts, through `RequestContext`
- `ActiveJobInstrumentation`, `SidekiqMiddleware` (server and client): profile jobs
  (`lib/profiler/job_profiler.rb`) and link them to the request that enqueued them
- `IrbInstrumentation`: profiles `rails console` expressions (`lib/profiler/console_profiler.rb`)

Tests are profiled by `lib/profiler/test_profiler.rb`, hooked into RSpec or Minitest by
`lib/profiler/test_helpers/`, and run from the dashboard or MCP by `lib/profiler/test_runner/`
(`Discovery`, `Runner`, `RunStore`).

### 3. Storage Layer

**Storage Architecture:**
- `BaseStore` (`lib/profiler/storage/base_store.rb`) defines the interface: `save` (which
  validates the token, calls the backend's `do_save`, then records the save for the toolbar's
  update checks), `load`, `list`, `find_by_parent`, `delete`, `clear`, `cleanup`
- `config.storage` picks the backend, built lazily by `Configuration#storage_backend`; the
  railtie defaults it to `:file` in development and test and to `:memory` elsewhere
- `Token` checks that a token is one the gem issued (32 hexadecimal characters) before any backend
  turns it into a file name or a key; `Summary` is what the lists show, kept apart from the full
  profile; `PrivateFiles` creates directories `0700` and files `0600`; `Unavailable` stands in for
  a store that could not be created, so that the dashboard answers `503` instead of failing

**Backends:**
- `MemoryStore` (`memory_store.rb`): a `Concurrent::Hash` per process, capped at `max_profiles`
- `FileStore` (`file_store.rb`): one JSON file per profile under `tmp_path/profiles`, an
  append-only index (`.profiles-index.jsonl`) shared by the processes of one machine under a lock
- `RedisStore` (`redis_store.rb`): sorted sets per type and per parent, TTL-based expiry, shared
  by several machines; needs the `redis` gem
- `SqliteStore` (`sqlite_store.rb`): one SQLite database, large payloads in `BlobStore`; needs
  the `sqlite3` gem

Every backend keeps at most `max_profiles` profiles. User-facing details:
[docs/storage.md](docs/storage.md).

**Save notifications** (`lib/profiler/sse/`): `EventBus` keeps, per process, a version number of
each profile's last save; `RedisEventBus` keeps it in Redis when the store is `RedisStore`, so that
every process sees the same versions. `GET /_profiler/api/events/:token` answers at once whether
the version moved; the toolbar polls it. Despite the directory name there is no Server-Sent Events
stream for profiles; the only `text/event-stream` route is the test runner's output.

### 4. Rails Integration

**Railtie** (`lib/profiler/railtie.rb`)
- Sets the defaults that depend on the Rails environment (`enabled`, `storage`, `track_tests`,
  `max_profiles`) only where the application has not assigned them, and applies
  `config.profiler.*`
- Inserts the two middlewares, then removes them after the application's initializers if
  `enabled` is false
- Loads the default collectors
- Installs the test, job (Sidekiq, ActiveJob) and console instrumentation, each only when enabled
- Starts the cluster client on a slave (see [section 8](#8-cluster-master-and-slaves))
- Applies the `ENV` overrides saved from the UI or MCP (`EnvOverrideStore`), never in production
- Registers the rake tasks (`lib/profiler/tasks/profiler.rake`)

**Engine** (`lib/profiler/engine.rb`, `config/routes.rb`)
- Isolated namespace; the host application mounts it, usually at `/_profiler`
- The MCP mount is routed only when `mcp_enabled` and `mcp_transport = :http`, and the cluster
  routes only when `cluster_master` is set: both constraints are read on each request

### 5. Web Interface

**Controllers** (`app/controllers/profiler/`):
- `ApplicationController`: the access check shared by every page and endpoint
  (`authorization_mode`, `LocalRequest` for `:allow_local`), forgery protection
  (`X-Profiler-Request` header or CSRF token), `403` while the profiler is disabled
- `ProfilesController`: the profile list (`index`) and a profile page (`show`), HTML; on a
  cluster master, `show` looks a token up locally, then on the slaves. Its member actions
  (`timeline`, `database`, `views`, `cache`, `performance`, `flamegraph`) return one collector's
  data as JSON, for the browser extension
- `TestRunnerController`: the test runner page
- `AssetsController`: serves `app/assets/builds/` (the gem ships no asset pipeline integration);
  the only routes without the access check, since they hold no application data
- `Api::*`: the JSON API of the dashboard, the toolbar, the AJAX script, the cluster and the
  extension (profiles, jobs, console, tests, outbound HTTP, toolbar, AJAX link, EXPLAIN, function
  profiling settings, `ENV` overrides, test runner, events, cluster, slave proxy)

**Views** (`app/views/`): two ERB layouts (`profiler/application`, and `profiler/embedded` for the
extension's DevTools panel, `?embed=true`) and three pages that only hold a mount point. A profile
page embeds the profile as JSON (`<script type="application/json" id="profiler-show-data">`,
escaped with `json_escape`), and the front-end renders every tab from it, without another request.

**Routes** (abridged, see `config/routes.rb`):
```
GET  /_profiler                         profile list (HTML)
GET  /_profiler/profiles/:id            profile page (HTML)
GET  /_profiler/profiles/:id/:collector one collector's data (JSON, for the extension)
GET  /_profiler/test_runner             test runner page (HTML)
GET  /_profiler/assets/*                compiled JS and CSS
     /_profiler/api/...                 JSON API, see swagger/v1/swagger.yaml
     /_profiler/mcp                     MCP over HTTP, when enabled
```

**API contract (OpenAPI):**

`swagger/v1/swagger.yaml` is the contract of the JSON API consumed by the dashboard and the
browser extension (27 paths as of 0.32.1); see [OpenAPI pipeline](#openapi-pipeline-single-source-of-truth)
for how it is produced and consumed. Two API routes are deliberately **outside** it, because an
OpenAPI path cannot describe them truthfully:

- `GET /_profiler/api/test_runner/runs/:id/stream` answers `text/event-stream` (Server-Sent
  Events frames: `output` events with a numeric `id`, a final `done` event, a `retry:` hint),
  resumable through the `Last-Event-ID` header or the `position` parameter. Each response
  carries the output produced so far and then ends; the client's `EventSource` reconnects after
  the `retry:` delay with the position it reached. The payload is a sequence of events, not one
  JSON document, and a generated client cannot model it.
- `ANY /_profiler/api/slaves/:slave_name/*path` is the cluster proxy. It accepts an arbitrary
  path and forwards `GET`, `POST`, `PATCH` and `DELETE` to the same path under the slave's
  `/_profiler/api/`. Its contract is the slave's own contract (this file, read on the slave),
  so listing it would mean duplicating every endpoint under a wildcard. It is routed only on a
  node with `cluster_master` set.

The master-side cluster routes (`cluster/register`, `cluster/heartbeat`, `cluster/slaves`),
`ajax/link` and `events/:token` are in the contract. `events/:token` is a plain JSON poll that
answers at once, despite its name, so it needs no exception. The other routes outside it are not
part of the JSON API: the `/_profiler/mcp` mount speaks the MCP protocol (see
[docs/mcp.md](docs/mcp.md)), `profiles#index`, `profiles#show` and `test_runner#index` return
pages, and the member actions of `profiles` (`timeline`, `database`, `views`, `cache`,
`performance`, `flamegraph`) return one collector's raw data, whose shape is the collector's, for
the extension's older client.

### 6. Frontend Assets

The dashboard and the toolbar are written in TypeScript with **Preact** and JSX
(`app/assets/typescript/profiler/`), styled with SCSS (`app/assets/stylesheets/profiler/`), and
built by esbuild and sass into `app/assets/builds/`, which the published gem ships and
`AssetsController` serves. There is no Rails asset pipeline involved.

**Entry points** (`package.json`, scripts `build:js` and `build:toolbar`):
- `main.tsx` builds `profiler.js`, loaded by the dashboard layout: it mounts the profile list
  (`components/ProfileList.tsx`), a profile page (`components/dashboard/ProfileDashboard.tsx`, or
  `JobProfileDashboard`, `ConsoleProfileDashboard`, `TestProfileDashboard` by profile type), the
  test runner (`components/test-runner/`) and, on a cluster master, the slave selector
  (`components/ProfilerSelector.tsx`)
- `toolbar-bundle.tsx` builds `profiler-toolbar.js`, loaded by every profiled page: it fetches
  `/_profiler/api/toolbar/:token` and renders `components/toolbar/ToolbarApp.tsx`, then polls
  `/_profiler/api/events/:token` (`hooks/useProfileEvents.ts`) to refresh itself when the profile
  is saved again

**Layout of `app/assets/typescript/profiler/`:**
- `components/dashboard/tabs/`: one component per dashboard tab (`MailerTab.tsx`, `AjaxTab.tsx`,
  `TestTab.tsx`...), shared by the four dashboards
- `components/toolbar/panels/`: the hover panels of the toolbar
- `flamegraph/`: the canvas flame graph of the Timeline tab; `timeline.ts`: the older SVG timeline
  (`initTimeline`), mounted on a `#profiler-timeline` element that no view of the gem renders
  any more
- `generated/`: the API client generated by orval (not committed, see below)
- `api-fetcher.ts`: the `apiFetch` mutator of the generated client (native `fetch`, the
  `X-Profiler-Request` header, the cluster prefix of `cluster-context.ts` when a slave is selected)
- `theme.ts`: the light and dark themes, kept in `localStorage`
- `app/assets/javascript/profiler-ajax-interceptor.js` (outside the bundles): the plain script the
  toolbar injector inlines into each page to link its AJAX calls

**Data access:** every component reads the API through the TanStack Query hooks orval generates
from `swagger/v1/swagger.yaml` (`@tanstack/preact-query`, aliased to the `@tanstack/react-query`
name that orval imports). The exceptions are the profile page, which reads its embedded JSON,
the AJAX script, which calls `ajax/link` with the original `fetch`, and the test runner's output
stream, read with `EventSource`.

**Build** (`package.json`):
- `yarn build:full` = `yarn codegen` (orval) then `yarn build`; a fresh checkout needs it, since
  `generated/` is not committed and `yarn build` alone fails on the missing import
- `yarn build` = `build:js` + `build:toolbar` (esbuild, `--jsx=automatic --jsx-import-source=preact
  --format=iife --target=es2020`) + `build:css` (sass, `main.scss`)
- `yarn watch` rebuilds `profiler.js` on change
- The CI job `build` runs `yarn build:full`; the release job refuses to build a gem without the
  compiled assets
- The Vitest suite of the front-end lives in the superproject (`tests/`, `yarn test`)

The design system (colors, fonts, themes) is described in [DESIGN.md](DESIGN.md).

### 7. MCP Server Integration

**MCP Server** (`lib/profiler/mcp/server.rb`)
- Built on the official `mcp` gem (a runtime dependency, `>= 0.3`), which implements the protocol
- Two transports: stdio (`rake profiler:mcp`, a process the MCP client starts) and Streamable HTTP
  (the engine's `/_profiler/mcp` mount), whose requests first go through `HttpGuard`
  (`lib/profiler/mcp/http_guard.rb`): enabled, `Host` check against DNS rebinding,
  `authorization_mode`, `Origin`, `Content-Type`
- Tools live in `lib/profiler/mcp/tools/`, one file each, and are registered in `server.rb`
  (`grep -c "handler: Tools::" lib/profiler/mcp/server.rb` gives 21 as of 0.32.1); resources live
  in `lib/profiler/mcp/resources/` (7)
- Every tool but `list_slaves` takes an optional `slave` argument: `SlaveSupport` then reads
  through a `Cluster::SlaveProxy` instead of the local store
- Helpers: `FileCache` (bodies saved with `save_bodies`, under `tmp_path/mcp-cache`, cleaned
  hourly), `PathExtractor` (`json_path`, `xml_path`), `BodyFormatter`

The tools, their arguments, the resources and the client setup are documented in
**[docs/mcp.md](docs/mcp.md)**, which is the list to keep up to date: this file does not repeat it.

### 8. Cluster (Master and Slaves)

Several applications, each with the gem, can report to one **master**, whose dashboard and MCP
server then read the profiles of every **slave**. The code is in `lib/profiler/cluster/`; the user
configuration is in [docs/cluster.md](docs/cluster.md).

**Registration and heartbeat:**
- A node is a slave when `master_url` is set. After the application has booted (and only if the
  profiler is enabled), the railtie starts `Cluster::MasterClient` (`master_client.rb`): it
  `POST`s `/_profiler/api/cluster/register` with its name and `self_url`, then, every
  `cluster_heartbeat_interval` seconds (15), `POST`s `/_profiler/api/cluster/heartbeat` from a
  background thread; a failed call makes it register again on the next beat
- On the master, `Api::ClusterController` checks the slave URL against
  `cluster_allowed_slave_urls` (`Cluster::Security.slave_url_denial`) and records the slave in
  `Cluster::SlaveRegistry` (`slave_registry.rb`), a `Concurrent::Hash` held in memory by each
  master process. A slave without a heartbeat for `cluster_offline_threshold` seconds (60) is
  listed offline; `GET /_profiler/api/cluster/slaves` returns the list
- These three routes and the proxy exist only on a node with `cluster_master` set
  (`config/routes.rb`, constraint `cluster_master?`); elsewhere they answer `404`

**Proxy:**
- `Cluster::SlaveProxy` (`slave_proxy.rb`) offers the storage interface (`list`, `load`,
  `find_by_parent`...) over the slave's own JSON API, with short timeouts and without following
  redirects; the MCP tools and the profile page use it
- `Api::SlaveProxyController` forwards `/_profiler/api/slaves/:slave_name/*path` for the
  dashboard, when a slave is selected in `ProfilerSelector`
- `ProfilesController#show` on the master looks a token up locally, then in
  `Cluster::TokenCache` (`token_cache.rb`, which slave answered for this token in the last 10
  minutes), then asks every online slave in parallel

**Security** (`security.rb`): register and heartbeat are authenticated by the shared
`cluster_secret` (`X-Profiler-Cluster-Secret`, compared in constant time), which the master also
sends on every proxied call; slave URLs must match the allow list, use HTTPS except on loopback
addresses, and carry no user info, query, fragment or dot segment; path segments sent to a slave
are escaped. The master makes HTTP requests to URLs that clients registered, so an allow list
that is too wide (`:any`, a broad pattern, a name whose DNS points inside your network) is a
**server-side request forgery** risk: whoever can register makes the master fetch internal hosts
and read the answer. The README and [docs/cluster.md](docs/cluster.md#how-the-cluster-is-protected)
document this risk and each setting that widens it; the security audit of this project discussed
it as well.

## OpenAPI pipeline (single source of truth)

The JSON API has one description, `swagger/v1/swagger.yaml`, committed in this repository. It is
generated from request specs, and both front-ends generate their API client from it:

```
test_app/spec/requests/ (rswag specs, in the superproject)
  | make swaggerize (superproject; writes into this repository)
swagger/v1/swagger.yaml (this repository, committed)
  | orval v7: yarn codegen here (orval.config.ts), or make codegen from the superproject
app/assets/typescript/profiler/generated/api.ts   <- TanStack Query hooks (this repository)
rails-profiler-extension/src/generated/api.ts     <- plain fetch functions (extension repository)
```

- The rswag specs live in the superproject's `test_app` (`spec/swagger_helper.rb` writes
  `../rails-profiler-gem/swagger/v1/swagger.yaml`): change an endpoint here, then describe it there
  and run `make swaggerize`. This repository's own `spec/requests/` are plain request specs.
- `orval.config.ts` in this repository generates the gem's client only; the superproject's
  `orval.config.ts` (`make codegen`) generates the gem's and the extension's in one pass. Both pass
  `offset` as the page parameter of the paginated list endpoints and keep the others as plain
  queries.
- The `apiFetch` mutator (`app/assets/typescript/profiler/api-fetcher.ts`) replaces axios: native
  `fetch`, no extra dependency.
- The `@tanstack/react-query` to `@tanstack/preact-query` alias is configured in the esbuild
  scripts of `package.json` (and in the superproject's `vitest.config.ts`).
- `generated/` is not committed and must never be edited by hand. Regenerate it with
  `yarn build:full` (or `yarn codegen`) here, or `make codegen` from the superproject.
- Gem front-end: esbuild (TSX to JS) and sass (SCSS to CSS), output to `app/assets/builds/`.
  Extension: webpack.

The superproject's own `ARCHITECTURE.md` still carries a copy of this section; it can now point
here instead.

## Data Flow

### Request Lifecycle

```
1. Request arrives
   ↓
2. ProfilerMiddleware (first in the stack): skipped path or refused by authorization_mode? → pass through
   ↓
3. Create Profile, subscribe the collectors (Lifecycle.subscribe_all)
   ↓
4. Application runs
   │ (collectors receive the notifications of this request's execution context,
   │  outbound HTTP, logs and dumps through thread-local slots)
   ↓
5. Application returns
   ↓
6. collect on every collector, release them (a streamed body keeps some until it is closed)
   ↓
7. Redact, save to the store (which bumps the profile's version for the toolbar)
   ↓
8. HTML page returned whole? → ToolbarInjector inserts the toolbar before </body>
   ↓
9. Response, with X-Profiler-Token
```

### Toolbar Loading

```
1. Page loads with the toolbar placeholder (data-token) and the AJAX interceptor
   ↓
2. /_profiler/assets/profiler-toolbar.js loads (deferred)
   ↓
3. GET /_profiler/api/toolbar/:token → profile JSON (AJAX children and child jobs added)
   ↓
4. ToolbarApp renders the items and their hover panels
   ↓
5. The page's fetch()/XHR answers carry X-Profiler-Token → POST /_profiler/api/ajax/link
   ↓
6. GET /_profiler/api/events/:token, at a decreasing pace while the tab is visible → refetch when the version moved
```

### Profile Viewing

```
1. Click a toolbar item, or open /_profiler
   ↓
2. ProfilesController#index: the list page; ProfileList reads /_profiler/api/profiles (paginated)
   ↓
3. Click a row → ProfilesController#show: the page embeds the profile JSON
   ↓
4. main.tsx picks the dashboard for the profile type and renders the tab from ?tab=
   ↓
5. Switching tabs renders from the same JSON; actions (EXPLAIN, delete, ENV changes) call the API
```

## Configuration System

**Configuration DSL:**
```ruby
Profiler.configure do |config|
  config.enabled = true
  config.storage = :file
  config.slow_query_threshold = 100
  # ... etc
end
```

**Configuration Object** (`lib/profiler/configuration.rb`)
- Holds all settings and their defaults
- Records which of the Rails-defaulted options the application assigned (`#default`)
- Validates the patterns of `cluster_allowed_slave_urls` and `mcp_allowed_hosts` when assigned
- Provides the `storage_backend` factory and the authorization logic (`#authorized?`)

Every option, with its default: [docs/configuration.md](docs/configuration.md). The function
profiler's settings are module attributes of `Profiler` (`lib/profiler.rb`), changed at runtime by
the Timeline tab.

## Extensibility

### Custom Collectors

```ruby
class MyCollector < Profiler::Collectors::BaseCollector
  def icon; '🔧'; end
  def subscribe; ...; end
  def unsubscribe; ...; end   # releases what subscribe installed; idempotent
  def collect; ...; end       # store_data(...)
  def toolbar_summary; ...; end
end

Profiler.configure { |config| config.collectors << MyCollector }
```

A custom collector's data is stored with the profile and returned by the API, but the dashboard
and the toolbar have a fixed set of tabs and items: they do not render it (see
[docs/configuration.md](docs/configuration.md#custom-collectors)).

### Custom Storage Backend

```ruby
class MyStore < Profiler::Storage::BaseStore
  def do_save(token, profile); ...; end   # BaseStore#save validates the token, then calls it
  def load(token); ...; end
  def list(limit: 50, offset: 0, type: nil, summary: false); ...; end
  def find_by_parent(parent_token); ...; end
  def delete(token); ...; end
  def clear(type: nil); ...; end
  def cleanup(older_than:); ...; end
end
```

`config.storage` only accepts the four built-in names; a custom backend has to be returned by
`Profiler.configuration.storage_backend` (for example by overriding it), which is not a supported
extension point.

## Performance Considerations

### Overhead
- Measured with `script/bench/request_overhead.rb` (a minimal application, 210 routes, a page with
  20 SQL events and 3 partials): a few milliseconds to about 13 ms per request depending on the
  machine and on the function profiling mode; see [docs/performance.md](docs/performance.md)
- When disabled, nothing is left in the middleware stack and no instrumentation is installed,
  except the `Thread#initialize` patch

### Optimizations
- Lists read summaries, not whole profiles; children found through a parent index
- Bodies capped (`max_captured_body_bytes`) and compressed past `compress_body_threshold`
- SQL backtraces only for the first run of a statement and for slow queries (`sql_backtrace`)
- The route table and `ENV` are read from the process when a profile is shown
  (`ProcessSnapshot`), not stored in each profile
- One notification subscriber per event for the whole process (`ScopedNotifications`)
- Function profiling by sampling (stackprof) rather than tracing, by default
- No server thread held by the toolbar's update checks; monotonic time for timings

## Security

### Measures
- Disabled by default outside development and test
- Every page and endpoint behind one access check (`authorization_mode`, `:allow_local` by
  default) and, for changes, forgery protection
- Sensitive data masked before storage by one filter (`Profiler::Redaction`) built on the
  application's `config.filter_parameters`: params, bodies, headers, outbound HTTP, SQL binds, job
  and mailer arguments, `ENV` (allowlist); the cluster secret masked by value everywhere
- Tokens validated by every store before they become a path or a key
- `0700` directories and `0600` files under `tmp_path`
- EXPLAIN limited to read-only statements (`SqlStatement`), on a separate connection, in a
  transaction always rolled back (`ExplainRunner`)
- Test runner limited to discovered test files; `ENV` overrides never applied in production
- MCP over HTTP and cluster routes off by default, each with its own checks
- No CORS and no framing by other sites by default
- Captured values escaped in the pages (`json_escape`), mail previews in a sandboxed frame

User-facing details: [docs/security.md](docs/security.md).

## Testing Strategy

`bundle exec rspec` runs the suite (123 spec files as of 0.32.1), in the CI on Ruby 3.3 and 3.4
(`rspec` and `rspec:ruby3.4` jobs). Both matter: the gem prepends modules to core classes
(`Thread#initialize` among them), and Ruby 3.4's standard library calls them differently.

- `spec/collectors/`, `spec/storage/`, `spec/models/`, `spec/sse/`: one collector, store or model
  at a time
- `spec/middleware/`: the middleware, bodies and streaming, the toolbar injector
- `spec/instrumentation/`: `Net::HTTP`, threads and executors, ActiveJob, Sidekiq, IRB
- `spec/requests/`: the engine's controllers in a small Rails application (`spec/support/rails_app.rb`),
  access control, the MCP mount, the cluster endpoints
- `spec/redaction/`: the masking of sensitive data, in one place: `Profiler::Redaction` itself, the
  SEC-03 regression specs and their review follow-ups, the cluster secret, and the ENV and EXPLAIN
  endpoints once masked
- `spec/cluster/`, `spec/mcp/`, `spec/test_runner/`, `spec/test_helpers/`
- Specs that need a real multi-threaded server start Puma (`spec/support/puma_app_server.rb`)
- `spec/explain_runner_postgresql_spec.rb` needs a PostgreSQL server
  (`PROFILER_TEST_POSTGRES_URL`) and is skipped without one

The front-end's Vitest suite and the rswag specs that produce the OpenAPI file live in the
superproject. Manual testing uses the superproject's `test_app` (Docker or not); the screenshots
of the documentation are produced from it by [docs/screenshots/run.sh](docs/screenshots/README.md).

## Future Enhancements

Not built as of 0.32.1:

1. **Export/Import**
   - Export profiles as JSON or HAR (only the `ENV` variables of the Env tab can be exported
     today)
   - Import for comparison
   - Profile diffing

2. **Advanced Visualizations**
   - Memory allocation graphs (allocations are counted per request and per method in full
     function profiling mode, not graphed)
   - A query plan view richer than the raw EXPLAIN output

3. **Real-time Updates**
   - Push instead of polling for the toolbar and the lists (the toolbar polls `events/:token`)

4. **Enhanced MCP**
   - More analysis tools
   - MCP notifications and resource subscriptions

5. **Custom collectors in the UI**
   - A generic tab and toolbar item for the data of a custom collector

Already shipped, and documented in the [README](README.md): flame graphs and function profiling,
background job profiling (Sidekiq, ActiveJob), outbound HTTP tracking, AJAX tracking, mailers,
test profiling and the test runner, the cluster, MCP over HTTP.
