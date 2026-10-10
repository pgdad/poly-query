# PolyQuery Specification

**Spec version:** 1.0.0  **Protocol version:** 1  **Storage format:** PQCF v1

This directory is the **sole normative authority** for every PolyQuery engine.
Engines in `implementations/<lang>/` MUST implement behaviour exactly as written
here. Where this specification is silent, behaviour is *implementation-defined*
and conformance tests MUST NOT depend on it.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as in RFC 2119.

| Area | Document |
|---|---|
| Data types, literals, coercion, null semantics | [data-types/types.md](data-types/types.md) |
| SQL grammar (EBNF) | [sql/grammar.md](sql/grammar.md) |
| SQL semantics (name resolution, evaluation, ordering, aggregation, joins, subqueries) | [sql/semantics.md](sql/semantics.md) |
| Scalar & aggregate functions | [sql/functions.md](sql/functions.md) |
| Data ingestion (CSV / JSON / JSONL) | [data-types/ingestion.md](data-types/ingestion.md) |
| Engine protocol (CLI, session JSONL, HTTP) | [protocol/protocol.md](protocol/protocol.md) |
| Protocol JSON schemas | [protocol/schema/](protocol/schema/) |
| Error codes | [errors/errors.md](errors/errors.md), [errors/error-codes.json](errors/error-codes.json) |
| Persistent storage format PQCF v1 | [storage/pqcf-v1.md](storage/pqcf-v1.md) |
| Indexes, statistics, planning | [storage/indexes-and-planning.md](storage/indexes-and-planning.md) |
| Concurrency, cancellation, timeouts, shutdown | [concurrency/concurrency.md](concurrency/concurrency.md) |
| Execution modes & optimization (Phase 5) | [phases/phase-5.md](phases/phase-5.md) |
| Native kernel ABI | [../native-kernels/include/pq_kernels.h](../native-kernels/include/pq_kernels.h), [phases/native-kernels.md](phases/native-kernels.md) |
| Phase definitions & capability strings | [phases/README.md](phases/README.md) |
| Acceptance criteria for engines and milestones | [acceptance/README.md](acceptance/README.md) |

## Change control

Changes to this directory after implementation work has begun are
**specification changes**. Each MUST:

1. bump the spec version (semver: patch = clarification, minor = additive, major = breaking);
2. be recorded in [CHANGELOG.md](CHANGELOG.md);
3. be accompanied by an ADR in `docs/decisions/` if behaviour changes.

Controlled-track (Track A) agents receive a frozen snapshot of this directory
at a recorded commit; the snapshot hash is part of every experiment manifest.
