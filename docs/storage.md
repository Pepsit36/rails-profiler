# Storage

Where profiles are kept. `config.storage` picks the backend: `:file` in development and test,
`:memory` elsewhere, unless the application sets it (see
[Configuration](configuration.md#defaults-that-depend-on-the-rails-environment)).
`config.storage_options` passes options to that backend.

| Backend | Option | Default |
|---|---|---|
| `:memory` | `max_profiles` | `config.max_profiles`, or 100 when it is `nil` |
| `:file` | `path`, `max_size`, `max_profiles` | `tmp_path/profiles`, 100 MB, `config.max_profiles` |
| `:redis` | `url` (or `redis`, a client), `ttl`, `key_prefix`, `max_profiles` | `ENV["REDIS_URL"]` or `redis://localhost:6379/0`, 24 hours, `"profiler"`, `config.max_profiles` |
| `:sqlite` | `database`, `blob_path`, `max_profiles` | `tmp_path/profiler.db`, `tmp_path/blobs`, `config.max_profiles` |

The Redis and SQLite backends need a gem the profiler does not depend on: `redis` (5.x) or
`sqlite3`, in the application's `Gemfile`.

## How many profiles are kept

Every backend keeps at most `config.max_profiles` profiles (100 by default), evicting the oldest:
past the cap, the oldest are removed down to 80% of it. `storage_options[:max_profiles]` sets it
for the store alone. In the test environment, where the [test profiler](testing.md#test-profiling) saves one
profile per example, there is no cap on the count unless the application sets one, so that the
report at the end of a suite sees every test.

```ruby
config.max_profiles = 500  # keep more
config.max_profiles = nil  # no cap on the count: the file store keeps up to max_size (100 MB),
                           # Redis up to its TTL, SQLite everything, as in earlier versions
```

The memory store always has a cap: `nil` leaves it at 100.

The eviction follows the order of the saves, not of the starts: a job, a console command or a
streamed response is saved when it ends, possibly long after it started, and is kept as the newest
profile; the lists still show the profiles by start time. The profile just saved is never evicted.

**When upgrading** from a version without the cap, the first save of the file or SQLite store
removes every profile past it, the first saved first: of 3,000 profiles of 17 KB written by
0.31.1, about 80 remain, and that first save takes about a second, during which the other
processes writing to the same file store wait. The Redis store does it on first use, a save or a
list, in the one process that indexes the data of the earlier version (about 0.4 s for 20,000
profiles); the other processes go on meanwhile. With no cap on the count, that indexing reads
every profile once, in that one request: about 5 s for 20,000 profiles, paid once. To keep them, set `config.max_profiles` (to a
higher number, or `nil`) **before** upgrading.

A store that cannot be created (its index or lock replaced by a symbolic link, a directory it
cannot write) is reported once per process, as a warning: the profiles are not saved and no
toolbar is added to the pages, the dashboard and its API answer `503` with the cause in one line
(no path), the MCP tools an error with it, and the store is created again on the next request
once the cause is gone.

With no cap on the count (`nil`, the default in the test environment), the file store index can
grow large: with 30,000 profiles it is about 16 MB, read in about a second by the first list of
each process, which then keeps it in memory (tens of MB), and every list after a save sorts it
again (about 0.1 s). Prefer a cap, or SQLite, for that many profiles.

Each backend lists, filters by type and pages the profiles itself, and finds the children of a
page (its AJAX sub-requests and its jobs) through an index of their parent, without reading the
other profiles. The dashboard lists summaries: the fields the lists show, without the bodies,
params and headers, and only the scalar values of each collector; the full profile is read when
it is opened.

## Memory

Fast, no persistence: data is lost on restart, and each process has its own. The default
outside development and test.

```ruby
config.storage = :memory
config.storage_options = { max_profiles: 100 }
```

## File

The default in development and test. Persistent, survives restarts. One JSON file per profile, named after its token, in
`tmp_path/profiles` (`tmp/rails-profiler/profiles`) unless `path` is given.

```ruby
config.storage = :file
config.storage_options = {
  path: Rails.root.join('tmp', 'profiler'),
  max_size: 100.megabytes
}
```

`path` is the directory that holds the profile files themselves, used as given: no `profiles`
subdirectory is added to it. A relative `path` is resolved against the current directory of the
process, not `Rails.root`: prefer `Rails.root.join(...)`. Only the files named after a profile token (32 hexadecimal
characters, then `.json`) are read, listed, evicted or cleared there, so a directory shared with
other files is safe, `tmp_path` included.

Next to the profiles, `.profiles-index.jsonl` holds one line per save or delete (the token, the
size, the type, the parent and the summary the lists show) and `.profiles-index.lock` the lock that
the processes writing to the directory share (Puma workers, Sidekiq). A save appends its line
instead of listing the directory, so it costs the same with 100 or 10,000 profiles; each process
reads only the lines the others appended since its last read. From time to time (past
`max_profiles` or `max_size`, or when the index holds more dead lines than live ones) one process
rewrites the index under the lock: it evicts the oldest profiles, adds the profile files the index
does not know, drops the lines of the files removed by hand and deletes the temporary files a
killed process left, and the profile files a compaction killed part way left behind (older than
that compaction and absent from its index: they were evicted). A missing or damaged index is rebuilt from the profile files, so the profiles
written by an earlier version are found without any migration.

The index relies on `flock` between the processes sharing the directory. It works on one host,
containers included (a named volume, a bind mount, Docker Desktop). A directory shared between
hosts over NFS, mounted `nolock` or with `flock` otherwise without effect, is not supported: lists
then miss live profiles or show evicted ones until the next compaction, and the cap is passed for
a while; with a lock daemon out of reach, `flock` fails or waits, and the saves fail with it (the
profile is lost, the request goes on). For several hosts, use Redis; SQLite, which relies on file
locks too, only on one host.

## Redis (recommended for multi-server)

Shared across servers, TTL-based expiry.

```ruby
config.storage = :redis
config.storage_options = {
  url: ENV['REDIS_URL'],
  ttl: 24.hours,
  key_prefix: 'profiler'
}
```

A profile expires a TTL after its last save, and the lists expire a TTL after the last save too.
On the first save after an upgrade from a version that did not index the saves, a job that started
more than a TTL ago and was saved recently can drop out of the lists once: it is a one-time effect,
bounded by the duration of the job.

## SQLite

Single-server persistence, no external dependency.

```ruby
config.storage = :sqlite
config.storage_options = {
  database: Rails.root.join('db', 'profiler.db'), # tmp_path/profiler.db by default
  blob_path: Rails.root.join('db', 'profiler-blobs') # tmp_path/blobs by default
}
```

`cleanup` and the eviction of the oldest profiles remove the blob directories that no row of
`database` refers to. Give each `database` its own `blob_path`: two stores that share one (a
development database and a test one, or one database per parallel test worker) remove each other's
blobs.

## Files under `tmp_path`

`config.tmp_path` (`tmp/rails-profiler` under the Rails root, or under the current directory
outside Rails) is always a `Pathname`, even when it is set from a `String`. By default it holds:

| Path | Written by |
|------|-----------|
| `profiles/<token>.json` | the file store |
| `profiles/.profiles-index.jsonl`, `profiles/.profiles-index.lock` | the file store, for its index |
| `profiler.db`, `profiler.db-wal`, `profiler.db-shm` | the SQLite store |
| `blobs/<token>/` | the SQLite store, for the large bodies |
| `mcp-cache/<token>/` | the MCP tools, for the bodies they save with `save_bodies` |
| `env_overrides.json`, `env_overrides.json.lock` | the [environment variable overrides](usage.md#environment-variable-overrides) |

Each part only reads, lists and removes its own files: clearing the profiles never removes the
env overrides, and the hourly cleanup of the MCP cache only removes the token directories under
`mcp-cache`.

A profile token is the 32 hexadecimal characters the profiler generates. Every storage backend
checks a token against that format before it turns it into a file name, a directory or a key: any
other value is not found (a `404` from the API), and nothing outside the storage is read, written
or deleted. There is no option to accept other tokens, since the profiler never issues them.

The profiles hold cookies, tokens and environment values, so the directories the profiler creates
are `0700` and its files (profiles, blobs, the SQLite database and its `-wal` and `-shm` files, the
env overrides, their lock and temporary files, the MCP cache) are `0600`, whatever the umask. A
directory that already exists keeps its mode: for one created by an earlier version, run
`chmod 700 tmp/rails-profiler`. When the web process and the workers that read the env overrides
or a shared file or SQLite store run as two different users (two containers with different uids
on one volume, for instance), restore the modes of the umask:

```ruby
config.restrict_storage_permissions = false # true by default
```

With `false`, the profiler creates its directories and files with the modes of the umask, follows
a symbolic link in place of its SQLite database, its `-wal` or `-shm` file or the lock of the env
overrides, and does not warn about a shared `tmp_path`, as versions before 0.31.1 did. It only
applies to what is created from then on: reopen what already exists with
`chmod -R u=rwX,go=rX tmp/rails-profiler` (`0755` and `0644`, the modes of the usual umask). A
worker under another user that writes there too (it opens `env_overrides.json.lock` for writing)
also needs the files to belong to a group of both users: give both users the same primary group,
or run `chgrp -R <group> tmp/rails-profiler` and `find tmp/rails-profiler -type d -exec chmod g+s {} +`
so that new files inherit the group; then run both processes with a umask of `002`, and
`chmod -R ug=rwX,o=rX tmp/rails-profiler`.

While the modes are restricted (the default), a symbolic link where the profiler keeps the SQLite
database, its `-wal` or `-shm` file or the lock of the env overrides is refused rather than
followed, and an existing `tmp_path` that belongs to another user or that group or others can
write to (a `tmp/rails-profiler` under a shared directory, outside Rails) is reported once on
standard error.

