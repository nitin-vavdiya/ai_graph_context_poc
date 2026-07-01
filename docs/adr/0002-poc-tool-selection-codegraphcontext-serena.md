# 2. Select CodeGraphContext + Serena for the context-tooling PoC

- **Status:** Accepted
- **Date:** 2026-06-26
- **Deciders:** Nitin Vavdiya
- **Builds on:** ADR 0001
- **Supersedes:** —

> **Post-POC note (2026-07-01):** both tools were benchmarked. For this multi-repo purpose CodeGraphContext (graph) proved the better fit than Serena (LSP) — LSP structurally cannot do off-disk retrieval and has no one-shot transitive op — but neither beats grep on on-disk work. Head-to-head: [`../../poc/docs/04-recommendation.md`](../../poc/docs/04-recommendation.md). Decision above stands as written.

## Context

ADR 0001 committed us to a permissive-OSS code-context layer, proven by a measured PoC. Research narrowed the field to a four-tool shortlist, all MIT-licensed (full analysis in `docs/research/context-graph-evaluation.md` §4–§8 and `docs/research/multi-repo-and-remote-deployment.md`):

- **CodeGraphContext** — persistent code graph; first-class Neo4j/Cypher; the **only** candidate that can also be a unified store served from a remote/shared server (MCP-over-SSE + remote Neo4j). Young, effectively single-maintainer.
- **codegraph** — persistent embedded-SQLite graph; lowest-ops, local-first; can unify nested repos at a root; **stdio-only (no remote)**. Most-starred but young, single-maintainer.
- **code-review-graph** — persistent per-repo SQLite graph; explicit token-budgeted retrieval; PR-review / change-impact specialist; localhost-only; has file-write refactor tools. Young, single-maintainer, contested benchmarks.
- **Serena** — no persistent graph; live LSP, on-demand; highest per-repo accuracy; **mature and multi-contributor** (lowest bus-factor).

The PoC must answer the highest-signal question: **does a persistent code graph actually beat live on-demand retrieval for our LLM's code-change tasks — and is it worth the operational cost — at our scale?** Answering that requires pairing one graph tool against the on-demand control, not two similar graph tools.

A genuine fork existed in choosing the graph arm:

- **CodeGraphContext** tests our actual strategic ambition (a unified store across ~100 repos, servable locally or remote) but costs more to set up (Neo4j + auth hardening).
- **codegraph** is the lower-ops graph option but is local-only, so it cannot test the shared/scaled delivery we care about. It overlaps heavily with CodeGraphContext on the core "graph vs live" question.

## Decision

The PoC will run **two tools plus a baseline**:

1. **CodeGraphContext** — the persistent-graph arm. Chosen over codegraph because it is the only graph tool that also exercises the unified/scaled/remote-served delivery in ADR 0001, so the PoC validates both the *value* question (graph vs live) and the *scale/delivery* ambition in one pass.
2. **Serena** — the on-demand control arm. Mature, low-risk, trivial to set up, and representative of the agentic + live-LSP pattern large engineering orgs actually run. It is the yardstick: if a graph cannot beat live symbol retrieval on our tasks, we do not need the graph.
3. **Plain Claude Code, no context tool** — the no-tool reference point, so results triangulate: *no-tool → live-LSP (Serena) → persistent-graph (CodeGraphContext)*.

We will measure the ADR 0001 metric set (tokens/change, tool-calls/change, latency, edit correctness/completeness/regressions) on a representative corpus — starting with the related cluster `ai-server`, `groundx-python`, `groundx-typescript`, `groundx-ai-middleware`, `groundx-ai-dashboard`, plus one standalone repo as a single-repo control.

**codegraph** and **code-review-graph** are **deferred, not rejected** (see "revisit conditions").

## Consequences

**Positive**

- One PoC answers two questions: graph-vs-live value, and whether the unified/scaled graph vision holds.
- Serena gives a low-risk, fast-to-stand-up control and a maturity anchor against the younger graph tool.
- Triangulating against no-tool prevents over-crediting either tool when built-in agentic grep is already sufficient.

**Negative / risks**

- CodeGraphContext carries maturity/bus-factor risk (young, single-maintainer) and setup cost (Neo4j; auth/TLS reverse proxy + locked-down CORS required before any non-local exposure — it ships neither).
- Its cross-repo edges are coincidental (path/name match), not designed cross-service links; cross-repo/service value still needs enrichment (ADR 0001).
- Serena is local-only with no persistent/shared graph and a filesystem/shell-bound remote story — acceptable for a control, but it cannot itself become the shared layer.
- Excluding codegraph means the lowest-ops graph experience is not directly trialed in this round.

**Revisit conditions (when to bring back the deferred tools)**

- Swap CodeGraphContext → **codegraph** if the priority shifts to fastest, zero-ops, local-only validation over testing scale/delivery.
- Add **code-review-graph** if PR-review / change-impact becomes the dominant target workflow, or to trial token-budgeted retrieval and a CI path.

## References

- ADR 0001 — adopt a code-context layer; value vs delivery.
- `docs/research/context-graph-evaluation.md` — §8 head-to-head, §8.1 three-way, §8.2 value-lens scorecard, §9 decision-support, §3.6 metrics.
- `docs/research/multi-repo-and-remote-deployment.md` — delivery, security, and remote-serving comparison.
