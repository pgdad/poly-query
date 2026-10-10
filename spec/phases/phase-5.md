# Phase 5 — Optimization

**Required capabilities:** Phases 1–4 plus `phase5`, `exec.row`, `exec.vectorized`,
`exec.parallel`, `join.hash`, `join.merge`, `join.nested_loop`.

Engines MUST provide, selectable per query (protocol.md §5.2 options):

| Option | Requirement |
|---|---|
| `mode: "row"` | row-at-a-time (iterator/Volcano) execution — the **unoptimized baseline**, retained permanently |
| `mode: "vectorized"` | batch execution over column vectors (batch size implementation-defined, recommended 1024–8192) incl. vectorized filtering and aggregation |
| `threads: N` | parallel table scans and parallel (partitioned or merge-based) aggregation |
| `join: "hash"` / `"merge"` / `"nested_loop"` | forced join algorithm for equi-joins (`nested_loop` also for non-equi); `auto` = cost-based choice |
| `optimize: false` | disables logical rewrites (baseline for plan-optimization measurements) |
| `native: true` | use native kernels (native-kernels.md) for supported operations when loaded |

Recommended optimizations (document which are implemented): constant folding,
predicate simplification, projection pushdown, join reordering for chains of
inner joins, top-N sort for `ORDER BY … LIMIT`, SIMD-friendly loops / explicit
SIMD (e.g. Java Vector API, Rust `std::simd` is nightly-only so portable
autovectorization or `std::arch`), memory pooling/arena allocation,
cache-aware layouts (e.g. partitioned hash tables).

**Correctness:** every conformance query MUST produce the same results under
every combination of `mode` × `join` × `threads ∈ {1, 4}` × `optimize` (the
`modes` harness suite runs the Phase 1–3 cases under these combinations).
