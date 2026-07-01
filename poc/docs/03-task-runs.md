# Task Definitions & Results

_The six benchmark tasks and the full 24-cell result matrix. **Single validated run (n=1), 2026-07-01**, under the fixed harness ([`02-poc-setup.md`](02-poc-setup.md)). Medians (×3) on the discriminating cells are still pending. Raw data: `poc/results/results.csv`; per-cell tool traces: `poc/runs/*.md`._

## Tasks

Two families: **R** = in-repo localize-and-fix (real historical bugs in `cashbot-go`, reverse-applied so the agent must re-find and re-fix them; graded by `go test`). **A** = cross-repo / scale scenarios designed to stress structural retrieval.

| id | scenario | repos (park) | what it tests | oracle |
|---|---|---|---|---|
| **R1** | MCP response decode bug | cashbot-go | in-repo localize+fix | `go test` passes |
| **R2** | shadowed partner MCP tool | cashbot-go | in-repo localize+fix | `go test` passes |
| **R3** | OAuth resource-URL normalization | cashbot-go | in-repo localize+fix | `go test` passes |
| **A2** | cross-repo field add, **both repos on disk** — add `engineVersion` to the webhook type | cashbot-go, ai-server | cross-repo retrieval when code is present | field is pointer+omitempty; `go build` |
| **A3** | cross-repo field add, **ai-server PARKED off-disk** — mirror `taskDuration` from ai-server's model | cashbot-go (park ai-server) | **off-disk retrieval** — the code is only in the graph | `taskDuration *int64` + `go build` |
| **A4** | transitive impact set of `PrepareStep` | cashbot-go | **deep call-graph traversal** | recall ≥0.8 vs independent Go-SSA oracle (37 files) |

A3 is the capability discriminator: the answer lives **only** in ai-server, which is physically removed from disk — so grep/LSP have nothing to read, and only a pre-built index can reach it. A4 is the efficiency/scale test: `PrepareStep` has 1 direct caller but many transitive ones, and none of the impact files contain the string "PrepareStep" (un-greppable by name).

## Results — full 24-cell matrix

`pass` = oracle passed · `mcp` = graph/LSP tool calls the model made · `turns`/`dur`/`cost` from the run.

| task | arm | pass | mcp | turns | dur (s) | cost ($) |
|---|---|---|---|---|---|---|
| R1 | baseline | ✅ | 0 | 13 | 111 | 0.71 |
| R1 | cgc | ✅ | 0 | 16 | 122 | 0.73 |
| R1 | serena | ✅ | 0 | 20 | 215 | 1.14 |
| R1 | both | ✅ | 0 | 17 | 136 | 0.99 |
| R2 | baseline | ✅ | 0 | 24 | 230 | 1.98 |
| R2 | cgc | ✅ | 0 | 21 | 319 | 1.96 |
| R2 | serena | ✅ | 0 | 27 | 252 | 2.16 |
| R2 | both | ✅ | 0 | 21 | 186 | 1.57 |
| R3 | baseline | ❌ | 0 | 20 | 309 | 2.13 |
| R3 | cgc | ❌ | 0 | 26 | 337 | 2.45 |
| R3 | serena | ❌ | 0 | 18 | 318 | 1.98 |
| R3 | both | ❌ | 0 | 20 | 345 | 2.22 |
| A2 | baseline | ✅ | 0 | 11 | 40 | 0.93 |
| A2 | cgc | ✅ | 0 | 12 | 52 | 0.49 |
| A2 | serena | ❌ | 0 | 12 | 50 | 0.37 |
| A2 | both | ✅ | 0 | 12 | 48 | 0.40 |
| A3 | baseline | ❌ | 0 | 14 | 92 | 0.73 |
| **A3** | **cgc** | **✅** | **2** | 21 | 137 | 1.27 |
| A3 | serena | ❌ | 0 | 15 | 238 | 0.54 |
| A3 | both | ❌ | 0 | 12 | 101 | 0.43 |
| A4 | baseline | ✅ (37/37) | 0 | 59 | 1209 | 6.25 |
| A4 | cgc | ✅ (34/37) | 5 | 42 | 656 | 3.19 |
| A4 | serena | ✅ (37/37) | 65 | 69 | 808 | 4.17 |
| A4 | both | ✅ (37/37) | 54 | 68 | 787 | 4.55 |

Total run cost: **$43.33**.

## Per-task reads

- **R1, R2 — in-repo fix, all arms pass, `mcp=0`.** Every arm solved these with grep/read; the graph and LSP were available and **never called**. Baseline is competitive (cheapest or near it).
- **R3 — all arms fail, `mcp=0`.** Not a tool signal — the OAuth-normalization fix was hard for all four arms equally (the model located the area but didn't produce a fix that passed the test). Included for completeness; it discriminates nothing between tools.
- **A2 — cross-repo, both repos on disk.** baseline/cgc/both pass, all with `mcp=0` — even the graph/LSP arms solved it with grep, because the code was right there. Serena's arm failed (a flake; it also used no LSP). Takeaway: when the code is on disk, structural tools add nothing.
- **A3 — the clean capability result.** Only **cgc** passed, and only because it invoked the graph (`mcp=2`, `find_code`) to read the off-disk symbol. baseline and serena failed (nothing to read). **The `both` arm failed with `mcp=0`** — it had the graph tool but the model didn't use it. Availability is not usage.
- **A4 — graph cheaper, slightly less complete.** All arms passed the 0.8 recall gate. cgc was cheapest and fastest ($3.19 / 656 s / 5 graph calls) but recalled 34/37. baseline reached full 37/37 by brute grep-BFS at the highest cost ($6.25 / 59 turns). serena reached 37/37 via **65** `find_referencing_symbols` calls — the manual level-by-level BFS made concrete.

## Tool usage summary

The model invoked a structural tool in **only 2 of 6 tasks**: the graph in A3 (2 calls), and the LSP/graph in A4 (heavy). On R1–R3 and A2 — every on-disk task — it used grep/read exclusively, `mcp=0`, despite the tools being available. Serena specifically was used in **1 of 6 tasks** (A4).

## Caveats on these numbers

- **n=1.** A3 (`both` failing by not calling the graph) and A4 (costs, cgc's 34 vs 37 recall) are the load-bearing cells and had historical variance; they need ×3 for medians before any figure is quoted as final.
- **R3 failing across all arms** may indicate the task or its oracle is too strict; it should be reviewed before being read as a capability signal (it isn't one — it's flat across arms).
- A4 recall is graded against a **sound lower bound** (static call graph, 37 files); dynamic-dispatch-only callers are out of scope, so an arm is never penalized for finding more.
