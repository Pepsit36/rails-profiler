# Performance

What the profiler costs a request, what it records and from which threads, and its known limits.

## What it costs and records

- Only active when enabled (development/test by default); when disabled, nothing is left in the
  middleware stack and no Sidekiq, ActiveJob, test, console or `Thread#initialize` instrumentation is installed
- Overhead, measured in the default configuration with `script/bench/request_overhead.rb`: on a
  page that runs 20 SQL queries and renders 3 partials and 20 KB of HTML, in an application with
  210 routes and the memory storage, the profiler adds about 10 to 13 ms per request, with or
  without stackprof, on Ruby 3.3 and 3.4 (the page itself takes 1 ms); about a quarter of it goes
  to finding where to insert the toolbar in the HTML. Each further SQL query adds about 0.1 ms.
  The figure depends on the machine (about 5 to 6 ms on the one that ran the table under
  [Function profiling](#function-profiling)): run the script to get yours
  (`bundle exec ruby script/bench/request_overhead.rb [--no-stackprof]`); it is not part of the
  gem and does not run in CI
- Each collector records the events of its own request only: the thread that runs it, the
  threads it starts with `Thread.new`, the fibers it creates (on Ruby 3.2 and later; with
  `render stream: true` the layout is rendered in one), the tasks it posts to a concurrent-ruby
  executor (`Concurrent::Promises`, `Concurrent::Future`), whichever pool thread runs them and
  whenever, the thread `ActionController::Live` runs the action in, and the server thread that
  iterates a streamed body. A job performed by ActiveJob's `:async` adapter is profiled on its own,
  apart from the request that enqueued it, even while that request runs; with `track_jobs` off, its
  queries are recorded in that request. A thread created by a pool (concurrent-ruby, Puma,
  including the one Puma starts for a request marked with `env["puma.mark_as_io_bound"]`) inherits
  nothing from the request that was running when it was created. The process holds one subscriber
  per event, however many requests are profiled at once. Under Falcon, set
  `config.active_support.isolation_level = :fiber`, as Rails requires, so that requests sharing a
  thread are told apart. Not covered: a pool of the application's own, whose threads are started
  with `Thread.new` while a request runs; they take that request's context for their whole life:
  its queries stop being recorded when the request ends, but the outgoing HTTP calls of their later
  tasks are still added to that request's profile. Measure it on your setup with
  `bundle exec ruby script/bench/puma_attribution.rb`
- What reaches a request's profile depends on what is recorded, because the SQL, view, cache and
  mailer events follow the request's notification scope, while the outbound HTTP calls, dumps and
  log lines follow values the request's own thread holds. Measured on Ruby 3.3 and 3.4, a request
  that runs a query, an outbound `Net::HTTP` call, a `Profiler.dump` and a `Rails.logger` line in
  each place (views and cache go through the same notification scope as the query):

  | Where the work runs | SQL, views, cache | Outbound HTTP | `Profiler.dump` | Log lines |
  |---|---|---|---|---|
  | The request's thread | yes | yes | yes | yes |
  | A thread started with `Thread.new` | yes | yes | no | no |
  | A thread started with `Thread.start` or `Thread.fork` | yes | no | no | no |
  | A fiber the request creates | yes | no | no | no |
  | A task posted to a concurrent-ruby executor | yes | yes | no | no |
  | A thread of a pool created before the request (the application's own queue, Sidekiq) | no | no | no | no |
  | A thread started during the request, after the request has ended | no | yes, for up to 0.5s or 100 entries after the request's collectors are released | no | no |

  `Thread.start` and `Thread.fork` do not run the `Thread#initialize` the profiler patches, and a
  fiber has its own thread-local values: both get the notification scope, which Ruby hands to new
  threads and fibers, and none of the values the HTTP, dump and log collectors read. A dump or a
  log line from any other thread or fiber than the request's is not kept. A thread created before
  the request can only get the request's context when its work goes through a concurrent-ruby
  executor
- The function profiler samples with [stackprof](https://github.com/tmm1/stackprof), which is not
  a dependency of the gem; see [Function profiling](#function-profiling) below for what each of
  its modes costs
- The route table and `ENV` are not stored in each profile. A profile keeps the route its request
  matched; the Routes tab lists the routes of the process that serves the page, rebuilt when the
  routes are reloaded in development, and the Env tab shows the current `ENV` of that process, not
  the `ENV` as it was during the request, masked as described under "Sensitive data". The profiles
  of jobs, console expressions and tests, which run in another process (Sidekiq, the console,
  rspec), keep the `ENV` of that process, masked, as before. Profiles saved by an earlier version
  keep showing their own table and variables
- Text bodies > 10 KB compressed automatically (gzip+base64)
- Bodies kept in a profile stop at `max_captured_body_bytes` (256 KB by default): `rack.input` is
  read up to that size and rewound for the application, a larger response is kept in part, and
  the Request tab says so with the whole size ("at least" when it is not known: no
  `Content-Length`, or a stream that stopped). A cluster secret cut in two by the limit is left
  out with the rest. `nil` keeps whole bodies. The parsed `params` a profile keeps are capped at
  the same size: long values are cut and the entries past it left out, with a `"[profiler]"` key
  saying so (the application still gets all of them). The log lines of a request are capped by
  `max_captured_log_bytes` (1 MB by default), a single `Parameters: ...` line included, and the
  Logs tab ends with the number of lines left out. Earlier versions kept a 5 MB JSON request three
  times, about 15 MB in its profile
- Outbound `Net::HTTP` bodies are capped by `max_captured_body_bytes` as well, sent and received:
  the HTTP tab and the `get_profile_http` MCP tool say when a body was cut. A compressed answer is
  inflated only up to that size, give or take one 16 KB buffer. A `body_stream` is read only when
  it can be put back where it was (a `StringIO`, a file), and no further than its
  `Content-Length`; a pipe, a socket or a stream without `pos` (a Faraday multipart body, a
  `RestClient::Payload`) is sent unread and its body is not captured.
  Earlier versions read any `body_stream` whole, which sent an empty body for a pipe
- Streamed responses go out as they are produced: a body that does not answer `to_ary` (an
  `ActionController::Live` or `response.stream` action that writes to the stream,
  `render stream: true`, an enumerator), a `text/event-stream`, or a file sent by its path
  (`send_file`, which keeps `to_path`) is handed to the server chunk by chunk, with a copy kept up
  to `max_captured_body_bytes`. A page an action of a `Live` controller renders whole is still a
  page, toolbar included. An error raised while the body is iterated reaches the server as it
  would without the profiler. The toolbar is only injected in pages the application returns
  whole, so a `render stream: true` page has none. Under Rack 2, `Rack::ETag` buffers a `Live`
  response before the profiler sees it, as it does without the profiler
- What a stream records: the collectors that only gather what notifications and the logger hand
  them (SQL, views, cache, exceptions, timeline, logs, outbound HTTP) stay subscribed until the
  server closes the body, so the queries, views and logs of the stream are in its profile, and so
  are its allocated objects. While the server iterates the body, its thread (or fiber) carries
  the profile: the log lines, the outbound `Net::HTTP` calls and the `Profiler.measure` blocks it
  runs then, a `render stream: true` template or an enumerator for instance, are recorded, and
  what that thread held before is given back afterwards. An `ActionController::Live` action runs
  in a thread of its own, to which Rails copies the request's thread-local values: its log lines
  and HTTP calls are recorded too. The collectors that keep state in the request's thread (dumps, mailers, I18n,
  function profiling) are read when the application returns. Like every subscription, these see
  what other threads do meanwhile. The profile is saved when the server closes the body, also
  when the client went away: until then it is not listed, and a request for its token answers
  404, so an endless event stream is never listed and the toolbar of an XHR that streams finds
  its profile only at the end. A body the server never closes (against the Rack rules) is
  finished when the fiber that started it starts its next profiled request (a threaded server
  runs each request in its thread's root fiber; a fiber-based server such as Falcon gives each
  its own, so a stream there is never cut by the next request), and its subscriptions are
  dropped after 5 minutes at the latest: the profile then says "collectors released after 300
  s", what the stream did later is missing. The server still closes the application's body,
  whatever happened to the profile
- A response already framed for the wire (`Transfer-Encoding`, as Rails 7.0 sends a
  `render stream: true` template) goes out untouched, without the toolbar
- Allocated objects: the profiles report `allocated_objects`, the number of objects Ruby
  allocated while the request, job, command or test ran (`GC.stat(:total_allocated_objects)`
  before and after). The counter belongs to the process: on a multi-threaded server (Puma with
  several threads, jobs running alongside), it includes what the other threads allocated
  meanwhile, so it is only exact when one thing runs at a time. It is not a byte count: the
  `memory` field the API still returns, deprecated, is that number times 40, the figure earlier
  versions showed as bytes
- Masking sensitive data adds well under 1 ms to a typical profile. A JSON body in whose text no
  filter matches is not parsed: about 10 ms per megabyte for ASCII text, 50 ms when it holds other
  characters. A body where a filter matches, in a key or only in a value (`"title": "reset your
  password"`), is parsed and filtered: about 100 to 300 ms per megabyte depending on the machine,
  in the request. Procs and regexps with anchors or lookarounds in `filter_parameters` send every
  JSON body to the parser
- Automatic cleanup of old profiles
- The profiler's pages, the toolbar and the test runner, keep no server thread waiting, however
  many are open. The toolbar learns that its profile was saved again (an outgoing HTTP request finished after the
  page, say) by asking the server, which answers at once: after 1 s, then less and less often,
  10 requests in the first minute and 2 a minute after that, none while the tab is hidden, and
  none after 10 minutes without a save (reload the page to follow it again). The test runner page
  asks for the new output once a second while a run is in progress. With several worker
  processes and no Redis storage, each worker only knows the saves it made: the toolbar sees a
  save when one of its requests reaches the worker that made it
- Known limits: three requests still hold a server thread for as long as they wait. The MCP tool
  `run_tests` waits for a local run up to its `timeout_seconds` (120 by default, with no upper
  bound); with a `slave`, it asks the slave every 2 seconds for as long. The cluster proxy
  (`/_profiler/api/slaves/:name/...`) waits for the slave with a read timeout that applies to each
  read, not to the whole answer

## Function profiling

The function profiler (`FunctionProfilerCollector`, Timeline tab) has two modes, set at runtime
from the Timeline tab or with `Profiler.function_profiling_mode` (see
[Configuration](configuration.md#function-profiling)):

- **lite** (the default) samples the stack every millisecond with
  [stackprof](https://github.com/tmm1/stackprof). stackprof is not a dependency of the gem: add
  `gem "stackprof", require: false` to the application's `Gemfile`. Without it, lite mode records
  nothing and costs nothing, and the Timeline tab says that stackprof is missing.
  `Profiler.function_profiling_tracepoint_fallback = true` traces every method call of the
  request's thread instead, at the cost of full mode below; earlier versions did that silently,
  on every thread.
- **full** traces every method call of the request's thread with a `TracePoint`, with
  allocations and memory bytes per method, whether stackprof is installed or not.

The sampler is process-wide: while one request holds it, a request that runs at the same time
records no function profile (the tab says the sampler was busy).

Measured with `script/bench/request_overhead.rb` on Ruby 3.4.6 (8 cores, two runs each), on its
synthetic page (20 SQL events, 3 partials, 20 KB of HTML), with a copy of the script that sets
the mode after loading the gem:

| Function profiling | Whole profiler overhead per request |
|---|---|
| off (`function_profiling_enabled = false`) | +5.3 to +5.8 ms |
| lite, stackprof not installed | +4.8 to +5.2 ms |
| lite, stackprof installed | +6.1 to +6.4 ms |
| full | +12.9 to +13.4 ms |

The synthetic page calls few Ruby methods of its own; the cost of full mode grows with the number
of method calls a request makes, so a real page pays more than this in full mode. The first two
rows differ by less than the noise between two runs. Ruby 3.3 was not
measured for this table. Run the script on your own machine to get your figures.
