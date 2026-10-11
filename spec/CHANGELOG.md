# Specification Changelog

## 1.2.0-cr2 — 2026-10-11 (experiment-scoped, capability `change.decimal38`)
CR-2 `spec/changes/decimal38.md`: DECIMAL precision up to 38 (narrow p ≤ 18
unchanged, wide result precision 38), exact INT64/DECIMAL comparison (resolves
SPEC-Q-001 for adopting engines), PQCF format version 2 (128-bit decimals; v1
remains the format for tables without wide columns). Base-suite test change:
`corrupt/version2.pqcf` replaced by `corrupt/version3.pqcf` (still
`STORAGE_VERSION_UNSUPPORTED` for every reader). Runner step `pqcf <path> <version>`.

## 1.1.0-cr1 — 2026-10-11 (experiment-scoped, capability `change.union_all`)
CR-1 `spec/changes/union-all.md`: `UNION ALL`.

## 1.0.0 — 2026-10-10
Initial specification: types, ingestion, SQL v1 grammar/semantics/functions,
protocol v1 (CLI, session JSONL, HTTP), error codes, PQCF v1 storage, indexes &
planning, concurrency contract, phases 1–5, native kernel ABI v1, acceptance criteria.
