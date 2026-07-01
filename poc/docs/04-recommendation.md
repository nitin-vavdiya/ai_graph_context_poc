# Recommendation: CodeGraphContext vs Serena

_Head-to-head guidance from the parity probes and the benchmark. Evidence: [`03-task-runs.md`](03-task-runs.md), [`../PARITY-RECHECK.md`](../PARITY-RECHECK.md). Single run (n=1); treat specifics as directional pending medians._

## Short answer

For this POC's purpose — giving an AI agent retrieval over a **multi-repo** codebase — **CodeGraphContext (the graph) is the better fit than Serena (LSP)**, but only because of two capabilities LSP structurally lacks. For everything else, **neither beats grep**, and the honest recommendation is a **grep-first hybrid** that escalates to the graph on specific triggers.

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
- You need **transitive/structural traversal** (blast radius, "everything that calls X through any chain") — one graph query vs an LSP's dozens of recursive reference lookups. Cheaper and less error-prone (A4).
- Index freshness/build cost matters at scale — tree-sitter indexing is far faster and needs no per-language server.

**Serena wins when:**
- You want **precise, always-current symbol resolution** on code that **is** on disk, with no index-staleness risk (LSP reads live files).
- **Completeness of symbol reach** matters — its LSP found symbols the graph's query missed (the graph is only as complete as its labels/queries).
- You don't want to run and maintain a graph database.

## The honest limits (both tools)

- **Neither derives cross-repo runtime coupling from code.** The service-to-service edges (HTTP/webhook) came from a hand-authored C4 model. Don't expect either tool to trace "cashbot-go calls ai-server" from source.
- **The model won't use either tool unless steered.** On 4 of 6 tasks the agent ignored both and used grep — including a cross-repo task and the arm that had *both* tools available (it still failed A3 by not calling the graph). A retrieval layer the model doesn't invoke is worthless.
- **No token/cost win as a general layer.** The graph only saved cost on the one deep-traversal task, and even there traded a little recall.

## Recommendation

1. **Adopt the graph (CGC over Serena) — selectively.** Use it for the two things it uniquely does: off-disk/cross-repo retrieval and transitive impact analysis. CGC beats Serena here because LSP structurally cannot do off-disk, and has no one-shot transitive op.
2. **Pair it with grep as a hybrid router.** Default to grep/read for on-disk localize-and-fix (where the model already prefers it and it's cheapest). Escalate to the graph on explicit triggers: symbol may be off-disk / in another repo, grep returns 0 or too-many hits, or the task needs transitive callers.
3. **Steer the model explicitly.** The graph only pays off when the prompt/tooling tells the agent *when* to reach for it. "Available" is not "used."
4. **Do not** deploy the graph as a general retrieval layer, and **do not** justify it on token savings.
5. **If you choose Serena instead** (e.g. you want live precision and no DB): accept that it cannot do off-disk retrieval and that transitive traversal is expensive (dozens of reference lookups), and scope it via a parent monorepo project (see [`01-multi-repo-setup-guide.md`](01-multi-repo-setup-guide.md)).

## Enterprise-scale caveat (unresolved)

The motivating problem is ~100 repos / billions of lines; this POC is 6 repos. **Nothing here proves the graph's advantage scales** — the off-disk win and the traversal efficiency were shown at small scale, and the cross-repo edges that would make the graph "enterprise-like" were hand-authored, not derived. Before committing at scale, test: (a) does index build/refresh stay tractable at 100 repos, (b) does automatic cross-repo edge derivation work without a hand-written model, (c) does the model's reluctance to invoke the tool change when grep gets expensive on a huge codebase. These are the open questions a follow-up must answer.
