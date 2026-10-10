# Phase 4 — Networking and Concurrency

**Required capabilities:** Phases 1–3 plus `phase4`, `http.streaming`.

Scope: protocol.md §7 (HTTP API, streaming, metrics, structured logs) and
concurrency/concurrency.md (snapshot isolation, worker limits, queueing,
backpressure, timeouts, cancellation, graceful shutdown).

No replication or consensus.

Conformance suites: `tests/conformance/cases/phase4/*` (run over HTTP via
`/v1/request`) and the `http` harness suite (tests/concurrency).
