# Design — Cross-Repo Graph Linkage (Phase 0) and the Code-Change Benchmark (Phase 1)

**Date:** 2026-06-26. **Status:** approved design, pre-implementation. **Scope:** defines how we make the CodeGraphContext (CGC) graph actually span repos, then how we benchmark the three arms (baseline / CGC / Serena) on real code-change tasks. This supersedes the loose "run the 3-arm benchmark next" note in `../../poc/SETUP-REPORT.md` §6 with a concrete, gated plan.

## 1. Why this design exists (the finding that forced it)

The benchmark was going to lead with cross-repo tasks, because the end goal is ~100 repos and the highest-value capability is cross-repo blast-radius (§3.6 of `context-graph-evaluation.md`). A live check of the populated Neo4j graph (2026-06-26) showed that **the graph cannot answer any cross-repo question today**:

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
- `poc/SETUP.md` / `SETUP-REPORT.md` updated with the enrichment step.

## 4. Phase 1 — the code-change benchmark (sketch, gated on Phase 0)

Not built until Phase 0 passes. Captured here so Phase 0 is built toward the right target.

### 4.1 Arms

1. **Baseline** — plain Claude Code, no MCP tool, `--add-dir` over the relevant repos (so grep *can* cross repos — a fair, strong baseline).
2. **CGC (enriched)** — CodeGraphContext MCP over the Phase-0-enriched graph.
3. **Serena** — LSP control arm; for cross-repo tasks it structurally sees only one repo. This is **reported as a documented limit**, not scored as a failure.

### 4.2 Task shape (cross-repo)

A change that originates in one repo and must ripple to another along a known C4 edge. Canonical example: rename/extend a field in `ai-server`'s layout webhook payload (`DocumentLayoutWebhook`); the correct change also updates the consumer in `cashbot-go`. Success = both repos' relevant tests pass and the consumer was actually updated (completeness).

### 4.3 Metrics (from §3.6)

Cost = tokens/change. Time = tool-calls/change + wall-clock latency. Quality = tests pass (oracle) + completeness (all required call/consumer sites updated) + regressions. Operational = enrichment build time + freshness lag.

### 4.4 Phase 1 prerequisites (gates — verify before authoring tasks)

- **Buildable + green test suites** for each repo a task touches (Python `pytest`, Go `go test`, TS `npm test`). Any repo that does not build/test green locally is **excluded from the runnable-oracle set**; tasks are authored only against repos that pass. This gate is checked per-repo before the corpus is locked.
- A **green baseline state** per task: the repo's tests pass *before* the task is applied, so a post-edit failure is attributable to the change.

## 5. Risks

- **Test suites may not build locally** (deps, fixtures, services). Mitigation: the §4.4 gate excludes non-runnable repos; if too few survive, fall back to golden-diff + completeness scoring for those tasks (revisit, do not silently switch oracles).
- **C4 dsl drift** — edges only as accurate as the hand-authored model. Mitigation: Phase-0 verify step prints the edge list for human sanity-check.
- **Repo-level edges too coarse** for some tasks. Mitigation: if a benchmark task needs symbol-precise cross-wire routing, that task documents the need for the deferred OpenAPI-enrichment track rather than forcing it now.

## 6. What this unblocks

A measured, honest answer to the core research question: does a cross-repo-aware graph let an LLM make a cross-repo change with fewer tokens / fewer tool-calls and more completely than strong baseline grep — and where Serena's single-repo model cannot follow. Numbers, not adjectives (§3.6).
