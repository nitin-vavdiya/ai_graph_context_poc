# Multi-Repo, Remote Deployment & Security — Operational Comparison of the Four Candidate Tools

> **Pre-POC research (2026-06-26).** The POC is now complete; for measured findings see [`../../poc/docs/00-executive-summary.md`](../../poc/docs/00-executive-summary.md).

**Date compiled:** 2026-06-26. **Tools:** CodeGraphContext, codegraph, code-review-graph, Serena. **Purpose:** the *value* these tools give an LLM coding agent is precise structural retrieval and impact analysis (see `context-graph-evaluation.md` §3.6); **this doc covers the separable second axis — how that knowledge is delivered to the agent** across ~100 repos. It compares multi-repo/unified-graph behaviour, cross-repo edges, remote MCP serving, security posture, storage location, and change pickup. Delivery affects *who benefits and how fresh the data is*, not the underlying help — so these are operational selection criteria, not the source of value.

**Evidence labels:** *documented* = stated in project docs/README; *source* = read from the project's source code by a research agent; *inference* = analytical conclusion; *undetermined* = not confirmed. Tool-specific facts are cited inline. This is an operational companion to `context-graph-evaluation.md`; it does not repeat the conceptual foundation or maturity assessment.

---

## 1. Executive Summary

The single most decision-relevant result: **only CodeGraphContext can be both a unified multi-repo store *and* a remotely-served MCP endpoint with a centralized database.** The other three are local-first by design — they either cannot serve over a network at all (codegraph: stdio-only), bind only to loopback (code-review-graph: `localhost`), or operate on whatever filesystem the server runs on with a remote-code-execution tool surface (Serena). This directly answers the earlier "run it on a remote server, connect local Claude" question: that architecture is viable **only with CodeGraphContext** (and even then it needs an authenticating reverse proxy, because it ships no auth).

A second important correction to an earlier claim: **codegraph *can* index multiple nested repos into one unified graph** (via `includeIgnored` / untracked nested repos at a root) — so "strictly per-repo" was too absolute. But codegraph still cannot be served remotely, so it can only deliver that knowledge to an agent running on the same machine.

A third result that holds across all four: **none of them build genuine cross-repo or cross-service edges.** Where "cross-repo" exists it is either path/name coincidence (CodeGraphContext), federated search across separate graphs (code-review-graph), or limited to TypeScript workspace config (Serena). The connected, cross-service view — where the dashboard's HTTP call resolves into the API server — is not something any of these produce from static parsing; it requires enrichment from architecture/topology sources (`workspace.dsl`, deploy, OpenAPI).

### Decision matrix

| Capability | CodeGraphContext | codegraph | code-review-graph | Serena |
|---|---|---|---|---|
| **Unified multi-repo graph (one store)** | ✅ One DB, many `Repository` nodes | ⚠️ One graph only if indexed at a root (`includeIgnored`); else per-repo | ❌ Per-repo graphs + federated registry | ⚠️ One "project" if you open a parent folder; no graph |
| **Remote MCP serving (local Claude → remote server)** | ✅ FastAPI MCP-over-SSE (`api start`, `0.0.0.0:8000`) | ❌ stdio only | ❌ stdio + **localhost-only** HTTP | ⚠️ HTTP/SSE exists, but operates on the *server's* filesystem |
| **Centralized / shared database** | ✅ External Neo4j (`NEO4J_URI`) | ❌ Local SQLite only | ❌ Local SQLite (relocatable, not shared) | ❌ No persistent graph |
| **Genuine cross-repo edges** | ❌ Coincidental (path/name) | ❌ No | ❌ No (federated search only) | ❌ No (TS workspace config only) |
| **Read-only tool surface** | ⚠️ Read + indexing/mutate graph; Cypher enforced read-only | ✅ Read-only | ⚠️ Read + **file-write refactor tools** | ❌ File-write + **`execute_shell_command`** |
| **Built-in authentication** | ❌ None (wildcard CORS) | ❌ None (local only) | ❌ None (local only) | ❌ None |
| **Multi-repo live watch** | ✅ Multiple paths | ✅ Within the served root tree | ✅ Via `crg-daemon` (per-repo watchers) | ⚠️ Index auto-updates for the active project |

**Verdict for the shared/remote delivery model (one unified store, served from a remote server to local Claude):** CodeGraphContext is the only fit — behind an authenticating reverse proxy, with a remote Neo4j backend, accepting that cross-repo edges are coincidental rather than designed. For local per-developer delivery, all four are viable and the choice is driven by the value metrics (§3.6 of the evaluation doc), not by topology.

---

## 2. CodeGraphContext

Sources: [Shashankss1205/CodeGraphContext](https://github.com/Shashankss1205/CodeGraphContext) · [org mirror](https://github.com/CodeGraphContext/CodeGraphContext) · [cgc.codes](https://cgc.codes) · [PyPI](https://pypi.org/project/codegraphcontext/). Facts marked *source* were read from `main`.

- **Multi-repo / unified graph — yes (*source*).** One database holds many repositories, each a `Repository` node. You add repos one `index` per path; `codegraphcontext list` lists them, `delete <path>` removes one, `update <path>` refreshes one. To build a unified graph of N repos you run `index` N times against the same backend.
- **Pointing at a parent folder (*inference/undetermined*).** `index` walks the directory tree you give it; pointing at a parent of several independent git repos ingests everything **as a single `Repository` rooted at that parent** — it does not appear to auto-detect nested `.git` boundaries and split them. (A separate `context`/`switch_context` mechanism exists for *segregating* logical workspaces into separate DBs — the opposite of unifying.) Verify nested-repo behaviour before relying on it.
- **Repo namespacing (*source*).** Repos are distinguished by **absolute filesystem path**, not an explicit `repo_id` tag. `delete_repository` cascades the `:CONTAINS` tree by path.
- **Cross-repo edges — coincidental, not designed (*source*).** Call/import resolution is **global across all indexed files**: `CALLS`/`IMPORTS` edges are matched by absolute file path + symbol name, not scoped per repo. So if repo A's resolved target path lands on a node from repo B, an edge forms — but this is name/path coincidence, **not** semantic service-to-service/RPC/HTTP linking, and **not** cross-language. Caveat: `delete_repository` does **not** clean up cross-repo `CALLS`/`IMPORTS` edges, which can become dangling after a delete. Treat as effectively per-repo with opportunistic cross-links.
- **Remote deployment — yes, natively (*source*).** Beyond stdio (`mcp start`, for local IDEs), there is a first-party FastAPI gateway: `codegraphcontext api start` exposes **MCP-over-SSE** at `/api/v1/mcp/sse` (+ REST under `/api/v1`, `/health`), defaults `--host 0.0.0.0 --port 8000`. So a local Claude Code can connect to a remote CodeGraphContext server. The **Neo4j backend can also be remote** (`NEO4J_URI`/`NEO4J_USERNAME`/`NEO4J_PASSWORD`), so server and DB can both be centralized.
- **Security (*source*) — high-severity caveat for remote use.** `execute_cypher_query` is **enforced read-only** (keyword/procedure/chaining checks). No shell-execution tool is exposed. **But** the server still exposes graph-mutating and filesystem-watching tools (`add_code_to_graph`, `watch_directory`, `delete_repository`, `load_bundle`), and ships **no authentication** with **wildcard CORS** (`allow_origins=["*"]`, with an inline "restrict in production" comment). Binding `0.0.0.0:8000` unauthenticated gives any reachable client full MCP/REST access including filesystem-watch on the host. **Must be fronted by an authenticating reverse proxy (TLS + authn) and locked-down CORS.** A path-sandbox util exists; its strictness for network callers is undetermined.
- **Storage (*documented/source*).** Embedded FalkorDB Lite (default, Unix/Py3.12+) or KuzuDB (cross-platform fallback) for local; **external Neo4j** for a centralized/shared store. Only the Neo4j (or remote-FalkorDB) path is network-shareable.
- **Change pickup (*source*).** `index` *blocks* re-indexing an already-indexed repo; use `update <path>` to refresh (incremental vs full-rebuild internally is undetermined). `watch <path>` does real-time incremental updates (re-parses only the changed file and its neighbours). **Multi-repo watch is supported** — the watcher tracks multiple paths concurrently (`list_watched_paths`/`unwatch_directory`).

---

## 3. codegraph (colbymchenry)

Sources: [colbymchenry/codegraph](https://github.com/colbymchenry/codegraph) · [README](https://raw.githubusercontent.com/colbymchenry/codegraph/main/README.md) · [docs](https://colbymchenry.github.io/codegraph/).

- **Multi-repo / unified graph — possible at a root (*documented*).** Default is one SQLite DB per project (`.codegraph/codegraph.db` at the project root). **Untracked** nested repos under the root are indexed automatically; for gitignored child repos (a "super-repo of independent clones") you opt them into **one unified graph** with `includeIgnored` in `codegraph.json` (e.g. `{"includeIgnored": ["packages/", "services/"]}`, then re-`index`). Each child is still indexed by its own `git ls-files`. So a single unified graph across nested repos *is* achievable — but it's one graph rooted at the parent, not auto-discovered separate graphs.
- **`projectPath` is a different mechanism (*documented/inference*).** In one session you can query a *separate already-indexed project* by passing `projectPath` — this selects that project's **own DB**, one at a time; it does **not** merge repos into one graph.
- **Cross-repo edges — none documented (*inference*).** Edges are within an indexed tree; codegraph deliberately keeps same-named symbols across sub-apps separate rather than merging. No documented cross-repo link resolution.
- **Remote deployment — no (*source/documented*).** stdio only (`codegraph serve --mcp`). **No HTTP/SSE, host, or port options exist.** Must run locally next to the code; cannot be a remote server for a local Claude.
- **Security (*documented*).** Read-only tool surface (`codegraph_explore`, `codegraph_callers/callees/impact`, etc.); **no file-write, no shell, no auth**; "100% local, nothing leaves your machine." The local DB contains verbatim source. Minimal attack surface precisely because there is no network listener.
- **Storage (*documented*).** Local embedded SQLite per project (or one unified graph at a root). **No centralized/shared-server option.**
- **Change pickup (*documented*).** Auto-sync on by default via native OS file events (FSEvents/inotify/ReadDirectoryChangesW), ~2s debounce (`CODEGRAPH_WATCH_DEBOUNCE_MS`). Watches the served project tree (so nested children under a unified root are covered). Manual `codegraph sync` (incremental) / `codegraph index` (full).

---

## 4. code-review-graph (tirth8205)

Sources: [tirth8205/code-review-graph](https://github.com/tirth8205/code-review-graph) · [README](https://raw.githubusercontent.com/tirth8205/code-review-graph/main/README.md) · `docs/COMMANDS.md`, `docs/USAGE.md`, `docs/FAQ.md`, `SECURITY.md`.

- **Multi-repo / unified graph — no, federated (*documented*).** Strictly **one graph per repository root** (`.code-review-graph/graph.db`); `build` auto-detects the root by walking up to the nearest `.git`. Multi-repo is a **registry** (`~/.code-review-graph/registry.json`, via `register`/`repos`/`unregister`) plus MCP tools `list_repos_tool` and `cross_repo_search_tool` that operate **across separate per-repo graphs** — a federated search, not a merged graph.
- **Cross-repo edges — none (*inference*).** Edges exist only within each repo's graph; `cross_repo_search_tool` is search-level federation, not graph-level linkage.
- **Remote deployment — effectively no (*documented*).** Transports are stdio (default) and **Streamable HTTP bound to `localhost:5555`**. No `--host`/`--port` to bind a non-loopback interface is documented. Not designed for remote serving; remote use would require a user-built tunnel/proxy and would be unauthenticated. (The GitHub Action runs in CI, separate from the MCP server.)
- **Security (*documented*).** Read-*mostly*, but exposes **file-write refactor tools** (`refactor_tool`, `apply_refactor_tool` — the latter writes files, with `dry_run` for diff-only). No shell-execution tool; git commands use list args (`shell=False`). **Cloud embeddings are the one opt-in data-egress path** (Gemini/MiniMax/OpenAI-compatible), gated by `CRG_ACCEPT_CLOUD_EMBEDDINGS=1`; default embeddings are local (`all-MiniLM-L6-v2`). **No server authentication** — threat model is explicitly a local dev tool.
- **Storage (*documented*).** Local SQLite per repo; relocatable via `--data-dir`/`CRG_DATA_DIR` (even to a network share), but that relocates one repo's DB — **not** a centralized merged store.
- **Change pickup (*documented*).** Incremental `update` via SHA-256 diffing (re-parses only changed files, <2s); `watch` (single-repo); **`crg-daemon`** is the multi-repo mechanism — watches each registered repo as a separate child process (30s health checks), still maintaining separate graphs.

---

## 5. Serena (oraios)

Sources: [oraios/serena](https://github.com/oraios/serena) · [docs](https://oraios.github.io/serena/). (Established in prior research; summarized here for completeness.)

- **Multi-repo — one active project; "monorepo folder" pattern (*documented*).** Only one project is active at a time; in `claude-code`/`ide` context, project switching (`activate_project`) is **disabled** — you work the single open project. The documented way to span repos is to open a **parent folder containing them as sub-folders** as one project. There is **no persistent graph** — Serena resolves symbols live via language servers.
- **Cross-repo edges — limited (*documented*).** The language server "only sees symbols within the project root"; cross-package references require `additional_workspace_folders` in `project.yml`, **currently TypeScript-only**. So cross-repo *semantic* resolution generally does not work across independent, mixed-language repos; file-level search across the tree does.
- **Remote deployment — possible but filesystem-bound (*documented*).** Serena supports an HTTP/SSE transport, but it **operates on the filesystem where the server runs** — remote Serena sees and edits the *remote* code copy, not your local working tree. Only coherent if the canonical code lives on the remote.
- **Security — highest-risk to expose (*documented*).** Serena exposes file read/write **and `execute_shell_command`**. Network-exposing it is effectively remote code execution as a service; no built-in auth. Must be tunnelled (SSH)/VPN'd, never on an open port.
- **Storage (*documented*).** No persistent graph store; per-project `.serena/project.yml` config; the "index" is LSP-derived and auto-updates as files change for the active project.

---

## 6. Implications for Delivering Code Context to the LLM

The *value* (precise retrieval + impact analysis) is what helps the agent; **delivery** decides how that value reaches it and who shares it. The delivery models split into three: **(a) local per-developer** (each dev runs the tool next to their code), **(b) one unified index** (all repos in a single graph), and **(c) a shared server** (local or remote) that many agents/devs query. Mapping the findings to those models:

- **CodeGraphContext is the only candidate that supports all three, including a shared/remote server:** one DB across many repos (*unified*), an external Neo4j (*centralized/shared*), and a native MCP-over-SSE server (*remote-served*). The non-negotiable conditions for the server model: put it **behind an authenticating TLS reverse proxy** with restricted CORS (it has neither), and accept that **cross-repo edges are path/name coincidence, not designed cross-service links**.
- **codegraph** supports models (a) and (b) — a unified graph via `includeIgnored` at a root, lowest-ops — but is **stdio-only**, so it cannot be a shared/remote server; it runs locally next to the code (great for the single-developer experience).
- **code-review-graph** is per-repo + federated search, **localhost-bound** → models (a) and a federated form of (b); not a shared remote server. Best suited to its specialty (PR review / change-impact, including CI).
- **Serena** delivers value model (a) only — local, on-demand, one project at a time; **no graph and no safe remote story** (filesystem-bound + shell execution).
- **The cross-repo/cross-service relationships** (e.g. `groundx-ai-dashboard` → `groundx-ai-middleware` → `ai-server` over HTTP) **will not be produced by any of these from code alone**, regardless of delivery model. They must be added by enriching the graph from non-code sources you already have — `workspace.dsl` (C4), `docker-compose.yml`/`deploy`, OpenAPI specs, dependency manifests. The tool gives intra-repo depth; the topology comes from those artifacts.

### Net recommendation for the delivery PoC

If you want the shared/remote delivery model, stand it up as **CodeGraphContext on a remote server with a remote Neo4j**, fronted by an auth proxy, indexing the related cluster first (`ai-server`, `groundx-python`, `groundx-typescript`, `groundx-ai-middleware`, `groundx-ai-dashboard`). Validate three things explicitly: (1) whether cross-repo queries return anything useful given edges are coincidental; (2) whether pointing `index` at a parent vs per-repo gives a better graph; (3) the security envelope (proxy + auth + CORS) before any non-local exposure. Keep **codegraph** as the local-only, zero-ops comparison and **Serena** as the on-demand control — neither can serve a shared remote endpoint. Crucially, measure all of them against the **value metrics** in `context-graph-evaluation.md` §3.6 (tokens/change, tool-calls/change, latency, edit correctness) versus a plain-Claude-Code baseline — delivery model is only worth optimizing once the value is proven.

---

## 7. Open Items to Verify in the PoC

- CodeGraphContext: exact behaviour of `index` on a parent folder of nested git repos (one `Repository` vs split); whether `update` is incremental or full rebuild; strictness of the path sandbox for network callers; usefulness of coincidental cross-repo edges; dangling-edge cleanup after `delete_repository`.
- codegraph: whether the watcher auto-syncs non-root `projectPath` targets; behaviour and performance of a large `includeIgnored` unified graph.
- code-review-graph: whether `serve --http` can bind a non-loopback interface via any undocumented flag/env; internal behaviour of `cross_repo_search_tool` (pure fan-out vs any cross-repo resolution).
- Serena: Go/PHP language-server coverage for this repo set; cost/accuracy of opening the whole parent folder as one project across mixed languages.
- No secrets or PII were encountered during this research.
