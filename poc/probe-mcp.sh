#!/usr/bin/env bash
# MCP callability probe — proves each arm's MCP tools are not just configured
# but actually CALLABLE in-session, returning real data.
#
# WHY THIS EXISTS (and why dryrun-isolation.sh is not enough):
#   dryrun-isolation.sh reads the `system/init` snapshot and checks which MCP
#   server NAMES are configured. That is necessary (proves the right config
#   loaded + no leaks) but NOT sufficient: in headless `claude -p` that snapshot
#   ALWAYS shows servers as status="pending" with ZERO mcp__ tools in its tools
#   array — even when the tools connect moments later and are fully callable.
#   So a server can look "loaded" yet a benchmark cell shows mcp=0 for either of
#   two opposite reasons: (a) the model DECLINED the tools, or (b) the tools were
#   never usable. Only an actual mcp__* tool_use in the transcript tells them
#   apart. This script forces that call and asserts it happened with no error.
#
# Run this in pre-flight (after docker compose up; costs ~3 real Claude calls)
# BEFORE trusting any mcp=0 result — especially before A2.
#
# Requires: Neo4j up (cgc) and the run repo indexed in Neo4j + .serena cache.
# Usage:  bash poc/probe-mcp.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNDIR="$ROOT/groundx-rnd/cashbot-go"   # indexed in both Neo4j and .serena
MCP="$ROOT/poc/mcp"
COMMON=(--strict-mcp-config --setting-sources project,local
        --permission-mode bypassPermissions --model claude-opus-4-8
        --output-format stream-json --verbose --max-turns 8)
TMP="$(mktemp -d)"

# arm | mcp-config | expected mcp tool-name prefix | force-call prompt
PROBES=(
  "cgc|$MCP/codegraphcontext.json|mcp__codegraphcontext__|Call your mcp__codegraphcontext__find_code tool to locate a function named NewClient and report how many it found. If you have no mcp__ tool available to you, reply exactly: NO_MCP_TOOLS."
  "serena|$MCP/serena.json|mcp__serena__|Call your mcp__serena__find_symbol tool to locate a symbol named NewClient and report how many it found. If you have no mcp__ tool available to you, reply exactly: NO_MCP_TOOLS."
  "both|$MCP/both.json|mcp__|Call any mcp__codegraphcontext__ or mcp__serena__ tool to locate NewClient and report how many it found. If you have no mcp__ tool available to you, reply exactly: NO_MCP_TOOLS."
)

pass=0; fail=0
cd "$RUNDIR" || { echo "run dir missing: $RUNDIR"; exit 1; }
echo "MCP callability probe — forcing a real tool call per arm (run dir: $(basename "$RUNDIR"))"
echo

for row in "${PROBES[@]}"; do
  IFS='|' read -r name cfg prefix prompt <<< "$row"
  echo "────────────────────────────────────────────────────────"
  echo "ARM: $name   (expect a $prefix* tool_use)"
  claude -p "$prompt" "${COMMON[@]}" --mcp-config "$cfg" \
    > "$TMP/$name.jsonl" 2>"$TMP/$name.err"
  # count mcp tool_use events with the expected prefix
  ncalls="$(jq -rs --arg p "$prefix" \
    '[.[]|select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|.name|select(startswith($p))]|length' \
    "$TMP/$name.jsonl" 2>/dev/null)"
  names="$(jq -rs --arg p "$prefix" \
    '[.[]|select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|.name|select(startswith($p))]|unique|join(", ")' \
    "$TMP/$name.jsonl" 2>/dev/null)"
  iserr="$(jq -rs '(map(select(.type=="result"))|last|.is_error) // "na"' "$TMP/$name.jsonl" 2>/dev/null)"
  if [ "${ncalls:-0}" -ge 1 ] && [ "$iserr" != "true" ]; then
    echo "  RESULT: PASS — called [$names] (is_error=$iserr)"
    pass=$((pass+1))
  else
    echo "  RESULT: FAIL — no $prefix* tool_use (calls=$ncalls is_error=$iserr) — tools NOT callable"
    echo "          stderr tail: $(tail -2 "$TMP/$name.err" 2>/dev/null | tr '\n' ' ')"
    fail=$((fail+1))
  fi
  echo
done

echo "========================================================"
echo "MCP callability probe: $pass passed, $fail failed."
echo "(baseline arm has no MCP by design and is not probed here.)"
rm -rf "$TMP"
[ "$fail" -eq 0 ]
