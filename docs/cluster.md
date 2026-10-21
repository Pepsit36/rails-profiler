# Cluster (master and slaves)

Connect multiple Rails profiler instances so a single **master** dashboard and MCP server can query any **slave**.

The master and its slaves authenticate each other with a **shared secret**, and the master only
sends requests to slave URLs you allow. Nothing is routed or accepted until you configure it.

> **Server-side request forgery.** The master sends HTTP requests to the URLs its slaves register,
> and returns what they answer. Keep `cluster_allowed_slave_urls` as narrow as you can, and read
> [How the cluster is protected](#how-the-cluster-is-protected) before you widen it: with
> `cluster_allowed_slave_urls = :any`, whoever can register makes the master fetch any host it
> can reach.

How the registration, the heartbeat and the proxy work inside the gem is described in
[ARCHITECTURE.md](../ARCHITECTURE.md#8-cluster-master-and-slaves).

## Setting up

**On the master**:
```ruby
Profiler.configure do |config|
  config.name = "main"  # optional display name
  config.cluster_master = true                                  # routes the cluster endpoints
  config.cluster_secret = ENV.fetch("PROFILER_CLUSTER_SECRET")  # same value on every node
  config.cluster_allowed_slave_urls = [
    "https://payment.internal:3001",  # a slave URL must match one entry
    "http://localhost:3002"           # plain HTTP is accepted for loopback addresses only
  ]
end
```

**On each slave**, add to `config/initializers/profiler.rb`:
```ruby
Profiler.configure do |config|
  config.name       = "payment-service"                         # display name
  config.master_url = "https://master-host:3000"                # master's URL
  config.self_url   = "https://payment.internal:3001"           # this instance's URL (reachable from master)
  config.cluster_secret = ENV.fetch("PROFILER_CLUSTER_SECRET")  # same value as the master

  # Optional tuning (defaults shown)
  config.cluster_heartbeat_interval = 15  # seconds between heartbeats
  config.cluster_offline_threshold  = 60  # seconds without heartbeat → offline
end
```

Generate the secret once, for example with `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`,
and give it to every node through the environment, never in the repository. A secret shorter than
32 characters, or blank, is ignored as if none were configured: the node logs a warning at boot,
and every cluster request is refused with a message saying why.

The slave registers automatically at boot and sends periodic heartbeats.

**Forking servers (Puma in cluster mode, Unicorn).** With `preload_app!` (or a preloaded Unicorn)
the application boots in the parent process, and a thread does not survive `fork`: the workers
would have no heartbeat and would never register again. On Ruby 3.1 and later the gem hooks
`Process._fork` and starts a heartbeat thread in each forked child, which registers again from
there (nothing is started when the child already has one). Where `Process._fork` does not exist
(Ruby 3.0), or when you would rather not rely on it, restart the client by hand in the worker:

```ruby
# config/puma.rb
on_worker_boot do
  Profiler::Cluster::MasterClient.restart_after_fork
end
```

For Unicorn, the same call goes in `after_fork`. It is safe to call in addition to the hook.

**The master must run as a single process.** The registry of slaves lives in the memory of the
process that received the registration, and each heartbeat reaches only one process. With several
workers (Puma in cluster mode, Unicorn, several `rails server`), a worker that misses every
heartbeat of a `cluster_offline_threshold` window shows its slaves as `offline`, or does not know
them at all, and the answer of the dashboard depends on which worker takes the request. Run the
master with a single process (`workers 0` in Puma, threads are fine). The slaves themselves may
run as many workers as you like.

**Two applications on one machine** (for example two git worktrees on ports 3000 and 3001) need
no HTTPS: loopback addresses are accepted over plain HTTP.

```ruby
# master, on port 3000
config.cluster_master = true
config.cluster_secret = ENV.fetch("PROFILER_CLUSTER_SECRET")
config.cluster_allowed_slave_urls = ["http://localhost:3001"]

# slave, on port 3001
config.master_url = "http://localhost:3000"
config.self_url = "http://localhost:3001"
config.cluster_secret = ENV.fetch("PROFILER_CLUSTER_SECRET")
```

**Slaves whose names are not known in advance** (for example one container per git worktree in a
Docker network): an entry of `cluster_allowed_slave_urls` can be a `Regexp` instead of a URL.

```ruby
# master
config.cluster_master = true
config.cluster_secret = ENV.fetch("PROFILER_CLUSTER_SECRET")
config.cluster_allowed_slave_urls = [%r{\Ahttp://myapp-[a-z0-9-]+:3000\z}]
config.cluster_allow_insecure_http = true  # plain HTTP to a non-loopback host, inside the Docker network only
```

- The pattern must start with `\A` and end with `\z`, so that it matches the whole URL: any other
  `Regexp` (unanchored, anchored with `^`, `$` or `\Z`, or whose `x`-mode comment hides the `\z`)
  raises an `ArgumentError` when it is assigned. It is matched as a whole even if it alternates at
  the top level, and its options (`i`, `x`) apply.
- It is matched against the URL as the master keeps it: lower-case scheme and host, no default port
  (`:80` for `http`, `:443` for `https`), no trailing slash, and path segments percent-encoded again
  (`~` becomes `%7E`, `:` becomes `%3A`). Write the pattern for that form, and keep the port in it
  if the slaves use a non-default one.
- The checks on the URL come first and the pattern cannot lift them: user info, a query, a fragment
  or a `.` or `..` segment are refused, and plain HTTP to a host that is not a loopback address
  still needs `cluster_allow_insecure_http`.
- Only a `Regexp` object is a pattern: a `String` is always a URL, even if it looks like a pattern.
- URLs and patterns can be mixed in one list. As with listed names, the pattern is matched against
  the name, not the address it resolves to: keep the character classes tight (`[a-z0-9-]+`, never
  `.*` for a host).

## Using it

**In the UI** (`/_profiler` on the master): a **Profiler** dropdown appears above the header,
listing the connected slaves. Selecting one proxies all data through the master; the rest of the
interface is unchanged (see the [UI Guide](ui.md#profiler-selector-cluster)).

![The profile list of a slave, read through the master](screenshots/cluster-selector.png)

**In MCP**: every tool but `list_slaves` accepts an optional `slave: "<name>"` parameter:
```
query_profiles slave: "payment-service", path: "/api/charges"
list_slaves  # → shows connected slaves and their status
```

## How the cluster is protected

- **Routes.** `POST /_profiler/api/cluster/register`, `POST /_profiler/api/cluster/heartbeat`,
  `GET /_profiler/api/cluster/slaves` and the proxy `/_profiler/api/slaves/<name>/...` exist only
  on a node with `cluster_master = true`; elsewhere they answer `404`. A slave needs no route of its
  own: `master_url` is what makes it register.
- **Shared secret.** A slave sends `X-Profiler-Cluster-Secret` on `register` and `heartbeat`, and
  the master sends it on every proxied call. It is compared in constant time. `register` and
  `heartbeat` are authenticated by the secret alone, from any address (a slave is a server, not a
  browser); they are refused when it is missing or wrong, and refused altogether while no
  `cluster_secret` is configured. On a slave (a node with `master_url`), a request carrying the
  right secret is let in as the master's, in place of `authorization_mode` and the forgery header;
  a wrong or missing secret changes nothing.
- **Slave URLs.** The master registers, and sends requests to, a slave URL only if it matches an
  entry of `cluster_allowed_slave_urls`: same scheme, host and port, compared after normalization
  (case of the host, default port, IPv6 between brackets), and a path under the entry's path,
  segment by segment. A URL with user info, a query, a fragment or a `.` or `..` segment is refused.
  An entry can also be an anchored `Regexp` (see *Slaves whose names are not known in advance*
  above). The default, `[]`, refuses every URL. The check runs again on each proxied call, so removing an
  entry cuts off a slave already registered.
- **HTTPS.** Slave URLs and `master_url` must use HTTPS, except for `localhost`, `127.0.0.0/8` and
  `::1`, so that the secret and the profiles do not cross the network in clear.
- **Redirects.** The master never follows a redirect from a slave: a `3xx` answer is reported as an
  error, without its body.
- **Paths.** Whatever a client puts in a proxied path, a profile token or an MCP argument stays
  inside one path segment under the slave's `/_profiler/api/`: `?`, `#` and `%` are encoded, and a
  `.`, `..` or `/` segment is refused before any request is sent.
- **What the allow list does not cover.** Entries are compared by name, not by the address the name
  resolves to: a listed name whose DNS points at an internal address, or is rebound to one after
  the check, is reached all the same. List only names whose DNS zone you control, or IP addresses.
- **One secret for the whole cluster.** Every node holds the same secret, so whoever compromises one
  node, or reads its environment, can register slaves on the master and call every slave as the
  master. Profiles and test runs mask it by value (see [Sensitive data](security.md#sensitive-data)), but
  your own log files and error trackers do not: keep it out of them, and change it on every node if
  one is exposed.
- The proxy route itself is called by your browser, so it stays behind `authorization_mode` and the
  forgery protection, like the rest of `/_profiler`.

## Restoring the behaviour of earlier versions

Each of these brings back a risk the defaults remove; set only the ones you need.

| Setting | Behaviour | Risk |
|---|---|---|
| `config.cluster_master = true` | Routes the cluster endpoints, which every application had in earlier versions | None by itself: the other checks still apply |
| `config.cluster_require_secret = false` (and no `cluster_secret`) | `register` and `heartbeat` accept any client that `authorization_mode` and the forgery header let in, as in 0.30.6, and the master proxies without a secret | Whoever passes `authorization_mode` can register a slave URL; a slave across the network has to admit the master's address itself |
| `config.cluster_allowed_slave_urls = :any` | Any slave URL is accepted, as in earlier versions | Server-side request forgery: whoever can register makes the master fetch any host and port it can reach, internal services and cloud metadata included, and read the answer |
| `config.cluster_allow_insecure_http = true` | Plain HTTP to any host | The secret and every proxied profile cross the network in clear |

---

