# Working notes (arm64-asm-engine)

## Status (end of session 1)
- Phase 1 complete: conformance runner `--phase 1` reports 225/225 pass,
  0 fail/error/not-implemented. `make build test lint` pass from a clean tree.
- Unit tests: test_rt, test_values (486), test_json (150), test_parser (152),
  test_ingest (89, incl. perf), test_binder (218) + tests/sh CLI smoke tests.
- Performance: 100k-row CSV loads in ~40 ms; full scans/sorts in ms.

## Module ownership / where things are
- include/pq.inc: all shared structs/constants; include/API.md: module API.
- Runtime rt.S, CLI main.S, protocol.S, catalog.S, exec.S, eval.S, binder.S,
  lexer.S/parser.S (full v1 grammar), ingest.S, json.S, values/decimal/
  datetime/types.S.

## What is missing (later phases)
- Phase 2: binder rejects GROUP BY/HAVING/DISTINCT, joins, derived tables,
  CTEs, subqueries, CASE/IN/BETWEEN/LIKE, scalar functions with UNSUPPORTED.
  The parser already builds the AST for all of these; extend binder.S
  (scope = array of range variables already exists) and exec.S.
- Phase 3+: storage (PQCF), indexes, stats, HTTP server, parallelism.

## Gotchas
- Library modules must not reference globals defined in main.S (unit tests
  link everything except main.o).
- glibc data symbols (stdin/stderr) must be loaded via GOT_LOAD (PIE).

## How to test
    make -C implementations/arm64-asm-engine build test
    python3 tests/conformance/runner.py --engine implementations/arm64-asm-engine/bin/polyquery --phase 1 -v
