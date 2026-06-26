# Context Graphs for AI-Assisted Development at Enterprise Scale — Research & Decision-Support Report

**Status:** Research-and-decision stage (hands-on PoC deferred). **Date compiled:** 2026-06-26. 

**Scope:** ~100 repositories, billions of lines of code, agentic/AI-assisted development. 

**Adoption constraint:** permissive open-source only (MIT / Apache-2.0 / BSD or similar); copyleft (GPL/AGPL) and proprietary/source-available tools are background context only, never recommended.

**A note on evidence.** Tool-specific facts were gathered via the GitHub REST API and project documentation by parallel research agents and are cited inline. Claims drawn from documentation are labelled as documented; analytical conclusions are labelled **(inference)**. No benchmarks, version numbers, or licenses were invented; where a figure is secondhand or unverifiable it is flagged as such. Two of the surveyed tools have star counts that are very high relative to their age (created in 2026); these were reported as API-consistent by the research agents but are flagged below as warranting one independent re-check before being treated as load-bearing.

---

## 1. Executive Summary & Recommendation

The core problem is real and well-supported by primary research: feeding code to AI agents by dumping files or repositories is expensive, slow, and actively degrades answer quality once the prompt grows large. Bigger context windows and cheaper/cached tokens do not solve it — they reduce price and latency but not the quality decay (documented as "lost in the middle" and "context rot"; see §3). The effective lever is **high-precision, high-recall context selection**, and a **code knowledge graph served to agents over MCP (Model Context Protocol)** is one of the strongest structural ways to achieve that selection, because code is natively a graph of definitions, calls, imports, and type relationships that flat-text and embedding-only retrieval discard.

Both candidate tools are credible, permissively licensed, MCP-native instances of this pattern, and both are young and effectively single-maintainer.

- **CodeGraphContext** (MIT) — a purpose-built, general code-context-graph MCP server + CLI. Multi-backend graph storage with **Neo4j/Cypher as a first-class enterprise path** (plus embedded FalkorDB/Kuzu options), tree-sitter parsing across ~23 languages, optional SCIP for higher precision. Its architecture is the better structural fit for **large-scale, general-purpose** code understanding.
- **code-review-graph** (MIT) — a local-first (SQLite) MCP server whose retrieval is explicitly **token-budget-aware** (minimal-context and review-context tools with configurable budgets and context-savings metadata). Its design is the most **directly aligned with the token-cost objective**, but it is framed around code review, uses an embedded store whose scaling to billions of LOC is unproven, and its headline token-reduction benchmarks have been contested even by the project itself.

### Recommendation: take a small PoC shortlist forward, not a single tool

No tool in this space has public evidence of operating at ~100 repos / billions of LOC, so a PoC at representative scale is mandatory before any commitment **(inference)**. The **final shortlist is four tools, all MIT-licensed** — three persistent-graph contenders plus one on-demand control. Run a head-to-head on a representative subset of repositories with:

1. **CodeGraphContext (MIT)** — *persistent graph, server-grade scale path.* Its first-class Neo4j/Cypher backend is the most credible route to enterprise-scale graph storage and multi-hop queries, and it is the most direct match to "general code-context graph over MCP." The pick when scale matters more than ops simplicity.
2. **codegraph (MIT)** — *persistent graph, lowest-ops.* Embedded SQLite ("100% local", nothing to run), explicit token-reduction focus, and the broadest harness support (Claude Code, Codex, Gemini, Cursor, OpenCode, etc.). The most momentum-backed (~54.8k★) of the set, but young (~5 mo, v1.0 in June 2026) and single-maintainer — popularity, not maturity. The pick when operational simplicity and harness breadth matter most.
3. **code-review-graph (MIT)** — *token-optimization / review specialist.* Embedded SQLite with explicitly token-budgeted retrieval and risk-scored change-impact; also ships a CI/GitHub Action path. Strongest specifically for the PR-review and change-impact workflow; validate its context-savings claims on your own repos.
4. **Serena (MIT)** — *mature baseline / control.* The only genuinely multi-contributor, longer-established option (~25.8k stars). It is LSP-based and on-demand (no persistent graph), so it is the yardstick to prove that a persistent graph actually earns its operational cost versus simpler symbol-level retrieval.

Keep **Blarify (MIT)** and **Potpie (Apache-2.0)** in reserve as graph engines you could wrap behind your own MCP server if none of the four scale. Exclude **GitNexus** (PolyForm Noncommercial — forbids commercial use), **Sourcebot** (FSL, source-available), and **Sourcegraph platform** (proprietary) from adoption on license grounds regardless of technical merit.

**Conditions that change the pick.** If your priority is *general agentic context at enterprise scale* → CodeGraphContext leads (Neo4j path). If your priority is *zero-ops local-first deployment with broad harness support* → codegraph leads. If your priority is *PR-review and change-impact with measured token savings* → code-review-graph leads. If the PoC shows a persistent graph does not beat on-demand symbol retrieval for your workflows → Serena (or wrapping it) is the lower-risk choice. Note that three of the four are young and single-maintainer (only Serena is not); if bus-factor risk is disqualifying for a long-horizon bet, favour the option you are most willing to fork and maintain (all four are MIT, so all are forkable), or build a thin MCP layer over Blarify/Potpie that you own.

### At-a-glance comparison


| Dimension         | CodeGraphContext                                                           | codegraph                                                                        | code-review-graph                                                                         | Serena (baseline/control)                          |
| ----------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------- |
| Primary purpose   | General code-context graph for agents                                      | General token-efficient code-context graph for agents                           | Code review / change-impact (general graph underneath)                                    | Symbol-level code intelligence for agents          |
| Approach          | Persistent graph, tree-sitter (+optional SCIP)                             | Persistent pre-built graph, tree-sitter, auto-sync                              | Persistent graph, tree-sitter + optional embeddings                                       | Live LSP index, on-demand (not a persistent graph) |
| Storage / backend | Neo4j/Cypher (first-class) + FalkorDB/Kuzu embedded                        | Embedded SQLite (FTS5) — "100% local"                                           | Embedded SQLite (FTS5, WAL)                                                               | LSP servers; no persistent graph store             |
| Retrieval         | NL→graph tools; direct Cypher on Neo4j; callers/callees/call-chains/impact | `codegraph_explore` → verbatim source + call paths + blast radius              | Token-budgeted context tools; FTS5 + optional vector; BFS/DFS traversal with token budget | find_symbol / find_references / symbolic edit      |
| Token-cost focus  | Implicit (precise retrieval)                                               | **Explicit** ("fewer tokens, fewer tool calls")                                | **Explicit** (budgeted context, savings metadata)                                         | Implicit (symbol-scoped retrieval)                 |
| MCP-native        | Yes                                                                        | Yes (broad harness support)                                                     | Yes (FastMCP, ~30 tools)                                                                  | Yes                                                |
| Languages         | ~23 (tree-sitter)                                                          | Multi (tree-sitter)                                                             | Very broad (~40+ listed)                                                                  | 40+ (via LSP)                                      |
| License           | **MIT** (permissive)                                                       | **MIT** (permissive)                                                            | **MIT** (permissive)                                                                       | **MIT** (permissive)                               |
| Created / age     | 2025-08 (~10 mo)                                                           | 2026-01 (~5 mo); v1.0 Jun 2026                                                  | 2026-02 (~4 mo)                                                                           | Established, very active                           |
| Stars             | ~3.8k                                                                      | **~54.8k** (most-starred)                                                       | ~18.9k                                                                                    | ~25.8k                                             |
| Maturity flag     | Active; effectively single-maintainer; pre-1.0 churn                       | Popular but young; single-maintainer (~90%); just hit v1.0                      | Very active; single-maintainer; contested benchmarks                                       | Mature, multi-contributor, active                  |


*(Full multi-tool comparison in §7; maturity detail in §6.)*

---

## 2. Glossary (key distinctions only)

- **Knowledge graph** — a structured representation of information as **nodes (entities)** and **edges (relationships)** with semantic meaning; captures *what exists and how it relates*. ([cio.com](https://www.cio.com/article/1308631/vector-database-vs-knowledge-graph-making-the-right-choice-when-implementing-rag.html))
- **Code knowledge graph / code context graph** — a knowledge graph specialized to a codebase: nodes are program constructs (files, symbols, functions, classes, types), edges are code relationships (calls, imports, inheritance, references). A "context graph" framing emphasizes a continuously-updated, query-focused store serving an agent; the term is less standardized than "knowledge graph" and is used differently by different vendors **(inference)**. ([codecontextgraph.com](https://codecontextgraph.com/); [kore.ai](https://www.kore.ai/blog/what-are-context-graphs))
- **Code Property Graph (CPG)** — the closest formally-specified sibling: a directed, edge-labelled, attributed multigraph merging the AST, control-flow graph, and program-dependence/data-flow graph into one structure (Joern). ([docs.joern.io](https://docs.joern.io/code-property-graph/))
- **Vector RAG** — retrieval over **embeddings** that capture semantic similarity; strong for fuzzy/paraphrase recall, weak at exact identifiers and multi-hop relational logic. ([neo4j.com](https://neo4j.com/blog/developer/knowledge-graph-vs-vector-rag/))
- **AST index** — parses code into Abstract Syntax Trees to enable **structural** (syntax-pattern) search; syntactic only — no type/data-flow semantics. ([ast-grep.github.io](https://ast-grep.github.io/advanced/core-concepts.html))
- **LSP (Language Server Protocol)** — a protocol for **live/interactive** language intelligence (go-to-definition, find-references) from a language server reusable across editors. ([microsoft.github.io](https://microsoft.github.io/language-server-protocol/))
- **LSIF / SCIP** — **precomputed, serialized** indexes of the cross-reference information an LSP server would compute. LSIF is the older JSON format; **SCIP** is Sourcegraph's smaller/faster Protobuf successor. ([sourcegraph.com](https://sourcegraph.com/blog/announcing-scip))
- **MCP (Model Context Protocol)** — an open standard (Anthropic, Nov 2024; donated to the Agentic AI Foundation, Dec 2025) for connecting AI applications to external tools/data via a client-server model with three server primitives: **Tools**, **Resources**, **Prompts**. ([anthropic.com](https://www.anthropic.com/news/model-context-protocol); [modelcontextprotocol.io](https://modelcontextprotocol.io/docs/learn/architecture))

**One-line disambiguation:** LSP is live; LSIF/SCIP are precomputed indexes (SCIP supersedes LSIF). AST indexes capture syntax; knowledge/context graphs capture semantic entities + relationships. Vector RAG is fuzzy-similarity retrieval — complementary to, not a substitute for, graph-based exact-relational retrieval.

---

## 3. Conceptual Foundation

### 3.1 Why feeding code to agents at scale is expensive and degrades quality

An estate of ~100 repos and billions of lines is many millions of tokens — orders of magnitude beyond any single context window — so retrieval/selection is mandatory, not optional **(inference)**. Four compounding problems make naive context-stuffing fail:

1. **Hard window limits.** Frontier models cap working memory: Claude Opus 4.8/4.7/4.6 and Sonnet 4.6 offer up to a 1M-token window on the Claude API; many models cap at 200K ([platform.claude.com](https://platform.claude.com/docs/en/build-with-claude/context-windows)). Anthropic explicitly frames the window as "working memory" and warns that "more context isn't automatically better … accuracy and recall degrade, a phenomenon known as context rot."
2. **"Lost in the middle."** Liu et al. (TACL 2024) document a U-shaped curve: models use information best at the start or end of a long context and "significantly degrade" when the relevant information sits in the middle. Their multi-document QA figures show a ~22-point swing from position alone (75.8% best vs 53.8% worst), with the worst case falling *below* the no-documents baseline (56.1%). ([arxiv.org/abs/2307.03172](https://arxiv.org/abs/2307.03172); figures from [ar5iv](https://ar5iv.labs.arxiv.org/html/2307.03172))
3. **Context rot.** Chroma's study across 18 frontier models finds performance degrades non-uniformly as input grows, even when content fits; a *single* distractor lowers performance, and the effect amplifies with length. For 1M-token models the observable onset is often around 300K–400K tokens. ([research.trychroma.com/context-rot](https://research.trychroma.com/context-rot)) A large dump of plausibly-related code is precisely a field of distractors — the regime that hurts most **(inference)**.
4. **Precision/recall bind.** Raising top-k raises recall but injects irrelevant chunks (more contradictions, more tokens, more latency). Because context rot means every low-precision chunk measurably hurts, you cannot simply max recall to compensate — selection must optimize precision *and* recall jointly. ([Ragas](https://docs.ragas.io/en/stable/concepts/metrics/available_metrics/context_precision/); [optyxstack.com](https://optyxstack.com/rag-reliability/rag-recall-vs-precision-diagnostic))

**Cost and latency.** Input cost scales linearly with tokens ("a 900k-token request is billed at the same per-token rate as a 9k-token request" — [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing)), so a 100× larger prompt is a 100× larger input bill. Prompt caching cuts the *price* of reusing a large prefix (cache hits ≈ 0.1× input on Claude) but does nothing for the quality decay — **caching helps cost, not correctness (inference)**. Latency is dominated by the prefill phase (time-to-first-token), which grows faster than linearly because attention is quadratic in sequence length. ([Anthropic prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching); [ibm.com](https://www.ibm.com/think/topics/time-to-first-token))

**Net:** the winning lever is high-precision, high-recall context selection — not bigger windows or cheaper tokens.

### 3.2 What a code knowledge graph models

A code knowledge graph turns source from flat text into a queryable structure. The **node** vocabulary is consistent across systems: files, modules, packages, namespaces (the containment hierarchy); symbols; and declared constructs — functions, methods, classes, interfaces, types, variables. The **edges** are the relationships that flat text discards:

- **Contains** — structural nesting (file → class → method). ([docs.joern.io](https://docs.joern.io/code-property-graph/))
- **Imports / depends-on** — module and package dependencies. ([engineering.fb.com — Glean](https://engineering.fb.com/2024/12/19/developer-tools/glean-open-source-code-indexing/))
- **Calls (the call graph)** — caller↔callee references. (Glean)
- **Inheritance / extends / implements / overrides.** (Glean)
- **Defines/declares ↔ references** — the definition→reference backbone of "go to definition" / "find references," central to LSIF/SCIP and stack graphs. ([sourcegraph.com](https://sourcegraph.com/blog/announcing-scip))
- **Ownership / blame** — git authorship layered on as metadata; a common real-world enrichment, not part of the formal CPG/SCIP specs **(inference)**.

**How it is built:** tree-sitter produces the syntactic tree (fast, incremental, per-keystroke capable) → LSP provides live semantic resolution → LSIF/SCIP are serialized precomputed indexes of that semantic information (SCIP being the smaller/faster Protobuf successor to JSON-based LSIF). ([tree-sitter.github.io](https://tree-sitter.github.io/tree-sitter/); [microsoft.github.io — LSP](https://microsoft.github.io/language-server-protocol/); [sourcegraph.com — SCIP](https://sourcegraph.com/blog/announcing-scip)) Real systems exemplifying the pattern include Sourcegraph (authored SCIP), Meta's Glean (typed code facts queried with the Angle language), Joern (CPG), GitHub CodeQL ("code as data"), and GitHub Stack Graphs (name resolution as graph path-finding).

### 3.3 How graph-based retrieval works, and why it needs fewer tokens

Retrieval begins from **seed entities** (the symbol/file relevant to the query) and performs **k-hop neighborhood expansion** — walking outward along edges to a bounded depth to pull in callers, callees, definitions, references, and imports. This formalizes the manual agentic loop (glob → grep → read → follow imports/references → inspect tests) into explicit edge walks. Candidates are then **ranked by graph proximity** (a direct callee is likelier relevant than something five hops away), commonly **blended with semantics** so the system can tell *which* of many neighbors matters. The 2025 RANGER paper describes exactly this: k-hop expansion balancing "structural proximity with semantic similarity," with a stated motivation that graph retrieval "significantly reduces context window requirements compared to vector-only RAG by filtering irrelevant distant code." ([arxiv.org/abs/2509.25257](https://arxiv.org/abs/2509.25257))

The token efficiency comes from two facts working together **(inference)**: (1) a graph walk returns code that is *connected*, not merely lexically similar — the actual dependency neighborhood a change touches; and (2) fewer relevant tokens beat more tokens because long contexts degrade (§3.1). Returning ~2,000 structurally-guaranteed-relevant tokens often beats stuffing 100,000 tokens of files — not because the graph is magic, but because it keeps the working set inside the model's high-attention budget and out of the rot regime.

### 3.4 Comparison of approaches


| Approach                                   | Strengths                                                                                                                                                                            | Weaknesses                                                                                                                                                                                                                       |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Graph-based retrieval**                  | Models call/import/inheritance structure others ignore; excels at multi-hop, cross-file, "global" reasoning; token-efficient (returns connected code); maps onto how agents navigate | Heavier indexing/maintenance (per-language parsers, freshness on edits); static analysis misses dynamic dispatch/reflection/metaprogramming edges; still needs a semantic layer to rank neighbors **(inference)**                |
| **Vector / embedding RAG only**            | Semantic recall without lexical overlap; good for fuzzy/NL queries                                                                                                                   | Chunking destroys structure; embeddings weak at structural relationships and exact identifiers; silent "plausible but wrong" retrievals ([mindstudio.ai](https://www.mindstudio.ai/blog/is-rag-dead-what-ai-agents-use-instead)) |
| **Full-file / full-repo stuffing**         | No retrieval step to get wrong; simple when code genuinely fits                                                                                                                      | Quality degrades with length (§3.1); doesn't scale past the window; cost linear and latency super-linear in tokens                                                                                                               |
| **Lexical (grep) + AST/structural search** | Exact-match precision, file/line results, near-zero hallucination, cheap/fast; why several agent tools lean on agentic grep                                                          | Text/syntax only; no semantic recall; no cross-file relationship reasoning beyond explicit queries ([ast-grep.github.io](https://ast-grep.github.io/advanced/tool-comparison.html))                                              |


**Hybrids win.** The consistent 2026 conclusion is that these failure modes are complementary, so combine them — typically fused via Reciprocal Rank Fusion plus a reranker. A clean layering **(inference)**: lexical/AST for exact symbols → vector for fuzzy recall → graph traversal to expand the seed set into its true dependency neighborhood → rerank the fused candidates → feed only that tight set into context. (RANGER itself is a graph + embeddings + BM25 hybrid.)

### 3.5 The role of MCP and a dedicated context-serving layer

**MCP** is an open standard (Anthropic, Nov 2024; donated to the Linux-Foundation-hosted Agentic AI Foundation, Dec 2025) for connecting AI applications to external tools/data, replacing N bespoke integrations with one protocol. It uses a client-server model and defines three server primitives — **Tools** (executable functions the agent invokes), **Resources** (read-only contextual data), and **Prompts** (reusable templates) — over JSON-RPC, with stdio (local) and Streamable HTTP (remote/multi-client) transports. ([anthropic.com](https://www.anthropic.com/news/model-context-protocol); [modelcontextprotocol.io](https://modelcontextprotocol.io/docs/learn/architecture))

A code-context graph maps onto these primitives almost directly **(inference, grounded in the spec's own database-server example)**: **Tools** like `find_definition`, `get_callers`, `get_callees`, `expand_neighborhood(symbol, depth)`, `find_implementations`, `search_symbols`; **Resources** exposing file/symbol bodies and the graph schema; **Prompts** wiring multi-step workflows ("investigate-bug", "trace-data-flow"); and change notifications to invalidate stale context after re-indexing.

Why a dedicated serving layer matters: it **decouples retrieval from the model** (documented purpose of MCP); it enables **reuse across agents/IDEs** the way LSP let one language server serve many editors — index once, serve Claude Code, Cursor, VS Code, and CI agents through one protocol; and it allows **centralized pre-computation** so relationships are "indexed and queryable in milliseconds" instead of re-derived every turn ([cloudraft.io](https://www.cloudraft.io/blog/context-graph-for-ai-agents)). A shared context server is stateful and must externalize its index/cache with explicit invalidation rather than holding in-process state — a horizontal-scaling constraint to plan for **(inference)**.

### 3.6 Value to the LLM coding tool, and how to measure it

This subsection ties the foundation back to the **end goal**: LLM tools making code changes across ~100 repos, faster, cheaper, and at higher quality. Everything above explains *why* structure-aware retrieval helps; this frames *what it buys the agent* and *how we will prove it*.

**The mechanism — replace "explore to understand" with "ask and get exactly what's relevant."** Today an LLM agent making a change runs a loop: `grep` → read a file → follow an import → read another → search again. It re-derives the codebase's structure every task by reading lots of files, and that is exactly where time, cost, and quality leak — each grep/read is a round-trip (a single change can take 10–30 tool calls), it pulls far more code into context than it needs, and it either misses relevant code (incomplete edit → bug) or floods context (context rot → worse answers; §3.1). A code-context tool collapses that loop into a few precise structural queries answered from a pre-built (or live) index.

**What it concretely buys, mapped to the three goals.**

| LLM needs to… | Without a tool | With a context tool | Improves |
|---|---|---|---|
| Find where something is defined | grep + read several files | `find_definition` → one answer | Time, Cost |
| Know what a change will break | guess, or read callers manually (often misses some) | `get_callers` / blast-radius / impact → every caller + dependent + test | Quality (complete edits, fewer regressions) |
| Understand a flow | read file after file | `call_chain` / `expand_neighborhood` → the connected code only | Time, Cost, Quality |
| Edit against real structure | infer relationships (can hallucinate) | edges come from the actual code (calls/imports/inheritance) | Quality (grounded, fewer hallucinations) |
| Stay within the model's attention | dump big files | token-budgeted, ranked context | Quality, Cost (less context rot) |

The single biggest quality lever is **impact/blast-radius**: before the agent changes a function, it learns every call site and affected test, so the edit is complete and it knows what to verify — the difference between "fixed here, broke three callers" and a correct change.

**Where it helps most vs. least (honest scope).** The large wins are **multi-hop / relationship queries** ("who calls this", "what's the blast radius", "trace this flow") and working in **large or unfamiliar** code. The win is **marginal** for small, local edits in code the agent already has open — Claude Code's built-in `grep`/read is already good there, and Anthropic deliberately uses agentic search (it beat naive RAG for many tasks), so the tool must **beat good built-in search**, not merely "be a graph." At the ~100-repo boundary the help is strong **inside** a repo but **limited across repos/services** — cross-repo and service-to-service relationships (e.g. dashboard → middleware → API server over HTTP) are not produced from code parsing alone and need enrichment from `workspace.dsl` (C4), `docker-compose`/deploy, and OpenAPI specs (see the operational doc, `multi-repo-and-remote-deployment.md`).

**Two separable axes — do not conflate them.** (1) *Value to the LLM* — precise structural retrieval + impact analysis; this is the point, and all four candidates provide a version of it. (2) *Delivery* — an embedded per-repo index, one unified graph, or a server (local or remote) over MCP; this affects who benefits and how fresh the data is, **not** the fundamental help. Pick the tool for the value; choose delivery for the team/ops reality.

**How we measure it (the PoC must produce numbers, not adjectives).** Run each tool against a **baseline of plain Claude Code with no context tool**, on the same set of real code-change tasks, and measure:

- **Cost** — input+output **tokens per change** (the headline metric tied to the original problem).
- **Time** — **tool-calls per change** and wall-clock **latency** to first useful edit.
- **Quality** — **edit correctness** (does it pass tests / do the right thing), **completeness** (did it update all call sites the change required), and **regressions introduced** (human-rated or test-detected).
- **Operational** — index build time, freshness lag after a change, and ops footprint (backend, memory).

Self-reported vendor savings (e.g. "82×", "fewer tokens") are **not** evidence — they must be reproduced on our corpus. The detailed PoC design (corpus, task selection, scale probes) is in §9.

---

## 4. Candidate Tool: CodeGraphContext

**Repository:** [github.com/Shashankss1205/CodeGraphContext](https://github.com/Shashankss1205/CodeGraphContext) (also mirrored at the [CodeGraphContext org](https://github.com/CodeGraphContext/CodeGraphContext)); homepage [cgc.codes](https://cgc.codes). **License: MIT** (verified in repo metadata `spdx_id: MIT` and the raw LICENSE file — permissive).

**What it is (documented).** An open-source Python tool that indexes a local codebase into a graph database and exposes that graph to AI assistants via MCP, while also working as a standalone CLI. Self-description: "An MCP server plus a CLI tool that indexes local code into a graph database to provide context to AI assistants." It targets the gap where LLM agents lack structural context (call chains, dependencies, inheritance, cross-file impact) and turns the repo into a queryable graph for those questions.

**Approach & architecture (documented).** Parses source with **tree-sitter** (via `tree-sitter-language-pack`) into ASTs from which it extracts entities/relationships; optional **SCIP indexing** for higher accuracy on C/C++/C# (`scip-clang`, `scip-dotnet`). Multi-backend graph storage: FalkorDB Lite (stated default on Unix/Python 3.12+), KuzuDB (embedded cross-platform fallback), FalkorDB Remote, and **Neo4j** (a core dependency, `neo4j>=5.15.0`, with **direct Cypher query** support — i.e. Neo4j/Cypher is a first-class path). It is explicitly an MCP server (`codegraphcontext mcp start`) and supports live re-indexing via `watchdog` file-watching (`cgc watch`). *(Inference: the embedded-default-plus-Neo4j-option split suggests a pivot toward embedded DBs while retaining Neo4j for scale; exact default-by-platform behavior is version-dependent — verify against the installed release.)*

**Graph model (documented).** Each language parser extracts "functions, classes, methods, parameters, inheritance relationships, function calls, and imports." Nodes ≈ {function, class, method, parameter, module/file}; edges ≈ {calls, inherits-from, imports, defines/contains}. Recent commits reference a "SCIP CALLS pass," reinforcing CALLS as a core edge.

**Retrieval (documented).** Agents query in natural language through MCP tools that map to graph traversals (and direct Cypher on Neo4j): symbol/definition lookup, caller/callee analysis, full call-chain tracing across files, impact/dependency analysis, inheritance/implementation lookup, file imports, and code-quality metrics (dead-code detection, cyclomatic complexity). Example NL queries from the README include "Where is the `process_payment` function?", "What other functions call `get_user_by_id`?", and "Show me the full call chain from `main` to `process_data`."

**Integration (documented).** `pip install codegraphcontext` (Python 3.10–3.14); `codegraphcontext mcp setup` auto-configures many clients (README lists VS Code, Cursor, Windsurf, Zed, **Claude**, Gemini CLI, ChatGPT, Cline, RooCode, Amazon Q, Kiro, Goose, OpenCode). Neo4j backend additionally needs Docker or a native server. A separate VS Code extension exists (tagged `v0.1.0-alpha`).

**Security note (low).** `mcp setup` writes into client config files and the server executes graph queries over your indexed source; treat the indexed graph as sensitive (it encodes whole-codebase structure). Standard MCP trust boundary — appropriate for local/controlled use. No dependency CVE audit was performed.

**Maturity (GitHub API, 2026-06-26).** Created 2025-08-16 (~10 months old); last commit 2026-06-12 (active); ~3,817 stars; ~759 forks; ~292 open issues/PRs; ~30 contributors (inflated by Hacktoberfest/Social-Winter-of-Code participation); ~16 release tags, latest **v0.4.7** (2026-05-07) with v0.5.x work in progress. **Assessment:** actively and recently maintained with a fast release cadence, but **effectively single-maintainer** (the lead has ~1,036 of ~1,300+ contributions; the next contributor ~54) — high bus-factor risk. Young and pre-1.0, with versioning churn and recent audit-remediation/parity commits indicating the API and backend behavior are still stabilizing. Popularity is notable for its age, with presence on MCP directories (mcpservers.org, PulseMCP, mcp.so) and community forks, but **no independent benchmarks or production case studies were found** — adoption evidence is stars and directory listings, not documented deployments.

**Caveats.** Latest GitHub *release tag* is v0.4.7 while README/commits reference v0.5.0/v0.5.1 — newest version may be on PyPI without a GitHub release; verify on PyPI before pinning. Two minor backend names ("LadybugDB"/"Nornic DB") surfaced in fetched summaries at low confidence — verify in `pyproject.toml`/docs.

---

## 5. Candidate Tool: code-review-graph

**Repository:** [github.com/tirth8205/code-review-graph](https://github.com/tirth8205/code-review-graph) (identified with ~95% confidence as the canonical project — it owns the name, the `pip install code-review-graph` package, and the [code-review-graph.com](https://code-review-graph.com) domain; other namespace hits are forks such as `n24q02m/better-code-review-graph` and `juspay/code-review-graph-rescript`). **License: MIT** (SPDX `MIT` — permissive). *If "code-review-graph" was meant as a category rather than this named tool, flag back — this analysis assumes the named project.*

**What it is (documented).** A local-first code-intelligence graph that builds a persistent structural map of a codebase so AI tools "read only what matters." It directly targets token/context waste on review tasks, claiming a median ~82× token reduction (range cited 38×–528×). It is **code-review-focused** (PR review, change-impact, architecture review), though the underlying graph is general-purpose.

**Approach & architecture (documented).** Tree-sitter multi-language AST parsing with targeted fallbacks (extracting functions, classes, imports, files). Storage is **local SQLite** (`.code-review-graph/graph.db`, WAL mode) — no external graph DB or cloud, a deliberate local-first design. Incremental updates via SHA-256 hash diffing (re-parses only changed files; claims sub-2s updates on ~~2,900-file repos), with `build`/`update`/`watch` and a `crg-daemon` for multi-repo background watching. **MCP server** via FastMCP (`code-review-graph serve`) exposing ~30 MCP tools plus 5 workflow prompt templates (review, architecture, debug, onboard, pre-merge). Very broad language coverage (~~40+ listed, including Python, JS/TS, Go, Rust, Java, C/C++, C#, Ruby, Kotlin, Swift, PHP, Scala, Solidity, and notebooks).

**Graph model (documented).** Nodes: files, functions, classes, imports. Edges: call (bidirectional caller/callee), import, inheritance, and test-coverage (test→code). Notably, edges carry a three-tier confidence label (`EXTRACTED / INFERRED / AMBIGUOUS`) with float scores — an honest acknowledgment that static call resolution is imperfect. Derived analyses include blast-radius (affected callers/dependents/tests), community detection (Leiden), hub/bridge detection (betweenness centrality), and execution-flow/criticality scoring.

**Retrieval (documented).** SQLite **FTS5** keyword search plus **optional semantic search via embeddings** (sentence-transformers, Gemini, MiniMax, or OpenAI-compatible). Graph queries via `query_graph_tool` (callers/callees/tests/imports/inheritance) and `traverse_graph_tool` (BFS/DFS with a **token budget**). Review/context tools are explicitly token-aware: `get_minimal_context_tool` (~100 tokens), `get_review_context_tool` (token-optimized), `get_impact_radius_tool` (BFS blast radius), `detect_changes_tool` (risk-scored change-impact), `get_architecture_overview_tool`. Responses carry context-savings metadata.

**Integration (documented).** `code-review-graph install` auto-detects/configures Claude Code, Cursor, Windsurf, Zed, Continue, OpenCode, Codex, GitHub Copilot, with slash commands (e.g. `/code-review-graph:review-pr`) and auto-update hooks on save/commit. A composite **GitHub Action** builds the graph on the runner and posts sticky risk-scored PR comments (risk-scored functions, affected flows, test gaps), with an optional `fail-on-risk` merge gate.

**Maturity (GitHub API, 2026-06-26).** Created 2026-02-26 (~~4 months old); last commit 2026-06-10; **~~18,914 stars**; ~2,030 forks; ~152 open issues; ~95 contributors (very long single-commit tail); 10 releases, latest **v2.3.6** (2026-06-10). **Assessment:** very actively maintained with a rapid release cadence, but **heavily single-maintainer** (lead ~333 contributions vs ~13 for #2; ~68 of ~95 contributors have a single commit) — high bus-factor risk. The ~18.9k stars at ~4 months old is striking and reads as a hype/viral curve — treat as a popularity signal, not production-hardening, and worth one independent re-check **(inference)**. The project has shipped CVE fixes (fastmcp), Windows-hang hotfixes, and a v2.3.6 note that "benchmarks are now independently checkable" — implying earlier benchmark claims were contested, so the headline 82×/500× figures should be **independently verified on your own repositories before being cited as fact (inference)**. Documentation is strong (dedicated site, README/CLAUDE.md, FAQ distinguishing it from LSP/RAG/grep); external mentions exist but several read as promotional.

**Decision lens.** *For:* MIT, local-first (no DB/cloud — good for data residency/air-gap), MCP-native, broad languages, active development, real CI story, explicitly token-optimized retrieval. *Against:* ~~4 months old, single-maintainer, contested benchmarks, fast-moving API surface (~~30 tools, frequent releases → churn), probabilistic edge accuracy (`INFERRED/AMBIGUOUS`), and an embedded SQLite store whose behavior at billions-of-LOC scale is unproven. *Mitigation if adopted:* pin a version, validate token savings on your own repos, and treat the fork ecosystem (`better-code-review-graph`, juspay's port) as continuity insurance.

---

## 6. Maturity & Evidence Quality — Summary


| Tool              | License    | Created          | Last activity | Stars     | Contributors (effective)                | Maturity flag                                                                 |
| ----------------- | ---------- | ---------------- | ------------- | --------- | --------------------------------------- | ----------------------------------------------------------------------------- |
| CodeGraphContext  | MIT        | 2025-08 (~10 mo) | 2026-06-12    | ~3.8k     | ~30 (single-maintainer; lead ~80%)      | Active, pre-1.0 churn, single-maintainer, no independent benchmarks           |
| code-review-graph | MIT        | 2026-02 (~4 mo)  | 2026-06-10    | ~18.9k ⚠️ | ~95 (single-maintainer; lead dominates) | Very active, single-maintainer, contested benchmarks, star count high-for-age |
| Serena            | MIT        | Established      | 2026-06-25    | ~25.8k    | Multi-contributor                       | Mature, very active (strongest adjacent option)                               |
| Potpie            | Apache-2.0 | —                | 2026-06-24    | ~5.5k     | Team (VC-funded)                        | Active; bundles its own agents (platform, not thin MCP layer)                 |
| Blarify           | MIT        | —                | 2026-05-25    | ~0.23k    | Small                                   | Active library; LSP+SCIP+tree-sitter graph builder                            |


**Cross-cutting flags.** No surveyed tool has public evidence of operating at ~100 repos / billions of LOC — a representative-scale PoC is mandatory before commitment **(inference)**. Both candidates are MIT and forkable, which partially offsets bus-factor risk. The very-high star counts on several 2026 tools (code-review-graph ~18.9k; and in the wider survey, `colbymchenry/codegraph` ~54.8k and `DeusData/codebase-memory-mcp` ~15k) were reported as API-consistent but are unusual for their age and should be re-verified before being treated as decision-grade signals.

---

## 7. Broader Landscape Survey

All licenses/activity below were API-verified by the research agents. **Adopt = permissive OSS; Background = copyleft/source-available/proprietary or out-of-scope.** GitHub's API reports several non-OSI licenses as `NOASSERTION`/`null` — do not read that as MIT.

### 7.1 Permissive OSS — graph-based code-context tools (adoptable peer group)


| Tool                    | Repo                         | Approach                                                                                       | MCP?          | License                                             | Maturity                           | Relation to candidates                                                                                               |
| ----------------------- | ---------------------------- | ---------------------------------------------------------------------------------------------- | ------------- | --------------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Potpie**              | potpie-ai/potpie             | Repo → property graph in **Neo4j** + RAG agents                                                | Unverified    | **Apache-2.0**                                      | ~5.5k★, active, VC-funded          | Closest full analogue, but a platform bundling its own agents, not a thin MCP layer                                  |
| **Blarify**             | blarApp/blarify              | Graph via **LSP** (+ optional **SCIP**, ~330× faster resolution) + tree-sitter; Neo4j/FalkorDB | Not mentioned | **MIT**                                             | ~0.23k★, active                    | A multi-backend graph-builder library — the engine you'd wrap behind your own MCP server; notable LSP+SCIP precision |
| **codegraph**           | colbymchenry/codegraph       | Tree-sitter → symbols + call edges in **SQLite (FTS5)**; blast-radius; multi-harness           | **Yes**       | **MIT**                                             | ~54.8k★ ⚠️ (re-verify), active, TS | Direct match; embedded SQLite (simpler ops than Neo4j peers)                                                         |
| **codebase-memory-mcp** | DeusData/codebase-memory-mcp | Persistent KG in a single static **C binary**, zero-dep; hybrid LSP; self-reported 120×        | **Yes**       | **MIT**                                             | ~15k★ ⚠️ (re-verify), active, C    | Direct match; native-binary performance angle; validate self-reported benchmarks                                     |
| **mcp-code-graph**      | JudiniLabs/mcp-code-graph    | MCP server over a **hosted** CodeGPT/DeepGraph backend                                         | **Yes**       | **MIT**                                             | ~0.4k★                             | Direct match but depends on a hosted service — poor fit for air-gapped enterprise                                    |
| **FalkorDB/code-graph** | FalkorDB/code-graph          | Demo: codebase → graph via GraphRAG-SDK + FalkorDB + UI                                        | No (demo)     | **MIT** (verify FalkorDB engine license separately) | ~0.32k★                            | Vendor reference impl, not an MCP server                                                                             |


### 7.2 Permissive OSS — retrieval/indexing tools (adoptable / complementary)


| Tool                    | Repo                                             | Approach                                                                        | MCP?                              | License                                             | Maturity               | Note                                                                                               |
| ----------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------- | --------------------------------- | --------------------------------------------------- | ---------------------- | -------------------------------------------------------------------------------------------------- |
| **Serena**              | oraios/serena                                    | **LSP**-based symbol toolkit (40+ langs); on-demand index, not persistent graph | **Yes**                           | **MIT**                                             | ~25.8k★, mature/active | Strongest mature adjacent option; recommended PoC baseline/control                                 |
| **Aider repo map**      | Aider-AI/aider                                   | Tree-sitter + networkx **PageRank**, token-budgeted ranked map                  | Internal, not MCP                 | **Apache-2.0**                                      | ~46.7k★, mature        | Canonical precedent for "feed a small ranked structural map, not raw files" — validates the thesis |
| **ast-grep (+ MCP)**    | ast-grep/ast-grep                                | Rust structural AST search/rewrite; stateless                                   | **Yes** (experimental)            | **MIT**                                             | engine ~14.8k★         | Precise structural matches; no persistent index/call graph                                         |
| **CocoIndex**           | cocoindex-io/cocoindex                           | Incremental indexing engine; tree-sitter chunking + embeddings                  | Framework (community MCP wrapper) | **Apache-2.0**                                      | ~10.5k★, active        | Embedding/semantic recall; its incremental engine is worth emulating for graph freshness           |
| **mcp-language-server** | isaacphi/mcp-language-server                     | Generic LSP↔MCP bridge (definition/refs/rename/diagnostics)                     | **Yes**                           | **BSD-3**                                           | ~1.56k★, active        | Most popular live-semantics bridge; stateless, no persistent graph                                 |
| **SCIP + indexers**     | scip-code/scip (+ scip-typescript/java/clang/go) | Protobuf cross-reference **index format**; compiler-precise                     | Producers, not servers            | **Apache-2.0** (scip-python `NOASSERTION` — verify) | active                 | A code-graph server could ingest SCIP instead of re-parsing                                        |
| **Zoekt**               | sourcegraph/zoekt                                | Fast trigram **lexical** search                                                 | No                                | **Apache-2.0**                                      | ~1.73k★, active        | Complementary substrate (original google/zoekt is archived/unlicensed — avoid)                     |


### 7.3 Background only — copyleft / source-available / proprietary (NOT adoptable)


| Tool                       | License                                      | Why excluded                                                                                                                                                                                         |
| -------------------------- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **GitNexus**               | **PolyForm Noncommercial 1.0.0**             | Forbids commercial use (despite a strong WASM-tree-sitter + Kuzu, MCP-native design). Disqualifying for an enterprise product unless a commercial license is negotiated.                             |
| **Sourcebot**              | **FSL** (source-available, not OSI)          | Self-hosted code search + "ask your codebase" + official MCP server, but commercial restrictions + license-key-gated Enterprise tier.                                                                |
| **Sourcegraph (platform)** | Proprietary (core repo made private 2024-08) | Engine not OSS/self-hostable as OSS; only peripheral pieces (SCIP, src-cli, indexers) remain Apache-2.0.                                                                                             |
| **Glean (Meta)**           | **BSD-3** (permissive!)                      | License is fine; excluded on *operational* grounds — heavyweight Hack/Haskell infra with no AI/agent or MCP layer. Conceptually the closest "code as a queryable fact graph" (Angle query language). |
| **Microsoft GraphRAG**     | **MIT** (permissive)                         | General-purpose, prose-oriented LLM-extracted KG — *not* code-specific. Conceptual blueprint, not a code engine.                                                                                     |


**Dependency-health warnings.** **KuzuDB** (an embedded-graph backend used by several tools) was **abandoned and archived 2025-10-10** ([The Register](https://www.theregister.com/2025/10/14/kuzudb_abandoned/)); tools depending on it inherit that risk (forks exist). **github/stack-graphs** is **archived (2025-09)**. Factor these into any backend choice.

### 7.4 Landscape takeaways (inference)

- The exact niche — **permissive, persistent, multi-hop code graph + native MCP** — is occupied by a cluster of young 2026 MIT tools (CodeGraphContext, codegraph, codebase-memory-mcp), with Potpie/Blarify as Apache/MIT graph engines to wrap. Serena (MIT, LSP, stateless) is the most mature adjacent option.
- The token-reduction thesis is well-validated in principle (Aider's repo map is the canonical precedent), but the specific 58–99% reduction figures marketed by individual MCP tools are self-reported and unbenchmarked by this research.
- Two precision families to choose between: **compiler-precise SCIP/LSP** (Blarify, Serena, scip-*) — accurate, heavier per-language setup — versus **tree-sitter AST** (CodeGraphContext, code-review-graph, codegraph) — zero-config, lower precision. Hybrids (Blarify) split the difference.
- The backend trend is embedded/local-first graphs for zero-ops deployment, but the Kuzu abandonment is a live cautionary tale about depending on a single embedded-graph vendor — relevant to any tool whose default backend is embedded.

---

## 8. Head-to-Head Comparison


| Dimension               | CodeGraphContext                                                             | code-review-graph                                                                                                 | codegraph                                                                       | Serena                                         | Blarify                            | Potpie                                  |
| ----------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------- | ---------------------------------- | --------------------------------------- |
| **Repo**                | Shashankss1205/CodeGraphContext                                              | tirth8205/code-review-graph                                                                                       | colbymchenry/codegraph                                                          | oraios/serena                                  | blarApp/blarify                    | potpie-ai/potpie                        |
| **Primary purpose**     | General code-context graph for agents                                        | PR review / change-impact (general graph underneath)                                                              | General token-efficient code-context graph for agents                           | Symbol-level code intelligence                 | Graph-builder library              | Graph + bundled agents platform         |
| **Approach**            | Persistent graph; tree-sitter (+optional SCIP)                               | Persistent graph; tree-sitter + optional embeddings                                                               | Persistent pre-built graph; tree-sitter; auto-syncs on file change              | Live LSP, on-demand (no persistent graph)      | LSP (+optional SCIP) + tree-sitter | Property graph + RAG agents             |
| **Graph model**         | functions/classes/methods/params/modules; calls, inherits, imports, contains | files/functions/classes/imports; calls, imports, inheritance, test-coverage (+confidence tiers)                   | symbols/functions + call edges; exposes call paths + blast radius               | LSP symbols & references (no persistent graph) | symbols + references via LSP/SCIP  | files/functions/classes; calls, imports |
| **Storage/backend**     | **Neo4j/Cypher (first-class)** + FalkorDB/Kuzu embedded                      | Embedded **SQLite** (FTS5, WAL)                                                                                   | Embedded **SQLite** (FTS5)                                                      | None (LSP servers)                             | Neo4j / FalkorDB                   | **Neo4j**                               |
| **Retrieval mechanism** | NL→graph tools + direct Cypher; callers/callees/call-chains/impact/quality   | **Token-budgeted** context tools; FTS5 + optional vector; BFS/DFS with token budget; risk-scored change detection | `codegraph_explore` → verbatim source + call paths + blast radius               | find_symbol / find_references / symbolic edit  | graph traversal (library API)      | RAG agents over the graph               |
| **Token-cost focus**    | Implicit (precise retrieval)                                                 | **Explicit & first-class**                                                                                        | **Explicit** ("fewer tokens, fewer tool calls")                                 | Implicit (symbol-scoped)                       | N/A (library)                      | Implicit                                |
| **Integration model**   | MCP (auto-config many clients) + CLI + VS Code ext                           | MCP (FastMCP, ~30 tools) + CLI + slash commands + **GitHub Action/CI**                                            | MCP, broad harness support (Claude Code, Codex, Gemini, Cursor, OpenCode, etc.) | MCP toolkit (any client)                       | Library (wrap yourself)            | Harness integrations + agent skills     |
| **Language stack**      | Python                                                                       | Python                                                                                                            | TypeScript                                                                      | Python                                         | Python                             | Python                                  |
| **License**             | **MIT**                                                                      | **MIT**                                                                                                           | **MIT**                                                                         | **MIT**                                        | **MIT**                            | **Apache-2.0**                          |
| **Scale credibility**   | Higher (Neo4j path) — but unproven at billions LOC                           | Lower (embedded SQLite) — unproven at billions LOC                                                                | Lower (embedded SQLite) — unproven at billions LOC                              | Per-repo on-demand; no central graph           | Depends on chosen backend          | Neo4j-backed; unproven at this scale    |
| **Maturity**            | Active, ~10 mo, single-maintainer, pre-1.0                                   | Very active, ~4 mo, single-maintainer, contested benchmarks                                                       | **Most-starred (~54.8k★) but young** (~5 mo, v1.0 Jun 2026), single-maintainer (~90%) | **Mature, multi-contributor**                  | Active, small                      | Active, team                            |
| **Best when**           | You want a general scalable context graph                                    | You want token-measured review/change-impact                                                                      | You want a simple local-first, token-optimized graph with broad harness support | You want a proven low-risk baseline            | You want to own the stack          | You want a turnkey agent platform       |

### 8.1 Direct comparison: codegraph vs CodeGraphContext vs Serena

These three are the most useful to weigh against each other because they represent **three distinct architectural bets** at three different risk profiles, all MIT-licensed. (GitHub metrics for codegraph re-verified 2026-06-26: MIT, 54,798★, 3,362 forks, created 2026-01-18, latest release v1.1.1 on 2026-06-24; contributors API shows the lead author at ~90% of commits — [api.github.com/repos/colbymchenry/codegraph](https://api.github.com/repos/colbymchenry/codegraph).)

- **Architecture / approach.** **codegraph** and **CodeGraphContext** are both *persistent pre-built graphs* that index the repo ahead of time and serve it over MCP — the difference is the backend: codegraph is **embedded SQLite only** (zero external services, "100% local"), whereas CodeGraphContext offers **first-class Neo4j/Cypher** alongside embedded options. **Serena** is the architectural opposite: **no persistent graph at all** — it proxies a live LSP server and resolves symbols/references *on demand*. So the real choice is "pre-computed graph, simple embedded store" (codegraph) vs "pre-computed graph, server-grade store option" (CodeGraphContext) vs "no graph, live semantic queries" (Serena).

- **Scale fit for ~100 repos / billions of LOC.** This is where they separate. codegraph's embedded SQLite is operationally the simplest (nothing to run) but is the least evidenced at very large scale — like code-review-graph, its store is unproven at billions of LOC **(inference)**. CodeGraphContext's Neo4j path is the most credible route to a large, multi-hop, possibly cross-repo graph. Serena sidesteps the question — it holds no central index, so it scales per-repo by delegating to language servers, but cannot answer pre-materialized multi-hop/blast-radius queries in one shot and gives you no cross-repo graph.

- **Maturity — correcting the "mature" read.** codegraph is the **most popular by far** (~54.8k stars vs ~25.8k Serena, ~3.8k CodeGraphContext), but popularity is not maturity: it was **created in January 2026 (~5 months old), only reached v1.0.0 on 2026-06-12, and is effectively single-maintainer (~90% of commits)** — the same bus-factor profile as CodeGraphContext and code-review-graph. **Serena remains the only one of the three that is genuinely multi-contributor and longer-established**, which is why it stays the recommended low-risk *baseline/control*. Treat codegraph's stars as a strong signal of developer interest and momentum, not of production hardening.

- **Token-cost alignment.** codegraph markets the objective directly ("fewer tokens, fewer tool calls") and its `codegraph_explore` returns verbatim source plus call paths and blast radius in one call — conceptually close to code-review-graph's token-budgeted retrieval and well-aligned with your goal. CodeGraphContext optimizes tokens implicitly through precise graph queries. Serena optimizes implicitly by returning only the requested symbol/references rather than whole files. All three are self-reported on savings; none are independently benchmarked here.

- **Verdict for the PoC.** codegraph earns a place **alongside** CodeGraphContext as a second persistent-graph contender — it is the lowest-ops option (embedded, multi-harness, no Neo4j to run) and the most momentum-backed, so it is the natural pick if operational simplicity and broad harness support matter more than server-grade scale. Keep **CodeGraphContext** as the contender when you need the Neo4j scale path, and keep **Serena** as the on-demand/no-graph control. The clean three-way PoC question becomes: *does a pre-built embedded graph (codegraph) or a pre-built server-grade graph (CodeGraphContext) beat live on-demand symbol retrieval (Serena) on tokens, quality, and latency for our workflows at our scale — and is the winner's bus-factor acceptable, or should we fork it?*

### 8.2 Value-lens scorecard (against the end goal)

The head-to-head above compares architecture and integration. This scorecard re-scores the four tools against the **end goal** from §3.6 — *helping an LLM make code changes faster, cheaper, and at higher quality* — with delivery and trust as secondary axes. Rating = how well the tool serves that part of the goal: **Strong / Partial / Weak**. These are capability claims to be confirmed by the §3.6 metrics, not measured results.

| Dimension (why it matters) | CodeGraphContext | codegraph | code-review-graph | Serena |
|---|---|---|---|---|
| **Precise lookup** (find def/search → cuts grep round-trips) | Strong | Strong | Strong | Strong |
| **Relationship queries** (callers/callees/flow → fewer reads) | Strong (call chains, Cypher) | Strong (call paths) | Strong | Strong (live LSP refs) |
| **Impact / blast-radius** (top quality lever) | Strong | Strong, explicit (`codegraph_explore` returns blast-radius) | Strongest, purpose-built (`get_impact_radius`, risk-scored `detect_changes`) | Partial (references, but no packaged test/impact rollup) |
| **Edge accuracy / grounding** (fewer hallucinations) | Medium (tree-sitter AST; optional SCIP some langs) | Medium (tree-sitter AST) | Medium (tree-sitter + honest confidence tiers) | Strong (LSP, compiler-grade within a repo) |
| **Token efficiency** (explicit budgeting → cost + less rot) | Implicit | Explicit ("fewer tokens/tool calls"; one-call explore) | Explicit (token-budgeted context tools) | Implicit (symbol-scoped) |
| **Freshness** (no stale index) | Medium (re-index / `watch`) | Strong (auto-sync ~2s) | Strong (SHA-diff incremental + daemon) | Strong (always live, no index to go stale) |
| **Acts on code** (edit vs read-only) | Read-only (agent edits) | Read-only | Read + refactor-write | Read + symbolic edit |
| **Delivery reach** (local → shared/remote across 100 repos) | Strong (local, unified, remote/shared) | Medium (local; unified-at-root; no remote) | Medium (local + federated; localhost only) | Weak (local, on-demand; no graph/shared; risky remote) |
| **Maturity / bus-factor** (long-horizon bet) | Weak (young, single-maintainer) | Weak (young, single-maintainer; most-starred) | Weak (young, single-maintainer; contested benchmarks) | Strong (mature, multi-contributor) |

**What each is best at, for this goal:**

- **CodeGraphContext** — the only one that delivers the value at **shared/remote scale** across ~100 repos (unified Neo4j + remote MCP). Strong on relationships and impact; pay for it in maturity risk and an auth/CORS hardening requirement. *Pick when the goal is one shared, always-on context service for many devs/agents.*
- **codegraph** — best **value-per-effort locally**: one-call `explore` returns connected code + blast-radius, explicit token reduction, zero-ops auto-sync, broadest harness support; no remote. *Pick for the fastest local win and the single-developer experience.*
- **code-review-graph** — the **most explicit impact + token-budget design**, plus a CI/PR path; review-framed but general underneath; has write/refactor tools; localhost only. *Pick when change-impact and PR review dominate.*
- **Serena** — **highest per-repo accuracy** (real LSP) and **best maturity / lowest bus-factor**, always-fresh, can edit; weakest on packaged blast-radius, no persistent/shared graph, no safe remote. *Pick as the low-risk local baseline and the control that proves whether a persistent graph beats live LSP retrieval.*

**Honest read:** for the highest-leverage capability (impact-aware edits) the persistent-graph trio leads, since they ship blast-radius as first-class; for raw per-repo correctness Serena (LSP) is most accurate but cannot span 100 repos or serve a team; for the shared-delivery ambition CodeGraphContext is the only structural fit. Every "Strong" here is a capability claim — the §3.6 metrics (tokens/change, tool-calls/change, latency, edit correctness vs. plain Claude Code) are what convert these ratings into a decision.

---

## 9. Decision-Support Reasoning

**Constraints recap:** permissive OSS only; ~100 repos; billions of LOC; agentic workflows; cost/latency/quality reduction is the goal; PoC follows separately.

**The final four.** The shortlist is **CodeGraphContext, codegraph, code-review-graph, and Serena** — three persistent-graph contenders plus one on-demand control, all MIT-licensed.

**Why all four pass the gate.** All are MIT (permissive — verified) and MCP-native (the right integration model for agentic workflows and reuse across Claude Code/Cursor/CI). The three graph tools implement the structurally-sound persistent-graph approach that the conceptual foundation (§3) shows is the effective token-reduction lever; Serena implements the on-demand/no-graph alternative that the enterprise-adoption evidence shows is the pattern large orgs actually run (agentic symbol/lexical retrieval). None is disqualified on license, and none is abandoned.

**Why no outright winner today.**

- Three of the four (CodeGraphContext, codegraph, code-review-graph) are young and effectively single-maintainer — a material bus-factor risk for a long-horizon enterprise bet. Only **Serena** is genuinely multi-contributor and longer-established. All four are MIT and therefore forkable, which partially offsets the risk; code-review-graph and codegraph also have fork ecosystems.
- None has public evidence of operating at ~100 repos / billions of LOC. At that scale the **storage backend is decisive**, and this is where the three graph tools diverge: CodeGraphContext's first-class Neo4j/Cypher path is the most credible route to a large, multi-hop, possibly cross-repo graph, whereas both codegraph and code-review-graph use **embedded SQLite** — excellent for zero-ops local-first deployment but unproven at billions of LOC **(inference)**.
- Self-reported token-savings figures (codegraph's "fewer tokens", code-review-graph's 82×/500×) are not independently verified; code-review-graph's own release notes now stress "independently checkable" benchmarks, so these must be validated on your own code before they can be trusted.
- codegraph's ~54.8k stars signal strong developer momentum, **not** production maturity — it only reached v1.0 in June 2026 and is single-maintainer like the others. Do not let popularity substitute for the PoC.

**Why a shortlist, not one tool.** The four optimize different things and occupy three architectural positions. **CodeGraphContext** is the better *general context-graph at enterprise scale* (Neo4j path). **codegraph** is the *lowest-ops persistent graph* (embedded, "100% local", broadest harness support) with an explicit token-reduction pitch. **code-review-graph** is the *token-optimized review/change-impact* specialist (budgeted context tools, risk-scored change detection, CI path). **Serena** answers the prior question that should precede any graph investment: *does a persistent multi-hop graph actually beat simpler on-demand symbol retrieval for our agents' real tasks?* Run them head-to-head and let measured results decide; if the graph tools do not beat Serena, the lower-risk path is Serena (or wrapping it), and the graph tools must justify their indexing/ops overhead.

**Recommended PoC design (to make the decision evidence-based).**

- **Representative corpus:** a handful of repos spanning your largest, your most cross-repo-coupled, and your most-active, rather than the whole estate.
- **Tasks:** real agentic workflows — bug investigation, change-impact/"who-calls-this", cross-file feature work, and PR review.
- **Metrics:** tokens per task, tool-call count, time-to-first-token/latency, task success/quality (human-rated), index build time and freshness lag on commits, and operational footprint (backend, memory, ops burden).
- **Scale probes:** index build time and query latency as repo size grows — does **embedded SQLite (codegraph, code-review-graph) diverge from Neo4j (CodeGraphContext)** at large repos? Behavior across repo boundaries (cross-repo edges) since the estate is ~100 repos. Serena's per-repo on-demand cost as a baseline.
- **Validate vendor claims:** independently measure codegraph's and code-review-graph's token-reduction on your corpus rather than citing their published figures.
- **Pin versions** for all four (the three graph tools are pre-stable and churning).

**Decision rule after the PoC.**

- If a persistent graph clearly beats Serena on token/quality for your workflows **and** scales: choose **CodeGraphContext** if you need general context at enterprise scale (Neo4j), **codegraph** if zero-ops local-first deployment and harness breadth matter most, or **code-review-graph** if review/change-impact dominates and its store holds up.
- If two graph tools tie on quality, let **operational fit and bus-factor** break it: codegraph (embedded, simplest) vs CodeGraphContext (Neo4j, scalable) vs the maintainer health of each.
- If the graph tools do not beat Serena, or their ops cost is too high: adopt **Serena**, or build a thin MCP layer over **Blarify/Potpie** that you own and can scale on Neo4j.
- If single-maintainer risk is unacceptable regardless of results: fork the winning MIT tool into an internal maintained copy, or build on the more-maintained graph engines (Blarify/Potpie) behind your own MCP server.

---

## 10. Assumptions & Caveats

- "code-review-graph" is assumed to mean the named project `tirth8205/code-review-graph` (~95% confidence). If the category was intended, the analysis still applies to the named tool as the leading instance.
- All GitHub metrics are as fetched on 2026-06-26 and will drift; the very-high star counts on several 2026 tools should be re-verified before being treated as decision-grade.
- Self-reported token-reduction benchmarks (both candidates and several surveyed tools) are **not** independently verified here and must be validated in the PoC.
- License determinations are from repo metadata and LICENSE files; GitHub's `NOASSERTION` classification was overridden by reading actual license files where flagged (e.g. GitNexus = PolyForm Noncommercial; Glean = BSD-3).
- Conceptual claims are cited to primary sources where available; figures from secondary/illustrative sources (e.g. GraphRAG percentage gains, specific prefill timings) are flagged as such and should not be quoted as vendor benchmarks.
- No secrets or PII were encountered during this research.

