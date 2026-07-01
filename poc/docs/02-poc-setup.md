# How This POC Was Set Up

_The concrete setup for this benchmark: the corpus, the two arms, the isolation, and the fairness fixes made on 2026-07-01 after the first attempt proved unreliable. General how-to (reusable): [`01-multi-repo-setup-guide.md`](01-multi-repo-setup-guide.md). Verification record: [`../PARITY-RECHECK.md`](../PARITY-RECHECK.md)._

## Corpus

Six repositories under `groundx-rnd/`, spanning Python, TypeScript/JS, and Go:
`ai-server`, `groundx-python`, `groundx-typescript`, `groundx-ai-middleware`, `groundx-ai-dashboard`, `cashbot-go`.

The parent `groundx-rnd/` actually contains ~27 dirs; the corpus is exactly these 6. Both tools are scoped to the same 6 so the comparison is apples-to-apples.

## The four arms

Every benchmark cell runs one of four arms; only the MCP tool config differs. All arms have Claude's built-in tools (grep/read/edit/bash) inside the sandbox.

| arm | tools |
|---|---|
| **baseline** | built-in only (grep/read/edit/bash) |
| **cgc** | + CodeGraphContext (graph) |
| **serena** | + Serena (LSP) |
| **both** | + CodeGraphContext **and** Serena |

## CGC arm (graph)

- One Neo4j 5 (Docker, `poc/docker-compose.yml`, `bolt://localhost:7687`).
- CGC installed with tree-sitter; all 6 repos indexed into the one graph with `--database neo4j`.
- Graph size: ~9,887 functions, ~50,938 CALLS edges.
- Cross-repo edges (`CALLS_SERVICE`, repo-level, 4 of them) added by `poc/enrich/enrich.py` from the hand-authored C4 model `groundx-rnd/workspace.dsl` — because indexing alone yields **zero** cross-repo edges (the real coupling is service-level HTTP, invisible to tree-sitter).
- Config: `poc/mcp/codegraphcontext.json`.

## Serena arm (LSP)

- Scoped to the **parent** `groundx-rnd/` as one monorepo project (config: `poc/mcp/serena.json`), with:
  - `languages: [python, typescript, go]` set explicitly in `groundx-rnd/.serena/project.yml`,
  - `ignored_paths` = the 21 non-corpus dirs (scopes Serena to exactly the 6),
  - web dashboard disabled, `--tool-timeout 300`.
- `gopls` installed on PATH for Go.
- Pre-indexed once with `serena project index` (~15 min; the Go half via gopls dominated at ~13 of those minutes).

## Isolation — how a cell is run (`poc/run.sh`)

Each cell: restore the repo to a pristine snapshot → apply the task setup → run `claude -p` with the arm's MCP config and the sandbox → run the task oracle → restore. Controls (identical on every arm):

- **macOS Seatbelt sandbox** (`--permission-mode dontAsk` + `poc/sandbox-settings.json`): every Bash subprocess is network-isolated (no `bolt:7687`, no docker) and cannot read outside the workspace (no `poc/` answer fixtures, no stray checkouts). `dontAsk` auto-denies any out-of-scope tool call with no prompt.
- `--strict-mcp-config` (only the arm's MCP), `--setting-sources project,local` (no user-source claude-mem hooks), per-arm `--allowedTools`, `GOPROXY=off GOTOOLCHAIN=local` (go works offline), fresh process per cell.
- The cgc/both arms still reach Neo4j via their MCP **server** (launched by Claude, not sandboxed); no arm's **Bash** can reach it.

## Why the first attempt was discarded (fairness fixes)

A parity recheck on 2026-07-01 found the original head-to-head unreliable and fixed three harness bugs. This is why the current results supersede all earlier ones.

1. **Serena was crippled to a single repo.** The old config used `--project-from-cwd`, and every cell ran from `cashbot-go` — so Serena only ever saw one repo and lost every cross-repo cell **by construction**, not by capability. Fixed by scoping it to the parent monorepo folder (above). Verified: Serena now resolves symbols across 3 languages / 4 repos in one query.
2. **A3's off-disk isolation was defeated.** Under the old `bypassPermissions`, a non-graph arm could `docker exec` into Neo4j (reading the leaked creds from a config file) and could read the answer fixtures in `poc/tasks/` — so it "passed" without any real capability. Fixed by the Seatbelt sandbox. A re-run smoke confirmed the honest result (baseline fails, cgc passes via the graph).
3. **A4's ground truth was circular.** The old oracle graded every arm against CGC's **own** Neo4j call-graph output (and it was incomplete — missed 8 files a compiler finds). Replaced with an **independent** Go SSA static call-graph oracle (`poc/oracle/`, 37-file set).

Also fixed: `run.sh`'s cleanup trap now catches `INT/TERM`, so an interrupted run no longer leaves `.git` hidden or repos parked to corrupt the next run.

## Known limitations of the setup

- **Local, single machine** — nothing exposed on a network; not a distributed/enterprise deployment.
- **Plaintext Neo4j credential** (`poctestpassword`) sits in `poc/mcp/*.json`, `docker-compose.yml`, and `.claude/settings.local.json`. Throwaway local value, but it is what leaked in the pre-fix A3 test; a production setup would use a secret store and bind Neo4j off the agent's reach.
- **Cross-repo edges are hand-authored** (the C4 model), repo-level, not code-derived — see [`00-executive-summary.md`](00-executive-summary.md) caveats.
