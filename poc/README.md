# PoC — Graph Context vs LSP for an AI Coding Agent

Hands-on comparison of **CodeGraphContext** (code knowledge graph / Neo4j) and **Serena** (LSP) against a plain-Claude-Code **baseline**, measured on real code-change tasks over the 6-repo `groundx-rnd/` corpus.

> **Status:** complete (single validated run, 2026-07-01). The first head-to-head was found unreliable and discarded; the harness was fixed and re-run — see [`PARITY-RECHECK.md`](PARITY-RECHECK.md).

## Read the results — `docs/`

| # | doc | what |
|---|---|---|
| **0** | [`docs/00-executive-summary.md`](docs/00-executive-summary.md) | **★ start here** — one-page verdict |
| 1 | [`docs/01-multi-repo-setup-guide.md`](docs/01-multi-repo-setup-guide.md) | reusable how-to: set up CGC + Serena for N repos |
| 2 | [`docs/02-poc-setup.md`](docs/02-poc-setup.md) | how *this* POC was set up + the fairness fixes |
| 3 | [`docs/03-task-runs.md`](docs/03-task-runs.md) | task definitions + full 24-cell results matrix |
| 4 | [`docs/04-recommendation.md`](docs/04-recommendation.md) | CGC vs Serena — adopt/don't-adopt guidance |

Supporting: [`PARITY-RECHECK.md`](PARITY-RECHECK.md) (verification trail — why the numbers are trustworthy). Superseded docs are in [`_archive/`](_archive/).

## The 4 arms (all use Claude's built-in tools; only the MCP config differs)

| arm | MCP | config |
|---|---|---|
| baseline | none | — |
| cgc | codegraphcontext | `mcp/codegraphcontext.json` |
| serena | serena | `mcp/serena.json` |
| both | codegraphcontext + serena | `mcp/both.json` |

Isolation is identical on every arm: a macOS Seatbelt sandbox (`--permission-mode dontAsk` + [`sandbox-settings.json`](sandbox-settings.json)) plus `--strict-mcp-config`, fresh process per cell — details in [`docs/02-poc-setup.md`](docs/02-poc-setup.md), verified by `dryrun-isolation.sh`.

## Layout

- `run.sh` — the benchmark runner (restore → run cell → oracle → restore).
- `sandbox-settings.json` — the Seatbelt sandbox config applied to every cell.
- `oracle/` — independent Go-SSA call-graph oracle for A4 ([`oracle/README.md`](oracle/README.md)).
- `tasks/` — task corpus (`tasks.jsonl`, `fixtures/`).
- `mcp/` — per-arm MCP configs.
- `enrich/` — cross-repo C4 service edges for the graph.
- `docker-compose.yml` — local Neo4j.
- `runs/` — per-cell run reports (generated). `results/` — raw logs + CSV (gitignored).
- `dryrun-isolation.sh` · `probe-mcp.sh` — pre-flight isolation + MCP-callability checks.

## Run it

```bash
docker compose -f poc/docker-compose.yml up -d     # Neo4j (cgc arm)
serena project index <abs path>/groundx-rnd        # one-time Serena index (see docs/02)
bash poc/dryrun-isolation.sh                        # pre-flight: MCP scoping + sandbox denial
bash poc/run.sh --tasks A3 --arms baseline,cgc      # one task, chosen arms
bash poc/run.sh                                     # full matrix (6 tasks x 4 arms)
```
