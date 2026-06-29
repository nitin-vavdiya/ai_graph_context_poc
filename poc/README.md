# PoC — code-context tools for an LLM coding agent

> ▶ **Picking this back up?** Start at [`RESUME.md`](RESUME.md) — the exact next commands.

Hands-on validation of the two finalized tools (**CodeGraphContext** + **Serena**) against a plain-Claude-Code baseline, measured on real code-change tasks over the `groundx-rnd/` corpus. The *why* and tool selection live in [`../docs/research/`](../docs/research/) and the [ADRs](../docs/adr/); this folder is the *execution*.

## Phases

| Phase | What | Status |
|---|---|---|
| **Setup** | Install + index the tools, wire them into Claude Code, verify | ✅ done — [`SETUP.md`](SETUP.md) (runbook) · [`SETUP-REPORT.md`](SETUP-REPORT.md) (as-built) |
| **Phase 0** | Make the graph span repos (C4 service edges) | ✅ done — [`enrich/enrich.py`](enrich/enrich.py); see SETUP-REPORT §5b |
| **Phase 1** | 4-arm code-change benchmark | design ready — [`benchmark-design.md`](benchmark-design.md); tasks + runner built, runs pending |

## Map

- [`TEST-PLAN.md`](TEST-PLAN.md) — **test plan & measurement plan**: objective, hypothesis, the 4 arms, test cases, procedure, what we measure and how we reach a verdict, execution schedule, validity limits.
- [`REFERENCE.md`](REFERENCE.md) — **one-stop reference**: command cheatsheet, arms + isolation, results/metrics schema, how to add a task, file map, versions, and gotchas.
- [`CONCLUSIONS.md`](CONCLUSIONS.md) — **★ start here**: one-page synthesis — verdict, results, cost/quality matrices, methodology lessons, recommendation.
- [`FINDINGS.md`](FINDINGS.md) — **running findings log**: the full evidence trail behind the conclusions (per-task, chronological).
- [`benchmark-design.md`](benchmark-design.md) — the plan: Phase-0 enrichment + the 4-arm benchmark (arms, oracle, **isolation §4.5**, gates). **New to this? Start at §0 "In plain terms".**
- [`SETUP.md`](SETUP.md) · [`SETUP-REPORT.md`](SETUP-REPORT.md) — reproducible setup runbook and the as-built record.
- [`tasks/`](tasks/) — the benchmark task corpus ([`tasks/README.md`](tasks/README.md), [`tasks/tasks.jsonl`](tasks/tasks.jsonl), `tasks/fixtures/`).
- `mcp/` — per-arm MCP configs: `codegraphcontext.json`, `serena.json`, `both.json` (baseline uses none).
- `enrich/` — Phase-0 cross-repo enrichment.
- `docker-compose.yml` — local Neo4j for CodeGraphContext.
- `runs/` — per-task run reports (generated). `results/` — raw logs + CSV (gitignored).

## The 4 arms (all use Claude's built-in tools; only the MCP config differs)

| Arm | MCP | Config |
|---|---|---|
| baseline | none | — |
| cgc | codegraphcontext only | `mcp/codegraphcontext.json` |
| serena | serena only | `mcp/serena.json` |
| both | codegraphcontext + serena | `mcp/both.json` |

Isolation is identical on every arm (`--strict-mcp-config --setting-sources project,local`, fresh process per cell) — spec in [`benchmark-design.md`](benchmark-design.md) §4.5, verified by `dryrun-isolation.sh`.

## How to run

```bash
docker compose -f poc/docker-compose.yml up -d     # Neo4j (cgc arm)
bash poc/dryrun-isolation.sh                        # pre-flight: prove arm isolation (no benchmark)
bash poc/run.sh --tasks C1                          # one task (its 4 arms); see results/results.csv + runs/C1.md
bash poc/run.sh                                     # full matrix (4 tasks x 4 arms)
```

Runs are paced **one task at a time** (Claude rate limits) — order C1 → B1 → A1 → A2.
