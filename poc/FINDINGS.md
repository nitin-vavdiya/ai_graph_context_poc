# Findings (running log)

Interim conclusions as the benchmark executes. Per-cell numbers live in [`runs/<TASK>.md`](runs/); metric mechanics in [`REFERENCE.md`](REFERENCE.md) §3. This file records what the results *mean*, updated after each task.

## Status as of R1 (×2) + R2 (×2) + R3 (×1) — single-repo tasks only

> **R3 update:** first task with failures — cgc and serena did not fix it, baseline and both did. The failures are **not arm-driven** (the graph arm `both` passed; the non-graph `baseline` passed; `mcp=0` everywhere) — they are task difficulty + run variance. Two sharper lessons: (a) **`oracle_pass` is itself noisy on hard tasks** (a single run gave a 50% pass rate mapping to no arm) → hard tasks need a multi-run pass *rate*, not one pass/fail; (b) **failing runs cost more** (wrong path = more turns), so cost and correctness are entangled — never compare cost across a mix of pass/fail cells. Detail: [`runs/R3.md`](runs/R3.md).


**Nothing so far proves any cost reduction from cgc or serena.** Three points:

1. **The arms never used the graph** (`mcp=0` on R1×2 and R2×2 — four single-repo runs, zero graph calls). You can't credit a tool that wasn't called. Whatever cost differences appeared came from grep/read/edit — the same built-in tools every arm used.
2. **The differences are noise, not effect.** The arms flip rank between runs (baseline cheapest in R1, expensive in R2; serena cheapest then mid; both 3rd then cheapest; cost decided by how many turns a run randomly took). A real arm effect wouldn't flip — it'd be consistent. So the spread is run-to-run turn variance, not cgc/serena. (The one non-flipping signal: cgc was the *most expensive* in both R2 runs — a mild repeatable **tax**, not a benefit.)
3. **So far the honest result is the opposite of a win:** on single-repo tasks the graph arms are at best neutral and at worst a small tax (extra schema tokens in `in_tokens`, sometimes more wandering) — with **zero demonstrated benefit**. That's the expected null for in-repo work, not a failure.

### What would actually prove a benefit (not yet shown)
- The graph arm **calls** the graph tools (`mcp > 0`), **and**
- that produces **fewer turns / lower cost at equal `oracle_pass`**, **and**
- the gap is **bigger than the run-to-run noise** (→ needs a multi-run median, not one run).

The only task designed to trigger all three is **A2 (cross-repo)**: baseline has to blindly hunt across repos, serena structurally *can't* span repos, and cgc has the `CALLS_SERVICE` edge that points straight to the consumer. If cgc shows `mcp>0` and a real turn/cost drop there — and it holds across a few runs — that's the proof. If even A2 shows `mcp=0`, then the honest conclusion is the graph didn't help as wired, and we report that.

### Bottom line
R1/R2 prove the **harness is sound and isolation is clean** — not that the graph saves cost. The claim stands or falls on **A2**.

### Why three near-identical in-repo tasks (R1–R3)?
They look alike because they *behaved* alike (`mcp=0`, easy-locate), but they are three distinct real bugs — R1 MCP response decode (`mcp.go`, stresses *time*), R2 shadowed-tool filtering (`pkg/mcp/mcp.go`, stresses *quality*), R3 OAuth URL normalization (`oauth.go`, stresses *time*). The multiplicity is deliberate:
1. **They are the control / null baseline.** The hypothesis is "graph helps *locate* code." R1–R3 are cases where locating is trivial (one grep → one file), so the graph *should not* help. Showing no benefit here is what lets us attribute any A2 benefit to the **cross-repo structure**, not to "graph good everywhere."
2. **One null is an anecdote; three is a pattern.** Three different bug types / files / packages all showing the same null makes the in-repo result robust against a per-bug fluke.
3. **They estimate the noise floor.** Repeated R-runs are how we learned the run-to-run cost swing is large — that number is the yardstick A2's effect must beat.

**Caveat — the design is lopsided: three in-repo control tasks vs one cross-repo treatment task (A2).** The entire verdict leans on a single treatment case. If A2 shows a strong effect, that is suggestive, not conclusive — a general "graph wins cross-repo" claim would need **additional cross-repo tasks** to confirm (the design mentions an `A1` cross-repo control that could be added). Treat a positive A2 as a strong lead, not proof of a general result.

### Methodology consequence
Because cost on easy tasks is dominated by `cache_read ≈ context-size × turns` (turn count is random per run), **rank arms by `oracle_pass` then `cost_usd`, never by `cache_read`/`total billable`, and never off a single run.** Run the decisive task (A2) **≥3× and take the median** so a true effect can clear the noise. (Details: [`REFERENCE.md`](REFERENCE.md) §3.)
