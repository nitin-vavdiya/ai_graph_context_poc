# Findings (running log)

Interim conclusions as the benchmark executes. Per-cell numbers live in [`runs/<TASK>.md`](runs/); metric mechanics in [`REFERENCE.md`](REFERENCE.md) §3. This file records what the results *mean*, updated after each task.

## ☑ Fresh validated run — all 24 cells, post-fix (2026-06-29 evening)

First full run with the anti-gaming + quality fixes (`.git` hidden during the agent call; pointer-type A2/A3 oracles; A4 recall + diagnostic precision). Prior results parked to `poc/results/_archive_pre-fix/`.

| task | baseline | cgc | serena | both | what it shows |
|---|---|---|---|---|---|
| R1 | ✅ mcp0 | ✅ mcp0 | ✅ mcp0 | ✅ mcp0 | easy in-repo — graph unused, all pass |
| R2 | ✅ mcp0 | ✅ mcp0 | ✅ mcp0 | ✅ mcp0 | same |
| R3 | ❌ | ❌ | ❌ | ❌ | **0/4 genuine** — gaming blocked (`.git` hidden); all made real `oauth.go` edits but didn't land the hard OAuth-normalization fix this run |
| A2 | ✅ | ✅ | ❌ | ❌ | quality oracle bites — serena/both added the field but **not `*string`**, correctly failed |
| A3 | ❌ | ✅ **mcp3** | ✅ mcp0 ⚠leak | ❌ | **cgc's graph win is the one clean positive**; serena passed via a leak (below); baseline/both failed |
| A4 | ✅ 29/30 mcp0 | ✅ 29/30 mcp5 | ✅ 30/30 mcp64 | ✅ 30/30 mcp58 | graph+LSP genuinely used; all complete; costs **bunched $3.6–4.6** |

### What this clean run establishes
1. **Anti-gaming works; R3's old "all pass" was mostly git-gaming.** With `.git` hidden, R3 is genuinely 0/4 — arms make real edits but don't land the fix. (Correctness is noisy — a prior genuine serena run *did* pass R3 — so the honest read is "hard, low single-shot pass rate, no arm advantage.")
2. **The quality oracle discriminates.** A2 now separates `*string` (pass) from `string` (fail): baseline/cgc pass, serena/both fail on type. "All passed" is gone.
3. **Graph value is real but narrow; efficiency is NOT robust.** A3/cgc used the graph (`mcp=3`) to retrieve an off-disk symbol and pass where baseline failed — a genuine capability win. A4: graph/LSP used by all tool arms, all complete (29–30/30), **but the earlier "~4× cheaper" did NOT reproduce** — every A4 arm cost $3.6–4.6 this run (both was $4.59, not the earlier $1.51). The graph's *reliable* advantage is **completeness/capability on structural queries**, not lower cost; the cost win is run-dependent noise.

### ⚠ Still-open harness bug: A3 isolation leaks
A3/serena passed with `mcp=0` because `park_repo` moves ai-server to `poc/results/.parked/` — **inside readable space** — so the agent `find`s and `Read`s it; it also found a **stray second checkout** at `/Users/nitin/projects/groundx/log_analysis/code/groundx-rnd/ai-server`. So file-moving does **not** isolate (same lesson as A2/A3 v1–v2: a capable agent searches the whole filesystem). Only **cgc's A3 pass is trustworthy** (graph, not file). Robust isolation needs OS-level sandboxing (container / restricted-read permission mode), not parking. **Net A3:** cgc demonstrably retrieved off-disk code via the graph; baseline failed; serena's pass is an artifact; both didn't try the graph.

## ★★ Updated headline (after A4 — the graph WAS used and CAN help)

A4 (impact analysis — list all transitive callers of `PrepareStep`, an answer that is **0% greppable by name**) is the first task where the graph/LSP were actually used, and it revises the picture below:

- **Adoption ceiling broken — conditionally.** With a task where grep obviously can't start *and* an explicit steer to use code-graph/symbol tools, all three tool arms called their MCP tools (cgc 8, serena 63, both 5). Neither the hard task nor the steer alone sufficed in R1–A3; both together did.
- **The graph, used well, is ~4× cheaper at equal completeness.** `both` produced the full 29/29 impact set in 5 graph calls / 15 turns / **$1.51**; baseline traced it by hand to 28/29 but cost **$5.90** / 64 turns. The graph wins by expressing transitive reachability as one `CALLS*` query instead of dozens of manual grep+read steps.
- **Three big caveats.** (1) baseline still reached 28/29 — the graph is an efficiency win here, not a capability the agent lacks. (2) "Graph available" ≠ "graph efficient": `cgc`-alone had the graph, used it, and still cost $6.30 — as much as baseline; the win depends on *how* it's used. (3) Single run per arm with large known variance — "4×" is indicative, not yet statistically firm.

**Net:** the graph's value is real but narrow and conditional — it shows up on **structural/transitive queries at scale, when the agent is steered to use it and expresses the query structurally**. On ordinary localize-and-edit tasks (R1–A3) with code on disk, the model rationally prefers grep and the graph goes unused. Full A4 detail: [`runs/A4.md`](runs/A4.md).

## ★ Headline conclusion (after R1–R3 + A2 pass 1)

**As wired, this benchmark does not demonstrate a graph/LSP benefit — and it revealed why.** Across every cell run (R1×3, R2×3, R3×2, A2×1 = 36 cells), **the model never once called a graph or LSP tool (`mcp=0` everywhere)**, even on A2, the cross-repo task designed to require the graph, where cgc had 25 graph tools offered and used none. All arms — including baseline — solved every task with built-in `grep`/`find`/`read`/`edit`, and all passed.

**The root cause is a design flaw, not a null result about graphs:** every task mounts all relevant repos via `--add-dir`, so plain `grep` can span the repo boundary. That neutralizes the graph's only real advantage — cheap structural lookup when you *can't* brute-force-search everything. At this 2-repo scale grep is simply sufficient, so a rational model never reaches for the graph. The hypothesis (graph cuts find-cost at ~100-repo, billions-of-lines scale) is therefore **untested**, not disproven: the harness doesn't reproduce the scale where brute-force grep breaks down.

**What a valid test would need** (see A2 redesign in [`runs/A2.md`](runs/A2.md)): deny brute-force search across all repos — e.g. mount only the run repo and force cross-repo discovery through the graph, and/or scale to many repos so grepping everything is infeasible. Until then, the honest finding is: *given local access to both repos, Claude prefers grep over the graph, and grep is enough.*

Everything below is the evidence trail that leads here.

## A3 — the redesign that actually forces the cross-repo question (built 2026-06-29)

A2 failed to test the hypothesis because both repos were mounted (grep spans them) and the answer was local. **A3 fixes both:**

- **Only the run repo is mounted.** A3 sets `repos: ["cashbot-go"]`, so `--add-dir` gives the agent cashbot-go only. ai-server is **off-disk** — grep/read cannot reach it. (serena indexes cwd only, so it's blind to ai-server too.)
- **The answer lives only in the unmounted repo.** A real producer change was seeded: ai-server's `DocumentResponse` callback model gained a field **`taskDuration`** (ai-server commit `8f404d9`). It occurs **0× in cashbot-go**. The task asks the agent to decode "the new field ai-server now sends" without naming it — so it must *retrieve* the field name/type from ai-server's model.
- **Only the graph can bridge it.** ai-server was re-indexed into Neo4j, so cgc's `find_code`/cypher can return `DocumentResponse.source` (which contains `taskDuration`) even though the repo isn't on disk. Verified: `MATCH (c:Class {name:'DocumentResponse'}) RETURN c.source CONTAINS 'taskDuration'` → TRUE.

**Expected discriminator:** cgc / both → `mcp>0`, find `taskDuration`, PASS. baseline / serena → cannot reach ai-server, must guess → FAIL (or add a wrong-named field). This is the first task that should make the graph earn its keep.

**⚠ Load-bearing setup (A3 breaks without it):** (1) ai-server commit `8f404d9` must be present (the `taskDuration` field); (2) ai-server must be **re-indexed into Neo4j** after that commit (`codegraphcontext --database neo4j index groundx-rnd/ai-server --force`). If Neo4j is wiped or ai-server is reset, redo both before running A3. A2 is left unchanged for contrast.

## Tool-availability verification (why `mcp=0` is a real choice, not a block)

**Verified 2026-06-29.** Before trusting any `mcp=0` result we confirmed the MCP tools are actually offered to the model in the benchmark harness:

- A forced probe (`claude -p "call mcp__codegraphcontext__find_code …"` with the exact arm flags) **succeeded** — the model called `mcp__codegraphcontext__find_code` and got a real graph result (20 `NewClient` definitions). The same probe with `serena.json` **succeeded** via `mcp__serena__find_symbol`.
- Therefore the tools are available and functional; `mcp=0` across R1–R3 means the model **declined** them on easy single-repo tasks, not that they were blocked or disconnected.

**⚠ Do not judge MCP availability from the stream-json `system/init` snapshot.** In headless `claude -p` mode that snapshot shows each MCP server as `status: "pending"` and lists **zero `mcp__` tools** in its `tools` array — *even when the tools are in fact available and callable later in the same session* (servers connect asynchronously after init and no "connected" event is re-emitted). The only reliable availability signals are (a) an actual `mcp__*` `tool_use` in the transcript, or (b) a forced-call probe. `dryrun-isolation.sh` checks server *names* in the init snapshot (necessary: proves the right config loaded + isolation holds) but that is **not** proof of connection. Callability is now a standing pre-flight check: **`poc/probe-mcp.sh`** forces a real `mcp__*` call per arm and asserts it lands — it must pass before any `mcp=0` result is trusted. (Process note: this check was added 2026-06-29 *after* R1–R3; those runs were retro-verified with the same probe and re-run to confirm — see the per-task `runs/*.md`.)

## Status as of R1 (×3) + R2 (×3) + R3 (×2) — single-repo tasks only

> **Post-verification reruns (2026-06-29):** after adding `probe-mcp.sh` and *proving* the graph/LSP tools are callable, all of R1–R3 were re-run. **Result: nothing changed — `mcp=0` in every one of the 32 single-repo cells (8 task-runs × 4 arms).** This is the definitive confirmation: the model declines the graph on easy in-repo tasks *by choice*, not because the harness blocked it. Conclusions below are unchanged and now rest on a verified harness. (R3's earlier cgc/serena failures did not reproduce — run-variable correctness, not an arm effect; see [`runs/R3.md`](runs/R3.md).)

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

## ⚠ Quality audit — "passed the oracle" ≠ "equal-quality result" (added 2026-06-29)

Prompted by the question "how do you ensure all four arms produced the same/quality result?", we audited *what each arm actually did* (not just pass/fail) via `poc/quality-audit.sh` + transcript inspection. Two real problems surfaced:

**1. Weak oracles pass quality differences (A2).** All four arms "passed" A2, but the actual edits differed: baseline added `EngineVersion **string**` while cgc/serena/both added `EngineVersion ***string**`. With `omitempty`, the value-type version can't distinguish absent-vs-empty and is inconsistent with the struct's other optional fields (all `*string`). The oracle (`grep 'json:"engineVersion'` + `go build`) can't see the difference — so a lower-quality change scored an identical pass.

**2. R1–R3 are gameable via git (critical).** The real-commit bug is injected as an *uncommitted* reverse-apply, leaving a git-visible fingerprint. On R3, **3 of 4 arms (baseline, cgc, both) did not debug the bug at all** — they ran `git diff`, then `git checkout HEAD -- oauth.go` / `git stash` to revert our injection, restoring the shipped fix for free. Only serena genuinely fixed it (6 edits). `go test` reports `oracle_pass=1` for all four regardless. So R3's pass-rate and cost/efficiency numbers are contaminated (they partly measure "did the arm think to git-revert," which is cheap, vs genuine debugging, which is expensive) — NOT graph-vs-grep. R1/R2 were fixed directly this time but are equally gameable (luck, not safety). The `mcp=0` graph-adoption finding is unaffected.

**Implications for reading the results:**
- Rank/efficiency comparisons on R1–R3 are unreliable wherever git-gaming occurred (confirmed on R3).
- "All arms passed" must never be reported without the per-arm quality audit (files changed, edit type, git-gaming check, mcp usage).

**Fixes (not yet applied):**
- **R1–R3:** inject the bug as a **commit** so `HEAD` holds the buggy code (`git checkout HEAD` then restores the *bug*, forcing a genuine fix); or strip `.git` / deny `git checkout` during the cell.
- **A2/A3:** tighten the oracle to assert the field *type* (`*string` + `omitempty`), not just the json tag.
- **A4:** score *precision* (penalize wrong files), not just recall.
- **General:** `poc/quality-audit.sh <TASK>` is now part of result review — run it before trusting any cross-arm comparison.

## Fixes applied before the next fresh run (2026-06-29)

The quality audit above drove four harness fixes (all dry-run validated):

1. **R1–R3 anti-gaming — hide `.git` from the agent.** `run.sh` now moves `cashbot-go/.git` aside for the duration of the `claude -p` call (restored before the oracle/restore, and by the EXIT trap on crash). Setup still uses git *before* hiding. With no `.git`, the agent cannot `git checkout`/`log`/`stash` to recover the shipped fix — it must genuinely fix the code. (Committing the bug was insufficient: the fix lives throughout history, so `git checkout <fixcommit>` would still recover it; only removing VCS access works.)
2. **A2 oracle — assert pointer type.** Now requires `*string` + `json:"engineVersion,omitempty"`, not just the json tag (catches the baseline `string` quality miss).
3. **A3 oracle — assert pointer int.** Requires `*int`/`*int64` + `json:"taskDuration,omitempty"`.
4. **A4 — fixed ground truth + diagnostic precision.** Ground truth regenerated at the *stable* transitive closure (`CALLS*1..12` → 30 files; depth-5 had undercounted at 29). Recall ≥0.8 still gates PASS; **precision is now computed (from list-only answer lines) and reported as a diagnostic, but NOT gated** — the GT is the graph's *static* CALLS closure, which misses dynamic dispatch (so an agent may legitimately list more) and is circular-favoring cgc, making a precision gate unfair. Precision appears in the result NOTE for human review.

**Quality-review process going forward:** after any run, `bash poc/quality-audit.sh <TASK>` is mandatory before trusting cross-arm comparisons — it shows files changed, `_test.go`/git-gaming violations, edit type, and mcp usage per arm. "Passed" is necessary but not sufficient.
