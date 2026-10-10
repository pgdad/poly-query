# Architecture Overview

```
                     ┌───────────────────────── spec/ (normative) ─────────────────────────┐
                     │ types · ingestion · SQL grammar/semantics/functions · protocol v1   │
                     │ errors · PQCF v1 storage · indexes/planning · concurrency · phases  │
                     └───────────────┬──────────────────────────────┬──────────────────────┘
                                     │ frozen snapshot per run       │
┌──────────── orchestration ─────────▼──────────┐          ┌─────────▼────────── verification ─────────────┐
│ pq_orchestrate.py: prepare → sandbox.sh(bwrap) │          │ tests/conformance  (.pqt runner, public+hidden)│
│ → claude -p (stream-json) → telemetry →        │          │ tests/concurrency  (HTTP/concurrency suite)    │
│ sandboxed validation → record → import/merge   │          │ tests/integration  (PQCF interop, crash)       │
└───────────────┬────────────────────────────────┘          │ tests/property-based, tests/fuzz               │
                │ one isolated agent per language           │ tools/validation (SQLite oracle, PQCF ref)     │
   ┌────────────┼──────────────┬───────────┬──────────┐     └────────────────────┬──────────────────────────┘
   ▼            ▼              ▼           ▼          ▼                          │ protocol only
 java/      clojure/        rust/      python/     go/   common-lisp/  ◄─────────┘ (session JSONL / HTTP)
   │  every engine: lexer → parser/AST → semantic analysis → logical plan → physical plan → execution
   │  catalog (immutable tables, snapshot isolation) · PQCF storage · indexes · HTTP server
   └──── optional FFI ──► native-kernels/libpqkernels (C17 reference + x86-64 / AArch64 asm, runtime dispatch)

benchmarks/harness/bench.py ──protocol──► engines        tools/reporting/report.py ──► results/, docs/results/
```

Key properties:

* **Independence:** no shared engine code. The only shared artifacts are the
  spec, the protocol and data files (fixtures, PQCF files).
* **Black-box verification:** every harness talks to engines only through
  `bin/polyquery` (session JSON lines or HTTP).
* **Independent authority:** expected results come from hand-written,
  spec-derived expectations and a SQLite oracle (ADR-0009); PQCF correctness
  from an independent reference reader/writer (ADR-0011).
* **Reproducibility:** deterministic generators with committed manifests and
  checksums; every agent run and benchmark records its environment and inputs.
