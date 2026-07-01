# Executive Summary — Graph Context for AI Coding Agents

_POC comparing a code **knowledge graph** (CodeGraphContext / Neo4j) against an **LSP** tool (Serena) as the retrieval layer for an AI coding agent, over a 6-repo corpus. Single validated run (n=1), 2026-07-01. Full detail in the companion docs; evidence in [`../PARITY-RECHECK.md`](../PARITY-RECHECK.md) and [`03-task-runs.md`](03-task-runs.md)._

## Verdict

**Graph context is a narrow, conditional capability — not a general win, and not a token-saver.** It earns its place in exactly one situation the alternatives cannot handle, and is otherwise unused by the model.

The single situation where the graph is decisive: **retrieving code that is not on the developer's disk** (a symbol defined in another repo that isn't checked out locally). A pre-built graph index answers it; grep and LSP structurally cannot. Everywhere else — ordinary localize-and-fix, and even cross-repo work where the code *is* on disk — the model reaches for grep/read and never touches the graph or the LSP.

## What the run showed

- **On-disk work (4 of 6 tasks): the graph is ignored.** On every in-repo localize-and-fix task and on the cross-repo task where both repos were present, the model used grep/read and made **zero** graph/LSP calls, even with the tools available. Baseline (grep-only) was competitive or cheapest.
- **Off-disk retrieval (A3): the one clean win.** With the target repo physically removed from disk, **only the graph arm succeeded** — it retrieved the off-disk symbol from the pre-built index. Grep/LSP arms failed.
- **"Available" ≠ "used."** In A3, the arm that had *both* the graph and LSP tools **still failed** — because the model didn't invoke the graph. The graph only pays off when the agent is explicitly steered to it.
- **Transitive impact (A4): graph is cheaper, slightly less complete.** The graph answered a deep call-graph query at ~half the cost of brute-force grep, but with marginally lower recall; grep and LSP both reached full recall with far more effort (LSP made 65 reference-lookup calls).

## Cost

There is **no reliable token/cost saving** from the graph as a general layer — on the 4 on-disk tasks it added nothing and cost roughly the same as baseline. Its only cost advantage was on the one deep-traversal task (A4), and even there it traded a little completeness for the savings.

## The load-bearing caveats

- **Enterprise scale is untested.** This corpus is 6 repos; the motivating problem is ~100 repos / billions of lines. Nothing here proves the graph's advantage grows (or holds) at that scale.
- **The graph's cross-repo edges were hand-authored.** The one cross-repo *relationship* the graph could trace (service-to-service HTTP) came from a hand-written C4 model, not from parsing code — neither tool derives runtime cross-repo topology from source.
- **Single run.** These are n=1 results; the discriminating cells (A3, A4) warrant ×3 for medians before any number is quoted as final.

## Bottom line

Adopt graph context **selectively**, for off-disk / cross-repo retrieval and deep impact analysis, paired with grep (a router that falls back to grep for on-disk work), and **only if the agent is explicitly told when to use it**. Do **not** deploy it as a general retrieval layer or justify it on token cost. See [`04-recommendation.md`](04-recommendation.md).
