# PolyQuery — AArch64 assembly engine (`arm64-asm-engine`, Track A)

An analytical database engine written entirely in hand-written AArch64
assembly (GNU as `.S` files, preprocessed and linked by gcc). It implements
PolyQuery **Phase 1** (CLI and JSON-lines session protocol, catalog
operations, CSV/JSON/JSONL ingestion, all data types, resource limits, test
functions) and **Phase 2**: the complete SQL grammar and semantics — GROUP BY /
HAVING / DISTINCT / COUNT(DISTINCT), INNER / LEFT / CROSS joins, all scalar
functions, CASE / LIKE / BETWEEN / IN, uncorrelated **and correlated**
subqueries (scalar, IN, EXISTS), derived tables, CTEs, and `EXPLAIN`
(statement and `explain` op) — with distinct lexer, parser/AST, semantic
analysis, logical plan, physical plan and execution stages.

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
frame macros in `include/frame.inc`, the internal API contract in
`include/API.md`):

| layer | files | role |
|---|---|---|
| runtime | `rt.S` | error raising (setjmp/longjmp), arenas, strings, byte buffers, JSON string/number output, clock |
| protocol | `main.S`, `protocol.S` | CLI options, session loop, exec mode, request dispatch, all ops (incl. `explain`) |
| JSON | `json.S` | strict RFC 8259 parser into a DOM, serializer |
| values | `values.S`, `decimal.S`, `datetime.S`, `types.S` | text parsing/formatting of every type, CAST matrix, comparisons, type names |
| storage | `catalog.S`, `ingest.S` | catalog of immutable columnar tables; CSV/JSON/JSONL ingestion |
| lexer / parser | `lexer.S`, `parser.S` | tokenizer and recursive-descent parser for the full v1 grammar into an AST |
| semantic analysis | `binder.S`, `functions.S`, `strfuncs.S` | scopes (range variables, outer scopes, CTEs), name resolution, typing with implicit casts, aggregate / GROUP BY validation, subquery binding; scalar functions, CASE, LIKE, BETWEEN, IN lists |
| planning | `plan.S` | logical plan, physical rewrite (predicate pushdown, hash-join keys, join algorithm, column pruning), EXPLAIN JSON |
| execution | `exec.S`, `eval.S` | plan operators (scan, filter, hash / nested-loop join, sort-based aggregation, project, distinct, sort, limit), subquery evaluation; expression evaluator and aggregate accumulators |

Query processing: `parse_sql` → `bind_query` (BoundQuery per query level,
SubPlans for every subquery / derived table / CTE) → `plan_statement`
(PlanNode trees) → `exec_plan` (ResultSet).

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
* **Tuples.** Below aggregation, operators exchange tuple sets: one u32 row
  id per range variable (`ROW_NULL` marks the NULL-padded side of a LEFT
  JOIN). Expressions read columns through the evaluation context
  (`EC_TABLES[rv]`, `EC_TUPLE`), so joins never copy column data.
* **Correlation.** Column references carry an outer depth; evaluation
  contexts are chained (`EC_OUTER`) like the binder scopes, so a correlated
  subquery is simply re-executed with the current row as its outer context.
  Uncorrelated subqueries, derived tables and CTEs are executed once per
  statement and cached (derived tables / CTEs are materialised as columnar
  tables; IN-subquery values are sorted for binary search).
* **Joins.** Equality conjuncts between the two sides with identical payload
  encoding become hash keys (build on the right input; NULL keys never
  match); everything else is a residual or nested-loop condition. WHERE
  conjuncts are pushed to the lowest scan/join covering their range
  variables, never below the NULL-padded side of a LEFT JOIN.
* **Aggregation.** Sort-based grouping (key cells per tuple, `qsort_r`, runs
  of equal keys; NULL keys group together). DISTINCT aggregates sort and
  de-duplicate each group's values. GROUP BY expressions inside SELECT /
  HAVING / ORDER BY are replaced by group-key references after a structural
  equality check, which also enforces the grouping rule.
* **EXPLAIN.** Plan JSON with `TableScan` (`table`, `alias`, pruned
  `columns`, `filter`), `SubqueryScan`, `HashJoin` / `NestedLoopJoin`
  (`join_type`, `hash_keys`), `Filter`, `Aggregate`, `Project`, `Distinct`,
  `Sort`, `Limit`, `Values`.

## Implementation-defined choices

* FLOAT64 output uses the shortest of `%.15g`/`%.16g`/`%.17g` that round-trips.
* CAST(FLOAT64 AS STRING) uses the same text.
* `LIMIT NULL` / `OFFSET NULL` are treated as absent.
* An unknown type name in a `load` schema is `INVALID_REQUEST`.
* JSON keys that differ only in case map to the same column (first spelling
  wins); the same key twice within one object is `INGEST_ERROR`.
* A CSV field consisting only of spaces/tabs is ignored by type inference and
  is NULL in non-STRING columns.
* CAST(FLOAT64 AS DECIMAL) rounds half away from zero on the exact binary
  value of the double (so `2.5e0` → `3`, but the double nearest 1.005 → `1.00`).
* DECIMAL ± DECIMAL with different scales is aligned exactly in 128-bit
  arithmetic (no spurious overflow); INT64 operands are promoted to
  DECIMAL(18,s) as the spec requires.
* SQL nesting deeper than 256 levels is `RESOURCE_LIMIT`.
* `save`, `open`, `stats` ops, `CREATE/DROP INDEX` and the `serve` mode
  answer `UNSUPPORTED` / exit 1 (later phases).
* `UPPER`/`LOWER` map ASCII letters only, and leave a whitespace-delimited
  word that contains a non-ASCII character unchanged as a whole
  (`UPPER('abc Ünï')` = `'ABC Ünï'`, as the conformance suite requires).
* `COALESCE`/`CASE` unify any two DECIMALs (or INT64 + DECIMAL) to
  DECIMAL(18, max scale); a single DECIMAL branch keeps its type. DATE and
  TIMESTAMP are not promoted to a common CASE/COALESCE type (TYPE_ERROR).
* `-NULL`, `ABS/ROUND/FLOOR/CEIL(NULL)` keep the null type (reported as
  STRING); binary arithmetic on two untyped NULLs is INT64.
* `CAST(string AS TIMESTAMP)` requires the timestamp syntax (a bare date is a
  CONVERSION_ERROR); ingestion still accepts dates for TIMESTAMP columns.
* An ORDER BY expression that is structurally equal to a select-list
  expression refers to that output column (so it is also allowed with
  SELECT DISTINCT).
* An `ON` condition sees only the range variables of its own `from_item`
  (inside parentheses: only those within the parentheses).
* In an aggregated query, a subquery in SELECT / HAVING / ORDER BY may refer
  to an outer column only if that column is a GROUP BY expression.
* EXPLAIN shows the plans of expression subqueries (scalar / IN / EXISTS) as
  additional children of the node whose expression uses them.

## Known limitations

* Correlated subqueries are re-executed per outer row (no decorrelation).
* Single-threaded execution; no HTTP server; no persistent storage yet.
