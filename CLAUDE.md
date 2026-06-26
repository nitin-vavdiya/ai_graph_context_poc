# CLAUDE.md

Non-code **research** repo. No build, no tests, no app. Output = docs, notes, diagrams, POC findings.

## Goal

Research **graph context for AI coding tools** (Claude Code etc.) at enterprise scale.

## Problem

- Scale: ~100 repos / very large enterprise product / **billions of lines of code**.
- Pain: AI burns huge tokens just to **find relevant code** before doing work.
- Hypothesis: a **graph context** layer (code graph — symbols, deps, calls, ownership, cross-repo edges) lets AI locate relevant code with far fewer tokens.

## Scope

- Research + POC only. Compare approaches to give AI cheap, precise code retrieval at scale.
- Topics likely in play: code knowledge graphs, repo indexing, semantic vs structural search, RAG-over-code, graph DBs, LSP/tree-sitter/SCIP/LSIF, embeddings, MCP servers exposing graph context.

## Conventions

- Markdown for all notes/reports. Diagrams as code (Mermaid).
- Markdown: do not hard-wrap text. Write each paragraph as a single continuous line and rely on the editor's soft wrap. Only insert line breaks between paragraphs, list items, or other distinct block elements — never mid-sentence or mid-paragraph.
- ADRs for hard-to-reverse decisions: `docs/adr/NNNN-title.md`.
- Cite sources in research docs.

## Status

Init only. Research **not started** yet (per user).
