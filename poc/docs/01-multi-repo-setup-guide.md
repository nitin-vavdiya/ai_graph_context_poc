# Setting Up CodeGraphContext and Serena for Multiple Repos

_A reusable, corpus-agnostic guide to standing up both tools so an AI agent can query **all** of a multi-repo codebase. For the exact commands used in this POC's 6-repo corpus, see [`02-poc-setup.md`](02-poc-setup.md)._

The two tools reach "multi-repo" by opposite means, and each has one non-obvious setting that silently degrades it if wrong.

| | CodeGraphContext (CGC) | Serena |
|---|---|---|
| model | persistent graph in Neo4j; index every repo into one DB | live LSP; one "project" that can be a parent folder over all repos |
| multi-repo | **simultaneous** — one query spans all indexed repos | **simultaneous** if pointed at a parent folder with `languages` set |
| cwd-dependence | none (queries the DB) | none, once `--project` is a fixed path |
| one-time cost | fast index (tree-sitter) | slow index (per-language LSP; a large language can dominate) |

## CodeGraphContext (graph)

### 1. Neo4j
Run a Neo4j 5 instance (Docker is fine). Note the bolt URI + credentials.

### 2. Install CGC **with tree-sitter**
```bash
uv tool install codegraphcontext --with tree-sitter --with tree-sitter-language-pack
codegraphcontext doctor      # MUST show: tree-sitter is installed
```
**Gotcha:** a plain install ships **without** tree-sitter — indexing then records 0 functions/classes (only non-code files). Always confirm with `doctor`.

### 3. Point CGC at Neo4j on **every** command
CGC's default backend is embedded FalkorDB, not your Neo4j. The `.env` creds alone do **not** switch backends — you must pass `--database neo4j` (or set `CGC_RUNTIME_DB_TYPE=neo4j`) on every invocation, or the index lands in the wrong store.
```bash
codegraphcontext --database neo4j index <repoA>
codegraphcontext --database neo4j index <repoB>
# ... one index per repo, all into the same Neo4j = one unified graph
codegraphcontext --database neo4j stats    # functions/classes > 0
```

### 4. Cross-repo edges are NOT free
Indexing produces **zero** cross-repo edges: imports resolve to name-only stubs, and real inter-repo coupling is usually service-level (HTTP/REST/webhook) that no parser can see. If you need cross-repo *relationships*, you must add them yourself (e.g. from a C4/architecture model) as explicit edges. Symbol *lookup* across repos works out of the box; cross-repo *call/dependency tracing* does not.

## Serena (LSP)

Serena has **no** "multiple active projects" — but one project can be a **parent ("monorepo") folder** containing all the repos as sub-folders (real dirs or symlinks). This is the documented pattern and the direct parallel to CGC's single graph.

### 1. Install + language servers
```bash
uv tool install -p 3.13 serena-agent
```
Language servers for Python/TypeScript auto-provision on first use; **Go needs a manual `gopls`** on PATH (`go install golang.org/x/tools/cmd/gopls@latest`). Provision every corpus language up front.

### 2. Point `--project` at the parent folder
```jsonc
// MCP config
"args": ["start-mcp-server", "--context", "claude-code",
         "--project", "/abs/path/to/parent-folder",
         "--tool-timeout", "300",
         "--enable-web-dashboard", "false", "--open-web-dashboard", "false"]
```

### 3. Set `languages:` **explicitly** in `<parent>/.serena/project.yml`
```yaml
languages:
- python
- typescript
- go
```
**Gotcha (silent):** if `languages:` is left empty, Serena auto-infers a **single** language and returns `[]` for symbols in the others with `is_error:false` — a silent failure. List every language you need; they run as parallel language servers.

### 4. Disable the web dashboard
**Gotcha:** with the dashboard on (the default), the MCP client intermittently drops with `MCP error -32000: Connection closed` (serena issue #898). Disable it via the flags above.

### 5. Scope to only the repos you want (`ignored_paths`)
If the parent folder contains more than your target repos, add the rest to `ignored_paths` in `project.yml` — otherwise Serena indexes everything under the parent (slow, and a scope mismatch vs CGC).

### 6. Pre-index once (mandatory for large trees)
```bash
serena project index /abs/path/to/parent-folder
```
The index is a symbol cache; run it **once** before any timed use (Serena auto-updates it afterward). **It can be slow** at multi-repo scale — a single heavy language (e.g. Go via gopls) can dominate the whole run. Budget for it; don't run it inside a latency-sensitive path.

## Verifying multi-repo actually works

Do not assume — verify with an **unscoped** query that must resolve symbols from **more than one repo/language** in a single call:
- CGC: one Cypher/`find_code` returning nodes from ≥2 repos.
- Serena: one unscoped `find_symbol` returning hits across ≥2 repos/languages (only reliable **after** the index completes; a cold/partial index can time out).

If either returns results from only one repo, the multi-repo setup is not actually in effect.
