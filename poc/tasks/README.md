# Benchmark Task Definition

What we run the 4 arms (baseline / CGC / Serena / both — see design doc §4.1) against. Start with **4 tasks** (one per scenario, plus an easy/hard pair for cross-repo) to validate the whole harness end-to-end, then expand. Oracle = run the repo's own tests (design §4.4); isolation per design §4.5; metrics per `../../docs/research/context-graph-evaluation.md` §3.6.

## Why these repos

The oracle is "run tests", so tasks live where tests run green locally (verified 2026-06-26):

- **cashbot-go** — builds clean (go 1.26.3); `pkg/formatter*`, `pkg/link`, `pkg/config` test **green** with no external services. The testable hub → scenarios B and C live here.
- **ai-server** — has tests but Detectron2/GPU deps make local runs risky → used only as the *source* end of the cross-repo task (scenario A), scored by completeness, not by running its tests.

## Task schema (`tasks.jsonl`, one JSON object per line)

```json
{
  "id": "A1",
  "scenario": "cross_repo_blast_radius | in_repo_impact | locate_and_fix",
  "repos": ["cashbot-go", "ai-server"],
  "run_dir": "groundx-rnd/cashbot-go",
  "prompt": "the exact instruction given to the agent — identical across all 4 arms",
  "setup": "git/precondition steps to reach a known green baseline (e.g. apply a seeded bug)",
  "oracle": {
    "test_cmd": ["go test ./pkg/formatter/..."],
    "must_change": ["file:symbol that a correct edit must touch"],
    "regression_cmd": ["go test ./..."]
  },
  "stresses": "cost | time | quality",
  "ground_truth_notes": "what a correct, complete change looks like (for human rating)"
}
```

`prompt` is **identical across arms** — only the available tools differ. `run_dir` is where `claude -p` is launched (Serena activates the repo from cwd).

## The three scenarios

| Scenario | Task shape | Oracle | Metric stressed | Expected arm ordering (hypothesis) |
|---|---|---|---|---|
| **A. cross-repo blast-radius** | A field in ai-server's layout webhook payload is renamed/added; update the cashbot-go consumer to match | completeness (found + edited the correct cashbot-go struct/handler) + cashbot-go tests for that area if green; **ai-server tests not run** | Quality (completeness), Cost | CGC / both > baseline > Serena (can't span) |
| **B. in-repo impact** | Change an exported function's signature in a green cashbot-go package; update every call site | `go test` on affected packages must pass + all call sites updated | Quality, Cost | CGC / Serena / both > baseline |
| **C. locate-and-fix** | A seeded one-line bug fails an existing test; "tests in pkg X fail — find and fix" | the package's `go test` goes red→green | Time, Cost (find-cost) | tools > baseline if structure beats grep |

**Honesty on A:** its downstream end (ai-server) may not build locally, so A is scored mainly on completeness + "did it find the right repo/file" + cost/time, with test-pass only on the cashbot-go end. B and C run entirely in cashbot-go for an airtight `go test` oracle.

## Scoring per run

- **Correctness** — oracle `test_cmd` exit 0 (and `regression_cmd` still green).
- **Completeness** — every entry in `must_change` actually changed (and no required call site missed).
- **Cost** — `usage` input+output (and cache) tokens from the JSON result.
- **Time** — `num_turns` / tool-call count (from stream-json `tool_use` events) + `duration_ms`.
- **Outcome** — `is_error`, plus pass/fail of correctness + completeness.

Each task runs once per arm (4 runs/task); record raw JSON per run for audit.

## Harness-validation goal (the "start tiny" step)

Before scaling the corpus: run all 4 tasks × 4 arms once (16 runs), confirm the runner (a) applies setup/green baseline, (b) launches each arm with the right isolation flags, (c) captures tokens/turns/is_error, (d) runs the oracle and records pass/fail, (e) restores the repo to clean state between runs. Only once that loop is trustworthy do we expand to ~2–3 tasks per scenario.

## Concrete tasks (3 — grounded + verified 2026-06-26)

See `tasks.jsonl`. All anchors are real symbols in green-testing code.

- **C1 — locate-and-fix (call-chain).** Seed a one-line bug in a *deep callee*: `pkg/link/hmac.go:calcHmac` (flip the `"&"` separator to `","`). Task = "`go test ./pkg/link` fails, find & fix". The failing test (`TestIsValid`/`ExampleRec_link_simple`) is in `link_test.go`; the cause is in a **different file** (`hmac.go`) reached via `IsValid → calcHmac`, and the symptom (wrong HMAC digest) never names `calcHmac` → the agent must trace the call chain (CGC `call_chain` / Serena go-to-def vs blind grep). Oracle `go test ./pkg/link` red→green. **Verified.**
- **B1 — in-repo impact.** Add a `secure bool` param to `(Upload).BaseURL()` (`pkg/config/upload.go:34`) and update **all ~20 call sites**. Oracle = `go build ./pkg/...` (green) + `go test ./pkg/config/...` + completeness via `grep '\.BaseURL()'` == 0 + a **behavior fixture** (`fixtures/B1_baseurl_behavior_test.go.txt`, injected post-edit) asserting the https/http scheme. Tests find-all-references vs grep.
- **A1 — cross-repo (easy/greppable control).** ai-server renames webhook field `resultURL`→`resultUri`; update the cashbot-go consumer (`pkg/model/services/response.go:Response.ResultURL` JSON tag). Oracle = completeness on the tag + `go build ./pkg/...`. The shared field name is greppable, so we **expect arms to roughly tie** — this validates the cross-repo harness and measures cost.
- **A2 — cross-repo (hard/relational discriminator).** ai-server *adds* a new field `engineVersion`; find the consuming service and add the field to its `Response` struct. The new name is **absent from cashbot-go (verified 0 hits) → not greppable there**, so the agent must trace the service relationship (ai-server layout webhook → cashbot-go). CGC's `CALLS_SERVICE` edge answers directly; baseline must infer (callbackURL → api.groundx.ai = cashbot-go); Serena can't span repos. Oracle = `Response` has the new field + `go build ./pkg/...`. **A1 vs A2 contrast = where the graph helps vs where grep already suffices.**

### Oracle facts established
- cashbot-go builds (go 1.26.3); `go build ./pkg/...` is green. (`go build ./...` is **not** — `lambda/*` & some `cmd/*` need `go generate` first; avoid whole-repo build as an oracle.)
- Green test packages with no external services: `pkg/formatter*`, `pkg/link`, `pkg/config`. (`pkg/copy`, `pkg/files` need a config file — excluded.)
- Webhook decode path (for A1/A2): `lambda/DocumentLayoutWebhook/main.go` wires `documentlayout.Handler`; the JSON unmarshal into `services.Response` is at `pkg/processor/documentlayout/handler.go:148`; struct at `pkg/model/services/response.go:16`.
