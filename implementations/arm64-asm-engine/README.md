# PolyQuery — AArch64 assembly engine (`arm64-asm-engine`, Track A)

An analytical database engine written entirely in hand-written AArch64
assembly (GNU as `.S` files, preprocessed and linked by gcc). It implements
PolyQuery **Phase 1**: the CLI and JSON-lines session protocol, catalog
operations, CSV/JSON/JSONL ingestion with inference and explicit schemas, all
data types (exact DECIMAL, DATE, TIMESTAMP, NULL semantics) and the
`sql.basic` SQL subset, resource limits and the test functions.

## Build prerequisites

* AArch64 Linux host
* GNU binutils (`as`) and gcc (used only as preprocessor/assembler driver and
  linker) — tested with gcc 13.3 / binutils 2.42
* glibc (libc, libm, libpthread), dynamically linked

```
make build        # -> build/polyquery
make test         # assembly unit tests (tests/unit) + CLI smoke tests (tests/sh)
make lint         # checks every object has a non-executable .note.GNU-stack
make fmt          # whitespace normalisation
bin/polyquery session --data-dir DIR
```

## Libraries

None besides glibc (`ENGINE.json`: `"libraries": []`). From glibc the engine
uses: malloc/realloc/free, memcpy/memcmp/memset/strlen/strcmp, strtod and
snprintf (float text conversion), qsort/qsort_r, setjmp/longjmp, getline,
open/read/fstat/close, clock_gettime, usleep.

## Design overview

Layered modules (one `.S` file each, shared definitions in `include/pq.inc`,
the internal API contract in `include/API.md`):

| layer | files | role |
|---|---|---|
| runtime | `rt.S` | error raising (setjmp/longjmp), arenas, strings, byte buffers, JSON string/number output, clock |
| protocol | `main.S`, `protocol.S` | CLI options, session loop, exec mode, request dispatch, all ops |
| JSON | `json.S` | strict RFC 8259 parser into a DOM, serializer |
| values | `values.S`, `decimal.S`, `datetime.S`, `types.S` | text parsing/formatting of every type, CAST matrix, comparisons, type names |
| storage | `catalog.S`, `ingest.S` | catalog of immutable columnar tables; CSV/JSON/JSONL ingestion |
| SQL front end | `lexer.S`, `parser.S` | tokenizer and recursive-descent parser for the full v1 grammar into an AST |
| semantic analysis | `binder.S` | name resolution, typing with implicit casts, aggregate detection, ORDER BY / LIMIT resolution → bound query |
| execution | `exec.S`, `eval.S` | scan/filter → aggregate or project → sort → offset/limit; expression evaluator and aggregates |

Key decisions:

* **Error handling.** Every request runs under `setjmp`; any error anywhere
  calls `pq_raise*` which longjmps back to the dispatcher. All per-request
  memory comes from a bump arena that is released after each response, so
  unwinding never leaks. Half-built tables are registered and freed on error,
  which makes `load` atomic.
* **Values.** A runtime value is a pair (64-bit payload, null flag) returned in
  `x0`/`x1`; the type is static (from the AST). DECIMAL is a scaled `i64`
  (precision ≤ 18) with exact 128-bit intermediates; DATE is days and
  TIMESTAMP microseconds since the epoch; strings are length-prefixed objects.
* **Storage.** Tables are columnar: per column an array of 64-bit payloads and
  a null-flag byte array, all inside a per-table arena (freed on drop/replace).
* **Typing.** The binder inserts explicit CAST nodes for numeric promotion and
  DATE→TIMESTAMP, so the evaluator only ever combines operands of one kind.
* **Execution.** Selection vectors (row ids) from the filtered scan; result
  rows are materialised as cell matrices including hidden ORDER BY keys;
  sorting uses `qsort_r`. Without ORDER BY, OFFSET/LIMIT are applied before
  projection.
* **Extensibility.** The parser already produces the full grammar (joins,
  GROUP BY/HAVING, DISTINCT, subqueries, CTEs, CASE/IN/BETWEEN/LIKE, EXPLAIN,
  CREATE/DROP INDEX); the Phase-1 binder answers `UNSUPPORTED` for those.

## Implementation-defined choices

* FLOAT64 output uses the shortest of `%.15g`/`%.16g`/`%.17g` that round-trips.
* CAST(FLOAT64 AS STRING) uses the same text.
* `LIMIT NULL` / `OFFSET NULL` are treated as absent.
* An unknown type name in a `load` schema is `INVALID_REQUEST`.
* JSON keys that differ only in case map to the same column (first spelling
  wins); the same key twice within one object is `INGEST_ERROR`.
* `explain`, `save`, `open`, `stats` ops and the `serve` mode answer
  `UNSUPPORTED` / exit 1 (later phases).

## Known limitations

* Phase-2+ SQL (GROUP BY, joins, subqueries, scalar functions other than
  `PQ_SLEEP`, CASE/IN/BETWEEN/LIKE, DISTINCT) is parsed but rejected with
  `UNSUPPORTED`.
* Single-threaded execution; no HTTP server; no persistent storage yet.
