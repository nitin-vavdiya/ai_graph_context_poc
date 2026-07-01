# Task Definitions & Results

_The six benchmark tasks and the results, under the fixed harness ([`02-poc-setup.md`](02-poc-setup.md)). **R1–R3: single run** (stable). **A2/A3/A4: 3 runs each → medians + averages** (2026-07-01), since those are the discriminating cells and had run-to-run variance. Raw data: `poc/results/results.csv`; per-cell tool traces: `poc/runs/*.md`._

## Tasks

Two families: **R** = in-repo localize-and-fix (real historical bugs in `cashbot-go`, reverse-applied so the agent must re-find and re-fix them; graded by `go test`). **A** = cross-repo / scale scenarios designed to stress structural retrieval.

| id | scenario | repos (park) | what it tests | oracle |
|---|---|---|---|---|
| **R1** | MCP response decode bug | cashbot-go | in-repo localize+fix | `go test` passes |
| **R2** | shadowed partner MCP tool | cashbot-go | in-repo localize+fix | `go test` passes |
| **R3** | OAuth resource-URL normalization | cashbot-go | in-repo localize+fix | `go test` passes |
| **A2** | cross-repo field add, **both repos on disk** (`engineVersion`) | cashbot-go, ai-server | cross-repo retrieval when code is present | field pointer+omitempty; `go build` |
| **A3** | cross-repo field add, **ai-server PARKED off-disk** (`taskDuration`) | cashbot-go (park ai-server) | **off-disk retrieval** — code only in the graph | `taskDuration *int64` + `go build` |
| **A4** | transitive impact set of `PrepareStep` | cashbot-go | **deep call-graph traversal** | recall ≥0.8 vs independent Go-SSA oracle (37 files) |

A3 is the capability discriminator: the answer lives **only** in ai-server, physically removed from disk — grep/LSP have nothing to read, only a pre-built index can reach it. A4 is the efficiency/scale test: `PrepareStep` has 1 direct caller but many transitive ones, none containing the string "PrepareStep" (un-greppable by name).

> **Scope of the tasks (important).** The **edit target is always `cashbot-go`**. R1/R2/R3/A4 are **single-repo** (cashbot-go only); A2/A3 are **two-repo** (`cashbot-go` ← a field defined in `ai-server`). **No task spans more than 2 repos, and 4 of the 6 corpus repos** (`groundx-python`, `groundx-typescript`, `groundx-ai-middleware`, `groundx-ai-dashboard`) **are never exercised by any task.** The 6-repo scope is the *tool/index* scope (a realistic retrieval haystack + realistic index build cost), **not** the task scope — the cross-repo advantage was only stressed across a single service hop (cashbot-go ↔ ai-server). See caveats.

## Results — R1–R3 (single run)

| task | baseline | cgc | serena | both | note |
|---|---|---|---|---|---|
| R1 | ✅ | ✅ | ✅ | ✅ | all pass, **mcp=0** — structural tools available but unused |
| R2 | ✅ | ✅ | ✅ | ✅ | all pass, mcp=0 |
| R3 | ❌ | ❌ | ❌ | ❌ | all fail — hard task, discriminates nothing between arms |

On in-repo localize-and-fix, every arm used grep/read and **never** called the graph or LSP. Baseline is competitive.

## Results — A2/A3/A4 (3 runs → medians)

`pass` = passes out of 3 · `mcp` = graph/LSP tool calls · tokens/cost are **averages** of the 3 runs.

| task | arm | pass | mcp | avg in-tok | avg out-tok | avg cost $ |
|---|---|---|---|---|---|---|
| **A2** | baseline | 2/3 | 0 | 2,628 | 2,555 | 0.85 |
| | cgc | 2/3 | 0 | 4,095 | 2,663 | 0.46 |
| | **serena** | **0/3** | 0 | 3,265 | 2,614 | 0.37 |
| | both | 3/3 | 0 | 3,903 | 2,445 | 0.48 |
| **A3** | baseline | 0/3 | 0 | 2,623 | 5,562 | 0.71 |
| | **cgc** | **2/3** | 2 (when pass) | 4,188 | 6,737 | 1.02 |
| | serena | 0/3 | 0 | 3,733 | 4,977 | 0.41 |
| | both | 0/3 | 0 | 4,515 | 5,091 | 0.49 |
| **A4** | baseline | 3/3 | 0 | 2,255 | 41,152 | 6.63 |
| | cgc | 3/3 | **2–5** | 1,733 | 36,804 | **7.03** |
| | serena | 3/3 | **60–66** | 13,855 | 46,156 | 4.06 |
| | both | 3/3 | 54–62 | 17,635 | 44,145 | 3.71 |

Per-arm overall averages (A2+A3+A4, 9 runs each): **baseline** in 2,502 / out 16,423 · **cgc** in 3,338 / out 15,401 · **serena** in 6,951 / out 17,915 · **both** in 8,684 / out 17,227. (Serena/both carry higher *input* tokens — MCP tool schemas + reference-lookup results in context; output is similar across arms.)

## Per-task reads (medians)

- **A2 (cross-repo, both on disk).** baseline/cgc/both pass via grep (`mcp=0`), **serena reliably fails (0/3)** — adding the LSP tool correlated with worse outcomes on an on-disk task; no arm used a structural tool. Takeaway: when the code is on disk, structural tools add nothing (and Serena's arm hurt).
- **A3 (off-disk) — the clean capability result.** **Only cgc passes (2/3), and passing is perfectly predicted by whether it invoked the graph** (pass ⟺ `mcp=2`; the one failure was `mcp=0`). baseline/serena fail all 3 (nothing to read). **The `both` arm fails all 3 with `mcp=0`** — it *had* the graph tool but never reached for it. Availability ≠ usage; the graph must be explicitly steered. cgc's passing runs cost ~2× the others' cheap failures ($1.02 avg vs $0.37–0.71) — capability isn't free.
- **A4 (transitive impact) — all arms pass, but the n=1 "graph is cheaper" claim did NOT survive.** Every arm reached the 0.8 recall gate; **median recall is 37/37 for all**, including cgc (its 34/37 was a single-run outlier). On cost, **cgc is the *most* expensive on average ($7.03)**, not the cheapest — $/token is dominated by output tokens (baseline's output alone spanned 14K→92K across runs) and is essentially noise-dominated. The **only robust efficiency signal is tool-call count**: cgc issued **2–5** graph queries where serena made **60–66** reference lookups (it has no transitive operator — it BFS-es the call tree by hand). That call-count gap reproduces; the dollar/token advantage does not.

## Tool usage summary

Across all runs, the model invoked a structural tool in only **2 of 6 task types**: the graph in A3 (only cgc, and not even every run), and the graph/LSP in A4 (heavy). On R1–R3 and A2 — every on-disk task — it used grep/read exclusively (`mcp=0`) despite the tools being available. **Serena** was used by the model in **1 of 6 tasks** (A4).

## Caveats

- **A4 cost/tokens are noise-dominated** — do not quote any arm as "cheaper." The defensible A4 metric is tool-call count, not $ or tokens.
- **R3 fails on all arms** — likely too strict a task/oracle; it discriminates nothing and should not be read as a capability signal.
- A4 recall is graded against a **sound lower bound** (static call graph, 37 files); dynamic-dispatch-only callers are out of scope, so an arm is never penalized for finding more.
- **n=3** for A2/A3/A4 (medians shown); R1–R3 remain n=1.
- **Cross-repo is only 2 repos deep.** Tasks span at most `cashbot-go ↔ ai-server`; the other 4 corpus repos are indexed but untested by any task. The graph's cross-repo edge was never stressed beyond one service hop — so "enterprise scale" (~100 repos, multi-hop dependency chains) is untested both in repo *count* and in cross-repo *task* complexity. A follow-up should add tasks whose answer chains through ≥3 repos.
