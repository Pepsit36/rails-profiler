#!/usr/bin/env bash
# Builds a demo application from the superproject's test_app and this directory's overlay,
# starts it as a cluster master (port 3000) and one slave (port 3001), fills every tab with
# fictitious data, then takes the screenshots. Run prepare.sh once first. See README.md.
#
#   docs/screenshots/run.sh <superproject test_app dir> [output dir]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
GEM=$(cd "$HERE/../.." && pwd)
SRC=${1:?usage: run.sh <test_app dir> [output dir]}
OUT=$(mkdir -p "${2:-$HERE}" && cd "${2:-$HERE}" && pwd)
RB=${RB:-$HOME/rb} PW=${PW:-$HOME/pw} LIBS=${LIBS:-$HOME/chromelibs}
# File paths show in the Dump and Views tabs: keep the application under a short neutral path.
APP=${APP:-/tmp/myapp}
export PATH=$RB/x64/bin:$PATH

# 1. Front-end assets of this checkout (generated/api.ts is not committed: build:full runs orval).
(cd "$GEM" && yarn install --frozen-lockfile && yarn build:full)

# 2. The demo application: test_app plus the overlay, on this checkout of the gem.
rm -rf "$APP" && cp -r "$SRC" "$APP" && cp -r "$HERE/demo_app/." "$APP/"
sed -i "s|path: '../rails-profiler-gem'|path: '$GEM'|" "$APP/Gemfile"
# test_app commits no Gemfile.lock and json 3.x breaks Rails 7.2 (unknown keyword: quirks_mode).
grep -q '^gem "json"' "$APP/Gemfile" || echo 'gem "json", "~> 2.9"' >> "$APP/Gemfile"
cd "$APP"
bundle install --quiet
bin/rails db:prepare db:seed >/dev/null
# The demo specs expect an empty test database: db:prepare would also load the seeds.
RAILS_ENV=test DATABASE_URL=sqlite3:storage/test.sqlite3 bin/rails db:create db:schema:load >/dev/null
rm -rf tmp/profiler

# 3. Two servers with an empty environment: nothing of this machine reaches the Env tab.
VERSION=$(grep -m1 -oP '^## \[\K[0-9]+\.[0-9]+\.[0-9]+' "$GEM/CHANGELOG.md")
SECRET=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(32)')
start() { # name port extra-env...
  local name=$1 port=$2; shift 2
  env -i PATH="$RB/x64/bin:/usr/bin:/bin" HOME="$APP/tmp/home" LANG=C.UTF-8 RAILS_ENV=development \
    PROFILER_NAME="$name" PROFILER_CLUSTER_SECRET="$SECRET" PROFILER_DEMO_VERSION="$VERSION" PORT="$port" "$@" \
    setsid bin/rails server -p "$port" -b 127.0.0.1 -P "tmp/pids/$name.pid" > "log/$name.server.log" 2>&1 &
}
for port in 3000 3001; do
  ! curl -s -o /dev/null "localhost:$port" || { echo "port $port is already in use"; exit 1; }
done
mkdir -p "$APP/tmp/home"
start myapp-web 3000 PROFILER_CLUSTER_MASTER=true
start myapp-billing 3001 PROFILER_MASTER_URL=http://localhost:3000 PROFILER_SELF_URL=http://localhost:3001
# SERVE=1 leaves both servers running after seeding, to iterate on shoot.mjs by hand.
[ -n "${SERVE:-}" ] || trap 'for f in "$APP"/tmp/pids/myapp-*.pid; do kill "$(cat "$f")" 2>/dev/null || true; done' EXIT
for port in 3000 3001; do
  for _ in $(seq 120); do curl -sf -o /dev/null "localhost:$port/up" && break; sleep 1; done
  curl -sf -o /dev/null "localhost:$port/up" || { echo "server on $port did not start, see $APP/log"; exit 1; }
done

# 4. Profiles: every request names a fictitious host.
hit() { curl -s -o /dev/null -H "Host: api.myapp.test:$1" -H "X-Request-Id: demo" "localhost:$1$2" "${@:3}"; }
for p in /api/users /api/slow_query /api/cache_intensive /api/n_plus_one /checkout /api/raise_named_error; do hit 3000 "$p"; done
hit 3000 /api/users -X POST -H "Content-Type: application/json" -d '{"name":"Jane Example","email":"jane@myapp.test"}'
for p in /api/users /api/n_plus_one /checkout; do hit 3001 "$p"; done
# Console profiles, in the master's store, from the same expressions as an IRB session.
env -i PATH="$RB/x64/bin:/usr/bin:/bin" HOME="$APP/tmp/home" LANG=C.UTF-8 RAILS_ENV=development \
  PROFILER_NAME=myapp-web PROFILER_DEMO_VERSION="$VERSION" bin/rails runner script/console_profiles.rb
sleep 16   # one heartbeat, so that the slave shows online

if [ -n "${SERVE:-}" ]; then
  echo "Servers left running (pids in $APP/tmp/pids). Shoot with: cd $PW && node shoot.mjs $OUT"
  exit 0
fi

# 5. Screenshots, then PNG optimization.
export LD_LIBRARY_PATH=$LIBS/ex/usr/lib/x86_64-linux-gnu:$LIBS/ex/lib/x86_64-linux-gnu
export FONTCONFIG_FILE=$LIBS/fonts.conf
cp "$HERE/shoot.mjs" "$PW/" && (cd "$PW" && node shoot.mjs "$OUT")
npx --yes oxipng -o 4 --strip safe "$OUT"/*.png
ls -l "$OUT"/*.png
