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
#   --permission-mode dontAsk + --settings sandbox-settings.json
#                                     macOS Seatbelt sandbox on Bash: network denied
#                                     (blocks bolt:7687 + docker), reads denied outside
#                                     the workspace (blocks poc/ answer fixtures + the
#                                     stray log_analysis/ checkout). See PARITY-RECHECK.md.
#   fresh process per run             no --continue/--resume (cold session)
# Claude's BUILT-IN tools (grep/read/edit/bash) are available in ALL arms WITHIN the
# sandboxed workspace. This script checks (1) MCP-server scoping per arm and (2) that the
# sandbox actually denies docker + out-of-workspace reads.
#
# Usage:  bash poc/dryrun-isolation.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNDIR="$ROOT/groundx-rnd/ai-server"   # any indexed repo; isolation is config-driven
MCP="$ROOT/poc/mcp"
COMMON=(--strict-mcp-config --setting-sources project,local
        --permission-mode dontAsk --settings "$ROOT/poc/sandbox-settings.json"
        --allowedTools "Read,Grep,Glob,Bash,Edit,Write,TodoWrite,Task"
        --model claude-opus-4-8
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

# ---- (2) sandbox denial check: prove Bash cannot reach docker/neo4j or read fixtures ----
echo "────────────────────────────────────────────────────────"
echo "SANDBOX DENIAL CHECK (baseline arm, from workspace)"
sbxlog="$TMP/sandbox.jsonl"
GOPROXY=off GOTOOLCHAIN=local claude -p \
  "Run each and report exit status, do not stop on failure: (1) Bash: docker ps  (2) Bash: cat $ROOT/poc/tasks/tasks.jsonl  (3) Bash: nc -zv localhost 7687" \
  "${COMMON[@]}" > "$sbxlog" 2>"$TMP/sandbox.err"
# Every sensitive action must be blocked; the transcript should show denials / 'not permitted'.
blocked="$(jq -rs '[.[]|select(.type=="user")|.message.content[]?|select(.type=="tool_result")|.content|tostring]|join(" ")' "$sbxlog" 2>/dev/null | grep -oiE "denied|not permitted" | wc -l | tr -d ' ')"
leaked="$(jq -rs '[.[]|select(.type=="user")|.message.content[]?|select(.type=="tool_result")|.content|tostring]|join(" ")' "$sbxlog" 2>/dev/null | grep -ciE "poctestpassword|\"id\": *\"A3\"|taskDuration")"
if [ "${blocked:-0}" -ge 2 ] && [ "${leaked:-0}" -eq 0 ]; then
  echo "  RESULT: PASS — docker/neo4j/fixtures all denied ($blocked denials, 0 leaks)"
else
  echo "  RESULT: FAIL — sandbox leak (denials=$blocked, leaked-content=$leaked) — INSPECT $sbxlog"
  fail=$((fail+1))
fi
echo

echo "========================================================"
echo "Isolation dry-run: $pass passed, $fail failed  (MCP scoping + sandbox denial)."
rm -rf "$TMP"
[ "$fail" -eq 0 ]
