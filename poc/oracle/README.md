# A4 independent call-graph oracle

Compiler-based (Go SSA) transitive-caller set for `summarizer.Process.PrepareStep`, built to replace the circular Neo4j-derived A4 ground truth. See `../PARITY-RECHECK.md` (Blocker 2).

```bash
cd poc/oracle
ALGO=static WITH_TESTS=1 go run .   # 37 files (precise, sound lower bound) — candidate ground truth
ALGO=static WITH_TESTS=0 go run .   # 15 files (production only)
ALGO=cha    WITH_TESTS=1 go run .   # ~1200 files (pessimistic dynamic dispatch — NOT usable)
ALGO=vta    WITH_TESTS=1 go run .   # ~1200 files (pessimistic — NOT usable)
```

`ALGO=static WITH_TESTS=1` output is saved as `../tasks/fixtures/A4_impact_files.static-ssa.txt`.
Targets the concrete `summarizer.Process.PrepareStep` (all value/pointer/generic forms); excludes the unrelated `workflow.Workflow.PrepareStep`.
