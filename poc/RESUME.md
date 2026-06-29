# ▶ Resume here (Monday)

**State:** everything is built, validated, documented, and pushed. **Only execution remains** — run the 4-arm benchmark, paced one task at a time. Last verified 2026-06-26: all oracle baselines green, Neo4j up with 4 cross-repo edges, isolation proven.

## Do this, in order

```bash
cd /Users/nitin/projects/groundx/ai_graph_context_poc

# 0. Pre-flight
docker compose -f poc/docker-compose.yml up -d        # in case Neo4j stopped over the weekend
bash poc/dryrun-isolation.sh                           # isolation: each arm loads only its own MCP server NAMES (4 trivial Claude calls)
bash poc/probe-mcp.sh                                  # callability: forces a real mcp__* call per arm — MUST pass, else mcp=0 is meaningless
#    together they confirm Claude auth/limits are live AND the graph/LSP tools actually work before spending on real cells

# 1. Step 1 — R1 (4 arms)
bash poc/run.sh --tasks R1
#    -> review poc/results/results.csv + poc/runs/R1.md, confirm repo restored clean, then continue

# 2..4 — one task per step, stop and review between each
bash poc/run.sh --tasks R2
bash poc/run.sh --tasks R3
bash poc/run.sh --tasks A2

# 5. Analysis — aggregate results.csv per arm; write the narrative into each poc/runs/<TASK>.md
```

## Rules
- **One task (4 arms) per step**, then check results before the next. Order R1 → R2 → R3 → A2.
- **Rate-limited?** Drop to one cell: `bash poc/run.sh --tasks R1 --arms cgc`. Completed cells are not redone (results just append; latest row per task,arm wins).
- **Reboot?** Re-run the `docker compose ... up -d` line before the cgc/serena/both arms.

## What "done" looks like (verdict)
At equal `oracle_pass`, do **cgc / both** use fewer tokens + tool-calls than **baseline**? And on **A2** (cross-repo) does cgc find the consumer while baseline struggles and serena can't span? Details: [`TEST-PLAN.md`](TEST-PLAN.md) §6.

## If you forget anything
- **Conclusions (start here): [`CONCLUSIONS.md`](CONCLUSIONS.md)** · What/why: [`benchmark-design.md`](benchmark-design.md) §0 · The tasks: [`tasks/README.md`](tasks/README.md) · Commands/schema/gotchas: [`REFERENCE.md`](REFERENCE.md) · Evidence trail: [`FINDINGS.md`](FINDINGS.md) · Hub: [`README.md`](README.md).
