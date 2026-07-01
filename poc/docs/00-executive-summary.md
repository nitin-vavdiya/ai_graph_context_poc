# Executive Summary — Graph Context for AI Coding Agents

_POC comparing a code **knowledge graph** (CodeGraphContext / Neo4j) against an **LSP** tool (Serena) as the retrieval layer for an AI coding agent, over a 6-repo corpus. 2026-07-01; A2/A3/A4 run 3× (medians), R1–R3 single-run. Full detail in the companion docs; evidence in [`../PARITY-RECHECK.md`](../PARITY-RECHECK.md) and [`03-task-runs.md`](03-task-runs.md)._

## Verdict

**Graph context is a narrow, conditional capability — not a general win, and not a token-saver.** It earns its place in exactly one situation the alternatives cannot handle, and is otherwise unused by the model.

The single situation where the graph is decisive: **retrieving code that is not on the developer's disk** (a symbol defined in another repo that isn't checked out locally). A pre-built graph index answers it; grep and LSP structurally cannot. Everywhere else — ordinary localize-and-fix, and even cross-repo work where the code *is* on disk — the model reaches for grep/read and never touches the graph or the LSP.

## What the run showed

- **On-disk work (4 of 6 tasks): the graph is ignored.** On every in-repo localize-and-fix task and on the cross-repo task where both repos were present, the model used grep/read and made **zero** graph/LSP calls, even with the tools available. Baseline (grep-only) was competitive or cheapest.
- **Off-disk retrieval (A3): the one clean win.** With the target repo physically removed from disk, **only the graph arm succeeded** — it retrieved the off-disk symbol from the pre-built index. Grep/LSP arms failed.
- **"Available" ≠ "used."** In A3, the arm that had *both* the graph and LSP tools **still failed** — because the model didn't invoke the graph. The graph only pays off when the agent is explicitly steered to it.
- **Transitive impact (A4): all arms succeed; graph uses far fewer tool calls but is NOT cheaper.** Across 3 runs every arm reached full recall (median 37/37). The graph's one robust advantage is **tool-call count** — it answered with **2–5** graph queries where the LSP made **60–66** reference lookups (it has no transitive operator). But that does *not* translate to lower cost: cgc's average cost was the **highest** of the four arms ($7.03), because $/tokens are dominated by output-token volume, which varied wildly run-to-run.

## Cost & tokens

There is **no reliable token/cost saving** from the graph — the single-run "graph is ~2× cheaper on A4" result **did not survive medians** and is retracted. Over 3 runs, cgc was in fact the **most expensive** arm on the deep-traversal task (avg $7.03 vs baseline $6.63, serena $4.06, both $3.71). $/token is driven by output-token volume, which is noise-dominated (baseline's A4 output ranged 14K→92K tokens across identical runs).

Per-arm average tokens (across A2/A3/A4, 9 runs each): baseline **2.5K in / 16.4K out**, cgc **3.3K in / 15.4K out**, serena **7.0K in / 17.9K out**, both **8.7K in / 17.2K out**. The graph/LSP arms carry higher *input* tokens (tool schemas + query results in context); output is comparable. Net: the graph does not lower token spend as a general layer, and can raise it.

## The load-bearing caveats

- **Enterprise scale is untested.** This corpus is 6 repos; the motivating problem is ~100 repos / billions of lines. Nothing here proves the graph's advantage grows (or holds) at that scale.
- **The graph's cross-repo edges were hand-authored.** The one cross-repo *relationship* the graph could trace (service-to-service HTTP) came from a hand-written C4 model, not from parsing code — neither tool derives runtime cross-repo topology from source.
- **Sample size.** A2/A3/A4 were run **3×** (medians reported); R1–R3 remain single-run. A4 cost/tokens are noise-dominated even at n=3 — treat them as ranges, not point estimates.

## Bottom line

Adopt graph context **selectively**, for off-disk / cross-repo retrieval and deep impact analysis, paired with grep (a router that falls back to grep for on-disk work), and **only if the agent is explicitly told when to use it**. Do **not** deploy it as a general retrieval layer or justify it on token cost. See [`04-recommendation.md`](04-recommendation.md).
