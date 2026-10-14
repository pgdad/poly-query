# Specification Changelog

## apps 1.0.0 — 2026-10-14 (application family; engine spec unchanged)
`spec/apps/pqledger.md` (the pqledger CLI: configuration, bank CSV import, duplicates, rules,
reports, budgets, output formats, normative ledger layout in PQCF) and `spec/apps/embedding.md`
(the in-process embedding API every engine exposes, packaging, `examples/embed-demo`), ADR-0018.
Tests: `tests/apps/pqledger/runner.py` (public cases; hidden cases in `tests/apps/hidden/`).

## 1.3.0-cr6 — 2026-10-12 (capability `change.expression_limits`; resolves SPEC-Q-002)
CR-6 `spec/changes/expression-limits.md` (ADR-0017): minimum statement sizes
(1 MiB of text, nesting depth 1,000 with an operator chain counting as one level,
25,000 operands) that every mode must execute. Beyond an engine's own limits the
answer is `RESOURCE_LIMIT`, which may take precedence over `PARSE_ERROR`. The
query timeout covers parsing, binding and planning, with `TIMEOUT` within 1 s of
expiry. Stack exhaustion must not end the process. No existing conformance case
changes. Check: `tests/regression/robustness_probe.py --only expression_limits`.

## kernel ABI 1 revision 1 (CR-4) — 2026-10-11 (assembly experiment family)
CR-4 `spec/changes/kernels-i128.md`: four additive 128-bit kernels
(`filter_i128`, `count_i128`, `sum_i128`, `minmax_i128`), `pqk_i128` type,
`PQK_ABI_REVISION` / `pqk_abi_revision()`. `pqk_abi_version()` stays 1; engines
are unaffected. Kernel tests report `<provided>/20 kernels`.

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
