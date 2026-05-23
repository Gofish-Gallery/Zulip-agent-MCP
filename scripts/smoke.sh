#!/usr/bin/env bash
# GOF-42 end-to-end smoke test for the Zulip MCP server.
#
# Boots the escript and drives the real newline-delimited JSON-RPC 2.0 stdio
# transport end to end: initialize -> tools/list -> a live, read-only
# tools/call (get_streams) against the configured realm. Exits non-zero on
# any failure so it's CI-friendly.
#
# Requires the same env the server reads:
#   ZULIP_SITE  ZULIP_EMAIL  ZULIP_API_KEY
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ZULIP_SITE:?ZULIP_SITE must be set}"
: "${ZULIP_EMAIL:?ZULIP_EMAIL must be set}"
: "${ZULIP_API_KEY:?ZULIP_API_KEY must be set}"

echo "[smoke] building escript..." >&2
mix escript.build >&2

requests=$(cat <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_streams","arguments":{}}}
JSON
)

echo "[smoke] driving stdio transport against ${ZULIP_SITE}..." >&2
out=$(printf '%s\n' "$requests" | ./zulip_mcp_ex 2>/dev/null)

# Each stdout line is one JSON-RPC response; slurp them into an array with jq.
init_name=$(echo "$out"     | jq -rs '.[] | select(.id==1) | .result.serverInfo.name')
tool_count=$(echo "$out"    | jq -rs '.[] | select(.id==2) | .result.tools | length')
has_register=$(echo "$out"  | jq -rs '[.[] | select(.id==2) | .result.tools[].name] | index("register_agent") != null')
has_ensure=$(echo "$out"    | jq -rs '[.[] | select(.id==2) | .result.tools[].name] | index("ensure_agent_session") != null')
streams_err=$(echo "$out"   | jq -rs '.[] | select(.id==3) | .result.isError')

fail=0
[ "$init_name" = "zulip-mcp-ex" ] \
  && echo "[smoke] OK   initialize -> $init_name" \
  || { echo "[smoke] FAIL initialize (got: '$init_name')"; fail=1; }

[ "${tool_count:-0}" -ge 13 ] 2>/dev/null \
  && echo "[smoke] OK   tools/list -> $tool_count tools" \
  || { echo "[smoke] FAIL tools/list count ('$tool_count')"; fail=1; }

[ "$has_register" = "true" ] && [ "$has_ensure" = "true" ] \
  && echo "[smoke] OK   agent-lifecycle tools present" \
  || { echo "[smoke] FAIL register_agent/ensure_agent_session missing"; fail=1; }

[ "$streams_err" = "false" ] \
  && echo "[smoke] OK   live get_streams against realm" \
  || { echo "[smoke] FAIL live get_streams (isError='$streams_err')"; fail=1; }

if [ "$fail" -eq 0 ]; then
  echo "[smoke] ALL PASSED"
else
  echo "[smoke] FAILURES" >&2
  exit 1
fi
