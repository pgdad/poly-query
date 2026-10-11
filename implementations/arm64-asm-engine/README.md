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
analysis, logical plan, physical plan and execution stages — and **Phase 3**:
row- and column-oriented in-memory layouts, dictionary encoding, null
bitmaps, the PQCF v1 file format (`save` / `open`, PLAIN / DICT / RLE,
CRC-32, atomic crash-safe writes, memory-mapped reads), table statistics
(`stats`), HASH and BTREE indexes (`CREATE` / `DROP INDEX`), cost-based
index selection, predicate pushdown with PQCF row-group skipping, column
pruning, join build-side selection and EXPLAIN plans with `IndexScan`.

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
| storage | `catalog.S`, `ingest.S`, `storage.S`, `pqcf.S`, `index.S` | catalog of immutable tables; CSV/JSON/JSONL ingestion; row / column layouts, dictionary encoding, statistics; PQCF v1 reader/writer; HASH / BTREE indexes |
| lexer / parser | `lexer.S`, `parser.S` | tokenizer and recursive-descent parser for the full v1 grammar into an AST |
| semantic analysis | `binder.S`, `functions.S`, `strfuncs.S` | scopes (range variables, outer scopes, CTEs), name resolution, typing with implicit casts, aggregate / GROUP BY validation, subquery binding; scalar functions, CASE, LIKE, BETWEEN, IN lists |
| planning | `plan.S`, `access.S` | logical plan, physical rewrite (predicate pushdown, hash-join keys, join algorithm, column pruning, build side), access paths (simple predicates, selectivity estimates, index selection, row-group skipping), EXPLAIN JSON |
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
* **Storage.** Every table lives in its own arena (freed on drop/replace).
  Two in-memory layouts (`load`/`open` option `layout`, default `column`):
  *column*: per column a vector of 64-bit payloads, or for STRING columns a
  dictionary encoding (u32 codes + dictionary of distinct strings; applied
  automatically when distinct values ≤ rows/2, or forced with
  `"dictionary":true`), plus a null bitmap (absent when the column has no
  NULL); *row*: a row store of fixed-size records (payloads followed by the
  row's null bitmap). Tables are built column-wise by ingestion / the PQCF
  reader and then converted (`table_finalize`). The evaluator's column access
  (`ev_col`) and the generic accessor `tbl_get` handle every representation.
* **Statistics.** `table_stats` computes per column null count, min, max and
  the exact distinct count (hash set) on first use and caches them (tables
  are immutable).
* **Indexes.** Single-column, global names. HASH: chained hash table over row
  ids (heads per bucket, next per row). BTREE: the "equivalent ordered
  structure" of the spec — a sorted permutation of the non-NULL row ids with
  the sorted values, searched by binary search for equality and ranges.
  NULLs are never indexed. Indexes are rebuilt from the table data when
  created / opened and dropped with their table.
* **Access paths.** Pushed-down scan filters are split into conjuncts;
  `column op constant` (op `= < <= > >=`, `BETWEEN` → two bounds) and
  `column IN (constants)` become *simple predicates* with the constant
  evaluated at planning time (literals, negation and the binder's implicit
  casts only, so planning never raises). Selectivity: equality 1/distinct,
  IN k/distinct, ranges by linear interpolation between min and max for
  numeric/temporal columns (both bounds of a column combined), 1/3 otherwise.
  The most selective indexable predicate is executed through its index when
  its selectivity is ≤ 10%, or when it is an equality / IN lookup expected to
  return at most 16 rows (cheaper than any scan). An index scan sorts and
  de-duplicates the candidate row ids and still evaluates the complete filter,
  so results never depend on the access path (`use_indexes:false` disables
  indexes). For PQCF-backed tables, row groups whose min/max/null statistics
  exclude a simple predicate are skipped.
* **Joins (Phase 3).** Scan and join cardinalities are estimated bottom-up;
  an inner hash join builds on the input with the smaller estimate (the
  inputs are swapped — tuples keep one slot per range variable, so the
  output does not depend on the order); LEFT joins build on the right.
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
* The `serve` mode answers exit 1 (Phase 4).
* `CREATE INDEX` without `USING` creates a BTREE index.
* An unknown table or column in `CREATE INDEX` is `SEMANTIC_ERROR`.
* EXPLAIN shows `estimated_rows` on scans and joins, `index`/`kind` on
  `IndexScan`, and `row_groups` / `row_groups_skipped` on scans of
  PQCF-backed tables; `schema` reports `layout`.
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
* Single-threaded execution; no HTTP server.
* Converting a table to the row layout or dictionary-encoding its columns
  keeps the intermediate column vectors in the table arena until the table
  is dropped (memory, not correctness).
