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
# --dry is a plumbing test; never let it clobber real results or truncate real
# transcripts. Route dry output to separate files.
RESULTS="$OUT/results.csv"; [ "$DRY" = 1 ] && RESULTS="$OUT/results.dry.csv"
[ -f "$RESULTS" ] || echo "ts,task,arm,is_error,oracle_pass,completeness,tool_calls,mcp_tool_calls,num_turns,in_tokens,out_tokens,cache_read,duration_ms,cost_usd" > "$RESULTS"

# ---- repo PARKING: physically move a repo off-disk so the agent genuinely
# cannot read it (—add-dir is NOT a sandbox under bypassPermissions: the Read/Bash
# tools open any absolute path). The graph (Neo4j) keeps the repo's indexed source,
# so only cgc can answer questions about a parked repo. Used by cross-repo tasks
# (A3) to recreate the real "repo not on this machine" condition. -----------------
PARKDIR="$OUT/.parked"; PARKED=""
park_repo() { # $1 = repo basename
  local r="$1"; [ -d "$RND/$r" ] || return 0
  mkdir -p "$PARKDIR"; mv "$RND/$r" "$PARKDIR/$r" && PARKED="$PARKED $r"
  echo "  parked off-disk: $r (absent from workspace; only the graph retains it)"
}
unpark_all() { local r; for r in $PARKED; do [ -d "$PARKDIR/$r" ] && mv "$PARKDIR/$r" "$RND/$r"; done; PARKED=""; }

# ---- repo snapshot / restore (file-based; bash 3.2 has no assoc arrays) ------
# All three are no-ops if the repo dir is absent (e.g. parked off-disk).
snapshot_repo() { # $1 = repo path
  [ -d "$1" ] || return 0
  local b s; b=$(basename "$1")
  s=$(git -C "$1" stash create 2>/dev/null); [ -z "$s" ] && s=$(git -C "$1" rev-parse HEAD)
  echo "$s" > "$OUT/.snap_$b"
  git -C "$1" ls-files --others --exclude-standard 2>/dev/null | sort > "$OUT/.untracked_base_$b"
}
restore_repo() { # $1 = repo path
  [ -d "$1" ] || return 0
  local r="$1" b snap; b=$(basename "$1"); snap=$(cat "$OUT/.snap_$b")
  git -C "$r" restore --source="$snap" -- . 2>/dev/null || git -C "$r" checkout "$snap" -- . 2>/dev/null
  # remove only files created during the cell; never touch preserved data dirs
  git -C "$r" ls-files --others --exclude-standard 2>/dev/null | sort > "$OUT/.untracked_now_$b"
  comm -13 "$OUT/.untracked_base_$b" "$OUT/.untracked_now_$b" \
    | grep -vE '^(\.serena/|documents-latest/)' | while read -r f; do rm -f "$r/$f"; done
}
# Belt-and-suspenders: assert the repo matches its snapshot (no prior cell's
# edits leaked in). Tracked files must equal the snapshot; the only allowed
# untracked files are the pre-existing base set + preserved data dirs.
# Returns 1 and prints a loud warning if contaminated. $2 = phase label.
assert_pristine() { # $1 = repo path, $2 = label
  [ -d "$1" ] || { echo "  (pristine check skipped: $(basename "$1") parked off-disk)"; return 0; }
  local r="$1" lbl="$2" b snap dirty extra; b=$(basename "$1"); snap=$(cat "$OUT/.snap_$b")
  dirty=$(git -C "$r" diff "$snap" --name-only -- . 2>/dev/null | tr '\n' ' ')
  git -C "$r" ls-files --others --exclude-standard 2>/dev/null | sort > "$OUT/.untracked_chk_$b"
  extra=$(comm -13 "$OUT/.untracked_base_$b" "$OUT/.untracked_chk_$b" \
    | grep -vE '^(\.serena/|documents-latest/)' | tr '\n' ' ')
  if [ -n "$dirty" ] || [ -n "$extra" ]; then
    echo "  ⚠ NOT PRISTINE [$b/$lbl] — tracked-changed=[$dirty] extra-untracked=[$extra] (cross-cell contamination!)"
    return 1
  fi
  echo "  pristine [$b/$lbl] ✓"
}

# ---- per-task setup / canonical solution / oracle ---------------------------
# Globals set per task in the main loop: TID TKIND TCOMMIT TCODE TPKG
setup_task() {
  if [ "$TKIND" = "real_commit" ]; then
    # recreate the original bug: reverse-apply the commit's CODE change (tests kept at HEAD)
    ( cd "$RND/cashbot-go" && git show "$TCOMMIT" -- $TCODE | git apply -R 2>/dev/null )
  fi
  # constructed tasks (A2) need no pre-seed
}
apply_solution() { # --dry only: produce a correct solution to exercise the pass path
  if [ "$TKIND" = "real_commit" ]; then
    ( cd "$RND/cashbot-go" && git checkout HEAD -- $TCODE )   # restore the real shipped fix
    return 0
  fi
  case "$TID" in
    A2) perl -0pi -e 's/(\tResultURL\s+\*string\s+`json:"resultURL,omitempty"`\n)/$1\tEngineVersion  *string `json:"engineVersion,omitempty"`\n/' "$RND/cashbot-go/pkg/model/services/response.go" ;;
    A3) perl -0pi -e 's/(\tResultURL\s+\*string\s+`json:"resultURL,omitempty"`\n)/$1\tTaskDuration  *int64 `json:"taskDuration,omitempty"`\n/' "$RND/cashbot-go/pkg/model/services/response.go" ;;
    *) return 1 ;;
  esac
}
oracle() { # sets globals ORACLE_PASS, COMPLETENESS, NOTE
  local cg="$RND/cashbot-go"; ORACLE_PASS=0; COMPLETENESS=0; NOTE=""
  if [ "$TKIND" = "real_commit" ]; then
    ( cd "$cg" && go test $TPKG >/dev/null 2>&1 ) && ORACLE_PASS=1
    COMPLETENESS=$ORACLE_PASS; NOTE="go test $TPKG"
    return
  fi
  case "$TID" in
    A2)
      grep -q 'json:"engineVersion' "$cg/pkg/model/services/response.go" && COMPLETENESS=1
      ( cd "$cg" && go build ./pkg/... >/dev/null 2>&1 ) && [ "$COMPLETENESS" = 1 ] && ORACLE_PASS=1
      NOTE="engineVersion_field=$COMPLETENESS" ;;
    A3)
      # cross-repo retrieval: the new field lives ONLY in ai-server (unmounted).
      # ground truth = taskDuration, added to ai-server DocumentResponse.
      grep -q 'json:"taskDuration' "$cg/pkg/model/services/response.go" && COMPLETENESS=1
      ( cd "$cg" && go build ./pkg/... >/dev/null 2>&1 ) && [ "$COMPLETENESS" = 1 ] && ORACLE_PASS=1
      NOTE="taskDuration_field=$COMPLETENESS" ;;
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
  # Preserve a hand-written narrative across regenerations: capture everything
  # after the marker; treat the TODO placeholder as empty. (Auto sections above
  # the marker are always rebuilt from the latest metrics.)
  local saved_narr=""
  if [ -f "$doc" ]; then
    saved_narr="$(awk 'index($0,"## Narrative / takeaway")==1{f=1;next} f' "$doc")"
    case "$saved_narr" in *"_TODO (filled after review"*) saved_narr="" ;; esac
  fi
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
    if [ -n "$saved_narr" ]; then
      printf '%s\n' "$saved_narr"
    else
      echo "_TODO (filled after review): what each arm did to locate the code, whether the graph/LSP changed the path, and the cross-arm comparison for this scenario._"
    fi
  } > "$doc"
  echo "  doc: $doc"
}

# ---- main loop --------------------------------------------------------------
snapshot_repo "$RND/cashbot-go"
snapshot_repo "$RND/ai-server"
trap 'unpark_all; restore_repo "$RND/cashbot-go"; restore_repo "$RND/ai-server"' EXIT

NTASK=$(jq -s 'length' "$TASKS")
echo "Runner: $NTASK tasks x ${#ARM_NAMES[@]} arms  (dry=$DRY)"; echo

for i in $(seq 0 $((NTASK-1))); do
  id=$(jq -rs ".[$i].id" "$TASKS")
  run_dir=$(jq -rs ".[$i].run_dir" "$TASKS")
  prompt=$(jq -rs ".[$i].prompt" "$TASKS")
  repos=( $(jq -rs ".[$i].repos[]" "$TASKS") )
  # per-task globals used by setup_task / apply_solution / oracle
  TID="$id"
  TKIND=$(jq -rs ".[$i].kind // \"constructed\"" "$TASKS")
  TCOMMIT=$(jq -rs ".[$i].commit // \"\"" "$TASKS")
  TCODE=$(jq -rs ".[$i].code_files // [] | join(\" \")" "$TASKS")
  TPKG=$(jq -rs ".[$i].test_pkg // \"\"" "$TASKS")
  TPARK=$(jq -rs ".[$i].park_repos // [] | join(\" \")" "$TASKS")
  wants "$id" "$ONLY_TASKS" || continue
  add=(); for r in "${repos[@]}"; do add+=(--add-dir "$RND/$r"); done

  # Physically remove parked repos from disk for this task's cells (real isolation,
  # since --add-dir does not sandbox reads). The graph still holds their source.
  for r in $TPARK; do park_repo "$r"; done

  for arm in "${ARM_NAMES[@]}"; do
    wants "$arm" "$ONLY_ARMS" || continue
    echo "──── task=$id  arm=$arm ────"
    echo "  boundary: built-in tools ALLOWED | MCP=$([ -n "$(arm_mcp "$arm")" ] && basename "$(arm_mcp "$arm")" || echo none) | add-dir=${repos[*]}"

    restore_repo "$RND/cashbot-go"; restore_repo "$RND/ai-server"
    assert_pristine "$RND/cashbot-go" "pre-$arm"; assert_pristine "$RND/ai-server" "pre-$arm"
    setup_task

    sfx=""; [ "$DRY" = 1 ] && sfx=".dry"
    cell="$OUT/${id}_${arm}${sfx}"; log="$cell.jsonl"; : > "$log"
    if [ "$DRY" = 1 ]; then
      echo "  [dry] skipping Claude; applying canonical solution"
      apply_solution || echo "  [dry] no auto-solution for $id (oracle expected to fail)"
      IS_ERROR=dry; NUM_TURNS=0; IN_TOK=0; OUT_TOK=0; CACHE=0; DUR=0; COST=0; TOOLS=0; MCPTOOLS=0
    else
      mcp="$(arm_mcp "$arm")"; mcpflag=(); [ -n "$mcp" ] && mcpflag=(--mcp-config "$mcp")
      ( cd "$RND/$(basename "$run_dir")" && claude -p "$prompt" "${ISO[@]}" "${mcpflag[@]}" "${add[@]}" \
          --output-format stream-json --verbose --max-turns "$MAXTURNS" ) > "$log" 2> "$cell.err"
      parse_metrics "$log"
    fi

    oracle
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo dry)
    echo "$ts,$id,$arm,$IS_ERROR,$ORACLE_PASS,$COMPLETENESS,$TOOLS,$MCPTOOLS,$NUM_TURNS,$IN_TOK,$OUT_TOK,$CACHE,$DUR,$COST" >> "$RESULTS"
    echo "  result: is_error=$IS_ERROR oracle_pass=$ORACLE_PASS completeness=$COMPLETENESS tools=$TOOLS(mcp=$MCPTOOLS) turns=$NUM_TURNS tokens=$IN_TOK/$OUT_TOK  [$NOTE]"

    restore_repo "$RND/cashbot-go"; restore_repo "$RND/ai-server"
    echo
  done
  unpark_all   # restore any parked repos before the next task / exit
  [ "$DRY" = 1 ] || gen_run_doc "$i"   # dry is plumbing-only; don't overwrite committed run docs
  echo
done

echo "Done. Results: $RESULTS  ·  Run docs: $RUNS"
