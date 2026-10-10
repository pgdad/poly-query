# PolyQuery — Python engine

An analytical database engine implementing the PolyQuery specification
(`spec/`) in pure Python. Current status: **Phase 3** (SQL v1 query engine
with row/column in-memory layouts, persistent PQCF v1 storage, statistics,
hash and ordered indexes and cost-based access-path selection).

Capabilities reported: `phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`,
`sql.basic`, `test.functions`, `phase2`, `sql.groupby`, `sql.join`,
`sql.functions`, `sql.subquery`, `sql.cte`, `sql.correlated_subquery`,
`phase3`, `storage.pqcf`, `storage.mmap`, `index.hash`, `index.btree`.

## Build prerequisites

* CPython 3.14 (`python3` on `PATH`). No other dependencies.
* **Libraries:** none. Only the Python standard library is used
  (`json`, `csv`, `decimal`-free integer arithmetic, `datetime`, `argparse`,
  `array`, `mmap`, `zlib` (CRC-32), `struct`, `bisect`, `unittest`, …).
  `sqlite3` is not used.

```sh
make build    # byte-compiles the package and smoke-tests the launcher
make test     # unit tests (unittest)
make lint     # compile with -W error + small stdlib-only lint (tools/lint.py)
make fmt      # whitespace normalisation (tools/fmt.py); no third-party formatter
make clean
bin/polyquery session --data-dir DIR     # JSON-lines protocol on stdin/stdout
bin/polyquery exec --request FILE|-      # one request or an array of requests
bin/polyquery version | capabilities
```

`bin/polyquery` is a POSIX shell launcher that resolves its own location and
runs `entry.py` with `python3 -I` (isolated mode: neither the current directory
nor `PYTHON*` environment variables can influence module loading).

## Architecture

Strictly layered; each layer only depends on the ones above it in this list.
A statement flows **lex → parse (AST) → bind (semantic validation & typing) →
logical plan → optimizer → physical plan → execution**.

| Package | Responsibility |
|---|---|
| `polyquery/datatypes.py`, `values.py`, `names.py` | SQL types, runtime value representation, exact decimal / date / timestamp helpers, ASCII identifier folding |
| `polyquery/storage/` | `table.py` (immutable `RowTable` / `ColumnTable` with row groups, lazily computed column statistics), `vectors.py` (typed column vectors, null bitmaps, dictionary encoding), `indexes.py` (hash and ordered indexes), `catalog.py` (tables + globally named indexes), `pqcf.py` (PQCF v1 writer with atomic replace, validating reader, lazy memory-mapped decoding) |
| `polyquery/ingest/` | CSV (stdlib `csv` reader in `QUOTE_NOTNULL` mode to distinguish `""` from empty) and JSON/JSONL ingestion, type inference, explicit-schema conversion, ingestion limits |
| `polyquery/sql/` | `lexer.py` (tokens with line/column), `parser.py` (recursive descent, complete v1 grammar), `ast.py` |
| `polyquery/analysis/` | `binder.py` (name resolution, CTE/derived-table/subquery binding, aggregate extraction, GROUP BY validation, ORDER BY resolution), `scope.py` (range variables, correlation tracking, CTE environments), `typing_rules.py` (promotion lattice, CAST matrix, CASE/IN/BETWEEN/LIKE typing), `functions.py` (function signatures & result types), `bound.py` (bound expression / query model) |
| `polyquery/planner/` | `planner.py` (bound query → logical plan), `logical.py` (Scan, Values, SubqueryScan, Filter, Join, Aggregate, Project, Distinct, Sort, Limit), `optimizer.py` (predicate pushdown, join-condition extraction), `physical.py` (algorithm and access-path choice: TableScan, IndexScan, LookupScan, HashJoin, NestedLoopJoin, HashAggregate, … with cardinality estimates, and the EXPLAIN JSON), `access.py` (index-usable predicates, selectivity estimation, index selection, row-group skipping), `explain.py` (expression rendering) |
| `polyquery/execution/` | `compiler.py` (bound expression → Python closure, incl. subquery evaluation), `functions.py` (scalar function kernels), `operators.py` (batch-at-a-time physical operators), `aggregates.py` (accumulators), `casts.py`, `context.py` (timeout / cancellation / memory budget / join-row limit, correlation parameters, per-statement caches) |
| `polyquery/service.py` | `Engine` facade: owns the catalog, runs `load`, SQL and `explain` |
| `polyquery/protocol/` | Transport-independent request handler (validation, path safety, responses), JSON-lines session loop, exec mode, canonical value serialization |
| `polyquery/cli.py` | Command line (`version`, `capabilities`, `session`, `exec`) |

### Storage (Phase 3)

* **Layouts.** `load`/`open` accept `{"options":{"layout":"row"|"column"}}`
  (default `column`; anything else is `INVALID_REQUEST`). A `RowTable` keeps a
  list of row tuples. A `ColumnTable` keeps row groups of typed vectors:
  `array('q')` for INT64 / DECIMAL (unscaled) / TIMESTAMP, `array('i')` for
  DATE, `array('d')` for FLOAT64, a 0/1 `bytearray` for BOOLEAN, and STRING
  either as a list of `str` or dictionary-encoded (`array('I')` codes + the
  distinct strings); NULLs are tracked in an LSB-first validity bitmap that
  is omitted when a vector has no NULLs. Both layouts implement the same
  `scan` / `fetch` / `column_values` interface, so query results are
  identical. `schema` reports `"layout"`.
* **Dictionary encoding** of STRING columns is applied automatically in the
  column layout when a column has fewer than n/2 distinct non-NULL values, and
  always with `{"options":{"dictionary":true}}`.
* **Statistics** (`stats` op and the planner): row count; per column NULL
  count, exact distinct count, min and max — computed on first use per column
  and cached (tables are immutable).
* **PQCF writer.** Row groups of `row_group_size` rows (default 65,536);
  chunks start 8-byte aligned; min/max are written for every type except
  STRING. Encoding `auto` chooses DICT for STRING columns with fewer than n/2
  distinct values and RLE for BOOLEAN/INT64/DECIMAL/DATE/TIMESTAMP chunks with
  fewer than n/4 runs, else PLAIN; `plain`/`dict`/`rle` force the encoding
  where it applies (PLAIN otherwise). In RLE, NULL slots continue the current
  run (their values are ignored by readers). The file is written to
  `.<target>.tmp-<pid>-<random>` in the target directory, fsynced, renamed
  over the target, and the directory is fsynced. Temporary files of earlier
  crashed saves (their pid no longer exists) are removed by the next save to
  the same target. A symlinked target is followed; a directory target or a
  missing parent directory is `IO_ERROR`. The table's indexes are recorded in
  the metadata.
* **PQCF reader.** `open` always validates header, version/flags, footer,
  metadata checksum, JSON and every structural rule of pqcf-v1.md §2 (unknown
  keys are ignored; type names are parsed like explicit schemas). Without
  `mmap` every chunk is then verified (CRC, exact size, bitmap/null_count,
  offsets, UTF-8, value ranges of §3.4) and decoded at `open`. With
  `{"options":{"mmap":true}}` the file is memory-mapped (`mmap` module) and
  each chunk is verified and decoded on first access, so a corrupt chunk
  makes the first query touching it fail with `STORAGE_CORRUPT` (nothing
  derived from it is returned). Indexes listed in the file are rebuilt; all
  index-name conflicts are checked before anything changes.
* **Indexes.** `HASH`: dict value → row positions. `BTREE`: the sorted
  permutation of the non-NULL rows (parallel key / row-id lists searched with
  `bisect`) supporting equality, IN and ranges. NULLs are never indexed.
  Index names are global and case-insensitive; dropping or replacing a table
  drops its indexes.

### Planning with statistics (Phase 3)

* **Index-usable predicates** are pushed-down conjuncts `col op constant`
  (`=`, `<`, `<=`, `>`, `>=`, `BETWEEN`, `IN` lists; constant on either side)
  where the column is not wrapped in a promotion and the constant (evaluated
  at planning time) is exactly representable in the column's type (e.g.
  `int_col = 1.5` or `dec2_col = 1.005` are left to the Filter).
* **Index selection.** Candidates are equality/IN lookups (hash or btree) and
  per-column ranges combining all range conjuncts (btree only). Selectivity:
  equality 1/distinct, IN k/distinct, ranges by linear interpolation between
  min and max for numeric/temporal types and 1/3 otherwise. The most
  selective candidate is used when its selectivity is ≤ 10%, or when it is
  expected to return at most 2 rows (a lookup that small never loses to a
  scan; this makes equality lookups on tiny tables use their index). The
  conjuncts the lookup implements are removed; the rest stay in a Filter.
  `use_indexes:false` never uses indexes.
* **Row-group skipping.** For tables opened from PQCF, the same predicates
  are checked against each row group's chunk min/max/null_count and groups
  that cannot contain a match are not read (EXPLAIN: `row_groups`,
  `row_group_filter` on the `TableScan`). The Filter above still evaluates
  every predicate.
* **Column pruning.** Scans read only the columns the query references.
* **Cardinality estimates** (every EXPLAIN node has `estimated_rows`) use the
  same selectivity rules; hash joins build on the input with the smaller
  estimate for INNER joins and on the right input for LEFT joins (EXPLAIN:
  `build`).

### Runtime value representation

`BOOLEAN` → `bool`, `INT64` → `int` (range-checked after every operation),
`FLOAT64` → `float` (non-finite results raise `NUMERIC_OVERFLOW`),
`DECIMAL(p,s)` → `int` holding the unscaled value (exact arbitrary-precision
intermediates; results checked against 18 digits), `STRING` → `str`,
`DATE` → `int` days since 1970-01-01, `TIMESTAMP` → `int` microseconds since
the epoch, `NULL` → `None`. Values are converted to their canonical JSON form
only at the protocol boundary.

### Binding and column keys

Every relation instance in a statement gets a unique id (`rel`): each range
variable of a FROM clause, each aggregation output and each projection. A bound
column reference is the *column key* `(rel, index)`; bound expressions are
frozen dataclasses with structural equality, which is what GROUP BY / ORDER BY
matching uses. Plan operators describe their output rows as a list of column
keys (*layout*); the expression compiler maps keys to tuple slots. A column key
that is not in an operator's input layout is a *correlation parameter*: a
reference from a subquery to an enclosing query, read from
`ExecutionContext.params`.

Aggregated queries are bound by first binding the GROUP BY keys, then binding
SELECT / HAVING / ORDER BY expressions with aggregate calls inline and
replacing (top-down) every sub-expression structurally equal to a grouping key
and every aggregate call by a reference to the Aggregate operator's output;
any remaining reference to a FROM column is a grouping violation
(`SEMANTIC_ERROR`).

### Subqueries and CTEs

* Scope chains resolve unqualified names innermost first; every scope that a
  resolution passes through records the outer column, so a subquery knows its
  correlation parameters (`Subquery.outer_keys`) and the enclosing expression
  carries the expressions that produce them (`args`, rewritten by GROUP BY
  substitution like any other expression). Derived tables and CTE bodies cannot
  see the FROM clause they appear in (no LATERAL), but can see enclosing queries.
* A subquery's physical plan is executed on demand by the expression that uses
  it; results are cached per distinct parameter tuple (an uncorrelated
  subquery runs at most once per statement). Scalar subqueries stop after two
  rows (cardinality check), `EXISTS` after one row.
* Correlated equality predicates (`inner_col = outer_col`) directly on a scan
  become a `LookupScan`: a hash table over the inner table is built once per
  statement and each execution only touches matching rows, which makes the
  common correlated `EXISTS` / scalar-aggregate patterns linear instead of
  quadratic. Compiled operator closures are cached per statement, so
  re-executing a subplan is cheap.
* CTEs are bound once at their definition (so errors are reported even for
  unused CTEs) and inlined at every reference (each reference gets its own
  relation id, so self-joins of a CTE work).

### Planning and execution

* Predicate pushdown: WHERE / ON conjuncts referencing only one side of an
  inner/cross join move below the join; conjuncts over both sides become join
  conditions. For LEFT joins, WHERE conjuncts on the preserved side and ON
  conjuncts on the nullable side are pushed. (Disabled by `optimize:false`.)
* Join algorithm: equality conjuncts whose sides reference disjoint inputs
  become hash-join keys (build side chosen by estimated size, see above; DECIMAL keys of different
  scales are aligned; NULL keys never match), the remaining conjuncts are a
  residual predicate; otherwise a nested-loop join. `join:"nested_loop"`
  forces nested loops. `--max-join-rows` is enforced per join.
* Grouping is a hash aggregation (dict of key tuple → rows, then batch
  accumulators per group); without GROUP BY one group is always produced.
* Operators exchange batches of up to 2048 row tuples. Scans zip only the
  referenced columns (column pruning). Expressions are compiled once into
  closures; projection lists into a single generated tuple-building function.
  Timeouts, cancellation and memory accounting are checked per batch;
  `PQ_SLEEP` sleeps in ≤ 10 ms slices.
* `EXPLAIN` / the `explain` op return the physical plan as JSON
  (`TableScan` with `table`/`columns`, `HashJoin`/`NestedLoopJoin` with
  `join_type`, …). Plans of subqueries used by an operator are listed under
  that node's `subqueries` key.

## Design decisions (where the spec leaves room)

* **CSV**: completely empty lines (also `\r\n`-only lines) are skipped.
  A field consisting only of spaces/tabs is treated like an empty field for
  non-STRING columns (NULL) and is not considered during inference. Header-only
  input yields an empty table of STRING columns; input without a header record
  is an `INGEST_ERROR`. A quote character inside an unquoted field is kept
  literally; text after a closing quote is an `INGEST_ERROR`.
  With an explicit schema and a header, the schema's spelling of column names is
  used.
* **Ingestion request errors**: an unknown type name in an explicit schema,
  a non-boolean `header`, an invalid `delimiter` (must be one ASCII character
  other than `"`, CR, LF) and `header:false` without a schema are
  `INVALID_REQUEST`.
* **JSON**: keys are matched ASCII case-insensitively; two keys that differ only
  in case (in one object or across objects) are an `INGEST_ERROR` (duplicate
  column). Lone UTF-16 surrogates in strings and numbers that overflow FLOAT64
  are `INGEST_ERROR`. Values of non-STRING columns given as JSON strings are
  trimmed of spaces/tabs before conversion (CSV rule).
* **Literals / CAST**: `TIMESTAMP '…'` literals and `CAST(… AS TIMESTAMP)`
  require the full timestamp syntax of types.md §3 (a bare date is only accepted
  by ingestion, as ingestion.md states explicitly). `CAST` from STRING trims
  ASCII whitespace for BOOLEAN/INT64/DECIMAL/FLOAT64 (as the CAST table says)
  but not for DATE/TIMESTAMP. FLOAT64 → STRING uses Python's shortest
  round-trip `repr` (`-0.0` → `0.0`).
* **Promotion**: in arithmetic an INT64 operand combined with a DECIMAL keeps
  scale 0 (`DECIMAL(18,0)`, as `1.5 * 2` → `DECIMAL(18,1)` requires); in
  comparisons an INT64 operand is promoted to `DECIMAL(18, s)` of the DECIMAL
  side; if it then needs more than 18 digits that raises `NUMERIC_OVERFLOW`
  (types.md §2). Two DECIMALs compare exactly by value. The untyped `NULL` literal in arithmetic
  takes the other operand's type (INT64 if both are NULL); unary minus keeps the
  null type. `SUM(NULL)` is INT64, `AVG(NULL)` FLOAT64.
* **ORDER BY**: only an unsigned integer literal is an ordinal (`0` is out of
  range); `ORDER BY -1` is a constant sort key.
* **Requests**: `NaN`/`Infinity` make a request line invalid JSON; a request
  whose `id` cannot be echoed (a number beyond the FLOAT64 range) is rejected
  with `INVALID_REQUEST` before it is executed.
* **Decimal division** computes the exact quotient and rounds once to FLOAT64.
  `AVG` over INT64/DECIMAL sums exactly before the single final division;
  float `SUM`/`AVG` use `math.fsum`.
* **LIMIT/OFFSET** must be constant INT64 expressions; `NULL` means "no limit".
  They are evaluated during validation, so a negative value is
  `INVALID_ARGUMENT` also for `EXPLAIN`.
* Subqueries compare structurally (same SQL text modulo positions, same
  correlation), so `GROUP BY <expr with subquery>` matches the identical
  select-list expression.
* **Query options**: `mode` accepts `auto` and `row` (this engine is
  row/batch based); `vectorized` and unknown values of known enum options are
  `UNSUPPORTED`; ill-typed option values are `INVALID_REQUEST`. `optimize`,
  `use_indexes` and `join:"nested_loop"` are honoured; `threads`,
  `join:"hash"|"merge"` and `native` are validated and otherwise ignored.
* Unknown ops are `INVALID_REQUEST`. `FULL`/`RIGHT` joins and `UNION` answer
  `UNSUPPORTED`.
* **CREATE INDEX** validates table and column first (`SEMANTIC_ERROR`), then
  the name (`ALREADY_EXISTS` unless `IF NOT EXISTS`). Explaining a
  `CREATE`/`DROP INDEX` statement with the `explain` op is `UNSUPPORTED`.
* **save/open options**: `encoding` must be `auto`/`plain`/`dict`/`rle`
  (case-insensitive) and `row_group_size` a positive integer, else
  `INVALID_REQUEST`. `open` answers the table's schema and indexes. A file
  with zero columns, duplicate index names or an unknown index kind is
  `STORAGE_CORRUPT`; min/max statistics that cannot be interpreted are
  ignored (they only serve row-group skipping). Opening a file with more rows
  than `--max-table-rows` is `RESOURCE_LIMIT`. OS permission errors are
  `ACCESS_DENIED`, other OS errors `IO_ERROR`.
* **UPPER / LOWER**: only ASCII letters are case-mapped, and a word (a run of
  non-whitespace characters) that contains a non-ASCII character is left
  unchanged as a whole. functions.md only says "ASCII letters only are
  case-mapped", but the public suite expects `UPPER('abc Ünï')` = `'ABC Ünï'`
  and `LOWER('ABC ÜNÏ')` = `'abc ÜNÏ'`, which a per-character mapping cannot
  produce; the word rule is the simplest rule consistent with both.
* **Common types** (CASE, COALESCE, IN, BETWEEN): identical types stay as they
  are (two `DECIMAL(3,2)` stay `DECIMAL(3,2)`); otherwise numeric promotion
  (two different DECIMALs → `DECIMAL(18,max(s))`), DATE+TIMESTAMP → TIMESTAMP.
  IN lists and BETWEEN promote the operand and all items to one common type.
* **Function argument typing**: `ABS`/`ROUND`/`FLOOR`/`CEIL` return "the same
  type" as their argument, so an untyped `NULL` argument stays the null type
  (reported as STRING); other functions have fixed result types;
  `NULLIF(a, b)` has the type of `a` and compares in the common type.
  `ROUND`'s digits and the `DATE_TRUNC`/`DATE_DIFF` unit must be constant
  (`SEMANTIC_ERROR` otherwise) and are evaluated during validation, so an
  unknown unit is reported as `INVALID_ARGUMENT` before execution. Units are
  matched case-insensitively. FLOAT64 `ROUND` rounds the shortest decimal
  representation half away from zero.
* **HAVING / WHERE** cannot reference SELECT aliases (only GROUP BY and ORDER BY
  can, as semantics.md specifies).
* An aggregate call inside a subquery always belongs to the subquery, even if
  its argument only references outer columns.
* **Memory budget**: materialized rows (sort buffers, DISTINCT sets, results)
  are accounted at ~64 bytes + 16 bytes per value against
  `--max-query-memory-mb` (default 4096) → `RESOURCE_LIMIT`.
* Default limits: `--max-ingest-bytes` 4 GiB, `--max-table-rows` 200,000,000.
* Responses are serialized with ASCII escaping (`\uXXXX`) so the output is always
  valid UTF-8 JSON on one line.

## Known limitations

* No HTTP server yet (Phase 4).
* In-memory tables loaded from CSV/JSON are a single row group without
  min/max zone maps, so row-group skipping applies to PQCF-backed tables only.
* Decoded vectors of memory-mapped files are cached once read, so a fully
  scanned mmap table ends up resident like an eagerly opened one.
* `save` materializes each column of the table as a Python list while
  writing (memory ≈ one decoded copy of the table).
* Indexes are used for single-table predicates only (no index nested-loop
  joins) and never to produce ordered output.
* Correlated subqueries are executed per distinct parameter tuple (with the
  LookupScan optimisation for equality correlation); correlation through
  non-equality predicates is evaluated by re-running the subquery and can be
  slow on large inputs.
* No merge join; `join:"merge"` is accepted and planned like `auto`.
* Single-threaded execution; the CSV/JSON readers hold the whole input in memory.
