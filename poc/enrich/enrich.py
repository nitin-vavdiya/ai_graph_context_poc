#!/usr/bin/env python3
"""Phase 0 — cross-repo graph enrichment.

The CodeGraphContext graph is six disjoint per-repo subgraphs: tree-sitter only
sees within-file/within-repo structure, so the real service-level coupling
(HTTP/REST/webhook) between these repos is absent. That coupling is recorded in
the hand-authored C4 model `groundx-rnd/workspace.dsl`.

This script parses the dsl's model-block relationships and writes repo-level
`CALLS_SERVICE` edges onto the existing `:Repository` nodes in Neo4j, so the
graph can answer cross-repo blast-radius questions. Idempotent (MERGE).

Design: poc/benchmark-design.md
"""
from __future__ import annotations

import os
import re
import sys
from collections import defaultdict
from pathlib import Path

try:
    from neo4j import GraphDatabase
except ModuleNotFoundError:
    sys.exit("neo4j driver missing — run with:  uv run --with neo4j python poc/enrich/enrich.py")

DSL_PATH = Path(__file__).resolve().parents[2] / "groundx-rnd" / "workspace.dsl"
NEO4J_URI = os.environ.get("NEO4J_URI", "bolt://localhost:7687")
NEO4J_USER = os.environ.get("NEO4J_USERNAME", "neo4j")
NEO4J_PASSWORD = os.environ.get("NEO4J_PASSWORD", "poctestpassword")

# A dsl container's description carries its repo as "Repo: <name>" (e.g.
# "Repo: ai-server (document/*).").  Capture the repo token only.
CONTAINER_RE = re.compile(
    r'(\w+)\s*=\s*container\s+"[^"]*"\s+"([^"]*)"', re.IGNORECASE
)
REPO_RE = re.compile(r"Repo:\s*([A-Za-z0-9_-]+)")
# Model-block relationship:  src -> dst "label" ["protocol"] ["tag"]
REL_RE = re.compile(
    r'^\s*(\w+)\s*->\s*(\w+)\s+"([^"]*)"(?:\s+"([^"]*)")?', re.MULTILINE
)


def parse_dsl(text: str) -> tuple[dict[str, str], list[tuple[str, str, str, str]]]:
    """Return (container_id -> repo_name, [(src_id, dst_id, label, protocol)]).

    Relationships are read ONLY from the model block (before `views {`) so the
    numbered dynamic-flow edges in the views block are not mistaken for real
    coupling.
    """
    model_text = text.split("views {", 1)[0]

    id_to_repo: dict[str, str] = {}
    for cid, desc in CONTAINER_RE.findall(model_text):
        m = REPO_RE.search(desc)
        if m:
            id_to_repo[cid] = m.group(1)

    rels = [
        (src, dst, label, protocol or "")
        for src, dst, label, protocol in REL_RE.findall(model_text)
    ]
    return id_to_repo, rels


def indexed_repos(driver) -> set[str]:
    with driver.session() as s:
        return {r["name"] for r in s.run("MATCH (r:Repository) RETURN r.name AS name")}


def main() -> int:
    if not DSL_PATH.exists():
        sys.exit(f"workspace.dsl not found at {DSL_PATH}")

    id_to_repo, rels = parse_dsl(DSL_PATH.read_text())
    driver = GraphDatabase.driver(NEO4J_URI, auth=(NEO4J_USER, NEO4J_PASSWORD))
    repos = indexed_repos(driver)
    print(f"Indexed repos in graph: {sorted(repos)}")

    # Aggregate dsl relationships to repo-level edges; collect labels per pair.
    edges: dict[tuple[str, str], list[str]] = defaultdict(list)
    skipped: list[str] = []
    for src, dst, label, protocol in rels:
        src_repo, dst_repo = id_to_repo.get(src), id_to_repo.get(dst)
        why = None
        if src_repo is None or dst_repo is None:
            why = "endpoint is infra/person/external (no repo)"
        elif src_repo not in repos or dst_repo not in repos:
            why = "endpoint repo not indexed"
        elif src_repo == dst_repo:
            why = "intra-repo (same repo)"
        if why:
            skipped.append(f"  {src} -> {dst}  [{src_repo} -> {dst_repo}]  — {why}")
            continue
        tag = f"{label} ({protocol})" if protocol else label
        edges[(src_repo, dst_repo)].append(tag)

    # Write repo-level CALLS_SERVICE edges (idempotent).
    with driver.session() as s:
        for (src_repo, dst_repo), labels in edges.items():
            s.run(
                """
                MATCH (a:Repository {name: $src}), (b:Repository {name: $dst})
                MERGE (a)-[r:CALLS_SERVICE {source: 'c4'}]->(b)
                SET r.labels = $labels
                """,
                src=src_repo, dst=dst_repo, labels=sorted(set(labels)),
            )

    print(f"\nWrote {len(edges)} cross-repo CALLS_SERVICE edge(s):")
    for (src_repo, dst_repo), labels in edges.items():
        print(f"  {src_repo} -> {dst_repo}")
        for lb in sorted(set(labels)):
            print(f"      · {lb}")

    print(f"\nSkipped {len(skipped)} dsl relationship(s) (logged, not dropped):")
    for line in skipped:
        print(line)

    # Verify: read back the cross-repo chain from the graph.
    print("\nVerify — cross-repo edges now in graph:")
    with driver.session() as s:
        rows = list(s.run(
            """
            MATCH (a:Repository)-[r:CALLS_SERVICE]->(b:Repository)
            RETURN a.name AS src, b.name AS dst, r.labels AS labels
            ORDER BY src, dst
            """
        ))
    if not rows:
        print("  NONE — enrichment produced no edges (FAIL)")
        driver.close()
        return 1
    for row in rows:
        print(f"  {row['src']} -> {row['dst']}  {row['labels']}")
    driver.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
