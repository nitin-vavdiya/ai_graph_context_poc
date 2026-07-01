# Graph Context for AI Coding Tools — POC Conclusions

_One-page synthesis of the benchmark. Evidence trail: [`FINDINGS.md`](FINDINGS.md); per-task detail: [`runs/`](runs/); how to run: [`REFERENCE.md`](REFERENCE.md)._

## TL;DR (the verdict)

**A code-graph context layer earns its keep on a *narrow* set of high-value cases — cross-repo / "code I haven't cloned" retrieval, and transitive impact analysis at scale — but NOT as a general token-saver for everyday in-repo edits, where plain `grep` already wins. And the agent won't use the graph unless the task genuinely needs it or it is explicitly steered to.**

The original broad hypothesis — *a graph cuts find-cost across the board and saves tokens* — is **not supported** for everyday work and **only narrowly supported** for structural/off-disk queries. The condition where the graph should help *most* (≈100 repos, billions of lines, code not on disk) was **not testable** on this 2-repo single-machine harness, so it remains **untested, not disproven**.

## What we tested

- **Question:** does a graph context layer (symbols, calls, cross-repo edges via CodeGraphContext→Neo4j; plus Serena's LSP) let an AI coding agent locate relevant code with fewer tokens than plain search?
- **4 arms**, identical isolation, only the tools vary: **baseline** (built-in grep/read/edit/bash), **cgc** (+ CodeGraphContext graph), **serena** (+ Serena LSP), **both**.
- **6 tasks** on the real `groundx-rnd` corpus (cashbot-go Go backend + ai-server Python):

| task | kind | what the agent must do | oracle |
|---|---|---|---|
| R1 | real bugfix | fix MCP response decode (`mcp.go`) | `go test` |
| R2 | real bugfix | hide shadowed partner tool (`pkg/mcp`) | `go test` |
| R3 | real bugfix | fix OAuth resource-URL normalization (`oauth.go`) | `go test` |
| A2 | cross-repo | decode ai-server's new `engineVersion` field (both repos mounted) | field is `*string` + `go build` |
| A3 | cross-repo | decode ai-server's `taskDuration` — **ai-server moved off-disk** | field is `*int64` + `go build` |
| A4 | impact analysis | list all 30 files transitively calling `PrepareStep` (0% greppable by name) | recall ≥ 80% |

## Results (validated run, 2026-06-29; all fixes applied)

| task | baseline | cgc | serena | both | takeaway |
|---|---|---|---|---|---|
| R1 | ✅ mcp0 | ✅ mcp0 | ✅ mcp0 | ✅ mcp0 | easy in-repo — graph unused, no benefit |
| R2 | ✅ mcp0 | ✅ mcp0 | ✅ mcp0 | ✅ mcp0 | same |
| R3 | ❌ | ❌ | ❌ | ❌ | genuinely hard (0/4); gaming blocked; graph unused |
| A2 | ✅ | ✅ | ❌ | ❌ | grep spans both mounted repos → graph unused; serena/both fail on field *quality* (`string` not `*string`) |
| A3 | ❌ | **✅ mcp3** | ✅ (leak) | ❌ | **cgc used the graph to retrieve off-disk code & passed where baseline can't** — the one clean win |
| A4 | ✅ 29/30 | ✅ 29/30 mcp5 | ✅ 30/30 mcp64 | ✅ 30/30 mcp58 | graph/LSP genuinely used; all complete |

### Cost (USD) — single run; mixes pass/fail so compare only at equal correctness
| task | baseline | cgc | serena | both |
|---|---:|---:|---:|---:|
| R1 | 0.63 | 1.10 | 0.76 | 0.72 |
| R2 | 1.86 | 1.55 | 1.80 | 1.86 |
| R3 | 2.34 | 2.50 | 2.40 | 2.94 |
| A2 | 0.74 | 0.41 | 0.42 | 0.35 |
| A3 | 1.50 | 0.87 | 0.38 | 0.51 |
| A4 | 4.46 | 4.06 | 3.58 | 4.59 |
| **total** | **11.53** | **10.48** | **9.34** | **10.97** |

No arm is reliably cheaper — the spread is within run-to-run noise (cost ≈ `cache_read` × turns, and turn count is random per run). **Rank arms by correctness/quality, never by single-run cost.**

## What we can conclude

1. **Code on disk → grep wins; the graph goes unused (R1, R2, A2).** A rational agent never queries a graph when a local `grep` is cheaper. No token benefit on everyday in-repo edits.
2. **The graph is only reached for when (a) the task is structural/transitive *and* steered (A4), or (b) the code is genuinely off-disk (A3).** Otherwise it sits idle even when loaded and proven callable.
3. **Its real value is capability/completeness, not cost.** A3: cgc solved an off-disk task baseline *couldn't*. A4: graph/LSP reliably produce the *complete* transitive set; the graph's `CALLS*` query is the right shape (vs LSP's 60+ recursive calls, vs baseline's costly manual trace). But it is **not reliably cheaper** — the earlier "~4× cheaper" did not reproduce.
4. **The target scale was not testable here.** 2 repos on one disk cannot reproduce "100 repos you haven't cloned." A3 simulated off-disk but isolation leaks (a capable agent searches the whole filesystem). The scale hypothesis is open.

## Methodology lessons (reusable; the hard-won part)

- **Oracles are gameable.** R1–R3 inject the bug as an uncommitted change → agents `git checkout`/`stash` the fix instead of debugging (R3: 3/4 gamed before we hid `.git`). Fix: remove VCS access during the agent run.
- **`--add-dir` is not a sandbox.** Under `bypassPermissions` the agent reads any absolute path; "unmounting" a repo via add-dir (and even moving it within the tree) doesn't isolate it. Real isolation needs OS-level sandboxing.
- **"Passed" ≠ "equal quality."** A weak oracle (field-tag only) passed a `string` vs `*string` quality difference. Assert the *right* result, not just a green check.
- **MCP adoption ceiling.** Graph/LSP tools go unused unless the task can't be done without them *or* the prompt steers to them — measured via per-cell `mcp_tool_calls` + forced-call probe (`probe-mcp.sh`).
- **Huge run-to-run noise.** Cost/turns swing enough to flip arm rankings; even `oracle_pass` is noisy on hard tasks. Single runs can't rank — use multi-run medians.
- **Don't trust the init snapshot** for MCP availability (`status:pending` ≠ broken); re-indexing wipes manually-injected `CALLS_SERVICE` edges (re-run `enrich.py`).

## Recommendation

- **Adopt graph context selectively** — for cross-repo impact analysis, "blast radius," and retrieval of code not in the local workspace at scale. Pair it with **explicit steering** (system prompt / tool-preference instruction) or the agent won't use it.
- **Do not expect it to reduce tokens** on routine in-repo localize-and-fix tasks; built-in search is already optimal there.

## To make this decision-grade (next steps)

1. **Test at real scale** — index dozens of repos; run cross-repo tasks where grepping everything is infeasible.
2. **Fix isolation properly** — container or restricted-read permission mode, so off-disk tasks are clean (file-moving leaks).
3. **Multi-run** the decisive tasks (A3, A4) for medians; single runs are noisy.
4. **Test steering** as an explicit variable (steered vs unsteered) to quantify the adoption effect.
