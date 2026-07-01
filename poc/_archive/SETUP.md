# PoC Setup Runbook (local only) — verified 2026-06-26

Stand up the two finalized tools — **CodeGraphContext** (graph arm) and **Serena** (control arm) — and verify each works with Claude Code before any benchmarking. Local machine only; nothing is exposed on a network.

Corpus repos (under `groundx-rnd/`): `ai-server`, `groundx-python`, `groundx-typescript`, `groundx-ai-middleware`, `groundx-ai-dashboard`, `cashbot-go`.

> All commands run from the project root unless noted: `/Users/nitin/projects/groundx/ai_graph_context_poc`.
> This runbook reflects the **actual working procedure** (two corrections vs. the tools' own docs are called out in **bold**).

## 0. Prerequisites (verified present)

Docker (running), Python 3.12, `uv`, Node, Claude Code 2.1.x. No `pipx` — we use `uv tool` to install Python CLIs in isolation.

## 1. CodeGraphContext (graph arm)

### 1a. Start Neo4j
```bash
docker compose -f poc/docker-compose.yml up -d
# wait ~5s, then http://localhost:7474  (neo4j / poctestpassword)
```

### 1b. Install the tool — **with tree-sitter, or it parses no code**
```bash
uv tool install codegraphcontext --with tree-sitter --with tree-sitter-language-pack
codegraphcontext --version          # 0.5.1 verified
codegraphcontext doctor             # must show: tree-sitter is installed
```
**Critical:** a plain `uv tool install codegraphcontext` ships **without** tree-sitter in 0.5.1 — indexing then records only non-code files (0 functions/classes). The `--with` flags fix it. Always confirm with `doctor`.

### 1c. Point it at Neo4j (connection creds)
```bash
mkdir -p ~/.codegraphcontext
cat > ~/.codegraphcontext/.env <<'EOF'
NEO4J_URI=bolt://localhost:7687
NEO4J_USERNAME=neo4j
NEO4J_PASSWORD=poctestpassword
EOF
```

### 1d. Index the corpus into the one graph — **must pass `--database neo4j`**
```bash
for r in ai-server groundx-python groundx-typescript groundx-ai-middleware groundx-ai-dashboard cashbot-go; do
  codegraphcontext --database neo4j index "groundx-rnd/$r"
done
codegraphcontext --database neo4j list     # all six repos
codegraphcontext --database neo4j stats    # functions/classes > 0
```
**Critical:** CGC 0.5.1 default backend is **FalkorDB (embedded)**, not Neo4j — the `.env` only holds creds, it does **not** switch the backend. The global flag `--database neo4j` (which sets `CGC_RUNTIME_DB_TYPE=neo4j`) is required on every command, or the index lands in the embedded store. **Do not run the interactive `cgc neo4j setup` wizard** — it spins up its own container and conflicts with this one.

Verified result on this machine: 6 repos, ~2,730 files, ~9,887 functions, ~403 classes, edges incl. ~50,916 CALLS / ~3,788 IMPORTS / ~266 INHERITS.

> Known non-fatal issue: `groundx-python` logs `'NoneType' object has no attribute 'split'` mid-index (a CGC parser bug on one file) but still indexes ~995 functions. To refresh later: `codegraphcontext --database neo4j update groundx-rnd/groundx-python` (or `index ... --force`).

### 1e. Verify in Neo4j (optional, visual)
```bash
docker exec cgc-neo4j cypher-shell -u neo4j -p poctestpassword \
  "MATCH ()-[c:CALLS]->() RETURN count(c)"
```

### 1f. Enrich cross-repo edges — **the graph is per-repo until you do this**
```bash
uv run --with neo4j python poc/enrich/enrich.py
```
**Why:** indexing alone produces **zero** cross-repo edges (verified: all imports resolve to name-only stubs, and the real coupling between these repos is service-level HTTP/REST/webhook that tree-sitter cannot see). This pass reads the hand-authored C4 model `groundx-rnd/workspace.dsl` and writes repo-level `CALLS_SERVICE` edges onto the `:Repository` nodes. Idempotent (`MERGE`); re-run after editing the dsl. Out-of-corpus and infra relationships are skipped and logged, not dropped.

Verified result: 4 cross-repo edges — `groundx-ai-dashboard → groundx-ai-middleware → cashbot-go ⇄ ai-server` (with protocol/endpoint labels). Confirmed answerable through Claude Code via CGC direct Cypher (`is_error: false`). Granularity is **repo-level**, not function-level (the dsl's ceiling) — enough to route an agent to the right downstream repo. Design + rationale: [`benchmark-design.md`](benchmark-design.md).

## 2. Serena (control arm)

### 2a. Install
```bash
uv tool install -p 3.13 serena-agent
serena --version          # 1.5.3 verified
```

### 2b. Scope Serena to ALL 6 corpus repos as ONE "monorepo" project — **not per-repo cwd**

> **Corrected 2026-07-01 (supersedes the earlier `--project-from-cwd` setup).** The original config activated Serena from the current working directory (`--project-from-cwd`), which pinned it to a **single repo** (`cashbot-go`) on every run. That silently handicapped Serena on all cross-repo tasks — it never saw the other repos, so it could not compete with cgc's all-repo graph. The head-to-head cells run under that config are **not reliable** and were discarded. Fixed below.

Serena's documented multi-repo pattern is a **"monorepo folder"**: point one project at a parent folder that contains all the repos as sub-folders (oraios docs, [Workflow](https://oraios.github.io/serena/02-usage/040_workflow.html); [Discussion #542](https://github.com/oraios/serena/discussions/542) — "full monorepo support, you just need to set the languages in your project.yml"). Our parent is `groundx-rnd/`. This is the direct parallel to cgc's single graph over all repos, and makes Serena **cwd-independent** like cgc.

**Three load-bearing config pieces** (verified — omit any and Serena silently degrades):

1. **`--project <abs parent>` + dashboard off + tool timeout** — in `poc/mcp/serena.json` / `both.json`:
```jsonc
"args": ["start-mcp-server", "--context", "claude-code",
         "--project", "/Users/nitin/projects/groundx/ai_graph_context_poc/groundx-rnd",
         "--tool-timeout", "300",
         "--enable-web-dashboard", "false", "--open-web-dashboard", "false"]
```
**Critical — disable the web dashboard.** With it enabled (the default), the Claude Code MCP client intermittently fails with `MCP error -32000: Connection closed` ([serena #898](https://github.com/oraios/serena/issues/898)). This produced a spurious "serena timed out" reading in early testing. The `--enable-web-dashboard false` flag removes the confound.

2. **`languages:` list in `groundx-rnd/.serena/project.yml`** — must be set **explicitly**:
```yaml
languages:
- python
- typescript
- go
```
**Critical:** if `languages:` is left empty, Serena auto-infers a **single** language (it picked `typescript` here) and **silently returns `[]`** for Python/Go symbols — no error, `is_error: false`. Verified failure mode. Multiple languages run as parallel language servers (pyright/tsserver/gopls) under the one project.

3. **`ignored_paths:` in the same `project.yml`** — scope to exactly the 6 corpus repos. The parent `groundx-rnd/` actually contains **27** dirs; without ignores, Serena indexes all of them (out-of-corpus repos, workspaces, PHP) — slower and a scope mismatch vs cgc (which indexed exactly 6). Ignore the 21 non-corpus dirs (`/eyelevel-wordpress/`, `/groundx-on-prem/`, `/workspace-*/`, … — see the file for the full list).

**`gopls` binary still required** (external; Serena does not auto-manage Go):
```bash
go install golang.org/x/tools/gopls@latest      # installs to $(go env GOPATH)/bin
command -v gopls                                 # must be on PATH (e.g. ~/go/bin)
```

**Mandatory one-time index (warm-up) — budget ~15 min:**
```bash
serena project index /Users/nitin/projects/groundx/ai_graph_context_poc/groundx-rnd
```
The index is a symbol cache; run it **once** before any timed run (Serena auto-updates it on file changes afterward). It is **slow at multi-repo scale, and gopls is the bottleneck**: verified 2026-07-01, the first ~45% (Python + TypeScript, 1079/2378 files) indexed at ~3540 files/s in under a second, then the **Go half collapsed to ~1.3 files/s** — a ~2600× throughput drop — taking ~13 of the ~15 total minutes. This one-time cost matches Serena's own note that "each workspace folder adds startup/index time" and issues [#308](https://github.com/oraios/serena/issues/308)/[#876](https://github.com/oraios/serena/issues/876). It is a **warm-up cost, not a per-query cost** (see verification below).

> Contrast: **CodeGraphContext needs none of the per-language / dashboard / project-scoping ceremony** — `tree-sitter-language-pack` covers all 23 languages in the single install from §1b, and the graph is cwd-independent by construction. Serena's setup burden (per-language LSP binaries, explicit `languages`, dashboard confound, slow gopls index, one-project-at-a-time) is a real operational factor at ~100 repos.

**Verified capability (2026-07-01, post-index, dashboard off):** a **single unscoped** `find_symbol` whole-project search resolved `DocumentResponse`, `Response`, and `PrepareStep` in **~36 s**, spanning **3 languages across 4 repos** (ai-server + groundx-python Python, dashboard + groundx-typescript TS, cashbot-go Go). Serena is genuinely multi-repo/multi-language for **symbol lookup** — parity with cgc. Earlier "unscoped search times out" readings were **artifacts of a cold/incomplete index + the dashboard bug**, not a Serena scaling limit; retracted.

**Verified capability LIMIT (from oraios docs):** cross-workspace-folder **reference / caller discovery is TypeScript-only** today — other language servers error if that setting is used. So Serena can *find* Go/Python symbols across repos, but **cannot trace cross-repo callers/references for Go/Python**. This is the genuine remaining Serena vs. cgc gap on A4-style transitive cross-repo call tracing (cgc's `CALLS*` closure has no such per-language restriction).

## 3. Verify both work with Claude Code (headless smoke test)

Uses the **same MCP config files** the benchmark will use, isolated via `--strict-mcp-config`, autonomous via `--permission-mode bypassPermissions` (read-only queries; PoC sandbox only).

```bash
# CodeGraphContext — graph holds all repos, so run from project root
claude -p "Use ONLY the codegraphcontext MCP tools. List 3 functions in ai-server and one caller of one of them. Be brief." \
  --mcp-config poc/mcp/codegraphcontext.json --strict-mcp-config \
  --permission-mode bypassPermissions --model claude-opus-4-8 \
  --output-format json | jq -r '.is_error, .result'

# Serena — project is the parent monorepo folder (cwd-independent). Run the index FIRST (§2b).
# This unscoped query must resolve symbols from MULTIPLE repos/languages — the multi-repo check.
claude -p "Use ONLY the serena MCP tools. Unscoped find_symbol for DocumentResponse (Python), Response (Go), PrepareStep (Go). Report file paths. Be brief." \
  --mcp-config /Users/nitin/projects/groundx/ai_graph_context_poc/poc/mcp/serena.json --strict-mcp-config \
  --permission-mode bypassPermissions --model claude-opus-4-8 \
  --output-format json | jq -r '.is_error, .result'
```

**Pass criteria:** `is_error == false` and the `result` shows the tool returned real symbols/relationships (not a grep fallback). CodeGraphContext (verified 2026-06-26) returned a real CALLS edge. Serena (verified 2026-07-01, post-index, dashboard off) resolved symbols across **3 languages / 4 repos** in one unscoped query (~36 s) — the multi-repo capability check. **Both arms must operate over all 6 corpus repos before any scored run** — a single-repo Serena scope invalidates every cross-repo cell.

## 4. Teardown / reset
```bash
docker compose -f poc/docker-compose.yml down       # stop Neo4j (keep data)
docker compose -f poc/docker-compose.yml down -v    # stop + wipe graph
uv tool uninstall codegraphcontext serena-agent
```

## Notes & gotchas
- **tree-sitter is mandatory** for CGC (see 1b) — the single most important gotcha.
- **`--database neo4j` on every CGC command** (see 1d), else it uses the embedded FalkorDB store (which on this machine already holds unrelated `ostrich-*` projects from prior use — left untouched).
- **Re-indexing:** `index` refuses an already-indexed repo; use `update <path>` or `index <path> --force`.
- **Serena cross-repo:** one active project at a time; cross-repo questions see only the project root — expected limitation, not a setup failure.
- **First runs are slow** (Neo4j pull, tool installs, Serena's first language-server download, `cashbot-go` Go indexing ~125s) — one-time; warm before any timing.
