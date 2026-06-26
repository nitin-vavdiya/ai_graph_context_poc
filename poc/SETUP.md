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

## 2. Serena (control arm)

### 2a. Install
```bash
uv tool install -p 3.13 serena-agent
serena --version          # 1.5.3 verified
```

### 2b. Provision ALL corpus language servers up front (single step — don't discover gaps mid-run)

> **One Serena server handles all languages — you do NOT run one server per language.** The single Serena MCP server (`poc/mcp/serena.json`) internally spawns the right language server (pyright/tsserver/gopls) as a child process for whatever language(s) the active project contains, including multi-language repos. The "per-language" work below is only ensuring each language-server **binary** is available on the machine — not running extra servers. (Serena's genuine one-at-a-time limit is about *projects/repos*, not languages.)

Front-load the binaries: enumerate the corpus languages first, then ensure each server before any use.

Corpus languages = **Python, TypeScript/JS, Go**.
- **Python, TypeScript/JS** — auto-provisioned by Serena on first activation (no action).
- **Go** — requires a manual external `gopls` (Serena does not auto-manage it; without it Go symbol tools fail with `Found a Go version but gopls is not installed`):
```bash
go install golang.org/x/tools/gopls@latest      # installs to $(go env GOPATH)/bin
command -v gopls                                 # must be on PATH (e.g. ~/go/bin)
```
Optional one-shot warm-up (downloads the auto servers now instead of during a timed run) — activate one project per language once:
```bash
for d in ai-server groundx-typescript cashbot-go; do
  ( cd "groundx-rnd/$d" && claude -p "Use serena get_symbols_overview on one file." \
      --mcp-config /Users/nitin/projects/groundx/ai_graph_context_poc/poc/mcp/serena.json \
      --strict-mcp-config --permission-mode bypassPermissions --model claude-opus-4-8 >/dev/null 2>&1 )
done
```
> Contrast: **CodeGraphContext needs none of this** — `tree-sitter-language-pack` covers all 23 languages in the single install from §1b. The per-language server burden is unique to Serena and grows with language diversity (a real operational factor at ~100 repos).

Verified language coverage (6-repo corpus): Python ✓, TypeScript/JS ✓, Go ✓ for **both** tools.

## 3. Verify both work with Claude Code (headless smoke test)

Uses the **same MCP config files** the benchmark will use, isolated via `--strict-mcp-config`, autonomous via `--permission-mode bypassPermissions` (read-only queries; PoC sandbox only).

```bash
# CodeGraphContext — graph holds all repos, so run from project root
claude -p "Use ONLY the codegraphcontext MCP tools. List 3 functions in ai-server and one caller of one of them. Be brief." \
  --mcp-config poc/mcp/codegraphcontext.json --strict-mcp-config \
  --permission-mode bypassPermissions --model claude-opus-4-8 \
  --output-format json | jq -r '.is_error, .result'

# Serena — run from inside the repo (so --project-from-cwd activates it)
cd groundx-rnd/ai-server
claude -p "Use ONLY the serena MCP tools to find one function/class definition and its file. Be brief." \
  --mcp-config /Users/nitin/projects/groundx/ai_graph_context_poc/poc/mcp/serena.json --strict-mcp-config \
  --permission-mode bypassPermissions --model claude-opus-4-8 \
  --output-format json | jq -r '.is_error, .result'
cd ../..
```

**Pass criteria (both verified 2026-06-26):** `is_error == false` and the `result` shows the tool actually returned symbols/relationships (not a grep fallback). CodeGraphContext returned a real CALLS edge; Serena located `detectLayout` in `document/tasks/detect_layout.py`.

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
