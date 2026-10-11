# PolyQuery — x86-64 assembly engine

An in-memory analytical database engine implementing the PolyQuery
specification (`spec/`), written entirely in hand-written x86-64 assembly
(GNU as, AT&T syntax). Status: **Phase 2** (protocol, catalog, CSV/JSON/JSONL
ingestion, all data types, the complete SQL grammar: GROUP BY/HAVING,
DISTINCT, INNER/LEFT/CROSS joins, all scalar functions, CASE/LIKE/BETWEEN/IN,
uncorrelated and correlated subqueries, derived tables, CTEs, EXPLAIN,
structured errors, resource limits, test functions).

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
| lexer | `lexer.S` | SQL text → tokens with line/column |
| parser / AST | `parser.S`, `ast.S` | recursive descent over the full grammar → statement, query, FROM-item and expression nodes (`include/sql.inc`); `ast.S` gives generic child access to every expression kind |
| semantic analysis + logical plan | `binder.S` | scopes and range variables, CTE visibility, name resolution (incl. correlation), typing with implicit promotions, aggregate / GROUP BY validation by structural equality, output naming, ORDER BY resolution, constant LIMIT/OFFSET → plan tree (`QP_*` per query block, `FP_*` FROM tree, `RV_*` range variables) |
| scalar functions | `functions.S` | binding (typing) and evaluation of all scalar functions, CASE, LIKE, BETWEEN, IN lists |
| physical planning / EXPLAIN | `binder.S` (`find_equi`), `explain.S` | join algorithm choice (hash join on an equi-key conjunct, else nested loop); JSON plan rendering |
| execution | `eval.S`, `exec.S`, `hash.S` | expression interpreter (exact DECIMAL with 128-bit intermediates, CAST matrix); materialising operators: scan, hash / nested-loop join, filter, hash aggregation, projection, DISTINCT, sort, offset/limit; subquery evaluation; generic hash table on value cells |
| protocol | `protocol.S`, `main.S` | CLI, JSON-lines session loop, `exec` mode, request validation, operations (`query`, `explain`, …), path safety, fault guard |

The SQL pipeline is lex → parse (AST) → bind (semantic validation, typed
AST) → plan (logical plan tree with the physical join choice) → execute.
Errors detected before execution are reported without executing anything.

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
  `rax:rdx`. The evaluation context holds one row index per range variable
  (a *tuple*), the range variables' tables, the current group's aggregate
  values and a link to the enclosing query's context (correlation).
* **Query blocks** execute as materialising operators. The FROM clause
  produces a tuple set (row indices only: base tables are never copied;
  `-1` marks a NULL-padded LEFT JOIN side). Derived tables and CTEs are
  executed once (results of uncorrelated plans are cached in the plan) and
  converted into columnar tables, so every range variable is a table.
* **Joins**: the binder extracts the first `left_expr = right_expr` conjunct
  of `ON` whose sides reference only the left resp. right input; such joins
  run as hash joins (build on the right input, which is also the correct
  side for LEFT JOIN), others as nested loops. The full `ON` predicate is
  always re-checked. `--max-join-rows` bounds every join output.
* **Grouping** hashes the GROUP BY key cells (NULLs group together); each
  group keeps a representative tuple and aggregate states. Because every
  column reference outside aggregates must be (structurally) a GROUP BY
  expression, outputs, HAVING and ORDER BY are evaluated on the
  representative tuple. DISTINCT aggregates keep a per-group hash set.
* **Subqueries**: scalar, `IN` and `EXISTS` subqueries are bound in a child
  scope; an uncorrelated one is executed once and its value / hash set is
  cached in the expression node. A correlated one (a column resolves to an
  enclosing scope, bound as `EK_OUTER` with a level count) is re-executed for
  each evaluation with the outer context chain.
* **Sorting** uses `qsort_r` over row pointers with a multi-key comparator
  (NULLS FIRST/LAST, ASC/DESC).
* **Robustness**: SIGSEGV/SIGBUS/SIGFPE handlers on an alternate stack turn an
  unexpected fault inside a request into an `INTERNAL_ERROR` response instead
  of a crash; parser recursion depth is bounded.
* **Timeouts**: `timeout_ms` sets a monotonic deadline checked every 1024 scanned
  rows and inside `PQ_SLEEP` (10 ms slices).

## Implementation-defined choices

* `CREATE INDEX` / `DROP INDEX` are parsed and answered with `UNSUPPORTED`
  (indexes are Phase 3). `UNION`, `RIGHT` and `FULL` joins are `UNSUPPORTED`.
* `PARSE_ERROR` responses carry `details.line`/`details.column` of the
  offending token (lexical errors: of the current scan position).
* EXPLAIN plan nodes: `Limit`, `Sort`, `Distinct`, `Project`, `Filter`
  (`predicate` is `"WHERE"` or `"HAVING"`), `Aggregate`, `HashJoin` /
  `NestedLoopJoin` (with `join_type`), `TableScan` (catalog `table`, `alias`,
  `columns` actually referenced), `SubqueryScan` (derived table / CTE, with
  its plan as child) and `Values` (SELECT without FROM). Subqueries inside
  expressions are not shown.
* Common type of CASE / COALESCE branches: identical types stay as they are;
  otherwise numeric promotion per types.md §2 (so two different DECIMAL types
  give `DECIMAL(18, max scale)`); otherwise all must be equal.
* `HAVING` and `WHERE` cannot reference SELECT aliases (only GROUP BY and
  ORDER BY can, as the spec defines).
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

* Phase 3+ features (indexes, statistics, PQCF storage) are not implemented.
* `serve` (HTTP, Phase 4) is not implemented and exits with status 1.
* Single-threaded execution.
