# Benchmark Task Definition

What we run the 4 arms (baseline / CGC / Serena / both) against. The corpus is **3 real historical bugfixes** replayed from `cashbot-go`'s git history (R1–R3) plus **3 constructed tasks** for the graph thesis: A2 (cross-repo, both repos on disk), A3 (cross-repo, target repo parked off-disk), A4 (transitive impact set). Oracle = run the repo's own tests (R-tasks) or a build/completeness/recall check (A-tasks). Task definitions + results: [`../docs/03-task-runs.md`](../docs/03-task-runs.md); isolation: [`../docs/02-poc-setup.md`](../docs/02-poc-setup.md).

## Why real commits

Earlier drafts used synthetic tasks (seed-a-bug, mechanical refactor, hypothetical field renames). They were replaced with **actual shipped commits** so the corpus reflects real development work, scored by the developers' own tests — the SWE-bench method.

**Replay method (per real task):**

1. Pick a real commit that fixed a bug/added behavior *and shipped with a test*, in a package that builds + tests green locally with no external services.
2. **Setup:** reverse-apply the commit's **code** change at HEAD (`git show <sha> -- <code_files> | git apply -R`) — this recreates the original bug. The commit's **test stays at HEAD** (the spec).
3. **Prompt:** the symptom/requirement (not the fix).
4. **Oracle:** the package's `go test` goes red→green.

Each candidate is vetted: no drift since the commit, reverse-apply is clean, and the test is verified to go RED after reverse and GREEN after restore.

## Repos

Oracle is "run tests", so tasks live where tests run green locally (verified 2026-06-26):

- **cashbot-go** — builds (go 1.26.3); the real-commit tasks live in packages that test green with no services (`pkg/partner/partners/groundx`, `pkg/mcp`).
- **ai-server** — GPU/Detectron2 deps make local test runs unreliable → used only as the *source* end of the cross-repo task (A2), scored by completeness, not by running its tests.

## The corpus

| # | Kind | Task (symptom given to the agent) | Real commit | Oracle | Stresses |
|---|---|---|---|---|---|
| **R1** | real bugfix | Partner MCP tool executions sometimes fail to decode the response (`failed to parse MCP execution response`) — fix it | `2548ec43` *Fix MCP execution response decoding* | `go test ./pkg/partner/partners/groundx` | Time (find) |
| **R2** | real bugfix | Partner accounts are exposed a shadowed customer MCP tool — hide it for partners | `5be28304` *Hide shadowed customer MCP tool for partners* | `go test ./pkg/mcp` | Quality |
| **R3** | real bugfix | Valid OAuth token requests wrongly rejected `invalid_grant` on resource-URL mismatch — fix normalization | `618633ec` *oauth fixes* | `go test ./pkg/partner/partners/groundx` | Time (find) |
| **A2** | constructed | ai-server adds webhook field `engineVersion`; find the consuming service and add it | — (service-level coupling; no single-commit equivalent) | `go build ./pkg/...` + field present | Time (cross-repo find) |

All three real bugfixes were verified red→green on 2026-06-26. A2 is kept constructed because a genuine cross-repo change does not land as one commit with one test suite (the coupling is service-level) — it is the graph discriminator: `engineVersion` is absent from cashbot-go (not greppable), so the agent must trace ai-server → cashbot-go.

## What we ask Claude (verbatim)

The exact prompt handed to Claude (identical across all 4 arms). It states the **symptom/requirement, not the fix** — locating and understanding the code is the agent's job.

**R1 — we ask:**
> "In the GroundX partner integration, executing an MCP tool sometimes fails to decode the upstream response (error: failed to parse MCP execution response). Diagnose the cause and fix the response handling so MCP tool executions decode correctly. Don't modify any test file."

→ kind of change: **a bug fix** — Claude edits `pkg/partner/partners/groundx/mcp.go` to decode the response properly.

**R2 — we ask:**
> "For partner MCP accounts, an auto-generated tool is being exposed that duplicates a partner-specific tool; partner accounts should not see it. Update the per-account tool registration so the shadowed operation is hidden for partners. Don't modify any test file."

→ **a behavior fix** — Claude edits `pkg/mcp/mcp.go` to filter out that tool.

**R3 — we ask:**
> "Valid OAuth token requests are sometimes rejected with invalid_grant because the resource URL doesn't match when it differs only by normalization. Fix the OAuth grant handling so resource URLs are compared correctly. Don't modify any test file."

→ **a bug fix** — Claude edits `pkg/partner/partners/groundx/oauth.go` to normalize URLs before comparing.

**A2 — we ask:**
> "The ai-server webhook is adding a new field engineVersion. Find the service that consumes this webhook and add the field so it's decoded."

→ **a small feature/change spanning repos** — Claude adds a field to the consumer struct (`pkg/model/services/response.go`).

> These prompts are paraphrased here for reading; the exact strings the runner sends live in [`tasks.jsonl`](tasks.jsonl) (`prompt` field).

## Task schema (`tasks.jsonl`, one JSON object per line)

```json
{
  "id": "R1",
  "kind": "real_commit | constructed",
  "scenario": "bugfix | cross_repo_blast_radius",
  "repos": ["cashbot-go"],
  "run_dir": "groundx-rnd/cashbot-go",
  "commit": "2548ec43",                       // real_commit only
  "code_files": ["pkg/.../mcp.go"],            // real_commit only: reverse-applied at setup
  "test_pkg": "./pkg/partner/partners/groundx",
  "prompt": "the symptom/requirement — identical across all 4 arms",
  "oracle": { "test_cmd": ["..."], "regression_cmd": ["..."] },
  "stresses": "time | quality | cost",
  "source": "...", "ground_truth_notes": "..."
}
```

`prompt` is **identical across arms** — only the available tools differ. The runner reads `kind`/`commit`/`code_files`/`test_pkg` to drive setup and the oracle generically.

## Scoring per run

- **Correctness** — oracle `test_cmd` exit 0 (and `regression_cmd` green).
- **Completeness** — for real tasks, equal to test-pass; for A2, the new field is present.
- **Cost** — `usage` input+output (and cache) tokens from the run JSON.
- **Time** — `num_turns` / tool-call count (stream-json `tool_use` events) + `duration_ms`.
- **Outcome** — `is_error` + pass/fail.

Each task runs once per arm (4 runs/task); raw JSON per run kept for audit.

## Oracle facts established

- cashbot-go builds (go 1.26.3). Real-task packages (`pkg/partner/partners/groundx`, `pkg/mcp`) test green with no services. `go build ./...` (whole repo) is **not** green (needs `go generate`) → A2 uses `go build ./pkg/...`.
- Webhook decode path (A2): `lambda/DocumentLayoutWebhook/main.go` wires `documentlayout.Handler`; the JSON unmarshal into `services.Response` is at `pkg/processor/documentlayout/handler.go:148`; struct at `pkg/model/services/response.go:16`.

## Runner (`../run.sh`)

```bash
bash poc/run.sh --dry                          # validate plumbing, no Claude calls
bash poc/run.sh --tasks R1 --arms baseline     # one real cell
bash poc/run.sh                                # full matrix: 4 tasks × 4 arms
```

Per cell it snapshots the repo (preserving pre-existing local state), applies the task setup (reverse-applies the real commit for R-tasks), launches Claude with that arm's isolation flags + MCP config, parses `usage`/turns/tool-calls/`is_error`, runs the oracle, appends to `results/results.csv`, generates `runs/<TASK>.md`, and restores. Raw logs + `results/` are gitignored (groundx-rnd code). Validated 2026-06-26 (dry: all 4 pass; real cell proven earlier).
