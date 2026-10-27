# Usage guide

What the profiler does for you in code and outside HTTP requests: query plans, variable dumps,
custom timeline events, background jobs, mailers, console expressions and `ENV` overrides. Tests
have their own page: [Tests](testing.md).

## Explaining a query

The **Explain** button of the Database tab, the `POST /_profiler/api/explain` endpoint and the MCP
`explain_query` tool all show the plan of a query the application already ran, with its bind values
put back. They run `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` on PostgreSQL, `EXPLAIN FORMAT=JSON`
on MySQL and `EXPLAIN QUERY PLAN` on SQLite.

Explain only runs while the profiler is enabled, in the `development` and `test` environments.
Elsewhere, `production` and `staging` included, it is refused even with `enabled = true`: a 403
from the endpoint, an error from the MCP tool, and nothing reaches the database. PostgreSQL's
`EXPLAIN ANALYZE` runs the query it explains, so a costly `SELECT` would run for real on that
database. An application that wants it there anyway sets
`config.allow_explain_outside_development = true`, knowing that each Explain runs the query once
more, for up to 30 seconds on PostgreSQL. Without Rails, the environment is unknown and Explain is
refused. With the `slave` parameter, the slave's own environment and configuration decide.

A query that fails for another reason (the database refuses it, the connection drops) answers a
generic `Explain failed`, a 500 from the endpoint; the error itself, SQL included, goes to the
application log.

A query whose bind values were masked when captured is refused first, since it cannot be rebuilt
(see [Sensitive data](security.md#sensitive-data)). Then only read-only statements are explained: those that
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

## Dumping variables

Inspect any value in the **Dump** tab:

```ruby
# Basic dump: shows value, file, and line number
Profiler.dump(@user)

# With a label
Profiler.dump(@posts, "Posts for current page")

# Chainable: returns the original value, also when the profiler is disabled
user = Profiler.dump(User.find(params[:id]), "Current user")

# Dump anything
Profiler.dump(params)
Profiler.dump(session[:user_id], "Current user ID")
```

## Custom instrumentation

Add custom events to the flame graph:

```ruby
result = Profiler.measure("payment.stripe_charge", metadata: { amount: 1000 }) do
  Stripe::Charge.create(amount: 1000, currency: 'usd')
end
```

Custom events appear as pink blocks in the **Timeline** tab, nested at the correct position in the call hierarchy.

## Background jobs

With `config.track_jobs = true` (the default), every ActiveJob job and every Sidekiq job is
profiled on its own: SQL, cache, outbound HTTP, dumps, logs, exceptions, its queue, arguments
(masked like request params, see [Sensitive data](security.md#sensitive-data)), status and error.
The job profiles are listed under **Background Jobs** at `/_profiler`, and a page that enqueued
jobs lists them in its **Jobs** tab. The instrumentation is installed at boot, only when the
profiler is enabled: Sidekiq server and client middlewares when `Sidekiq` is loaded, and an
ActiveJob hook when `ActiveJob::Base` is.

## Mailers

With `config.track_mailers = true` (the default), every mail an ActionMailer delivers during a
request or a job is recorded in the **Mailers** tab of its profile: mailer
and action, subject, recipients, template, parts, render and delivery times, and the mails queued
with `deliver_later`. The same mailer action called more than three times in one request is
flagged as a possible send loop, and only the first 50 mails of a request are kept.

```ruby
Profiler.configure do |config|
  config.capture_mail_body = true           # keep the HTML and text bodies (100 KB each at most)
  config.sanitize_mailer_recipients = true  # jane@myapp.test is shown as j***@***.test
  config.mailer_skip_actions = ["DeviseMailer", "UserMailer#password_reset"]
end
```

The MCP tools `get_profile_mailers` and `query_mailers` read the same data (see the
[MCP Guide](mcp.md#get_profile_mailers)).

## Console profiling

When `track_console: true` (default), every expression evaluated in `rails console` is automatically profiled:

```ruby
# In rails console, all of these are profiled automatically
User.where(active: true).count
Post.includes(:comments).limit(10).to_a
```

Both IRB and Pry (for example through `pry-rails`) are supported. Under Pry, the Ruby expressions
are profiled; Pry commands such as `ls` or `cd` are not.

Results appear in the **Console** tab at `/_profiler`. Each entry shows the expression, duration, SQL query count, and whether it raised an error.

Env overrides set via the profiler UI or MCP tools are applied before each console evaluation, so there is no need to restart the console to pick up changes. They follow the rules of [Environment variable overrides](#environment-variable-overrides): never in production, and not while the profiler is disabled.

To disable console profiling:

```ruby
Profiler.configure do |config|
  config.track_console = false
end
```

## Environment variable overrides

Values set, deleted or reset from the **Env** tab or the MCP env tools are saved in
`env_overrides.json` under `tmp_path` (`tmp/rails-profiler` by default) and applied to `ENV` at
boot, before each Sidekiq job and before each console evaluation. They are applied only when both
hold:

- the application is not running in production (`Rails.env.production?`), with no option to
  change that: an overrides file deployed with the application is never read into `ENV`;
- the profiler is enabled, as the application sets it (`config.enabled` in
  `config/initializers/profiler.rb`). Set `config.apply_env_overrides_when_disabled = true` to
  apply them while the profiler is disabled, as versions before 0.30.8 did.

### Which variables can be overridden

The Env tab and the MCP env tools only set or delete a variable whose name is made of letters,
digits and underscores, not starting with a digit: a name with `=`, a space, a dash or a dot is
refused (422 from the endpoint, an error from the tool) before anything is written, the file
included. A value holding a NUL byte, which no environment variable can hold, is refused the same
way. They also refuse, whatever their case:

- the variables that select the environment, the database or the secrets: `RAILS_ENV`,
  `RACK_ENV`, `DATABASE_URL` and every name ending in `_DATABASE_URL` (Active Record reads
  `PRIMARY_DATABASE_URL` before `DATABASE_URL`), every name starting with `PG` (libpq) or
  `MYSQL_`, `SECRET_KEY_BASE`, `RAILS_MASTER_KEY`;
- those that send the application's connections elsewhere or change which certificates it
  trusts: every name ending in `_PROXY` (`http_proxy`, `HTTPS_PROXY`, `no_proxy`...),
  `SSL_CERT_FILE`, `SSL_CERT_DIR`, every name starting with `OPENSSL_`;
- those that make a process load or run other code: `PATH`, `HOME`, `RUBYOPT`, `SPEC_OPTS`,
  `NODE_OPTIONS`, `GCONV_PATH`, `IRBRC`, `PRYRC`, `ZDOTDIR`, `LESSOPEN`, `JAVA_TOOL_OPTIONS`,
  `EDITOR`, `PAGER`, and every name starting with `RUBY`, `GEM_`, `BUNDLE_`, `LD_`, `DYLD_`,
  `GIT_`, `BASH_`...;
- `PROFILER_MCP_READ_ONLY` ([Read-only mode](mcp.md#read-only-mode)).

The test runner leaves the same names out ([Tests](testing.md#test-runner)). It is a deny list,
and a deny list cannot be complete: a gem the application uses may read a variable of its own that
no list in the profiler knows about. Set any of these in the shell that starts the application
instead.

An override with such a name, saved by an earlier version, stays in the file but is no longer
applied; a warning gives how many were left out, never which. Resetting it from the Env tab or
`reset_env_var` takes it out of the file.

### Several processes

Each process applies the file on its own: the web process at boot, each Sidekiq process before
each job, each console before each evaluation. The file is parsed again only when it changed since
the last time, so a job that runs while nothing changed does not read it. A reset leaves a marker
in the file for seven days: every process that applied the override puts back the value it had
before, at its next job or evaluation; a process that never applied it leaves the variable alone.
A worker that runs nothing for longer than that keeps the override until it restarts. The other
workers of a clustered web server (Puma with `workers`) do not read the file between requests: the
reset reaches them when they restart.

### Errors

When the file cannot be read or written, the Env tab and the MCP env tools answer an error and
leave `ENV` unchanged. At boot, before a Sidekiq job and before a console evaluation, the error is
only printed as a warning: an override never makes the application fail.

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
