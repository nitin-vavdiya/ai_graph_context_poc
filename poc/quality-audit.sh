#!/usr/bin/env bash
# Quality audit across the 4 arms for a task — goes beyond the pass/fail oracle.
# For each arm it extracts, from the stream-json transcript, WHAT the arm actually
# did so quality (not just "it passed") can be compared:
#   - files edited (count + paths)         -> over-editing / wrong-file signal
#   - edits to _test.go                    -> forbidden-file violation (R*/A3 say don't touch tests; A4 says don't edit at all)
#   - the actual change to the target file -> correctness/style (e.g. *string vs string)
#   - non-edit answer (A4)                 -> reported file list (for precision/recall)
#
# Usage:  bash poc/quality-audit.sh <TASK> [logsuffix]    e.g.  bash poc/quality-audit.sh A2 .p1
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/poc/results"
TASK="${1:?usage: quality-audit.sh <TASK> [suffix]}"; SFX="${2:-}"

echo "==================== QUALITY AUDIT: $TASK${SFX:+ ($SFX logs)} ===================="
for arm in baseline cgc serena both; do
  log="$OUT/${TASK}_${arm}${SFX}.jsonl"
  echo "──── $arm ────"
  if [ ! -s "$log" ]; then echo "  (no transcript)"; continue; fi
  # edit/write tool calls
  edits=$(jq -rs '[.[]|select(.type=="assistant")|.message.content[]?|select(.type=="tool_use" and (.name=="Edit" or .name=="MultiEdit" or .name=="Write"))]' "$log" 2>/dev/null)
  nedits=$(printf '%s' "$edits" | jq -rs 'add // [] | length' 2>/dev/null)
  files=$(printf '%s' "$edits" | jq -rs 'add // [] | [.[].input.file_path | sub(".*/groundx-rnd/";"")] | unique | join(", ")' 2>/dev/null)
  ntest=$(printf '%s' "$edits" | jq -rs 'add // [] | [.[].input.file_path | select(test("_test\\.go"))] | length' 2>/dev/null)
  echo "  edits made:        ${nedits:-0}"
  echo "  files changed:     ${files:-none}"
  echo "  _test.go edits:    ${ntest:-0}  $([ "${ntest:-0}" -gt 0 ] && echo '⚠ FORBIDDEN' || echo 'ok')"
  # mcp usage (was the graph/LSP used at all)
  nmcp=$(jq -rs '[.[]|select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|.name|select(startswith("mcp__"))]|length' "$log" 2>/dev/null)
  echo "  mcp tool calls:    ${nmcp:-0}"
done
echo "=================================================================="
