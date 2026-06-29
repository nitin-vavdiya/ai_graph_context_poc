#!/usr/bin/env bash
# Dry-run isolation check for the 4 benchmark arms.
#
# This does NOT run the benchmark. It starts each arm for a single trivial turn
# and reads the `system/init` event Claude Code emits, which lists the MCP
# server NAMES configured for that run. It then asserts each arm loaded EXACTLY
# its intended servers and nothing else — proving the arms cannot see each
# other's tools, and that no stray MCP (claude-mem, caveman, chrome) leaks.
#
# SCOPE / LIMITATION: this checks which servers are CONFIGURED, not whether their
# tools are CALLABLE. The init snapshot always shows servers as status="pending"
# with zero mcp__ tools even when they connect and work moments later, so a PASS
# here does NOT prove the graph/LSP tools actually function. For that, run
# `poc/probe-mcp.sh`, which forces a real mcp__* tool call and asserts it lands.
# Pre-flight = BOTH scripts (isolation here + callability there).
#
# Isolation controls applied to every arm (same on all → only MCP config varies):
#   --strict-mcp-config         only MCP servers from --mcp-config (none for baseline)
#   --setting-sources project,local   omit the `user` source where claude-mem
#                                      hook + plugins are registered
#   fresh process per run             no --continue/--resume (cold session)
# Claude's BUILT-IN tools (grep/read/edit/bash) are available in ALL arms by design.
#
# Usage:  bash poc/dryrun-isolation.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNDIR="$ROOT/groundx-rnd/ai-server"   # any indexed repo; isolation is config-driven
MCP="$ROOT/poc/mcp"
COMMON=(--strict-mcp-config --setting-sources project,local
        --permission-mode bypassPermissions --model claude-opus-4-8
        --output-format stream-json --verbose --max-turns 1)
TMP="$(mktemp -d)"

# arm | mcp-config (empty = none) | expected servers (comma-sep, empty = none)
ARMS=(
  "baseline|||"
  "cgc|$MCP/codegraphcontext.json|codegraphcontext"
  "serena|$MCP/serena.json|serena"
  "both|$MCP/both.json|codegraphcontext,serena"
)

boundary() {
  local name="$1" allowed="$2"
  echo "────────────────────────────────────────────────────────"
  echo "ARM: $name"
  echo "  Claude built-in tools : ALLOWED (grep/read/edit/bash)"
  echo "  MCP servers ALLOWED   : ${allowed:-none}"
  echo "  MCP servers FORBIDDEN : everything else (claude-mem, caveman, chrome, and the other arms' tools)"
  echo "  Memory / hooks        : disabled (--setting-sources project,local; no --continue/--resume)"
  echo "────────────────────────────────────────────────────────"
}

pass=0; fail=0
cd "$RUNDIR" || exit 1
for row in "${ARMS[@]}"; do
  IFS='|' read -r name cfg expected <<< "$row"
  boundary "$name" "$expected"
  args=("${COMMON[@]}")
  [ -n "$cfg" ] && args+=(--mcp-config "$cfg")
  claude -p "ok" "${args[@]}" > "$TMP/$name.jsonl" 2>"$TMP/$name.err"
  actual="$(head -1 "$TMP/$name.jsonl" | jq -r '[.mcp_servers[]?.name] | sort | join(",")' 2>/dev/null)"
  want="$(echo "$expected" | tr ',' '\n' | sort | paste -sd, -)"
  if [ "$actual" = "$want" ]; then
    echo "  RESULT: PASS — loaded servers = [${actual:-none}]"
    pass=$((pass+1))
  else
    echo "  RESULT: FAIL — expected [${want:-none}] but got [${actual:-none}]"
    fail=$((fail+1))
  fi
  echo
done

echo "========================================================"
echo "Isolation dry-run: $pass passed, $fail failed."
rm -rf "$TMP"
[ "$fail" -eq 0 ]
