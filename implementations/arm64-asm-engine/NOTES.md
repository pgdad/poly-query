# Working notes (arm64-asm-engine)

## Status
- Session 1: interfaces (include/pq.inc, include/API.md), runtime, CLI,
  protocol, catalog, executor written by the lead; value library + JSON,
  lexer + parser, ingestion, binder + evaluator written in parallel.

## Next steps
- Integrate all modules, run the Phase 1 conformance suite, fix failures.

## How to test
    make -C implementations/arm64-asm-engine build test
    python3 tests/conformance/runner.py --engine implementations/arm64-asm-engine/bin/polyquery --phase 1 -v
