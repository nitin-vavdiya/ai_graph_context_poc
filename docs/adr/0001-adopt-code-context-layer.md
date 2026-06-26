# 1. Adopt a code-context layer for AI-assisted development; separate value from delivery

- **Status:** Accepted
- **Date:** 2026-06-26
- **Deciders:** Nitin Vavdiya
- **Supersedes:** —

## Context

We use LLM coding tools (Claude Code and similar) to make code changes across a large estate — roughly 100 repositories and billions of lines of code. Without help, an LLM agent making a change runs an expensive loop: grep → read a file → follow an import → read another → search again, re-deriving the codebase's structure every task by reading many files. This is where cost, time, and quality leak:

- **Cost** — it pulls far more code into context than it needs to find the relevant part.
- **Time** — each grep/read is a round-trip; one change can take 10–30 tool calls.
- **Quality** — it either misses relevant code (incomplete edit → bug) or floods context, triggering "context rot" (degraded answers as input grows), a documented effect along with "lost in the middle." Bigger context windows and prompt caching reduce price/latency but not this quality decay.

A code-context / code-knowledge-graph tool addresses this by replacing exploration with a few precise structural queries (find definition, callers/callees, call chains, impact/blast-radius) answered from a pre-built or live index. The detailed conceptual foundation and evidence are in `docs/research/context-graph-evaluation.md` (see §3 and §3.6).

Two axes were repeatedly conflated during analysis and must be kept separate:

1. **Value to the LLM** — precise structural retrieval and impact analysis. This is the point.
2. **Delivery** — how that knowledge is stored and served: a local per-developer index, one unified graph, or a server (local or remote) over MCP. This affects who benefits and how fresh the data is, but is **not** the source of value.

A hard limit established by the research: static parsing of code does **not** produce cross-repo / cross-service relationships (e.g. a UI calling an API over HTTP). Those must come from architecture/topology sources we already maintain (`workspace.dsl` C4 model, `docker-compose`/deploy, OpenAPI specs).

## Decision

1. We will pursue a **code-context layer** that serves structural code context to our LLM coding tools, rather than relying on the agent's built-in grep/read exploration alone.
2. We will treat **value as the selection driver** and **delivery (local vs unified vs remote/shared) as a secondary, separable choice** made for our team/ops reality.
3. We will restrict adoption to **permissive open-source licenses** (MIT / Apache-2.0 / BSD). Copyleft (GPL/AGPL) and proprietary/source-available tools are background context only.
4. We will **prove value with measured metrics in a PoC** before any broad rollout — vendor-reported savings are not accepted as evidence. The metric set: tokens per change, tool-calls per change, latency, and edit correctness/completeness/regressions, measured against a plain-Claude-Code (no-tool) baseline.
5. We accept that **cross-repo/cross-service relationships require enrichment** from non-code sources and are out of scope for the code-parsing tools themselves.

## Consequences

**Positive**

- A clear, falsifiable goal: reduce tokens/time per change and improve edit quality, measured rather than asserted.
- Separating value from delivery prevents premature architecture debates (e.g. "central bucket vs local") from blocking tool selection.
- Permissive-OSS-only keeps options open for self-hosting, forking, and air-gapped deployment.

**Negative / risks**

- A context layer adds operational surface: indexing, freshness, and (for shared delivery) a stateful service to run and secure.
- The leading tools in this space are young; maturity/bus-factor risk is real (addressed in ADR 0002).
- Cross-repo/service value depends on enrichment we have not yet built; intra-repo depth is the near-term win.
- The win may be marginal for small local edits where built-in agentic grep is already effective; the PoC must quantify where the tool actually helps.

## References

- `docs/research/context-graph-evaluation.md` — conceptual foundation (§3), value & measurement (§3.6).
- `docs/research/multi-repo-and-remote-deployment.md` — delivery-model comparison.
- ADR 0002 — PoC tool selection.
