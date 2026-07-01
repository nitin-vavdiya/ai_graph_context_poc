# Parity Recheck & Pre-Run Verification — 2026-07-01

Verification pass before discarding the old benchmark results and re-running. Goal: put **cgc** (graph) and **serena** (LSP) on an equal footing — same repo scope, same isolation, cwd-independent — then retest their real capability differences, so any comparative claim rests on a fair setup. All results below are from live runs on this machine on 2026-07-01 (model `claude-opus-4-8`, `--strict-mcp-config --permission-mode bypassPermissions`).

**Bottom line:** the setup is now at parity for symbol lookup, but **two hard blockers remain before any scored run** — (1) A3's isolation is defeated by `docker exec` into the graph, and (2) A4 has no objective ground truth. Both are detailed below with fixes.

## Why this recheck happened

The original harness activated serena with `--project-from-cwd`, and every task ran from `groundx-rnd/cashbot-go`. That pinned serena to a **single repo** on every cell, so it never saw the other repos and could not compete with cgc's all-repo graph on any cross-repo task (A2/A3/A4). The head-to-head cells run under that config were tilted toward cgc **by construction** and are discarded. See the corrected serena setup in [`SETUP.md`](SETUP.md) §2b.

## Setup fixes applied and verified

- **serena scoped to all 6 corpus repos as one "monorepo" project** (`--project <groundx-rnd>`), matching cgc's single graph — serena is now cwd-independent like cgc. (oraios documents this "monorepo folder" pattern; [Discussion #542](https://github.com/oraios/serena/discussions/542) — "full monorepo support, you just need to set the languages in your project.yml".)
- **`languages: [python, typescript, go]`** set explicitly in `groundx-rnd/.serena/project.yml`. **Load-bearing:** left empty, serena auto-infers a *single* language (it picked `typescript`) and **silently returns `[]`** for the others (`is_error: false`). Verified failure mode.
- **`ignored_paths`** = the 21 non-corpus dirs. The parent `groundx-rnd/` actually holds **27** dirs; without this, serena indexes all of them — slower and a scope mismatch vs cgc (exactly 6).
- **Web dashboard disabled** (`--enable-web-dashboard false`). With it on (the default), the Claude Code MCP client intermittently fails with `MCP error -32000: Connection closed` ([serena #898](https://github.com/oraios/serena/issues/898)); this produced a spurious "serena timed out" reading in early testing.
- **`--tool-timeout 300`** to survive cold LSP starts.
- **One-time `serena project index`** run to completion (~15 min — see cost note below).

Config files updated: [`poc/mcp/serena.json`](mcp/serena.json), [`poc/mcp/both.json`](mcp/both.json).

## Config parity — achieved

| dimension | cgc | serena | parity |
|---|---|---|---|
| repo scope | all 6 (Neo4j graph) | all 6 (parent project + `ignored_paths`) | ✓ |
| cwd-dependence | none | none (was `--project-from-cwd`) | ✓ |
| UI/dashboard | n/a | disabled | ✓ |
| isolation flags | strict-mcp / setting-sources / bypass | identical | ✓ |
| one-time warm-up index | ~3.5 min (tree-sitter, 6 repos) | **~15 min** (LSP) | both required |

**Indexing-speed asymmetry (verified):** cgc reindexed all 6 repos into fresh Neo4j in ~3.5 min total (per-repo 5–13 s; cashbot-go Go 136 s). serena's `project index` took ~15 min — the first ~45% (Python + TypeScript, 1079/2378 files) flew at ~3540 files/s, then the **Go half collapsed to ~1.3 files/s** (a ~2600× throughput drop), consuming ~13 of the 15 min. gopls is the multi-repo bottleneck. This is a **one-time warm-up cost, not per-query** (see A4 timing below). Fresh cgc graph verified: 9887 functions, 50938 CALLS edges, 4 cross-repo `CALLS_SERVICE` edges, `taskDuration` present.

## Capability parity — matched probes (identical 5-item task, only MCP config differs)

| # | probe | cgc | serena | verdict |
|---|---|---|---|---|
| 1 | Python symbol (`DocumentResponse`) | ✓ `ai-server/document/classes/response.py` | ✓ same file | **parity** |
| 2 | Go symbol (`PrepareStep`) | ✓ `cashbot-go/.../process.go` | ✓ same file | **parity** |
| 3 | multi-repo reach (`DocumentResponse` everywhere) | **2 repos** (Python only) | **4 repos** (Py + TS) | **serena more complete** |
| 4 | transitive callers of `PrepareStep` | **31 files, 1 query** | **36 files (60 w/tests), 48 queries, 13 BFS levels** | cgc far more efficient; **counts disagree** |
| 5 | cross-repo HTTP (`cashbot-go`↔`ai-server`) | ✓ full bidirectional trace | ✗ can't derive structurally | cgc wins **only via hand-authored edges** |

**Run totals:** cgc = 54 s / 11 turns / 7 cypher queries. serena = **562 s / 60 turns / 54 queries / $2.40**.

### Honest reading of the differences

- **Probe 3 — "graph = more complete multi-repo" is false here.** cgc's `MATCH (c:Class {name})` missed the TypeScript **interfaces** (labeled `Interface`, not `Class`) → 2 repos. serena's LSP found all 4. cgc's completeness depends on query construction and label coverage.
- **Probe 4 — cgc's one genuine, robust win: efficiency.** cgc traversed the whole transitive closure in **1 `CALLS*1..` query / 54 s**; serena has no transitive op and did manual level-by-level BFS — **48 `find_referencing_symbols` calls, 13 levels, 9.4 min, $2.40**. But the two tools **disagree on the answer** (cgc 31 vs serena 36/60) — neither is ground truth (see A4 blocker).
- **Probe 5 — cgc "wins" by enrichment, not by being a graph.** cgc's `CALLS_SERVICE` edges are tagged `source:c4` — **hand-authored** from the C4 model, not code-derived. Pure code-derived, cgc *also* can't trace runtime cross-language HTTP (raw IMPORTS were name-stubs). serena can't either. This is "a hand-authored C4 model beats LSP," **not** "graph beats LSP."
- **Documented serena limit (oraios docs):** cross-workspace-folder **reference/caller discovery is TypeScript-only**. serena can *find* Go/Python symbols across repos but cannot trace cross-repo callers/references for Go/Python — the genuine remaining gap vs cgc's `CALLS*` closure.

## BLOCKER 1 — A3 isolation is defeated by `docker exec` into the graph

Parked-repo A3 test (ai-server physically moved off-disk; only the graph retains it):

- **cgc:** genuine win — `find_code` returned `taskDuration: Optional[int]` from Neo4j with no files on disk.
- **serena arm:** **did not use serena at all.** Under `bypassPermissions` + Bash it: (1) found ai-server gone, (2) `find`'d the filesystem, (3) **read `poc/mcp/both.json` — which contains the Neo4j credentials in plaintext**, (4) `docker ps` → discovered the running `cgc-neo4j` container, (5) `docker exec cgc-neo4j cypher-shell ... MATCH (c:Class {name:'DocumentResponse'})` and read the answer straight from the graph.

The graph is a **running service on the host**; its creds live in agent-readable repo files; every arm has Bash. **Parking the repo hides the files, not the graph.** Any non-cgc arm can reach Neo4j and defeat the isolation. The old A3 "cgc wins" result is therefore not trustworthy as a *comparative* claim (cgc's *capability* — retrieving off-disk code from a pre-built index — is still genuine).

⚠️ **Security (low sev):** plaintext Neo4j password (`poctestpassword`) is committed in `poc/mcp/*.json`. Throwaway local credential, but it is exactly what leaked here.

### ✅ RESOLVED 2026-07-01 — OS sandbox wired into `run.sh`

`bypassPermissions` was the root cause (agent could read/exec anything). Replaced with a macOS Seatbelt sandbox, validated end-to-end:

- `--permission-mode dontAsk` — auto-**denies** any tool call outside the allow-set, **no prompt** (headless-safe). Confines the Read/Grep/Glob tools to the `--add-dir` workspace.
- `--settings poc/sandbox-settings.json` — `sandbox.enabled: true` (Seatbelt) puts every Bash subprocess under OS-level isolation: **network denied** (blocks `bolt:7687` and docker daemon) and **`denyRead`** on `poc/` (answer fixtures) + `log_analysis/` (the stray ai-server checkout).
- `permissions.deny: ["Bash(docker *)"]` — belt-and-suspenders on the docker CLI.
- Per-arm `--allowedTools` (dontAsk denies un-allowed MCP tools) — baseline none, cgc `mcp__codegraphcontext`, serena `mcp__serena`, both both.
- `GOPROXY=off GOTOOLCHAIN=local` — `go build`/`test` must work offline (network denied); modules are already cached.

**Validated (direct probes, 2026-07-01):** Bash `cat poc/tasks/tasks.jsonl` → *Operation not permitted*; `docker ps`/`docker exec neo4j` → *denied*; `nc localhost 7687` → *Operation not permitted*; `go build`/`go test` offline → exit 0 (10.9 s); **cgc's MCP server still reaches Neo4j** (its server is launched by Claude, not sandboxed — only the agent's Bash is isolated) → returns the path, `is_error:false`. A baseline R1 cell ran through `run.sh` doing grep/python/read entirely within the workspace with **zero sandbox-denial errors** (isolation does not break legitimate work).

A3 still **physically parks** ai-server (removes the source from disk); the sandbox adds the graph/fixture/stray-checkout blocking that parking never covered. **Also fixed:** `run.sh` trap now catches `INT TERM` (not just `EXIT`) — a killed run no longer leaves `.git` hidden / repos parked to corrupt the next run.

## BLOCKER 2 — A4 has no objective ground truth

An **independent** call-graph oracle was built with the Go compiler toolchain (`golang.org/x/tools/go/callgraph`, SSA), targeting the concrete `summarizer.Process.PrepareStep`, reverse-reachability to files. Code: `poc/oracle/` (`ALGO=static|cha|vta`, `WITH_TESTS=0|1`).

| method | files | nature |
|---|---|---|
| static SSA (precise, no dynamic dispatch) | 15 prod / **37 w/tests** | sound lower bound |
| cha / vta (pessimistic dynamic dispatch) | 834–1212 | interface dispatch → explodes |
| cgc (tree-sitter, name-based) | 31 | static-ish |
| serena (LSP references + impls) | 36 / 60 | static-ish + impls |
| **old Neo4j GT — used to grade every arm** | 30 | **cgc's own query output** |

**"Transitive callers" is ill-posed under Go interface dispatch** — sound methods span 15 → 1200 files depending on the dispatch-resolution assumption. Diffing the independent static set (37) against the old ground truth (30): 29 overlap, the old GT **missed 8 files** the compiler finds (`pkg/orchestrate/enrich.go`, `handler.go`, `server/ProcessFiles/summarizer.go`, plus test files) and claimed 1 (`cmd/searchtest/regressions_test.go`) the compiler doesn't. So the old oracle graded everyone against cgc's **incomplete AND circular** output.

### ✅ RESOLVED 2026-07-01 — independent oracle wired into `run.sh`

- Ground truth is now the **compiler-derived static-SSA set** (`poc/tasks/fixtures/A4_impact_files.static-ssa.txt`, 37 files) — independent of every tool under test. `run.sh`'s A4 oracle and `tasks.jsonl` provenance updated to point at it; the old circular `A4_impact_files.txt` is retired.
- Recall is graded against that set as a **sound lower bound** (every file provably contains a static-dispatch transitive caller; dynamic-dispatch-only callers are out of scope by design, so a tool is never penalized for finding *more*).
- **The defensible A4 headline is the efficiency contrast**, not the recall score: cgc 1 query / 54 s vs serena 48 queries / 9.4 min / $2.40 (`run.sh` already records `tool_calls`/`num_turns`/`duration`/`cost` per cell). Recall is meaningful only now that the sandbox stops the agent reading the fixture (Blocker 1).

## Status for the re-run

- ✅ Config parity achieved and verified.
- ✅ Symbol-lookup parity confirmed (serena marginally more complete on multi-repo reach).
- ✅ cgc's one robust advantage confirmed: efficiency on transitive/structural queries.
- ✅ cgc's cross-repo-HTTP edge shown to be enrichment-derived, not graph-derived.
- ✅ **A3 isolation RESOLVED** — macOS Seatbelt sandbox (`dontAsk` + `poc/sandbox-settings.json` + `GOPROXY=off`) wired into `run.sh` and validated: fixtures/docker/bolt all denied, offline go works, cgc's MCP still reaches the graph, baseline runs normally.
- ✅ **A4 ground truth RESOLVED** — independent compiler-derived static-SSA set (37 files) wired in; efficiency contrast is the headline.
- ✅ **run.sh trap** now catches `INT TERM` so interrupted runs don't corrupt state.

Both blockers cleared. The scored 4-arm re-run (baseline/cgc/serena/both × R1–R3,A2,A3,A4) can now proceed — **run it in the background**; cells take 2–14 min each (≈2–4 h for the full 24-cell matrix, ≥3× for medians). R1–R3 were never blocked.
