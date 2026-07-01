# Benchmark Test Plan & Measurement Plan

How we run the benchmark and how we turn the runs into a verdict. Conceptual background in [`benchmark-design.md`](benchmark-design.md) (§0 plain terms); concrete tasks in [`tasks/README.md`](tasks/README.md); commands/schema in [`REFERENCE.md`](REFERENCE.md).

## 1. Objective

Measure whether giving Claude a code-context tool (a code graph and/or an LSP) lets it close real coding tasks **cheaper and more reliably** than plain Claude, across a multi-repo codebase.

## 2. Hypothesis

The tool arms (cgc / both) achieve the **same pass rate** as baseline using **fewer tokens and fewer tool-calls**; and the graph wins specifically on the **cross-repo** task (A2), where plain search structurally cannot find the link between repos.

## 3. Subjects under test (the 4 arms)

All arms use Claude's built-in tools (grep/read/edit/bash), the same prompt, and identical isolation flags; the **only** variable is the MCP config.

| Arm | Tool added |
|---|---|
| baseline | none (today's normal) |
| cgc | CodeGraphContext graph |
| serena | Serena (LSP) |
| both | graph + LSP |

Isolation: `--strict-mcp-config --setting-sources project,local`, fresh `claude -p` per cell (details in `benchmark-design.md` §4.5; verified by `dryrun-isolation.sh`).

## 4. Test cases

| ID | Type | Task (symptom given to Claude) | Oracle |
|---|---|---|---|
| R1 | real bugfix | MCP tool executions fail to decode the response | `go test ./pkg/partner/partners/groundx` |
| R2 | real bugfix | partners see a shadowed customer MCP tool | `go test ./pkg/mcp` |
| R3 | real bugfix | valid OAuth requests rejected on resource-URL mismatch | `go test ./pkg/partner/partners/groundx` |
| A2 | constructed | cross-repo: ai-server adds webhook field `engineVersion`; update the consumer | `go build ./pkg/...` + field present |

R1–R3 are real shipped commits replayed (reverse-apply the fix → bug returns → the commit's own test is the oracle). A2 is constructed (a real cross-repo change never lands as one commit with one test). **4 tasks × 4 arms = 16 cells.**

## 5. Test procedure (per cell)

1. Restore the repo to a pristine snapshot (preserves pre-existing local state).
2. Apply setup — real tasks: reverse-apply the commit's code (recreate the bug); A2: none.
3. Run Claude with the arm's flags + MCP config + the task prompt.
4. Run the oracle → pass/fail.
5. Record metrics + regenerate the run doc; restore the repo.

Driven by `poc/run.sh`; one row per cell appended to `poc/results/results.csv`.

## 6. Measurement plan

Every metric is a hard number captured automatically — no human judgement in scoring. The three dimensions map to the project goal (Cost / Time / Quality, per evaluation §3.6).

| Dimension | Metric | Source |
|---|---|---|
| **Quality** | `oracle_pass` — did the real test go green | we run `go test` / `go build` after the agent |
| | `completeness` — change covered what it had to | task check (real = oracle_pass; A2 = field present) |
| | `is_error` | stream-json `result` event |
| **Cost** | `in_tokens`, `out_tokens`, `cache_read` | `result` event `.usage` |
| | `cost_usd` | `result` event `.total_cost_usd` |
| **Time** | `tool_calls`, `mcp_tool_calls` | count of `tool_use` events in the stream |
| | `num_turns` | `result` event |
| | `duration_ms` | `result` event |

`mcp_tool_calls` also tells us **whether the tool was actually used** (did cgc query the graph, or fall back to grep).

### How we turn metrics into a verdict

Baseline is the reference. For each task, compare the tool arms against baseline:

1. **Did it pass?** (`oracle_pass`) — quality first; a cheaper run that fails does not count.
2. **At equal pass, how much cheaper?** — Δ tokens and Δ tool-calls vs baseline. This is the headline: does the tool reduce the cost of *finding + fixing*?
3. **Was the tool used?** — `mcp_tool_calls` > 0 on the tool arms.

Example read: *"R1 — all four pass; cgc 8k tokens / 9 tool-calls vs baseline 22k / 19 → graph cut find-cost ~60%."*

### The decisive measurement — A2 (cross-repo)

- **cgc / both**: should locate the consumer in a few graph queries → far fewer tokens/calls, passes.
- **baseline**: must guess from config/URLs; expect many tool-calls and possible failure to find the right repo.
- **serena**: cannot span repos → documented limit, not scored as failure.

If cgc ≫ baseline here, the graph thesis is demonstrated; if they tie, it is not.

### Analysis output

After the cells run, aggregate `results.csv` into a per-task, per-arm comparison (pass / median tokens / tool-calls / turns / cost) and write the narrative into each [`runs/<TASK>.md`](runs/). Headline: does cgc/both beat baseline on cost at equal quality, and does A2 expose the cross-repo gap.

## 7. Execution schedule (paced, gated)

Pre-flight (free) → **Step 1: R1** → checkpoint + your go → **R2** → go → **R3** → go → **A2** → go → **Analysis**. One task (4 arms) per step; stop after each for explicit go. If a Claude rate limit hits mid-step, drop to per-cell (`--arms <one>`) and resume — completed cells are not redone. Order: R1 → R2 → R3 → A2 (cheap/simple → cross-repo).

## 8. Environment & pre-flight

`cgc-neo4j` up + 4 `CALLS_SERVICE` edges + `gopls` on PATH; `bash poc/dryrun-isolation.sh` passes (all 4 arms load only their own MCP). Versions pinned in `REFERENCE.md` §7.

## 9. Validity & limitations (honest)

- **Single sample per cell** → directional, not statistically significant. Re-run borderline cells.
- **Same prompt across arms** → differences are attributable to the tool, not wording.
- **CLAUDE.md is a constant** across all arms (can't be suppressed without an API key) → affects all four equally, does not bias the comparison.
- **Tokens/cost are Claude Code's own reported usage**, not estimates.
- **ai-server tests are not run locally** (GPU/Detectron2) → A2 is scored by completeness + `go build ./pkg/...`, not ai-server's own tests.
- **A2 is constructed**, not a real commit — flagged; it is the one task whose realism is traded for testing the cross-repo thesis.
