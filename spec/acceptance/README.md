# Acceptance Criteria

## 1. Result comparison rules (used by every harness)

* Column count, column names and column **types** must match exactly
  (type strings canonical per types.md §1). Names of `_colN` columns are checked too.
* Values are compared per type: INT64, BOOLEAN, STRING, DATE, TIMESTAMP and
  DECIMAL (string form, exact) must match exactly; FLOAT64 matches when
  `|a − b| ≤ 1e-9 · max(1, |a|, |b|)`.
* Row order is compared exactly for tests marked `ordered`, otherwise as a
  multiset. Tests marked `ordered` always have a total order on their sort keys.
* Expected errors match on `code` only.
* A response that is not valid protocol JSON, a crash, a hang (per-request
  timeout, default 30 s), or an `INTERNAL_ERROR` is always a failure.

## 2. Engine phase acceptance

An engine **passes Phase k** iff it claims every capability required by
phases/phase-k.md and, for the public suite **and** the hidden acceptance suite
of Phases 1..k: 100% of tests pass (0 failures, 0 errors, 0 not_implemented).
Partial results are reported as percentages but never as "passed".

Hidden acceptance tests (`tests/conformance/hidden/`) are excluded from agent
workspaces in controlled runs and only executed by the orchestrator after an
attempt ends.

## 3. Milestone acceptance

| Milestone | Acceptance criteria |
|---|---|
| **M0** Repository, spec, methodology, infrastructure | Directory layout present; spec documents for types, ingestion, SQL grammar/semantics/functions, protocol, errors, storage, indexes/planning, concurrency, phases, kernels ABI; AGENTS.md, README, methodology & ADRs; project-state.json valid against its schema; `just doctor` runs; `just spec-validate` passes. |
| **M1** Protocol & conformance harness | Conformance runner executes `.pqt` suites against any engine via `bin/polyquery session`; result comparison per §1; JSON + Markdown reports; SQLite oracle cross-check of all oracle-eligible expected results passes; harness self-tests pass; ≥ 300 public test cases across Phases 1–3 and a hidden suite exist. |
| **M2** Datasets & benchmark harness | Deterministic generators for all dataset families with manifests and checksums for SF 10k–100M; generation is byte-reproducible (verified twice); benchmark harness measures latency percentiles, throughput, startup, warmup, RSS, CPU, ingestion, storage size; raw results retained; telemetry schema and collector; orchestrator can prepare isolated workspaces and run the agent adapter. |
| **M3** Phase 1 engines | Each of the 6 engines passes Phase 1 (§2) with Track A telemetry recorded. |
| **M4** Phase 2 engines | Each engine passes Phase 2. |
| **M5** Phase 3 engines | Each engine passes Phase 3, plus the cross-engine storage interop matrix (6×6 + golden files) and the crash-consistency suite. |
| **M6** Phase 4 engines | Each engine passes Phase 4 incl. the HTTP/concurrency suite. |
| **M7** Phase 5 engines | Each engine passes Phase 5 incl. the `modes` suite; benchmark results show baselines vs optimized. |
| **M8** Native kernels | Reference C passes unit + randomized differential tests (incl. ASan/UBSan); x86-64 scalar and AVX2 variants pass differential tests on native x86-64; AArch64 scalar and NEON pass on native AArch64 (emulated runs count only as *functional* evidence and are labeled as such). |
| **M9** Native integration | Each engine with `native.kernels` passes conformance with `native: true`; kernel micro-benchmarks and end-to-end comparisons recorded. |
| **M10** Reports & reproducibility | Reports 1–8 generated (JSON/CSV/HTML) from raw data with links to manifests; a clean-clone reproduction of at least one engine's build + conformance + one benchmark succeeds via documented commands. |
