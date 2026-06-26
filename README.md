# AI Graph Context PoC

Research and decision-support for giving **LLM coding tools** (Claude Code and similar) precise code context across a large codebase — **~100 repositories, billions of lines of code** — so that AI-assisted code changes are **faster, cheaper, and higher quality**.

This is a non-code research repository. The deliverables are the documents under `docs/research/`.

## End goal

We use LLM tools to make code changes across ~100 repos. We want those tools to spend fewer tokens and fewer steps locating relevant code, and to produce more correct, complete edits. The question this research answers: **how do code-context / code-graph tools help the LLM achieve that, and which tool(s) should we take into a PoC?**

## Problem statement

Today, an LLM agent making a change does this loop: grep → read a file → follow an import → read another → search again… It re-derives the codebase's structure every task, by reading lots of files. That's exactly where the time, cost, and quality leak:

- **Time** — each grep/read is a round-trip; understanding one change can take 10–30 tool calls.
- **Cost** — it pulls far more code into context than it needs, just to find the bit that matters.
- **Quality** — it either misses relevant code (incomplete edit → bug) or floods context (too much → "context rot" → worse answers).

A code-context tool collapses that loop into a few precise structural queries answered from a pre-built (or live) index.

## What it concretely buys, mapped to the three goals

| LLM needs to… | Without a tool | With a context tool | Improves |
|---|---|---|---|
| Find where something is defined | grep + read several files | `find_definition` → one answer | Time, Cost |
| Know what a change will break | guess, or read callers manually (often misses some) | `get_callers` / blast-radius / impact → every caller + dependent + test | Quality (complete edits, fewer regressions) |
| Understand a flow | read file after file | `call_chain` / `expand_neighborhood` → the connected code only | Time, Cost, Quality |
| Edit against real structure | infer relationships (can hallucinate) | edges come from the actual code (calls/imports/inheritance) | Quality (grounded, fewer hallucinations) |
| Stay within the model's attention | dump big files | token-budgeted, ranked context | Quality, Cost (less context rot) |

The single biggest quality lever is **impact/blast-radius**: before the agent changes a function, it learns every call site and affected test, so the edit is complete and it knows what to verify. That's the difference between "fixed here, broke three callers" and a correct change.

## How the knowledge reaches the LLM (a secondary, separable choice)

*How* this knowledge is stored and served — an embedded per-repo index, one unified graph, or a server (local or remote) exposing it over MCP — is a **delivery** decision. It affects who benefits and how fresh the data is, but it is **not** the source of the value. The value is precise structural retrieval and impact analysis; delivery is how we ship that value to the agent. We pick the tool for the value and the delivery model for our team/ops reality.

## Candidate tools (PoC shortlist)

All four are permissive OSS (MIT). Detail and comparison live in the research docs.

- **CodeGraphContext** — persistent graph; Neo4j/Cypher scale path; the only one that can also be served remotely with a centralized DB.
- **codegraph** — persistent graph; embedded SQLite; lowest-ops, local-first; can unify nested repos at a root.
- **code-review-graph** — persistent per-repo graph; token-budgeted retrieval; PR-review / change-impact specialist; federated cross-repo search.
- **Serena** — no persistent graph; live LSP, on-demand; the mature multi-contributor control arm.

## Documents

The repo has two tiers: **research & decision** (why a code-context layer, which tools) and **PoC execution** (setup + benchmark).

**Research & decision** — `docs/`

- [`docs/research/context-graph-evaluation.md`](docs/research/context-graph-evaluation.md) — the main report: conceptual foundation, value & measurement, tool overviews, landscape survey, head-to-head comparison, and decision-support recommendation.
- [`docs/research/multi-repo-and-remote-deployment.md`](docs/research/multi-repo-and-remote-deployment.md) — operational comparison: multi-repo behaviour, remote serving, security, storage, and change pickup.
- [`docs/adr/0001-adopt-code-context-layer.md`](docs/adr/0001-adopt-code-context-layer.md) — decision to adopt a code-context layer; value vs delivery; permissive-OSS + measured-PoC constraints.
- [`docs/adr/0002-poc-tool-selection-codegraphcontext-serena.md`](docs/adr/0002-poc-tool-selection-codegraphcontext-serena.md) — decision to take **CodeGraphContext + Serena** (plus a no-tool baseline) into the PoC.

**PoC execution** — `poc/` (start at the hub)

- [`poc/README.md`](poc/README.md) — **PoC hub**: phases, the 4 arms, how to run, and links to everything below.
- [`poc/benchmark-design.md`](poc/benchmark-design.md) — Phase-0 enrichment + the 4-arm benchmark design (arms, oracle, isolation, gates).
- [`poc/SETUP.md`](poc/SETUP.md) · [`poc/SETUP-REPORT.md`](poc/SETUP-REPORT.md) — setup runbook and as-built record.
- [`poc/tasks/README.md`](poc/tasks/README.md) — the benchmark task corpus and scoring.

## Status

Research-and-decision stage complete. **PoC tools finalized: CodeGraphContext + Serena**, measured against a plain-Claude-Code (no-tool) baseline (see ADR 0002).

**Setup done + verified** (Python/TS/Go) — see [`poc/SETUP-REPORT.md`](poc/SETUP-REPORT.md).

**Phase 0 done** — cross-repo linkage. Indexing alone produced zero cross-repo edges (the real coupling is service-level, not in source); [`poc/enrich/enrich.py`](poc/enrich/enrich.py) loads the C4 `workspace.dsl` into the graph as repo-level `CALLS_SERVICE` edges, verified through Claude Code.

**Next (Phase 1):** the 4-arm code-change benchmark (baseline / CGC / Serena / both) — design in [`poc/benchmark-design.md`](poc/benchmark-design.md). Tasks + runner are built; arm isolation is verified ([`poc/dryrun-isolation.sh`](poc/dryrun-isolation.sh), all arms pass). Runs are paced one task at a time; gated on per-repo test-suite buildability (§4.4), with ai-server's Detectron2/GPU deps the open risk.
