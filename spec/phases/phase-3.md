# Phase 3 — Storage and Indexing

**Required capabilities:** Phases 1–2 plus `phase3`, `storage.pqcf`, `index.hash`,
`index.btree`. `storage.mmap` is required where the platform supports memory
mapping (all supported platforms do), but an engine MAY implement it as a
documented fallback to buffered reads if its language cannot mmap without
third-party libraries in Track A — this MUST be stated in the engine README.

Scope: storage/pqcf-v1.md, storage/indexes-and-planning.md: row & column
layouts, dictionary encoding, null bitmaps, PQCF save/open with checksums,
DICT/RLE encodings, atomic writes, `stats`, hash & ordered indexes, index
selection, predicate pushdown (incl. row-group skipping), column pruning,
basic cost-based choices, accurate `EXPLAIN` node properties.

Interoperability: every engine reads every other engine's PQCF files, and the
golden files in `tests/conformance/fixtures/pqcf/`.

Conformance suites: `tests/conformance/cases/phase3/*`, `interop` and
`storage-crash` harness suites.
