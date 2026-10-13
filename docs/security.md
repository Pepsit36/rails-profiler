# Security

How the profiler decides who gets in, and what it masks before it stores a profile.

## Summary

- Disabled by default in production
- Only requests from this machine get in by default (`authorization_mode: :allow_local`), on every page and endpoint; see [Access control](#access-control)
- API mutations require the `X-Profiler-Request` header or a CSRF token
- The test runner only runs discovered test files; see [Test runner](testing.md#test-runner)
- The MCP HTTP endpoint is routed only when enabled, and goes through the same checks
- The cluster is off by default; when on, nodes authenticate with a shared secret and the master only reaches allowed slave URLs
- No CORS and no framing by other sites by default
- Sensitive data masked before it is stored, using your `config.filter_parameters`; see [Sensitive data](#sensitive-data)
- Env overrides saved from the UI or MCP are never applied in production, nor while the profiler
  is disabled (`apply_env_overrides_when_disabled`)
- Profile tokens are checked by every storage backend: a malformed one is not found and never
  becomes a path; see [Files under `tmp_path`](storage.md#files-under-tmp_path)
- The profiler's directories are created `0700` and its files `0600` (`restrict_storage_permissions`)
- EXPLAIN runs read-only statements only, in a transaction always rolled back (see [Explaining a query](usage.md#explaining-a-query))


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
`cluster_secret` (see [Cluster](cluster.md)).

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

Without `extension_cors_enabled = true`, `cors_allowed_origins` adds no CORS header. The MCP HTTP
endpoint reads the list on its own, whatever `extension_cors_enabled` says: a browser `Origin`
listed there passes its origin check (see [MCP](mcp.md#http-transport-alternative)). A granted
preflight allows `GET` and `POST` with the `X-Profiler-Request` header.

`"*"` (the default before 0.30.6, with `extension_cors_enabled = true`) is still accepted, and it
**reopens the profiler to every website you visit, as before 0.30.6**: any page open in your browser
can then read the profiler's data and, since a preflight is granted, change it (start test runs,
and, where Rails' `_method` override turns a form `POST` into another verb, delete profiles or
write `ENV`). Under `:allow_local` the check rests on the address and the `Host`, not on
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


## Sensitive data

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

