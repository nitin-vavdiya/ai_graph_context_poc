# PoC Reference

One-stop reference for the benchmark PoC: commands, the arms, results schema, how to add tasks, file map, environment, and gotchas. Conceptual "why" is in [`benchmark-design.md`](benchmark-design.md) (start at §0). Setup narrative is in [`SETUP.md`](SETUP.md) / [`SETUP-REPORT.md`](SETUP-REPORT.md).

## 1. Command cheatsheet

```bash
# --- one-time setup (see SETUP.md for detail) ---
docker compose -f poc/docker-compose.yml up -d        # Neo4j for CodeGraphContext (container cgc-neo4j)
uv tool install codegraphcontext --with tree-sitter --with tree-sitter-language-pack
uv tool install -p 3.13 serena-agent
# index the 6 corpus repos into Neo4j (per-repo): codegraphcontext --database neo4j index groundx-rnd/<repo>
uv run --with neo4j python poc/enrich/enrich.py       # Phase-0: add cross-repo CALLS_SERVICE edges from C4

# --- pre-flight (no tokens) ---
docker ps --filter name=cgc-neo4j                      # Neo4j up?
docker exec cgc-neo4j cypher-shell -u neo4j -p poctestpassword "MATCH ()-[r:CALLS_SERVICE]->() RETURN count(r)"  # expect 4
command -v gopls                                       # Serena Go arm
bash poc/dryrun-isolation.sh                           # prove arm isolation (4 arms pass)

# --- run the benchmark (paced one task at a time) ---
bash poc/run.sh --dry                                  # validate plumbing, no Claude calls
bash poc/run.sh --tasks R1                             # one task, all 4 arms
bash poc/run.sh --tasks R1 --arms cgc                 # a single cell (resume / escape hatch)
bash poc/run.sh                                        # full matrix (4 tasks x 4 arms)

# --- inspect results ---
column -s, -t poc/results/results.csv                  # the metrics table
cat poc/runs/R1.md                                     # the per-task report

# --- teardown ---
docker compose -f poc/docker-compose.yml down -v       # stop + wipe Neo4j
uv tool uninstall codegraphcontext serena-agent
```

## 2. The four arms

All arms use Claude's **built-in** tools (grep/read/edit/bash); only the MCP config differs.

| Arm | MCP config | Loads |
|---|---|---|
| baseline | *(none)* | no MCP |
| cgc | `mcp/codegraphcontext.json` | codegraphcontext only |
| serena | `mcp/serena.json` | serena only |
| both | `mcp/both.json` | codegraphcontext + serena |

**Isolation flags applied to every arm** (so the only variable is the MCP config) — full rationale in `benchmark-design.md` §4.5:

- `--strict-mcp-config` — only the arm's own MCP servers load (no claude-mem, caveman, chrome).
- `--setting-sources project,local` — omits the `user` settings source where the claude-mem hook + plugins are registered.
- fresh `claude -p` per cell — no `--continue`/`--resume` (cold session).
- `--permission-mode bypassPermissions --model claude-opus-4-8` — autonomous, fixed model.
- `--output-format stream-json --verbose --max-turns 80`.
- `--add-dir <repo>` for each repo in the task (lets baseline/CGC read across repos; Serena still sees one project).

> `--bare` would isolate in one flag but **requires `ANTHROPIC_API_KEY`** (no OAuth) — we have OAuth only, hence the flag combo above. Verified equivalent by `dryrun-isolation.sh` + a model self-report (no MCP, no recalled memory, no session leakage).

## 3. Results & metrics

**`poc/results/results.csv`** — one row per cell (re-running a cell appends; analysis takes the latest row per `task,arm`). Columns:

| Column | Meaning |
|---|---|
| `ts` | UTC timestamp of the run |
| `task` / `arm` | which cell |
| `is_error` | Claude Code reported an error (`true`/`false`/`na`) |
| `oracle_pass` | the task's test/oracle passed (1/0) — the correctness signal |
| `completeness` | task-specific completeness (for real tasks = oracle_pass; A2 = field present) |
| `tool_calls` | total tool calls Claude made |
| `mcp_tool_calls` | of those, how many were MCP tools (graph/LSP) vs built-in |
| `num_turns` | assistant turns |
| `in_tokens` / `out_tokens` | input / output tokens (the cost signal) |
| `cache_read` | cached input tokens re-read across all turns of the cell |
| `duration_ms` | wall-clock |
| `cost_usd` | Claude Code's reported cost |

### Interpreting the metrics (read before ranking arms)

- **`in_tokens` — the stable, arm-specific number.** It's mostly the fixed prompt, so it's roughly constant per arm across runs and reflects the **standing MCP-schema tax**: baseline ~2.6K < serena ~3.3K < cgc/both ~4.1–4.5K. Carrying a graph server's tool definitions costs input tokens **every turn whether or not the tools are called**. This is a real, measurable cost of loading a graph MCP even when unused.
- **`out_tokens` / `num_turns` — noisy.** The LLM is non-deterministic; the same arm on the same task can swing widely run-to-run (R1 cgc out: 7372→5022; baseline: 5158→6717), enough to flip which arm "wins." **Single runs do not rank arms** on easy tasks — average multiple runs, or rely on tasks where the gap exceeds this noise (A2).
- **`cache_read` ≈ context-size × turns — the noisiest, and easy to misread.** It is *not* a fixed prompt size. Each turn re-reads the cached context (system prompt + conversation-so-far), and that context grows every turn as tool outputs accumulate. So cache_read is driven mainly by **how many turns the cell took** and **how verbose** its tool outputs were — both consequences of how that particular run unfolded, not properties of the arm. Example (R1 run 2): baseline 15 turns → 548K; cgc 10 turns → 346K. The arm-specific MCP-schema floor (point 1) is real but small next to the turn-count effect, so it gets swamped.
- **`total billable` = in + out + cache_read** — useful as a raw token total, but cache_read dominates it (300–550K vs a few K of in/out) and is the noisiest component, so don't rank arms by it on easy tasks.
- **`cost_usd` is the best apples-to-apples cost measure.** cache_read is billed cheaply (~10% of input rate), so the giant cache_read numbers overstate cost impact; `cost_usd` already weights everything correctly. On R1 it stays flat (~$0.46–0.62) across all arms and both runs — confirming the arms are within noise on an easy single-repo task.
- **The decisive signal is A2 (cross-repo)**, where the expected gap (graph finds the consumer; baseline burns tokens hunting; serena can't span repos) should exceed this per-run noise.

**`poc/runs/<TASK>.md`** — committed per-task report: task summary, the isolation conditions in effect, the 4-arm metrics table, and a per-arm tool-call trace (tool **names** × count only — no code). Auto-generated by `run.sh`; narrative filled by hand after review.

**`poc/results/*.jsonl`** — raw stream-json transcript per cell. **Gitignored** (contains groundx-rnd code snippets). `*.err` = stderr per cell.

## 4. How `run.sh` executes one cell

1. **Snapshot-restore** the repo to a pristine baseline — `git stash create` captures tracked state; restored with `git restore --source=<snap>`; only files created during the cell are removed. **Preserves pre-existing local state** (a modified `AGENTS.md`, untracked `documents-latest/`, `.serena/`) — never `reset --hard`. Then **`assert_pristine`** verifies the repo matches its snapshot before the cell runs and prints `pristine ✓` (or a loud `NOT PRISTINE` naming the leaked files) — live proof that no prior arm's edits contaminate the next. Combined with a fresh `claude -p` per cell (no `--continue`/`--resume`) and `--setting-sources project,local` (user-level claude-mem / memory excluded), the arms are fully independent.
2. **Setup** — for a `real_commit` task, reverse-apply the commit's code (`git show <sha> -- <code_files> | git apply -R`) to recreate the bug; the test stays at HEAD. (A2: no setup.)
3. **Launch Claude** with the arm's isolation flags + MCP config + the task prompt.
4. **Parse** `usage`/turns/tool-calls/`is_error` from the stream-json log.
5. **Oracle** — real tasks: `go test <pkg>` green; A2: new field present + `go build ./pkg/...`.
6. **Record** a CSV row + regenerate the run doc, then **restore** the repo.

The runner is **data-driven**: it reads each task's `kind`/`commit`/`code_files`/`test_pkg` from `tasks.jsonl`. macOS **bash 3.2 compatible** (no associative arrays / mapfile / `set -u`).

## 5. How to add a new benchmark task (real commit)

The supply is the repo's git history (cashbot-go has ~3,094 commits). To add one:

1. **Find** a commit that fixed a bug / added behavior **with a test**, in a package that tests green with no external services.
2. **Vet** (all must hold):
   - no drift: `git -C groundx-rnd/cashbot-go log --oneline <sha>..HEAD -- <code_files>` is empty.
   - green at HEAD: `go test ./<pkg>` passes.
   - reverse-applies cleanly: `git show <sha> -- <code_files> | git apply -R --check`.
   - red→green: reverse-apply → `go test ./<pkg>` fails → restore → passes.
3. **Add a row** to [`tasks.jsonl`](tasks/tasks.jsonl):
   ```json
   {"id":"R4","kind":"real_commit","scenario":"bugfix","repos":["cashbot-go"],
    "run_dir":"groundx-rnd/cashbot-go","commit":"<sha>","code_files":["pkg/.../x.go"],
    "test_pkg":"./pkg/...","prompt":"<symptom, not the fix>",
    "oracle":{"test_cmd":["go test ./pkg/..."],"regression_cmd":["go test ./pkg/..."]},
    "stresses":"time","source":"...","ground_truth_notes":"..."}
   ```
4. **Dry-check**: `bash poc/run.sh --dry --tasks R4` (should pass — the canonical fix is `git checkout HEAD`).

No code changes needed — the runner picks it up from the schema.

## 6. File map

```
poc/
  README.md            PoC hub (phases, arms, how to run)
  REFERENCE.md         this file
  benchmark-design.md  the plan (§0 plain terms, Phase-0 enrichment, 4-arm benchmark, isolation §4.5, run plan §7)
  SETUP.md             reproducible setup runbook
  SETUP-REPORT.md      as-built record (decisions, problems/fixes, verification)
  run.sh               benchmark runner (per-cell setup/launch/oracle/restore + run docs)
  dryrun-isolation.sh  pre-flight: prove each arm loads only its own MCP
  docker-compose.yml   local Neo4j (cgc-neo4j)
  enrich/enrich.py     Phase-0: C4 workspace.dsl -> CALLS_SERVICE edges in Neo4j
  mcp/                 per-arm MCP configs: codegraphcontext.json, serena.json, both.json
  tasks/
    README.md          corpus + verbatim prompts + scoring + schema
    tasks.jsonl        the 4 tasks (R1-R3 real, A2 constructed)
  runs/                generated per-task reports (committed)
  results/             results.csv + raw logs (gitignored except results.csv)
```

## 7. Environment & versions (verified 2026-06-26)

| Component | Version |
|---|---|
| Docker | 28.3.2 |
| Python | 3.12.12 · uv 0.8.17 |
| Node | v25.2.1 |
| Go (cashbot-go) | 1.26.3 |
| Claude Code | 2.1.193 |
| CodeGraphContext | 0.5.1 (Neo4j backend) |
| Serena | 1.5.3 (pyright / tsserver / gopls) |

**Graph contents (Neo4j, after indexing + enrichment):** 6 repos, ~2,730 files, ~9,887 functions, ~50,916 `CALLS`, ~3,788 `IMPORTS`, **4 `CALLS_SERVICE`** (cross-repo, from Phase 0).

**Corpus (`groundx-rnd/`, gitignored):** ai-server, groundx-python, groundx-typescript, groundx-ai-middleware, groundx-ai-dashboard, cashbot-go.

## 8. Gotchas (learned the hard way)

- **CodeGraphContext needs tree-sitter** — `uv tool install codegraphcontext --with tree-sitter --with tree-sitter-language-pack`, else indexing records 0 functions. Confirm with `codegraphcontext doctor`.
- **CGC defaults to FalkorDB, not Neo4j** — pass `--database neo4j` on every CLI command and set `CGC_RUNTIME_DB_TYPE=neo4j` in the MCP env. Don't run the `cgc neo4j setup` wizard (spins a conflicting container).
- **Serena needs the language-server binary per language** — Python/TS auto-provision; **Go needs a manual `gopls`** (`go install golang.org/x/tools/gopls@latest`). One Serena server handles all languages (not one per language).
- **`--bare` needs `ANTHROPIC_API_KEY`** — unavailable on OAuth; use `--strict-mcp-config --setting-sources project,local` instead.
- **`go build ./...` is NOT green** in cashbot-go (lambda/* and some cmd/* need `go generate` first) — use `go build ./pkg/...` for the A2 oracle.
- **Repo restore is snapshot-based** — never `git reset --hard`/`clean -fdx` on cashbot-go (would wipe a modified `AGENTS.md`, untracked `documents-latest/`, `.serena/`).
- **macOS ships bash 3.2** — scripts avoid associative arrays, `mapfile`, and `set -u`.
- **zsh `nomatch`** aborts a whole `rm` line if any glob (e.g. `*.err`) matches nothing — use `find ... -delete` for cleanup.
- **Results contain real code** — `poc/results/` (raw logs) is gitignored; committed run docs include tool **names only**, never inputs/outputs.
- **`--dry` is isolated from real data** — it writes `results.dry.csv` + `*.dry.jsonl` and skips run-doc regen, so plumbing tests can't clobber real `results.csv`/run docs/logs. (Before this fix, a dry run appended `dry` rows that "latest-row-wins" then treated as the real result, and truncated the real transcripts.)
- **cache_read is noise, not an arm property** — see §3 "Interpreting the metrics"; rank arms by `cost_usd` / `oracle_pass`, not by `cache_read` or `total billable`, and never off a single run on an easy task.
- **MCP `status: "pending"` in the init snapshot is NOT a failure** — in headless `claude -p` the `system/init` event shows MCP servers as `pending` with **zero `mcp__` tools** in its `tools` array, even when those tools are available and callable later in the same session (async connect, no "connected" event re-emitted). Judge availability only from an actual `mcp__*` `tool_use` in the transcript or a forced-call probe — never from the init snapshot. Verified 2026-06-29: forced probes called `mcp__codegraphcontext__find_code` and `mcp__serena__find_symbol` successfully, so `mcp=0` in the R-tasks is a genuine model choice, not a block.

## 9. Glossary

- **Arm** — one configuration of Claude in the race (baseline / cgc / serena / both).
- **Oracle** — the automatic pass/fail check for a task (here, the package's `go test`).
- **Completeness** — whether the change covered everything it had to (for real tasks, equals oracle pass).
- **`CALLS_SERVICE`** — the cross-repo, service-level edge added in Phase 0 from the C4 model (`workspace.dsl`), since tree-sitter can't see HTTP/webhook coupling.
- **real_commit task** — a benchmark task built by replaying a real historical fix (reverse-apply its code; its own test is the oracle).
- **constructed task** — a hand-built task (A2) used where no single real commit fits (cross-repo).
- **Cell** — one (task, arm) run.
