# PolyQuery — x86-64 assembly engine

An in-memory analytical database engine implementing the PolyQuery
specification (`spec/`), written entirely in hand-written x86-64 assembly
(GNU as, AT&T syntax). Status: **Phase 3** (protocol, catalog, CSV/JSON/JSONL
ingestion, all data types, the complete SQL grammar: GROUP BY/HAVING,
DISTINCT, INNER/LEFT/CROSS joins, all scalar functions, CASE/LIKE/BETWEEN/IN,
uncorrelated and correlated subqueries, derived tables, CTEs, EXPLAIN,
structured errors, resource limits, test functions; row and column
in-memory layouts with NULL bitmaps and dictionary encoding, table
statistics, HASH and ordered (BTREE) indexes, predicate pushdown, index
selection, row-group skipping, column pruning, join build-side selection,
and the PQCF v1 columnar file format with PLAIN/DICT/RLE encodings, CRC-32
checksums, atomic crash-safe saves and memory-mapped reads).

## Build prerequisites

| Tool | Version | Use |
|---|---|---|
| GNU binutils (`as`, `ld`) | 2.42 | assembler / linker |
| gcc | 13.3 | **driver only**: runs cpp on `.S` files, the assembler and the linker. No C source exists anywhere in the build. |
| glibc (libc, libm, libpthread) | system | dynamically linked runtime (malloc, read/write, strtod, snprintf, qsort_r, setjmp/longjmp, …) |
| GNU make, POSIX sh | any | build and tests |

```
make build        # -> out/polyquery
make test         # assembly unit tests (text, JSON, ingest, hash, SQL,
                  # storage, planner) + end-to-end session tests
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
| storage | `catalog.S`, `ingest.S`, `table.S` | catalog of immutable tables; CSV / JSON / JSONL ingestion with inference and explicit schemas; physical row / column layouts, NULL bitmaps, dictionary encoding, lazily computed statistics |
| indexes | `index.S` | HASH (chained over row ids) and BTREE (sorted permutation + keys, binary search) indexes; CREATE / DROP INDEX |
| PQCF files | `pqcf.S` | PQCF v1 writer (PLAIN / DICT / RLE, chunk statistics), validating reader, CRC-32, UTF-8 validation, atomic replacement |
| lexer | `lexer.S` | SQL text → tokens with line/column |
| parser / AST | `parser.S`, `ast.S` | recursive descent over the full grammar → statement, query, FROM-item and expression nodes (`include/sql.inc`); `ast.S` gives generic child access to every expression kind |
| semantic analysis + logical plan | `binder.S` | scopes and range variables, CTE visibility, name resolution (incl. correlation), typing with implicit promotions, aggregate / GROUP BY validation by structural equality, output naming, ORDER BY resolution, constant LIMIT/OFFSET → plan tree (`QP_*` per query block, `FP_*` FROM tree, `RV_*` range variables) |
| scalar functions | `functions.S` | binding (typing) and evaluation of all scalar functions, CASE, LIKE, BETWEEN, IN lists |
| physical planning / EXPLAIN | `binder.S` (`find_equi`), `planner.S`, `explain.S` | join algorithm choice (hash join on an equi-key conjunct, else nested loop); predicate pushdown, index selection, row-group skipping, cardinality estimates and hash-join build side; JSON plan rendering |
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
* **Values** are one `u64` slot each: BOOLEAN 0/1, INT64, FLOAT64 bits,
  DECIMAL unscaled i64, STRING as a pointer to a length-prefixed string, DATE
  days and TIMESTAMP microseconds since the epoch.
* **Physical layouts** (`table.S`, option `layout` of `load`/`open`, default
  `column`): ingestion fills a staging form (slots + NULL bytes) which
  `table_finalize` turns into either
  * the *column* layout — one dense vector per column plus a NULL bitmap
    (omitted when the column has no NULLs); STRING columns are dictionary
    encoded (u32 codes + dictionary of shared strings) when the distinct
    count is at most half the rows, or always with `"dictionary":true`; or
  * the *row* layout — one row-major block of tuples (the slots followed by
    the tuple's NULL bitmap words).
  Each Column carries accessor fields (data base, stride, NULL bitmap base,
  bit stride and bit offset, dictionary), so one accessor (`col_get`) serves
  both layouts and the rest of the engine is layout-agnostic: results are
  identical by construction. `schema` reports the layout.
* **Statistics** (`stats` op, planner): per column NULL count, distinct
  count (exact with a hash set up to 200,000 values, then a HyperLogLog
  sketch, so memory stays bounded), min and max; computed on first use per
  column and cached in the (immutable) table.
* **Indexes** (`index.S`) are single-column and belong to their table (dropped
  with it, or when it is replaced); names are global. `HASH`: bucket heads and
  a per-row `next` array over row ids. `BTREE`: an ordered structure realised
  as the non-NULL row ids sorted by (value, row id) plus the sorted keys;
  equality and range lookups by binary search. NULLs are never indexed.
  `CREATE INDEX` defaults to `BTREE`; each index owns an arena freed by
  `DROP INDEX`.
* **Planning** (`planner.S`, run for every query block after binding):
  WHERE conjuncts referencing exactly one range variable (that is not on the
  NULL-padded side of a LEFT JOIN, and without correlated subqueries) are
  pushed into that variable's scan; `col = c`, `col IN (c, ...)` and range
  conjuncts (`<`, `<=`, `>`, `>=`, `BETWEEN`, intersected per column) with
  literal constants that convert exactly to the column type are analysed with
  the statistics (equality 1/distinct per value; ranges by linear
  interpolation between min and max for numeric/temporal types, 1/3
  otherwise). An index is used when its estimated selectivity is ≤ 10%
  (and, for tiny tables, for equality lookups estimated at ≤ 16 rows). For
  PQCF-backed tables, row groups whose chunk min/max (or all-NULL chunk)
  exclude a constraint are skipped. Inner hash joins build on the input with
  the smaller estimated cardinality; LEFT joins build on the right input.
  `use_indexes:false` disables index use; `optimize:false` disables pushdown
  (and thereby index use and row-group skipping). Pushed conjuncts are
  always re-evaluated on every candidate row, so index lookups and skipping
  only need to be conservative.
* **Column pruning** is inherent: scans produce row ids, and only the columns
  the query references (shown as `columns` of `TableScan`/`IndexScan`) are
  ever read.
* **PQCF** (`pqcf.S`): `save` assembles the file in memory (8-byte aligned
  chunks, row groups of `row_group_size` rows, default 65536; encodings
  `auto` = RLE when runs < n/4 for BOOLEAN/INT64/DECIMAL/DATE/TIMESTAMP, DICT
  when distinct < n/2 for STRING, else PLAIN; `plain`/`dict`/`rle` force the
  encoding where the type allows it, PLAIN otherwise; min/max written for
  every type), writes it to `.<name>.tmp-<pid>-<seq>` in the target's
  directory, `fsync`s it, `rename`s it over the target and `fsync`s the
  directory. `open` validates header, footer, metadata CRC and structure,
  every chunk's CRC and every value (UTF-8, offsets, decimal precision,
  date/timestamp range, finite floats, RLE booleans and run lengths,
  dictionary codes, bitmap NULL counts, exact chunk sizes) before the table
  is published, then recreates the file's indexes. With `"mmap":true` (and
  the default column layout) the file is memory-mapped (`mmap(2)`) and
  decoded lazily: `open` validates header, footer, metadata checksum and the
  complete metadata structure, and every column is decoded — its chunk CRCs
  verified and every value validated — on its first access (`col_get` tests
  one flag), so queries only decode the columns they reference; a corrupt
  chunk then fails the query that touches it with `STORAGE_CORRUPT` and the
  column stays undecoded. The table owns the mapping until it is dropped or
  replaced; `save` always writes a new file and renames it, so saving over an
  open file never disturbs the mapping. Without `mmap` (or with the row
  layout) the file is read and decoded completely at `open`. Row-group
  min/max statistics are kept for skipping.
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

* `UNION`, `RIGHT` and `FULL` joins are `UNSUPPORTED`.
* EXPLAIN shows pushed-down conjuncts as a `Filter` node (`"predicate":"WHERE
  (pushed down)"`) directly above the scan; `IndexScan` nodes carry `index`,
  `kind` and `lookup` (`equality`/`range`); scans carry `estimated_rows` and,
  for PQCF-backed tables with skipped groups, `row_groups_skipped`;
  `HashJoin` carries `build` (`left`/`right`).
* PQCF: an unknown `encoding` save option is `INVALID_REQUEST`;
  `row_group_size` 0 means the default. Index names duplicated inside a file
  are `STORAGE_CORRUPT`. A metadata `row_count` above `--max-table-rows` is
  `RESOURCE_LIMIT`. Temporary files of a crashed save are not removed
  automatically (readers ignore them).
* `load`/`open` option `layout` other than `"row"`/`"column"` is
  `INVALID_REQUEST`.
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
* `UPPER`/`LOWER` map ASCII letters only, and leave a whole word (maximal run
  of ASCII letters/digits and non-ASCII characters) unchanged when it contains
  a non-ASCII character: `UPPER('abc Ünï')` is `'ABC Ünï'` (as the conformance
  suite expects).
* `ROUND(x, n)` with a NULL `n` is NULL; `DATE_TRUNC`/`DATE_DIFF` with a NULL
  unit are NULL. Constant arguments (`ROUND`'s `n`, units) are evaluated at
  validation time.
* Comparisons inside `IN` lists, `BETWEEN`, simple `CASE` and `NULLIF` promote
  per pair at run time (INT64 vs DECIMAL compares exactly; DATE vs TIMESTAMP
  uses midnight).
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

* Without `mmap`, PQCF files are decoded completely at `open`.
* A lazily opened file must not be modified in place by other processes while
  it is open (PQCF files are immutable; the engine itself only replaces files
  by rename).
* Distinct counts are exact up to 200,000 distinct values per column and
  HyperLogLog estimates (2^14 registers, ~1% error) beyond.
* Index contents are rebuilt whenever a table is loaded or opened (PQCF
  persists only index definitions); statistics are recomputed per table on
  first use.
* `serve` (HTTP, Phase 4) is not implemented and exits with status 1.
* Single-threaded execution.
