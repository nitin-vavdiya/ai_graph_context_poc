# Recommendation: CodeGraphContext vs Serena

_Head-to-head guidance from the parity probes and the benchmark. Evidence: [`03-task-runs.md`](03-task-runs.md), [`../PARITY-RECHECK.md`](../PARITY-RECHECK.md). A2/A3/A4 are 3-run medians; R1–R3 single-run._

## Short answer

There is no single overall winner — it's conditional — but two calls are clear-cut:

- **Serena (LSP) is the clear loser.** No task where it uniquely wins; it *reliably fails* A2 (0/3, worse than plain grep on on-disk code); the model invoked it in only 1 of 6 tasks. **If you add one tool, it is never the LSP.**
- **CodeGraphContext (graph) is the clear winner *when a structural tool is needed*** — it is the only arm that can retrieve off-disk/cross-repo code (A3), which grep and LSP structurally cannot, and it needs far fewer tool calls for transitive traversal. cgc > serena, unambiguously.
- **grep (baseline) is the workhorse** — it wins or ties every on-disk task (R1, R2, A2), is cheapest/competitive, and is what the model reaches for by default.

So for this POC's purpose — giving an AI agent retrieval over a **multi-repo** codebase — the recommendation is a **grep-first hybrid**: default to grep, add **CodeGraphContext** as a narrow escalation for off-disk/cross-repo and deep-traversal queries, and steer the model to it explicitly. Do not adopt Serena.

## Capability parity (matched probes, identical task, only the tool differs)

| dimension | CGC (graph) | Serena (LSP) | winner |
|---|---|---|---|
| symbol lookup, single repo | ✅ | ✅ | tie |
| symbol lookup, **across repos** | ✅ (one query, all repos) | ✅ (parent project, once indexed) | tie |
| multi-repo *reach* completeness | found 2 repos (missed TS interfaces — `Class`-only query) | found all 4 repos/langs | **Serena** |
| **transitive callers** (one op) | ✅ one `CALLS*` query | ✗ no transitive op — manual BFS (48–65 ref lookups) | **CGC** (efficiency) |
| **off-disk retrieval** (repo not on disk) | ✅ from the pre-built graph | ✗ LSP needs files on disk | **CGC** (capability) |
| cross-repo *reference* tracing (Go/Python) | via hand-authored edges only | ✗ cross-workspace refs are TS-only | tie (neither derives it from code) |
| index build speed | fast (tree-sitter, ~min) | slow (per-language LSP; gopls dominated ~13 min) | **CGC** |
| setup burden | Neo4j + tree-sitter + `--database` flag + enrich | per-lang servers + `languages` + dashboard-off + long index | **CGC** (fewer sharp edges) |

## Where each wins

**CodeGraphContext wins when:**
- The relevant code is **not on the developer's disk** (another repo, not checked out) — a pre-built central index is the *only* thing that reaches it. This is the decisive, unique win (A3).
- You need **transitive/structural traversal** (blast radius, "everything that calls X through any chain") — **far fewer tool calls**: 2–5 graph queries vs the LSP's 60–66 recursive reference lookups (it has no transitive operator). Note: fewer calls did **not** mean lower $ or tokens (A4 cost was noise-dominated; cgc's average cost was actually the highest) — the win is call-count and simplicity, not cost.
- Index freshness/build cost matters at scale — tree-sitter indexing is far faster and needs no per-language server.

**Serena wins when:**
- You want **precise, always-current symbol resolution** on code that **is** on disk, with no index-staleness risk (LSP reads live files).
- **Completeness of symbol reach** matters — its LSP found symbols the graph's query missed (the graph is only as complete as its labels/queries).
- You don't want to run and maintain a graph database.

## The honest limits (both tools)

- **Neither derives cross-repo runtime coupling from code.** The service-to-service edges (HTTP/webhook) came from a hand-authored C4 model. Don't expect either tool to trace "cashbot-go calls ai-server" from source.
- **The model won't use either tool unless steered.** On 4 of 6 tasks the agent ignored both and used grep — including a cross-repo task and the arm that had *both* tools available (it still failed A3 by not calling the graph). A retrieval layer the model doesn't invoke is worthless.
- **No token/cost win as a general layer.** Over 3 runs the graph saved nothing on cost — on the one deep-traversal task (A4) its *average* cost was the highest of the four arms. Its only reproducible efficiency edge is tool-call count.
- **Serena's arm can actively hurt.** On A2 (cross-repo, both repos on disk) the Serena arm **failed all 3 runs** while grep-based arms mostly passed — adding the LSP tool correlated with worse outcomes on a task where grep sufficed.

## Recommendation

1. **Adopt the graph (CGC over Serena) — selectively.** Use it for the two things it uniquely does: off-disk/cross-repo retrieval and transitive impact analysis. CGC beats Serena here because LSP structurally cannot do off-disk, and has no one-shot transitive op.
2. **Pair it with grep as a hybrid router.** Default to grep/read for on-disk localize-and-fix (where the model already prefers it and it's cheapest). Escalate to the graph on explicit triggers: symbol may be off-disk / in another repo, grep returns 0 or too-many hits, or the task needs transitive callers.
3. **Steer the model explicitly.** The graph only pays off when the prompt/tooling tells the agent *when* to reach for it. "Available" is not "used."
4. **Do not** deploy the graph as a general retrieval layer, and **do not** justify it on token savings.
5. **If you choose Serena instead** (e.g. you want live precision and no DB): accept that it cannot do off-disk retrieval and that transitive traversal is expensive (dozens of reference lookups), and scope it via a parent monorepo project (see [`01-multi-repo-setup-guide.md`](01-multi-repo-setup-guide.md)).

## Enterprise-scale caveat (unresolved)

The motivating problem is ~100 repos / billions of lines; this POC is 6 repos. **Nothing here proves the graph's advantage scales** — the off-disk win and the traversal efficiency were shown at small scale, and the cross-repo edges that would make the graph "enterprise-like" were hand-authored, not derived. Before committing at scale, test: (a) does index build/refresh stay tractable at 100 repos, (b) does automatic cross-repo edge derivation work without a hand-written model, (c) does the model's reluctance to invoke the tool change when grep gets expensive on a huge codebase. These are the open questions a follow-up must answer.
