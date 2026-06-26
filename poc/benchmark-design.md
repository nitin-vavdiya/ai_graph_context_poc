# Design — Cross-Repo Graph Linkage (Phase 0) and the Code-Change Benchmark (Phase 1)

**Date:** 2026-06-26. **Status:** approved design, pre-implementation. **Scope:** defines how we make the CodeGraphContext (CGC) graph actually span repos, then how we benchmark the four arms (baseline / CGC / Serena / both) on real code-change tasks. This supersedes the loose "run the 3-arm benchmark next" note in [`SETUP-REPORT.md`](SETUP-REPORT.md) §6 with a concrete, gated plan.

## 0. In plain terms (start here)

**The question.** We have a huge codebase (100s of repos). When we ask Claude to make a code change, it burns time and tokens *hunting for the right code*. We think a **code map** (a code-graph tool) could help it find code faster. We want to prove whether that's true — with numbers, not opinion.

**How we prove it — a fair race.** We give Claude the **same job** and run it **four ways**, then compare cost and success:

| Contestant (arm) | What it has beyond plain Claude |
|---|---|
| baseline | nothing (today's normal) |
| cgc | the code map (CodeGraphContext graph) |
| serena | a code-aware tool (Serena / LSP) |
| both | both tools |

For each run we measure: **did it succeed, how many tokens, how many tool-calls/steps.** If the tool arms win, the map is worth it; if they tie with baseline, it isn't.

**The "job" = a real bug-fix ticket.** A race needs a job with a clear finish line. So each task is a **real bug that was already fixed in this codebase** (it came with a test). We *put the bug back* (undo the old fix, keep the test), then hand Claude the **symptom** — e.g.:

> *"Partner MCP tool executions sometimes fail to decode the response (`failed to parse MCP execution response`). Diagnose and fix it. Don't modify tests."*

Claude must locate the right file and re-implement the fix. **Finish line = the original test goes from red to green** — checked automatically, no human opinion.

**What kind of changes are they?** Real bug-fix tickets (R1–R3) plus one small cross-repo change (A2). Each edit is *small* (usually one file). The hard part — and the thing we're actually measuring — is **finding the right code to change** in a massive repo, and whether the map/LSP makes that finding cheaper. The concrete tasks and exact prompts are in [`tasks/README.md`](tasks/README.md).

**What is a "cross-repo" task, and why it's the headline.** Big products are split into separate services, each its own repo (e.g. `ai-server` in Python, `cashbot-go` in Go). They don't call each other as normal code — they talk **over the network** (HTTP/webhook). So a *cross-repo task* is a change you can't finish by staying in one repo: a change in one service's contract must ripple to the **other** repo that consumes it.

| | In-repo task (R1–R3) | Cross-repo task (A2) |
|---|---|---|
| Where the answer lives | one repo | spans two repos |
| How the code connects | function calls (in the source) | HTTP / webhook (over the wire) |
| Can plain `grep` find the link? | yes — it's in the code | **no** — there is no code call between the repos |
| What the agent needs | search within a repo | know the **service relationship** |

This is exactly the pain at ~100 repos: when something changes, the agent doesn't know which *other* repo is affected, because the connection isn't a line of code — it's a network call `grep` can't see. The graph fixes this: Phase 0 added a `CALLS_SERVICE` edge (ai-server → cashbot-go) from the architecture model, so the agent can ask "who consumes this webhook?" and get a direct answer. **Baseline** must guess from config/URLs; **Serena** can't (one repo at a time). That is why A2 is the headline test — and why it had to be constructed (a real cross-repo change never lands as a single commit with a single test).

**One line:** take a real bug → put it back → have 4 versions of Claude fix it → see which is cheapest and correct → learn if the code-map helps.

## 1. Why this design exists (the finding that forced it)

The benchmark was going to lead with cross-repo tasks, because the end goal is ~100 repos and the highest-value capability is cross-repo blast-radius (§3.6 of [`../docs/research/context-graph-evaluation.md`](../docs/research/context-graph-evaluation.md)). A live check of the populated Neo4j graph (2026-06-26) showed that **the graph cannot answer any cross-repo question today**:

- **Cross-repo `CALLS` edges: 0.** **Cross-repo `IMPORTS` edges: 0.**
- **All 3,788 `IMPORTS` edges are unresolved name stubs** — their target `Module` node has `path = NULL` (e.g. `numpy`, `torch`, `document.tasks.detect_layout`). CGC records the *name* of an import but never links it to the real definition node, even within a single repo.
- The only `groundx`-named import in the corpus is `groundx-python` importing **itself**. No other indexed repo imports the SDK by package name in the graph.

**Conclusion:** CGC's "unified graph" is really six **disjoint per-repo subgraphs** sharing one database. No edge bridges repos.

**Root cause:** the real coupling between these repos is **service-level** — HTTP/REST, SQL, webhooks, queues — which crosses process and language boundaries over the wire. tree-sitter parses source files; it cannot see an HTTP call from a React dashboard to a Node middleware to a Go API. Symbol-level import resolution (even if CGC did it well) would therefore recover almost no cross-repo edges in this corpus, because the repos barely share code-level symbols — they share *contracts*.

**Where the cross-repo truth actually lives:** a hand-authored, verified **C4 model** at `groundx-rnd/workspace.dsl` (249 lines), and `groundx-rnd/docker-compose.yml`. The dsl declares container-to-container relationships with protocols, and annotates each container with its repo (`Repo: groundx-ai-dashboard`, `Repo: cashbot-go`, `Repo: ai-server (document/*)`, …).

The relevant chain among the six indexed repos:

```
groundx-ai-dashboard --REST/JSON--> groundx-ai-middleware --HTTPS/REST--> cashbot-go (GroundX API)
cashbot-go --HTTPS/REST--> ai-server (layout / summary / ranker services)
ai-server --HTTPS webhook (DocumentLayoutWebhook)--> cashbot-go
```

This is precisely the blast-radius the graph is missing, and it is exactly what an LLM needs when a change in `ai-server`'s webhook payload ripples up to `cashbot-go`, `middleware`, and the `dashboard`.

## 2. Decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| Benchmark unit | **Full code-change tasks** (agent edits real code) | Closest to the end goal; retrieval-only would understate quality effects. |
| Correctness oracle | **Run the repo's own test suite** (pass = success) | Most objective. Gated on the repo building + testing green locally first. |
| Task scope | **Cross-repo is the target** | The ~100-repo end goal; the highest-value, currently-missing capability. |
| Cross-repo linkage | **Build it first (Phase 0) before any benchmark** | Verified: the linkage does not exist; benchmarking now would measure nothing. |
| Linkage source | **`workspace.dsl` (C4) only** | Hand-verified, has protocols + repo mapping + named flows. `compose depends_on` is infra startup order (mysql/redis), not application coupling. |
| Edge granularity | **Repo/service-level** (`Repository -> Repository`) | Matches what the dsl knows; enough to point the agent at the right downstream repo. Symbol-precise cross-wire mapping deferred. |

## 3. Phase 0 — cross-repo enrichment

### 3.1 Goal

Load the C4 service relationships into the **same** Neo4j graph as edges on the existing `Repository` nodes, so cross-repo blast-radius queries return real answers. Tool-agnostic (operates on the graph, not on CGC internals — no upstream fork).

### 3.2 Component: `poc/enrich/`

One idempotent script (Python, `neo4j` driver already a CGC dependency). Behaviour:

1. **Parse `workspace.dsl`** — extract every `container` definition and its `Repo: <name>` annotation to build a `container_id -> repo_name` map. Parse every `->` relationship line, capturing source container, destination container, and the quoted label/protocol.
2. **Map to indexed repos** — keep only relationships where *both* endpoints map to a repo present in the Neo4j graph (the six indexed repos). Containers that map to out-of-corpus repos (`workspace-runner`, `internal-arcadia-agents`, infra like `mysql`/`redis`/`opensearch`) are **skipped and logged**, never silently dropped (no-silent-caps rule).
3. **Write edges** — for each kept relationship:
   ```cypher
   MATCH (a:Repository {name: $src}), (b:Repository {name: $dst})
   MERGE (a)-[r:CALLS_SERVICE {source: 'c4'}]->(b)
   SET r.protocol = $protocol, r.label = $label
   ```
   `MERGE` keeps the pass idempotent — re-running does not duplicate edges.
4. **Verify** — re-run the cross-repo query and assert the expected chain (`dashboard -> middleware -> cashbot-go -> ai-server`, plus the `ai-server -> cashbot-go` webhook) is present. Print the edge list.

### 3.3 Honest ceiling (stated, not hidden)

- Edges are **repo/service granularity**, not function granularity. The graph will say "ai-server's layout service feeds cashbot-go", not "Go struct `X.field` decodes this exact payload". That is enough to route the agent to the right repo; the agent's in-repo tools (CGC's working in-repo `CALLS`, or Serena's LSP) take it from there.
- **Symbol-precise cross-service mapping is deferred** — recovering "which handler decodes this webhook" needs OpenAPI specs + handler mapping. YAGNI until a benchmark task proves repo-level is insufficient.
- **Within-repo import stubs remain unresolved** — a CGC limitation, out of scope here. In-repo `CALLS` edges (50,916) already work, so in-repo retrieval is unaffected.
- The enrichment is **only as fresh as `workspace.dsl`** — a hand-maintained artifact. Drift between the dsl and reality is a known risk; auto-sync is out of scope (consistent with the PoC's no-auto-sync decision).

### 3.4 Phase 0 done-criteria

- `poc/enrich/` runs idempotently against the live graph.
- Cross-repo query returns the expected `CALLS_SERVICE` chain among the six repos.
- The skipped (out-of-corpus / infra) relationships are logged.
- [`SETUP.md`](SETUP.md) / [`SETUP-REPORT.md`](SETUP-REPORT.md) updated with the enrichment step.

## 4. Phase 1 — the code-change benchmark (sketch, gated on Phase 0)

Not built until Phase 0 passes. Captured here so Phase 0 is built toward the right target.

### 4.1 Arms

Four ways of giving Claude Code the **same** task, then compared on tokens, steps, and edit correctness. **Every arm uses Claude's built-in capability** (grep/read/edit/bash); the arms differ only in which MCP context tools are added on top.

1. **Baseline — Claude alone, no helper.** Plain Claude Code as-is; it finds code by searching/reading files (grep). We point it at the relevant repos with `--add-dir` so it *can* search across them. This is the "what we do today" arm — the bar to beat. **No MCP tools.**
2. **CGC (enriched) — Claude + the graph.** Same Claude, but it can ask the CodeGraphContext graph structural questions ("who calls this?", "what's downstream of ai-server?") instead of grepping. The graph already knows the structure, including the cross-repo `CALLS_SERVICE` links added in Phase 0. Should reach the right code in fewer searches. **MCP: codegraphcontext only — must not see Serena.**
3. **Serena — Claude + a language-server.** Same Claude, using IDE-grade "go to definition / find usages" — precise *inside* one repo, but it sees only one repo at a time, so on cross-repo tasks it cannot follow the trail. **Reported as a documented limit, not scored as a failure. MCP: serena only — must not see CGC.**
4. **Both — Claude + graph + language-server.** Same Claude with *both* tools available, to test whether they are complementary (graph for cross-repo routing, LSP for in-repo precision) and beat either alone. **MCP: codegraphcontext + serena, nothing else.**

### 4.2 Task corpus

The concrete corpus and its schema live in [`tasks/README.md`](tasks/README.md) ([`tasks/tasks.jsonl`](tasks/tasks.jsonl)). It is **3 real historical bugfixes** replayed from `cashbot-go` (the SWE-bench method: reverse-apply the commit's code to recreate the bug, the commit's own test is the oracle) **plus 1 constructed cross-repo task** (A2) for the graph thesis.

- **Real in-repo tasks (R1–R3)** — genuine shipped fixes (MCP response decoding, hiding a shadowed partner tool, OAuth resource-URL normalization). Success = the package's `go test` goes red→green. These stress finding the right code in a large repo.
- **Constructed cross-repo task (A2)** — a change that originates in `ai-server`'s layout webhook payload and must ripple to its consumer in `cashbot-go` (add field `engineVersion`). A genuine cross-repo change does not land as one commit with one test suite (the coupling is service-level), so this one is constructed. The new field is absent from cashbot-go (not greppable) → the agent must trace the service relationship; success = the consumer struct gains the field and `go build ./pkg/...` passes.

### 4.3 Metrics (from §3.6)

Cost = tokens/change. Time = tool-calls/change + wall-clock latency. Quality = tests pass (oracle) + completeness (all required call/consumer sites updated) + regressions. Operational = enrichment build time + freshness lag.

### 4.4 Phase 1 prerequisites (gates — verify before authoring tasks)

- **Buildable + green test suites** for each repo a task touches (Python `pytest`, Go `go test`, TS `npm test`). Any repo that does not build/test green locally is **excluded from the runnable-oracle set**; tasks are authored only against repos that pass. This gate is checked per-repo before the corpus is locked.
- A **green baseline state** per task: the repo's tests pass *before* the task is applied, so a post-edit failure is attributable to the change.

### 4.5 Arm isolation protocol (so the baseline is genuinely "plain Claude")

The baseline must run with **Claude Code's built-in tools only** (Grep/Glob/Read/Edit/Bash — the realistic "today" arm), and with **no unfair side-context**: no MCP tools, no prior-session memory, no plugin-injected observations. `--bare` would do this in one flag, but it forces `ANTHROPIC_API_KEY` auth and **we have no API key** (OAuth login only) — so we assemble OAuth-safe equivalents.

Each arm must also see **only its own** MCP tools — CGC must not see Serena and vice-versa, and the "both" arm sees exactly those two and nothing else. Apply the **same** isolation flags to all four arms; the *only* variable is the MCP config.

**Verified by dry-run (2026-06-26), all four arms PASS** — `poc/dryrun-isolation.sh` starts each arm for one trivial turn and reads the authoritative `system/init` event listing the loaded MCP servers:

| Arm | MCP servers loaded (asserted) |
|---|---|
| baseline | *(none)* |
| cgc | `codegraphcontext` only |
| serena | `serena` only |
| both | `codegraphcontext` + `serena` only |

A model self-report on the baseline additionally confirmed: no MCP tools, **no recalled memory/observations** (claude-mem hook did not fire — 0 hook events), and **no knowledge of the session-specific PoC artifacts** (`CALLS_SERVICE`/enrichment) — only the generic CLAUDE.md framing. This empirically settles the earlier open question: `--setting-sources project,local` does drop the claude-mem hook.

| Leak vector | Control | Status |
|---|---|---|
| MCP context tools (CGC / Serena / claude-mem MCP) | `--strict-mcp-config`; baseline passes **no** `--mcp-config`; each tool arm passes only its own config | **verified** — dry-run init events (table above) |
| Cross-arm tool leak (CGC seeing Serena or vice-versa) | per-arm `--mcp-config` + `--strict-mcp-config` | **verified** — cgc arm = `codegraphcontext` only; serena arm = `serena` only |
| claude-mem SessionStart hook + caveman plugin (both registered in **user** source `~/.claude/settings.json`) | `--setting-sources project,local` (omits `user`) | **verified** — 0 hook events; model recalled no observations |
| This interactive session's context | one fresh `claude -p` process per task; never `--continue` / `--resume` | verified (headless is a cold session) |
| CLAUDE.md auto-discovery (global `~/.claude/CLAUDE.md`, the research-repo `CLAUDE.md`, and `groundx-rnd/.claude/CLAUDE.md` — all parents of the target repos) | **Accepted as a controlled constant** — not removed | decided 2026-06-26 |

**Residual bias (documented, by decision):** CLAUDE.md cannot be suppressed without `--bare`/API key, and `--setting-sources` does not govern it. It loads **identically in all four arms** (a constant, not a differential), and its content is generic project/working-style guidance, not task answers (the baseline self-report confirmed it conveys no task-specific knowledge). We therefore accept it rather than mutate files mid-run. If a specific task's nearest `CLAUDE.md` is found to hint at structure relevant to that task, that task is dropped or relocated.

**Command shapes (identical isolation flags; only the MCP config varies):**
```bash
# Baseline — no MCP
claude -p "<task>" --strict-mcp-config --setting-sources project,local \
  --add-dir <repos> --permission-mode bypassPermissions --model claude-opus-4-8 --output-format json
# CGC / Serena / Both — add the arm's config
... --mcp-config poc/mcp/codegraphcontext.json ...      # cgc
... --mcp-config poc/mcp/serena.json ...                # serena
... --mcp-config poc/mcp/both.json ...                  # both
```

**Re-verify isolation any time** (does not run the benchmark): `bash poc/dryrun-isolation.sh` — prints each arm's boundary and asserts the loaded MCP servers match exactly. Run it before each benchmark session as a pre-flight.

## 5. Risks

- **Test suites may not build locally** (deps, fixtures, services). Mitigation: the §4.4 gate excludes non-runnable repos; if too few survive, fall back to golden-diff + completeness scoring for those tasks (revisit, do not silently switch oracles).
- **C4 dsl drift** — edges only as accurate as the hand-authored model. Mitigation: Phase-0 verify step prints the edge list for human sanity-check.
- **Repo-level edges too coarse** for some tasks. Mitigation: if a benchmark task needs symbol-precise cross-wire routing, that task documents the need for the deferred OpenAPI-enrichment track rather than forcing it now.
- **Baseline contamination** (no API key → cannot use `--bare`). Mitigation: the §4.5 OAuth-safe isolation protocol; the `--setting-sources project,local` claim must be empirically confirmed by the §4.5 probe before any numbers are trusted. CLAUDE.md is an accepted constant, not a differential.

## 6. What this unblocks

A measured, honest answer to the core research question: does a cross-repo-aware graph let an LLM make a cross-repo change with fewer tokens / fewer tool-calls and more completely than strong baseline grep — and where Serena's single-repo model cannot follow. Numbers, not adjectives (§3.6).

## 7. Run plan — incremental, checkpointed

We do **not** run the full 16-cell matrix in one shot — a Claude rate limit or a single bad cell would otherwise blow up the whole batch. Runs are paced so a failure costs at most one task.

**Unit = one task at a time** (each task = its 4 arms = 4 Claude runs). After each task: stop, show `results/results.csv`, confirm the repo restored clean, and wait for explicit go before the next.

**Order (cheap/safe → expensive/complex):**

1. **C1** — locate-and-fix, 1 repo, fast (baseline already proven).
2. **B1** — in-repo, ~20-file edit, more tool calls.
3. **A1** — cross-repo easy / control.
4. **A2** — cross-repo hard / discriminator.

**Within a task, arm order:** `baseline → cgc → serena → both` — baseline cheapest first, so if a limit hits mid-task we've already captured the most arms.

**Escape hatch:** the runner filters by `--tasks` and `--arms`, so if a limit looms we drop to one cell at a time (`bash poc/run.sh --tasks C1 --arms cgc`) and resume exactly where we stopped — completed cells are not redone.

**Pre-flight before each MCP batch (cgc / serena / both arms):**

- `cgc-neo4j` container up **and** the Phase-0 `CALLS_SERVICE` edges present (the CGC arm needs them).
- Serena's first call may warm language servers (slower) — expected, not a failure.

**Results handling:** the runner *appends* to `results/results.csv`; re-running a cell adds a row (kept for audit). Analysis takes the **latest** row per `(task, arm)`. Any duplicate is flagged before analysis.

**Per-task checkpoint reported:** per arm — `is_error`, `oracle_pass`, `completeness`, tool-calls (+ mcp), turns, tokens — plus "repo restored clean ✓". Captured in that task's [`runs/<TASK>.md`](runs/).
