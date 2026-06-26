#!/usr/bin/env bash
# Benchmark runner — 4 arms x N tasks (poc/tasks/tasks.jsonl).
#
# For each (task, arm): restore the repo to a pristine snapshot, apply the task
# setup, run Claude Code with that arm's isolation flags + MCP config, then run
# the task oracle (tests / build / completeness) and record metrics. The repo is
# restored after every cell so runs never contaminate each other.
#
# Isolation (same on every arm; only the MCP config varies) — verified by
# poc/dryrun-isolation.sh:
#   --strict-mcp-config         only the arm's own MCP servers
#   --setting-sources project,local   no user-source claude-mem hook/plugins
#   fresh process per cell             no --continue/--resume
# All arms use Claude's BUILT-IN tools (grep/read/edit/bash).
#
# Repo restore is SNAPSHOT-based (not reset --hard): cashbot-go has pre-existing
# local state (modified AGENTS.md, untracked documents-latest/, .serena/) that
# must be preserved. We snapshot tracked state with `git stash create` once, then
# `git restore --source=<snap>` after each cell and delete only files created
# during that cell.
#
# Usage:
#   bash poc/run.sh                 # all tasks x all arms (16 real Claude runs)
#   bash poc/run.sh --dry           # no Claude calls; applies canonical fixes to
#                                    # exercise setup/oracle/restore/parse plumbing
#   bash poc/run.sh --tasks C1,A2   # subset of tasks
#   bash poc/run.sh --arms baseline,cgc
# (Written for macOS bash 3.2 — no associative arrays / mapfile / set -u.)
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RND="$ROOT/groundx-rnd"
MCP="$ROOT/poc/mcp"
FIX="$ROOT/poc/tasks/fixtures"
TASKS="$ROOT/poc/tasks/tasks.jsonl"
OUT="$ROOT/poc/results"
RUNS="$ROOT/poc/runs"
MODEL="claude-opus-4-8"
MAXTURNS=80
ISO=(--strict-mcp-config --setting-sources project,local --permission-mode bypassPermissions --model "$MODEL")

ARM_NAMES=(baseline cgc serena both)
arm_mcp() { case "$1" in baseline) echo "" ;; cgc) echo "$MCP/codegraphcontext.json" ;; serena) echo "$MCP/serena.json" ;; both) echo "$MCP/both.json" ;; esac; }

DRY=0; ONLY_TASKS=""; ONLY_ARMS=""
while [ $# -gt 0 ]; do case "$1" in
  --dry) DRY=1 ;; --tasks) ONLY_TASKS="$2"; shift ;; --arms) ONLY_ARMS="$2"; shift ;;
  *) echo "unknown arg: $1"; exit 2 ;; esac; shift; done

wants() { [ -z "$2" ] || echo ",$2," | grep -q ",$1,"; }

mkdir -p "$OUT" "$RUNS"
RESULTS="$OUT/results.csv"
[ -f "$RESULTS" ] || echo "ts,task,arm,is_error,oracle_pass,completeness,tool_calls,mcp_tool_calls,num_turns,in_tokens,out_tokens,cache_read,duration_ms,cost_usd" > "$RESULTS"

# ---- repo snapshot / restore (file-based; bash 3.2 has no assoc arrays) ------
snapshot_repo() { # $1 = repo path
  local b s; b=$(basename "$1")
  s=$(git -C "$1" stash create 2>/dev/null); [ -z "$s" ] && s=$(git -C "$1" rev-parse HEAD)
  echo "$s" > "$OUT/.snap_$b"
  git -C "$1" ls-files --others --exclude-standard 2>/dev/null | sort > "$OUT/.untracked_base_$b"
}
restore_repo() { # $1 = repo path
  local r="$1" b snap; b=$(basename "$1"); snap=$(cat "$OUT/.snap_$b")
  git -C "$r" restore --source="$snap" -- . 2>/dev/null || git -C "$r" checkout "$snap" -- . 2>/dev/null
  # remove only files created during the cell; never touch preserved data dirs
  git -C "$r" ls-files --others --exclude-standard 2>/dev/null | sort > "$OUT/.untracked_now_$b"
  comm -13 "$OUT/.untracked_base_$b" "$OUT/.untracked_now_$b" \
    | grep -vE '^(\.serena/|documents-latest/)' | while read -r f; do rm -f "$r/$f"; done
}

# ---- per-task setup / canonical solution / oracle ---------------------------
setup_task() { # $1=id
  case "$1" in
    C1) perl -0pi -e 's/mac\.Write\(\[\]byte\("&"\)\)/mac.Write([]byte(","))/' "$RND/cashbot-go/pkg/link/hmac.go" ;;
    B1|A1|A2) : ;;  # no pre-seed
  esac
}
apply_solution() { # $1=id  — used only in --dry to exercise the pass path
  case "$1" in
    C1) perl -0pi -e 's/mac\.Write\(\[\]byte\(","\)\)/mac.Write([]byte("&"))/' "$RND/cashbot-go/pkg/link/hmac.go" ;;
    A1) perl -0pi -e 's/json:"resultURL,omitempty"/json:"resultUri,omitempty"/' "$RND/cashbot-go/pkg/model/services/response.go" ;;
    A2) perl -0pi -e 's/(\tResultURL\s+\*string\s+`json:"resultURL,omitempty"`\n)/$1\tEngineVersion  *string `json:"engineVersion,omitempty"`\n/' "$RND/cashbot-go/pkg/model/services/response.go" ;;
    B1) return 1 ;;  # too multi-file to auto-apply; dry leaves it failing
  esac
}
oracle() { # $1=id ; sets globals ORACLE_PASS, COMPLETENESS, NOTE
  local id="$1" cg="$RND/cashbot-go"; ORACLE_PASS=0; COMPLETENESS=0; NOTE=""
  case "$id" in
    C1)
      ( cd "$cg" && go test ./pkg/link >/dev/null 2>&1 ) && ORACLE_PASS=1
      COMPLETENESS=$ORACLE_PASS; NOTE="go test ./pkg/link" ;;
    B1)
      local built=0 tested=0 behav=0 leftovers
      ( cd "$cg" && go build ./pkg/... >/dev/null 2>&1 ) && built=1
      ( cd "$cg" && go test ./pkg/config/... >/dev/null 2>&1 ) && tested=1
      leftovers=$(grep -rn --include='*.go' '\.BaseURL()' "$cg" | grep -v _test.go | wc -l | tr -d ' ')
      [ "$leftovers" = "0" ] && COMPLETENESS=1
      cp "$FIX/B1_baseurl_behavior_test.go.txt" "$cg/pkg/config/zz_b1_behavior_test.go" 2>/dev/null
      ( cd "$cg" && go test ./pkg/config >/dev/null 2>&1 ) && behav=1
      rm -f "$cg/pkg/config/zz_b1_behavior_test.go"
      [ "$built" = 1 ] && [ "$tested" = 1 ] && [ "$behav" = 1 ] && ORACLE_PASS=1
      NOTE="build=$built test=$tested behavior=$behav leftover_calls=$leftovers" ;;
    A1)
      ( cd "$cg" && go build ./pkg/... >/dev/null 2>&1 ) || NOTE="build-fail"
      if grep -q 'json:"resultUri' "$cg/pkg/model/services/response.go" && ! grep -q 'json:"resultURL' "$cg/pkg/model/services/response.go"; then COMPLETENESS=1; fi
      ( cd "$cg" && go build ./pkg/... >/dev/null 2>&1 ) && [ "$COMPLETENESS" = 1 ] && ORACLE_PASS=1
      NOTE="${NOTE} resultUri_tag=$COMPLETENESS" ;;
    A2)
      grep -q 'json:"engineVersion' "$cg/pkg/model/services/response.go" && COMPLETENESS=1
      ( cd "$cg" && go build ./pkg/... >/dev/null 2>&1 ) && [ "$COMPLETENESS" = 1 ] && ORACLE_PASS=1
      NOTE="engineVersion_field=$COMPLETENESS" ;;
  esac
}

# ---- metrics from a stream-json log -----------------------------------------
metric() { jq -rs "$1" "$2" 2>/dev/null; }
parse_metrics() { # $1=log ; sets IS_ERROR NUM_TURNS IN_TOK OUT_TOK CACHE DUR COST TOOLS MCPTOOLS
  local f="$1"
  IS_ERROR=$(metric '(map(select(.type=="result"))|last|.is_error) as $e | if $e==null then "na" else $e end' "$f")
  NUM_TURNS=$(metric '(map(select(.type=="result"))|last|.num_turns) // 0' "$f")
  IN_TOK=$(metric '(map(select(.type=="result"))|last|.usage.input_tokens) // 0' "$f")
  OUT_TOK=$(metric '(map(select(.type=="result"))|last|.usage.output_tokens) // 0' "$f")
  CACHE=$(metric '(map(select(.type=="result"))|last|.usage.cache_read_input_tokens) // 0' "$f")
  DUR=$(metric '(map(select(.type=="result"))|last|.duration_ms) // 0' "$f")
  COST=$(metric '(map(select(.type=="result"))|last|.total_cost_usd) // 0' "$f")
  TOOLS=$(metric '[.[]|select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")]|length' "$f")
  MCPTOOLS=$(metric '[.[]|select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|select(.name|startswith("mcp__"))]|length' "$f")
}

# ---- per-task run doc (committed; tool NAMES + metrics only, no code) --------
csv_field() { # $1=task $2=arm $3=col(1-based) — latest matching row
  awk -F, -v t="$1" -v a="$2" -v c="$3" '$2==t && $3==a {v=$c} END{print v}' "$RESULTS"
}
gen_run_doc() { # $1 = task index
  local i="$1"
  local id scn prm rdir; id=$(jq -rs ".[$i].id" "$TASKS"); scn=$(jq -rs ".[$i].scenario" "$TASKS")
  prm=$(jq -rs ".[$i].prompt" "$TASKS"); rdir=$(jq -rs ".[$i].run_dir" "$TASKS")
  local reps; reps=$(jq -rs ".[$i].repos|join(\", \")" "$TASKS")
  local doc="$RUNS/$id.md"
  {
    echo "# Benchmark Run — $id ($scn)"
    echo
    echo "_Auto-generated by \`poc/run.sh\` (tool **names** + metrics only — no code/inputs). Raw logs are gitignored under \`poc/results/\`. Narrative added after review._"
    echo
    echo "## Task"
    echo "- **Scenario:** $scn"
    echo "- **Repos:** $reps · **run_dir:** \`$rdir\`"
    echo "- **Prompt:** $prm"
    echo
    echo "## Isolation (identical on every arm — design §4.5, verified by \`poc/dryrun-isolation.sh\`)"
    echo "- \`--strict-mcp-config\` (only the arm's own MCP) · \`--setting-sources project,local\` (no user-source claude-mem hook / plugins) · fresh \`claude -p\` per cell (no \`--continue\`/\`--resume\`)."
    echo "- Claude **built-in** tools (grep/read/edit/bash) enabled on **all** arms. \`--add-dir\`: $reps."
    echo
    echo "| Arm | MCP servers allowed | Forbidden |"
    echo "|---|---|---|"
    echo "| baseline | none | all MCP |"
    echo "| cgc | codegraphcontext | serena, all others |"
    echo "| serena | serena | codegraphcontext, all others |"
    echo "| both | codegraphcontext + serena | all others (claude-mem, caveman, chrome) |"
    echo
    echo "## Metrics"
    echo
    echo "| Arm | is_error | oracle_pass | completeness | tools | mcp_tools | turns | in_tok | out_tok | cost_usd |"
    echo "|---|---|---|---|---|---|---|---|---|---|"
    local a
    for a in "${ARM_NAMES[@]}"; do
      [ -z "$(csv_field "$id" "$a" 1)" ] && { echo "| $a | _not run_ | | | | | | | | |"; continue; }
      echo "| $a | $(csv_field "$id" "$a" 4) | $(csv_field "$id" "$a" 5) | $(csv_field "$id" "$a" 6) | $(csv_field "$id" "$a" 7) | $(csv_field "$id" "$a" 8) | $(csv_field "$id" "$a" 9) | $(csv_field "$id" "$a" 10) | $(csv_field "$id" "$a" 11) | $(csv_field "$id" "$a" 14) |"
    done
    echo
    echo "## Tool-call trace per arm (names × count, in call order they are grouped)"
    for a in "${ARM_NAMES[@]}"; do
      echo
      echo "### $a"
      local lg="$OUT/${id}_${a}.jsonl"
      if [ ! -s "$lg" ]; then echo "_no log (not run, or dry)_"; continue; fi
      jq -rs '[.[]|select(.type=="assistant")|.message.content[]?|select(.type=="tool_use")|.name] | if length==0 then "_no tool calls_" else (group_by(.)|map({n:.[0],c:length})|sort_by(-.c)|.[]|"- `\(.n)` ×\(.c)") end' "$lg" 2>/dev/null || echo "_parse error_"
    done
    echo
    echo "## Narrative / takeaway"
    echo
    echo "_TODO (filled after review): what each arm did to locate the code, whether the graph/LSP changed the path, and the cross-arm comparison for this scenario._"
  } > "$doc"
  echo "  doc: $doc"
}

# ---- main loop --------------------------------------------------------------
snapshot_repo "$RND/cashbot-go"
snapshot_repo "$RND/ai-server"
trap 'restore_repo "$RND/cashbot-go"; restore_repo "$RND/ai-server"' EXIT

NTASK=$(jq -s 'length' "$TASKS")
echo "Runner: $NTASK tasks x ${#ARM_NAMES[@]} arms  (dry=$DRY)"; echo

for i in $(seq 0 $((NTASK-1))); do
  id=$(jq -rs ".[$i].id" "$TASKS")
  run_dir=$(jq -rs ".[$i].run_dir" "$TASKS")
  prompt=$(jq -rs ".[$i].prompt" "$TASKS")
  repos=( $(jq -rs ".[$i].repos[]" "$TASKS") )
  wants "$id" "$ONLY_TASKS" || continue
  add=(); for r in "${repos[@]}"; do add+=(--add-dir "$RND/$r"); done

  for arm in "${ARM_NAMES[@]}"; do
    wants "$arm" "$ONLY_ARMS" || continue
    echo "──── task=$id  arm=$arm ────"
    echo "  boundary: built-in tools ALLOWED | MCP=$([ -n "$(arm_mcp "$arm")" ] && basename "$(arm_mcp "$arm")" || echo none) | add-dir=${repos[*]}"

    restore_repo "$RND/cashbot-go"; restore_repo "$RND/ai-server"
    setup_task "$id"

    cell="$OUT/${id}_${arm}"; log="$cell.jsonl"; : > "$log"
    if [ "$DRY" = 1 ]; then
      echo "  [dry] skipping Claude; applying canonical solution"
      apply_solution "$id" || echo "  [dry] no auto-solution for $id (oracle expected to fail)"
      IS_ERROR=dry; NUM_TURNS=0; IN_TOK=0; OUT_TOK=0; CACHE=0; DUR=0; COST=0; TOOLS=0; MCPTOOLS=0
    else
      mcp="$(arm_mcp "$arm")"; mcpflag=(); [ -n "$mcp" ] && mcpflag=(--mcp-config "$mcp")
      ( cd "$RND/$(basename "$run_dir")" && claude -p "$prompt" "${ISO[@]}" "${mcpflag[@]}" "${add[@]}" \
          --output-format stream-json --verbose --max-turns "$MAXTURNS" ) > "$log" 2> "$cell.err"
      parse_metrics "$log"
    fi

    oracle "$id"
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo dry)
    echo "$ts,$id,$arm,$IS_ERROR,$ORACLE_PASS,$COMPLETENESS,$TOOLS,$MCPTOOLS,$NUM_TURNS,$IN_TOK,$OUT_TOK,$CACHE,$DUR,$COST" >> "$RESULTS"
    echo "  result: is_error=$IS_ERROR oracle_pass=$ORACLE_PASS completeness=$COMPLETENESS tools=$TOOLS(mcp=$MCPTOOLS) turns=$NUM_TURNS tokens=$IN_TOK/$OUT_TOK  [$NOTE]"

    restore_repo "$RND/cashbot-go"; restore_repo "$RND/ai-server"
    echo
  done
  gen_run_doc "$i"
  echo
done

echo "Done. Results: $RESULTS  ·  Run docs: $RUNS"
