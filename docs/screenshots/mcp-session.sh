#!/usr/bin/env bash
# Replays the MCP session shown in docs/mcp.md ("A real session") against the demo application,
# with the MCP Inspector CLI as the client and the stdio transport. Prints the text of every tool
# response. Start the demo application first and leave it running:
#
#   SERVE=1 docs/screenshots/run.sh <superproject test_app dir>
#   docs/screenshots/mcp-session.sh
#
# The session finds the N+1 of /api/n_plus_one, explains the repeated query, fixes it in the
# demo copy of the application (Rails reloads the controller), checks the new profile, then
# puts the original code back.
set -euo pipefail
RB=${RB:-$HOME/rb}
APP=${APP:-/tmp/myapp}
INSPECTOR=@modelcontextprotocol/inspector@2.10.1
CONTROLLER=$APP/app/controllers/api_test_controller.rb
BUGGY='posts = Post.all.to_a'
FIXED='posts = Post.includes(:author).to_a'

curl -sf -o /dev/null localhost:3000/up || { echo "start the demo first: SERVE=1 run.sh <test_app>"; exit 1; }
grep -qF "$BUGGY" "$CONTROLLER" || { echo "$CONTROLLER does not hold the N+1 any more"; exit 1; }

# The MCP server, as a client starts it: `bundle exec rake profiler:mcp` in the application's
# directory. Same empty environment as the demo servers; PROFILER_NAME selects the profile store
# of the master (the demo gives each node its own SQLite file).
SERVER=$(mktemp)
trap 'rm -f "$SERVER"; sed -i "s/$FIXED/$BUGGY/" "$CONTROLLER"' EXIT
cat > "$SERVER" <<EOF
#!/bin/sh
cd "$APP" && exec env -i PATH="$RB/x64/bin:/usr/bin:/bin" HOME="$APP/tmp/home" LANG=C.UTF-8 \\
  RAILS_ENV=development PROFILER_NAME=myapp-web bundle exec rake profiler:mcp
EOF
chmod +x "$SERVER"

call() { # tool key=value...
  local tool=$1; shift
  local args=()
  for a in "$@"; do args+=(--tool-arg "$a"); done
  echo "### tools/call $tool $*"
  npx --yes "$INSPECTOR" --cli "$SERVER" --method tools/call --tool-name "$tool" "${args[@]}" 2>/dev/null |
    python3 -c 'import json, sys; [print(c["text"]) for c in json.load(sys.stdin)["content"]]'
  echo
}
hit() { curl -s -o /dev/null -H "Host: api.myapp.test:3000" localhost:3000/api/n_plus_one; }

hit
LIST=$(call query_profiles path=/api/n_plus_one limit=1)
echo "$LIST"; echo
# explain_query does not take "latest": it needs the token of the profile.
TOKEN=$(grep -oE '[0-9a-f]{32}' <<<"$LIST" | head -1)
call analyze_queries "token=$TOKEN"
call get_profile "token=$TOKEN" 'sections=["database"]'
call explain_query "token=$TOKEN" query_index=1

echo "### fix: $BUGGY -> $FIXED"
sed -i "s/$BUGGY/$FIXED/" "$CONTROLLER"
echo
hit
call analyze_queries token=latest summary_only=true
call get_profile token=latest 'sections=["database"]'
