# ▶ Resume here (next: 2026-06-30)

**State (2026-06-29):** full 24-cell benchmark executed and validated with all anti-gaming + quality fixes; conclusions written. See **[`CONCLUSIONS.md`](CONCLUSIONS.md)** first. Prior contaminated run is parked in `poc/results/_archive_pre-fix/`.

**Tomorrow's task:** run **A3 and A4 two more times each** to get multi-run medians (single-run cost/correctness is noisy — see [`FINDINGS.md`](FINDINGS.md)). A3 and A4 are the only tasks where the graph/LSP actually get used, so they're the ones worth repeating.

## Do this, in order

```bash
cd /Users/nitin/projects/groundx/ai_graph_context_poc

# 0. Pre-flight (infra + callability)
docker compose -f poc/docker-compose.yml up -d                 # if machine rebooted
docker exec cgc-neo4j cypher-shell -u neo4j -p poctestpassword "MATCH ()-[r:CALLS_SERVICE]->() RETURN count(r)"   # expect 4
#   if NOT 4 (e.g. after any re-index):  NEO4J_PASSWORD=poctestpassword uv run --with neo4j python poc/enrich/enrich.py
docker exec cgc-neo4j cypher-shell -u neo4j -p poctestpassword "MATCH (c:Class {name:'DocumentResponse'}) WHERE c.path CONTAINS 'ai-server' RETURN c.source CONTAINS 'taskDuration'"  # expect TRUE (A3 seed)
bash poc/probe-mcp.sh                                           # MUST pass (graph/LSP callable), else mcp results are meaningless

# 1. Re-run A3 twice (cross-repo; ai-server auto-parked off-disk)
bash poc/run.sh --tasks A3      # run #2
bash poc/run.sh --tasks A3      # run #3
#   (each run appends to results.csv; archive transcripts if you want per-run logs:
#    for a in baseline cgc serena both; do cp poc/results/A3_$a.jsonl poc/results/A3_$a.runN.jsonl; done)

# 2. Re-run A4 twice (impact analysis; slow — cgc/serena/both cells can take 10–30 min)
bash poc/run.sh --tasks A4      # run #2
bash poc/run.sh --tasks A4      # run #3

# 3. Analysis
bash poc/quality-audit.sh A3 ; bash poc/quality-audit.sh A4    # quality per arm (mandatory before trusting numbers)
grep ',A3,\|,A4,' poc/results/results.csv                       # all rows; take MEDIAN per arm for cost/turns, and pass RATE
#   update the narratives in poc/runs/A3.md and poc/runs/A4.md with the median view
```

## Rules
- **One task at a time**; review between. A4 cells are expensive ($3.5–6 each) and slow — watch the session limit.
- **Session-limited?** Drop to one cell: `bash poc/run.sh --tasks A4 --arms cgc`. Completed cells append; analysis takes the latest/median rows. An errored cell shows `is_error=true` with ~0 tokens — discard and re-run it.
- **Don't rank arms by single-run cost** — it's `cache_read`×turns noise. Use medians + pass rate at equal correctness.

## ⚠ Known caveat to keep in mind
A3's "off-disk" isolation **leaks**: `park_repo` moves ai-server into `poc/results/.parked/` (still readable) and a stray copy exists at `~/projects/groundx/log_analysis/code/groundx-rnd/ai-server` — a capable agent `find`s them. So on A3 only **cgc's pass (via the graph, `mcp>0`) is trustworthy**; serena/baseline passing by reading a leaked copy is an artifact. Proper fix (container / restricted-read) is an open follow-up — see [`CONCLUSIONS.md`](CONCLUSIONS.md) "next steps".

## If you forget anything
- **Conclusions (start here): [`CONCLUSIONS.md`](CONCLUSIONS.md)** · Evidence trail: [`FINDINGS.md`](FINDINGS.md) · Commands/metrics/gotchas: [`REFERENCE.md`](REFERENCE.md) · The tasks: [`tasks/README.md`](tasks/README.md) · Hub: [`README.md`](README.md).
