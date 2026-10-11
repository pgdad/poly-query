# PolyQuery — x86-64 assembly engine

An in-memory analytical database engine implementing the PolyQuery
specification (`spec/`), written entirely in hand-written x86-64 assembly
(GNU as, AT&T syntax). Status: **Phase 1** (protocol, catalog, CSV/JSON/JSONL
ingestion, all data types, the `sql.basic` SQL subset, resource limits, test
functions).

## Build prerequisites

| Tool | Version | Use |
|---|---|---|
| GNU binutils (`as`, `ld`) | 2.42 | assembler / linker |
| gcc | 13.3 | **driver only**: runs cpp on `.S` files, the assembler and the linker. No C source exists anywhere in the build. |
| glibc (libc, libm, libpthread) | system | dynamically linked runtime (malloc, read/write, strtod, snprintf, qsort_r, setjmp/longjmp, …) |
| GNU make, POSIX sh | any | build and tests |

```
make build        # -> out/polyquery
make test         # assembly unit tests + end-to-end session tests
make lint         # verifies every object carries a non-executable .note.GNU-stack
make fmt          # whitespace normalisation
make clean
bin/polyquery session --data-dir DIR
```

`bin/polyquery` is a small shell launcher that builds on first use and execs
`out/polyquery`; it works from any directory.

## Libraries

None besides glibc (`ENGINE.json`: `"libraries": []`).

## Design overview

The code is organised in layers, one module (`src/*.S`) per layer, with shared
structure layouts and macros in `include/`:

| Layer | Module | Responsibility |
|---|---|---|
| runtime | `util.S` | globals, error raising (`pq_raise` → `longjmp`), arenas, byte buffers, vectors, length-prefixed strings |
| text | `text.S` | number/date/timestamp/decimal parsing and canonical formatting, type names |
| JSON | `json.S` | strict RFC 8259 parser to a DOM, serializer |
| storage | `catalog.S`, `ingest.S` | immutable columnar tables; CSV / JSON / JSONL ingestion with inference and explicit schemas |
| SQL front end | `lexer.S`, `parser.S` | tokens → AST (`include/sql.inc`) |
| semantic analysis / planning | `binder.S` | name resolution, typing, implicit promotions, aggregate validation, output naming, ORDER BY resolution, constant LIMIT/OFFSET → query plan |
| execution | `eval.S`, `exec.S` | expression interpreter (incl. exact DECIMAL arithmetic with 128-bit intermediates, CAST matrix), scan → filter → aggregate → project → sort → offset/limit, JSON result serialization |
| protocol | `protocol.S`, `main.S` | CLI, JSON-lines session loop, `exec` mode, request validation, operations, path safety, fault guard |

Key decisions:

* **Error handling** uses glibc `_setjmp`/`longjmp`: any layer raises an error
  with a code and message; the request dispatcher reports it. Since all
  per-request memory comes from a request arena (reset per request) and tables
  under construction live in their own arena (destroyed on failure), no cleanup
  code is needed on error paths, and failed operations never modify the catalog.
* **Memory**: arenas (bump allocation in malloc'd chunks). The request arena
  carries the `--max-query-memory-mb` budget (exceeding it ⇒ `RESOURCE_LIMIT`).
  Each table owns an arena, freed on `drop`/`replace`/`reset`.
* **Storage** is columnar already: each column is a `u64` array plus a null
  byte map. BOOLEAN 0/1, INT64, FLOAT64 bits, DECIMAL unscaled i64, STRING as a
  pointer to a length-prefixed string, DATE days and TIMESTAMP microseconds
  since the epoch. This is the layout later phases (statistics, PQCF,
  vectorized execution) build on.
* **Types** are packed into one word (`kind | precision<<8 | scale<<16`). The
  binder inserts explicit promotion casts (INT→DECIMAL/FLOAT, DATE→TIMESTAMP),
  so the evaluator only sees same-kind operands (DECIMAL scales are aligned
  exactly with 128-bit arithmetic).
* **Evaluation** is a tree-walking interpreter returning `(payload, null)` in
  `rax:rdx`. Aggregates are bound to slots; the same mechanism will serve
  GROUP BY in Phase 2.
* **Sorting** uses `qsort_r` over row pointers with a multi-key comparator
  (NULLS FIRST/LAST, ASC/DESC).
* **Robustness**: SIGSEGV/SIGBUS/SIGFPE handlers on an alternate stack turn an
  unexpected fault inside a request into an `INTERNAL_ERROR` response instead
  of a crash; parser recursion depth is bounded.
* **Timeouts**: `timeout_ms` sets a monotonic deadline checked every 1024 scanned
  rows and inside `PQ_SLEEP` (10 ms slices).

## Implementation-defined choices

* Phase-2 syntax (`GROUP BY`, `HAVING`, `DISTINCT`, joins, subqueries, `CASE`,
  `IN`, `BETWEEN`, `LIKE`, `WITH`, `EXPLAIN`, `CREATE/DROP INDEX`, scalar
  functions such as `UPPER`) is parsed or recognised and answered with
  `UNSUPPORTED`; unknown function names give `SEMANTIC_ERROR`.
* In DECIMAL arithmetic an INT64 operand takes part as `DECIMAL(18,0)`
  (e.g. `1.5 * 2` is `DECIMAL(18,1)`); in comparisons the INT64 side is
  promoted to the other operand's scale.
* FLOAT64 output uses the shortest of `%.15g`/`%.16g`/`%.17g` that round-trips.
* `TIMESTAMP` literals and `CAST(string AS TIMESTAMP)` also accept a bare date
  (midnight).
* `LIMIT NULL` means no limit; a non-INT64 `LIMIT`/`OFFSET` is a `TYPE_ERROR`.
* An invalid type name in a load schema is `INVALID_REQUEST`; `header:false`
  without a schema is `INVALID_REQUEST`.
* JSON input must be valid UTF-8; lone surrogate escapes are rejected.

## Known limitations

* Only Phase 1 capabilities are implemented (see `NOTES.md`).
* `serve` (HTTP, Phase 4) is not implemented and exits with status 1.
* Single-threaded execution.
