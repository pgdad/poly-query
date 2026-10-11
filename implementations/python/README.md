# PolyQuery — Python engine

An analytical database engine implementing the PolyQuery specification
(`spec/`) in pure Python. Current status: **Phase 5** (SQL v1 query engine
with row/column in-memory layouts, persistent PQCF v1 storage, statistics,
hash and ordered indexes, cost-based access-path selection, an HTTP/1.1
server with streaming results, admission control, timeouts, cancellation,
Prometheus metrics, structured logs and graceful shutdown; plus two execution
engines — row-at-a-time and vectorized —, hash / sort-merge / nested-loop
joins, parallel partitioned pipelines and a switchable rule-based logical
optimizer, separate from physical planning (CR-3)).

Capabilities reported: `phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`,
`sql.basic`, `test.functions`, `phase2`, `sql.groupby`, `sql.join`,
`sql.functions`, `sql.subquery`, `sql.cte`, `sql.correlated_subquery`,
`phase3`, `storage.pqcf`, `storage.mmap`, `index.hash`, `index.btree`,
`phase4`, `http.streaming`, `phase5`, `exec.row`, `exec.vectorized`,
`exec.parallel`, `join.hash`, `join.merge`, `join.nested_loop`,
`native.kernels` (M9: the native kernel library `libpqkernels` is used
through `ctypes` when loaded, see *Native kernels* below), `change.union_all`
(change request CR-1, `UNION ALL`, see *UNION ALL (CR-1)* below),
`change.decimal38` (change request CR-2, DECIMAL precision 38 and PQCF v2,
see *DECIMAL precision 38 (CR-2)* below).

## Build prerequisites

* CPython 3.14 (`python3` on `PATH`). No other dependencies.
* Optional: the native kernel library, built with `make -C native-kernels`
  (`native-kernels/build/x86_64/libpqkernels.so`) and passed with
  `--native-kernels PATH`. It is loaded with the standard library's `ctypes`;
  the engine works identically without it.
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
bin/polyquery serve --port N [--workers N --queue-depth Q --query-timeout-ms T ...]
bin/polyquery version | capabilities
python3 tools/bench.py --data DIR       # Phase 5 benchmarks over pqgen.py datasets
python3 tools/workload.py --data DIR [--before OLD/bin/polyquery]   # analytics workload latency
python3 tools/difftest.py --seed N      # random queries under the whole option matrix
python3 tools/native_difftest.py --lib LIB   # native: true vs false on random queries
python3 tools/native_bench.py --lib LIB      # kernel micro-benchmarks vs the CPython code
```

Engine-specific flag: `--parallel-min-rows N` (default 200,000): parallel
pipelines whose driving scan has fewer rows run their partitions in-process
(see Phase 5). It is also the size from which a query *without* a `threads`
option is parallelized automatically when `--threads` is not given (see
*Latency optimization* below).

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
| `polyquery/native/` | `kernels.py`: `ctypes` binding of the `libpqkernels` C ABI (signatures, ABI check, zero-copy buffer addresses, loading with fallback) |
| `polyquery/storage/` | `table.py` (immutable `RowTable` / `ColumnTable` with row groups, lazily computed column statistics), `vectors.py` (typed column vectors, null bitmaps, dictionary encoding), `indexes.py` (hash and ordered indexes), `catalog.py` (tables + globally named indexes), `pqcf.py` (PQCF v1 writer with atomic replace, validating reader, lazy memory-mapped decoding) |
| `polyquery/ingest/` | CSV (stdlib `csv` reader in `QUOTE_NOTNULL` mode to distinguish `""` from empty) and JSON/JSONL ingestion, type inference, explicit-schema conversion, ingestion limits |
| `polyquery/sql/` | `lexer.py` (tokens with line/column), `parser.py` (recursive descent, complete v1 grammar), `ast.py` |
| `polyquery/analysis/` | `binder.py` (name resolution, CTE/derived-table/subquery binding, aggregate extraction, GROUP BY validation, ORDER BY resolution), `scope.py` (range variables, correlation tracking, CTE environments), `typing_rules.py` (promotion lattice, CAST matrix, CASE/IN/BETWEEN/LIKE typing), `functions.py` (function signatures & result types), `bound.py` (bound expression / query model) |
| `polyquery/planner/` | `pipeline.py` (bound statement → logical plan → optimizer → physical plan), `planner.py` (bound query → logical plan), `logical.py` (`LogicalPlan`; Scan, Values, SubqueryScan, UnionAll, Filter, Join, Aggregate, Project, Distinct, Sort, Limit; `format_plan`), `optimizer.py` (rule-based optimizer) with `rules/` (one module per rule: constant folding, predicate simplification, predicate pushdown, column pruning), `physical.py` (all execution decisions: TableScan, IndexScan, LookupScan, HashJoin, MergeJoin, NestedLoopJoin, HashAggregate, TopN, Gather, … with cardinality estimates, join reordering, parallel pipelines, execution mode, native kernel plans, and the EXPLAIN JSON), `access.py` (index-usable predicates, selectivity estimation, index selection, row-group skipping), `explain.py` (expression rendering) |

| `polyquery/execution/` | `compiler.py` (bound expression → row closure, incl. subquery evaluation), `vcompiler.py` (bound expression → vector function over column batches), `row_engine.py` (row-at-a-time Volcano operators, `mode:"row"`), `vector_engine.py` (column-batch operators, `mode:"vectorized"`/`auto`), `parallel.py` (partitioned execution of `Gather` pipelines, in-process or in worker processes), `worker_pool.py` (persistent forked worker processes, plans sent by reference), `semi_join.py` (correlated `EXISTS` as a hash semi-join), `common.py` (algorithms shared by both engines: merge pairing, sort orders, join limits, LookupScan tables), `group_states.py` (columnar aggregation state of the vectorized engine), `aggregates.py` (accumulators of the row engine), `functions.py` (scalar function kernels), `casts.py`, `executor.py` (mode dispatch, result streaming), `context.py` (timeout / cancellation / memory budget / join-row limit, correlation parameters, per-statement caches, GC pausing) |
| `polyquery/execution/native_ops.py` | Execution paths that use the kernels (`native: true`): scan filtering, gathers, scan aggregation, group sums, hash partitioning; `kernel_plan` compiles the kernel plan of an operator for the physical planner |
| `polyquery/service.py` | `Engine` facade: owns the catalog, runs `load`, SQL and `explain` |
| `polyquery/protocol/` | Transport-independent request handler (validation, path safety, responses, streaming cursor), JSON-lines session loop, exec mode, canonical value serialization |
| `polyquery/server/` | `serve` mode: `http.py` (HTTP/1.1 routing, bodies, JSON / NDJSON responses, query lifecycle), `queries.py` (query registry + admission control), `watcher.py` (client-disconnect detection), `metrics.py` (Prometheus text), `app.py` (server lifecycle, signals, graceful shutdown) |
| `polyquery/cli.py` | Command line (`version`, `capabilities`, `session`, `exec`, `serve`), JSON-lines log formatter |

### Storage (Phase 3)

* **Layouts.** `load`/`open` accept `{"options":{"layout":"row"|"column"}}`
  (default `column`; anything else is `INVALID_REQUEST`). A `RowTable` keeps a
  list of row tuples. A `ColumnTable` keeps row groups of typed vectors:
  `array('q')` for INT64 / narrow DECIMAL (unscaled) / TIMESTAMP, a list of
  Python ints for wide DECIMAL (precision > 18, CR-2), `array('i')` for
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
* **Column pruning.** Scans read only the columns the query references; a
  top-down pass also removes derived-table / CTE output columns the enclosing
  query never reads (when they are plain column references or literals), so
  `WITH w AS (SELECT * FROM t) SELECT a FROM w` reads only `a`.
* **Cardinality estimates** (every EXPLAIN node has `estimated_rows`) use the
  same selectivity rules; hash joins build on the input with the smaller
  estimate for INNER joins and on the right input for LEFT joins (EXPLAIN:
  `build`).

### Runtime value representation

`BOOLEAN` → `bool`, `INT64` → `int` (range-checked after every operation),
`FLOAT64` → `float` (non-finite results raise `NUMERIC_OVERFLOW`),
`DECIMAL(p,s)` → `int` holding the unscaled value, for narrow and wide
decimals alike (exact arbitrary-precision intermediates; results checked
against the result precision, 18 or 38 digits), `STRING` → `str`,
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
* Correlated `EXISTS` whose subquery is a `LookupScan` with conditions that
  cannot fail and read no other outer column (`execution/semi_join.py`) is
  a set membership test: the keys of the inner rows satisfying the
  conditions are collected once per statement, vectorized.
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
  conjuncts on the nullable side are pushed. Conjuncts on a derived table /
  CTE move below its projection when neither the conjunct nor any projected
  expression can fail (see CR-3 below). (Disabled by `optimize:false`.)
* Join keys: equality conjuncts whose sides reference disjoint inputs become
  equi-join keys (DECIMAL keys of different scales are aligned; NULL keys
  never match), the remaining conjuncts are a residual predicate; joins
  without keys are nested-loop joins. The algorithm is chosen as described
  in Phase 5 below. `--max-join-rows` is enforced per join.
* Grouping is a hash aggregation; without GROUP BY one group is always
  produced. Groups are emitted in the order of their first appearance.
* Expressions are compiled once per statement (row closures or vector
  functions); compiled operator state is cached per statement, so
  re-executed subplans (correlated subqueries) are cheap. Timeouts,
  cancellation and memory accounting are checked per batch (vectorized) or
  every 4,096 rows (row mode); `PQ_SLEEP` sleeps in ≤ 10 ms slices.
* `EXPLAIN` / the `explain` op return the physical plan as JSON
  (`TableScan` with `table`/`columns`, `HashJoin`/`MergeJoin`/
  `NestedLoopJoin` with `join_type`, `IndexScan` with
  `table`/`index`/`columns`, `TopN`, `Gather` with `partitions`, …). Plans
  of subqueries used by an operator follow its inputs in `children`, marked
  `"subquery": true`, so every scan of the statement appears in the tree.

### UNION ALL (CR-1, `spec/changes/union-all.md`)

`query = [WITH …] select_core { UNION ALL select_core } [ORDER BY …] [LIMIT …]`,
usable wherever a query is (top level, CTE bodies, derived tables, scalar /
`IN` / `EXISTS` subqueries, `EXPLAIN`). The change is carried through every
layer as a new relation kind, so everything that consumes a bound query
(subqueries, CTEs, derived tables, the executor's option matrix) works
unchanged:

| Layer | Module | Change |
|---|---|---|
| AST | `sql/ast.py` | `Compound(branches)`; `Query.body` is a `Select` or a `Compound` |
| Parser | `sql/parser.py` | `parse_compound`: `UNION ALL` chains of plain select cores; `UNION` without `ALL` stays `UNSUPPORTED`; a branch `ORDER BY`/`LIMIT` or a parenthesized branch is a `PARSE_ERROR` |
| Binding | `analysis/binder.py`, `analysis/bound.py`, `analysis/typing_rules.py` | `_bind_compound`: a compound is bound as a query over a `UnionRelation` (`SELECT * FROM (b1 UNION ALL b2 …) ORDER BY … LIMIT …`); branch arity check (`SEMANTIC_ERROR`), `union_type` per column (`TYPE_ERROR`), first-branch names, ORDER BY restricted to output names / positions (`_output_position`, shared with plain SELECTs) |
| Logical plan | `planner/planner.py`, `planner/logical.py`, `planner/optimizer.py`, `planner/rules/` | `UnionAll(branches)`; a branch whose column types differ from the output types gets a `Project` of implicit promotions (`Cast`, so INT64 → DECIMAL overflow is `NUMERIC_OVERFLOW`); expression simplification and pushdown run inside each branch; column pruning maps the required output columns to every branch |
| Physical plan | `planner/physical.py` | `UnionAll` node (EXPLAIN `op: "UnionAll"`, children = branch plans in order, estimated rows = sum); with `threads > 1` every selective branch pipeline gets its own `Gather` |
| Execution | `execution/row_engine.py`, `execution/vector_engine.py` | `_union_all`: the branches' rows / batches concatenated in branch order |
| Protocol | `protocol/handlers.py` | capability `change.union_all` |

Branch scopes are children of a compound scope without range variables, so
correlated references inside a branch pass through it and make the whole
compound subquery correlated. `max_rows` applies to the final result as for
any query. Unit tests: `tests/test_union_all.py`.

### DECIMAL precision 38 (CR-2, `spec/changes/decimal38.md`)

**Representation.** A wide decimal (`DECIMAL(p,s)`, 19 ≤ p ≤ 38) is, like a
narrow one, a Python `int` holding the unscaled value. Python integers are
arbitrary precision, so there is no separate 128-bit type: one set of
kernels serves both widths, and intermediates are exact (a product of two
wide operands may have 76 digits before the overflow check). The type
decides only the overflow limit (10^18 or 10^38) and the storage form:

* in column tables a narrow DECIMAL vector is an `array('q')`, a wide one a
  `list` of ints (NULL slots 0). A list has no int64 view, so wide columns
  can never reach the native kernels;
* in PQCF files wide values are 128-bit two's-complement little-endian
  integers (`int.to_bytes(16, "little", signed=True)`); narrow DECIMAL
  columns keep the 64-bit layout, also inside v2 files.

**Narrow / wide dispatch.** Every rule that produced precision 18 now
produces `W = result_precision(operand types)`: 38 if any DECIMAL operand is
wide (`DataType.is_wide`), else 18 (INT64 operands do not count). This is
decided once at bind time (`datatypes.decimal_result`), so the runtime only
sees a result type: arithmetic kernels (`compiler._decimal_kernel`, the
vectorized `_decimal_check`), `SUM` (`SumDecimal`, `SumState`), `ROUND` and
the casts check against `e.type.precision`. An INT64 arithmetic operand is
promoted to `DECIMAL(W,0)`.

**Exact comparison (SPEC-Q-001).** INT64/DECIMAL mixes are compared in an
internal type `DECIMAL(77, max scale)` (`COMPARISON_PRECISION`; INT64 or
DECIMAL values rescaled to a scale ≤ 38 have at most 76 digits), so the
implicit promotion can never overflow. It is used by comparisons, BETWEEN,
IN lists and subqueries, simple CASE, NULLIF and join-key alignment; it never
appears as a result type (comparisons yield BOOLEAN). DECIMAL operands that
already have the comparison scale are not wrapped in a cast, so index and
native-kernel planning still see the bare column. MIN/MAX, ORDER BY, GROUP BY
and DISTINCT compare Python ints, which is exact anyway.

**Storage.** `pqcf.format_version_for(columns)`: v2 if a column is wide,
else v1. The reader accepts v1 and v2; header/metadata version mismatch, a
wide column in a v1 file, or a value with |unscaled| ≥ 10^p is
`STORAGE_CORRUPT`; version > 2 or flags ≠ 0 is `STORAGE_VERSION_UNSUPPORTED`.

**Modules touched.**

| Layer | Module | Change |
|---|---|---|
| Types | `datatypes.py` | max precision 38, `is_wide`, `result_precision` / `decimal_result` (W), `comparison_type`, `COMPARISON_PRECISION`; `DECIMAL` alias stays `DECIMAL(18,0)` |
| Values | `values.py` | decimal literals up to 38 digits, `check_decimal` takes the precision, `POW10` up to 10^79 |
| Lexer / parser | `sql/lexer.py`, `sql/parser.py` | `FULL` / `RIGHT` (reserved only for future syntax) accepted as an alias after an explicit `AS` (the public case uses `… AS full`) |
| Analysis | `analysis/typing_rules.py`, `analysis/functions.py` | W rule for `+ - *`, product-scale limit W, common types; exact comparison promotion (`promote_compared`); `SUM`/`ROUND`/`FLOOR`/`CEIL` result precision; NULLIF comparison type |
| Execution | `execution/compiler.py`, `vcompiler.py`, `functions.py`, `aggregates.py`, `group_states.py`, `casts.py`, `common.py` | overflow checks at the result precision; DECIMAL → INT64 range check; join keys aligned in the comparison type |
| Native | `execution/native_ops.py` | wide columns and wide SUM/AVG states are never given to kernels (`_int64_type`, `NativeGroupSums`) |
| Storage | `storage/vectors.py`, `storage/pqcf.py` | list vectors for wide columns; PQCF v2 writer/reader (i128 PLAIN and RLE) |
| Protocol | `protocol/handlers.py` | capability `change.decimal38` |

Ingestion needed no change: schemas are parsed by `parse_type` (now up to
38, `INVALID_REQUEST` beyond), conversion is exact text parsing, and JSON
numbers keep their literal text. `spec_version` stays `1.0.0`, which the
public catalog case expects (CR-2 names `1.2.0-cr2`). Unit tests:
`tests/test_decimal38.py`.

### Logical / physical plan separation (CR-3, `spec/changes/refactor-plan-separation.md`)

A behaviour-preserving refactoring: every response, error and capability is
unchanged. A statement is planned in three separate steps
(`planner/pipeline.py`):

1. **Logical plan** (`planner/planner.py` → `planner/logical.py`): a
   `LogicalPlan` holds the query's operator tree (`Scan`, `Values`,
   `SubqueryScan` for derived tables / CTE references, `UnionAll`, `Filter`,
   `Join` with type and condition, `Aggregate` with keys and aggregate calls,
   `Project`, `Distinct`, `Sort`, `Limit`) plus one tree per scalar / `IN` /
   `EXISTS` subquery (by subquery id, nested ones included). Nodes carry no
   algorithm choices. `str(plan)` / `format_plan(node)` print it.
2. **Optimizer** (`planner/optimizer.py`, `planner/rules/`): an ordered list
   of named rules applied to every tree. Each rule is a class with a `name`
   and `apply(tree)`; expression rules also have `rewrite(expr)` for one
   expression node, and consecutive expression rules share one bottom-up
   pass (`RewriteExpressions`), exactly like the former single
   simplification pass (`NOT (FALSE AND x)`: simplification gives
   `NOT FALSE`, which folding then turns into `TRUE` at the parent).
   `optimize: false` → `Optimizer([])`: no rule is applied.
3. **Physical planning** (`planner/physical.py`): maps the optimized trees to
   physical operators and alone takes every execution decision: access paths
   (TableScan / IndexScan / LookupScan, row-group skipping), join algorithm
   (honouring `join`), build side, join order and `TopN` (both cost-based;
   off with `optimize: false`, as before), `Gather` pipelines for `threads`,
   the execution `mode` (`auto` → vectorized) and the operators that run on
   native kernels. The result (`PhysicalPlan`: root, subquery plans, mode,
   kernels) is what the executor runs and what `EXPLAIN` prints, unchanged.

**Module map.**

| Concern | Before | After |
|---|---|---|
| Logical plan | `planner/logical.py` (operator nodes only); subquery trees built on demand inside the physical planner | `planner/logical.py`: nodes with `expressions()` / `describe()`, `LogicalPlan` (query + subquery trees), `walk`, `format_plan`; `planner/planner.py`: `LogicalPlanner.plan_statement` |
| Constant folding | `planner/rewrite.py` (`ExprSimplifier._fold`, fused with simplification) | `planner/rules/constant_folding.py`: `ConstantFolding` |
| Predicate simplification | `planner/rewrite.py` (`ExprSimplifier`, `simplify_plan`) | `planner/rules/predicate_simplification.py`: `PredicateSimplification`; predicate normalisation in `planner/rules/base.py`: `RewriteExpressions` |
| Predicate pushdown | `planner/optimizer.py` (`optimize`, `_push`; join inputs only) | `planner/rules/predicate_pushdown.py`: `PredicatePushdown` (join inputs and below derived-table projections) |
| Column pruning | `planner/optimizer.py` (`prune_columns`) | `planner/rules/column_pruning.py`: `ColumnPruning` |
| Rule interface / driver | — (fixed function calls in `physical.py`) | `planner/rules/base.py`: `Rule`, `ExpressionRule`; `planner/optimizer.py`: `Optimizer`, `default_rules` |
| Physical planner | `planner/physical.py` (also called the logical planner and the optimizer for every query and subquery) | `planner/physical.py`: `PhysicalPlanner.plan_statement(LogicalPlan)`, no logical rewrites |
| Execution mode | `service.py` (`ROW if options.mode == ROW else VECTORIZED`) | `planner/physical.py` (`PhysicalPlan.mode`) |
| Native kernels | `execution/native_ops.py` compiled kernel plans lazily during execution (`ctx.cached`) | `planner/physical.py` binds them (`Filter.native`, `HashAggregate.native`) through `PlanOptions.kernel_plan` = `native_ops.kernel_plan`; `PhysicalPlan.native` |
| Pipeline | `physical.plan_statement` | `planner/pipeline.py`: `plan_statement` |

Unit tests: `tests/test_optimizer_rules.py` (the logical plan and each rule
on its own and through the optimizer), `tests/test_planning.py` (physical
decisions).

*Decisions.*
* Pushing a conjunct below a derived table's projection is the one place
  where the refactoring makes the optimizer do more than before (CR-3 lists
  it among the required rules). Results and errors cannot change: it is
  only done when neither the conjunct nor any projected expression can fail
  (no arithmetic, casts, function calls or subqueries), so the same rows are
  filtered and no error is skipped or added; the pushed conjuncts are placed
  after the conjuncts of the derived table's own `WHERE` / `HAVING`. It is
  visible in `EXPLAIN` only as a different Filter position (and possibly an
  `IndexScan` inside the derived table). A differential run over every
  conformance query × the option matrix (results and EXPLAIN, with and
  without native kernels) showed no other difference.
* Join reordering and `TopN` stay in the physical planner: both depend on
  physical cardinality estimates (index choices) and choose physical
  operators, so they are not logical rules. They keep honouring
  `optimize: false` exactly as before.
* The physical planner layer does not import the execution layer; the
  kernel-plan compiler is passed in (`PlanOptions.kernel_plan`), like the
  constant evaluator.

### Execution modes and optimization (Phase 5)

All options of protocol.md §5.2 are honoured per query; every combination
returns the same rows (the order of rows is only defined by ORDER BY) and
raises the same errors.

**`mode: "row"` — the baseline** (`execution/row_engine.py`). A classic
Volcano engine: every operator is a Python iterator yielding one row tuple
at a time, expressions are row closures (`compiler.py`), aggregates are one
accumulator object per group and aggregate fed one value at a time.

**`mode: "vectorized"`** (also `auto`; `execution/vector_engine.py`,
`vcompiler.py`). Operators exchange column batches `(columns, n)` of up to
4,096 rows; row tuples are only built for the result.

* *Scans* decode only the referenced columns and only the row range they
  read (`ColumnVector.to_list(start, stop)`), then hand out slices.
* *Expressions* compile to vector functions whose per-row work happens in
  C-implemented builtins: `map` over `operator` functions, `compress`,
  `itemgetter` gathers, `list.count`/`in`, `min`/`max`. Each kernel has a
  branch-free fast path for batches without NULLs. Overflow checks run once
  per batch with `min`/`max`, the same way division-by-zero is found with
  `in`. This is the CPython analogue of SIMD-friendly loops (see
  *SIMD* below). Constant subexpressions are evaluated once per batch;
  constant `LIKE` prefixes/suffixes/infixes use `str` methods instead of
  regexes. Expressions without a vector kernel (subqueries, non-constant
  LIKE patterns) run their row closure over just the columns they
  reference.
* *Short-circuit parity*: operands that may raise an error are evaluated
  only for the rows that need them, exactly like the row closures. This
  covers the right side of AND/OR, CASE branches (each WHEN is evaluated
  only on the still-undecided rows), and the right operand of
  NULL-propagating operators. A function call whose later arguments may
  fail uses its row closure. So `b <> 0 AND a / b > 1` never divides by
  zero, in any mode.
* *Filters* compute a boolean vector and compact every column with
  `compress`.
* *Hash joins* materialize the build side column-wise and map key →
  position. When the build keys are unique (the common primary-key join),
  probing a whole batch is `map(table.get, keys)` + `compress`. If every
  probe row matched once, the probe columns are passed on without a gather.
* *Aggregation* uses columnar group state (`group_states.py`): per
  aggregate, flat lists of totals/counts/minima indexed by a dense group id
  instead of an accumulator object per group. A batch's new keys are found
  with `dict.fromkeys`, group ids with `map(index.__getitem__)`. Batches
  with few groups are sorted by group id (a C-level sort of positions) and
  each group's slice is reduced with one `sum`/`min`/… call; batches with
  many groups update the state lists row by row.
* *Sorts* compute a permutation with C-level keys (`column.__getitem__`),
  one stable pass per key with NULLs split off. The columns are then
  gathered once.

**`join`**: `hash` → `HashJoin`, `merge` → `MergeJoin` (sort-merge: both
inputs materialized, positions sorted by key, equal-key runs paired;
inner and LEFT), `nested_loop` → `NestedLoopJoin` (vectorized: block
nested loops evaluating the condition over blocks of ~4,096 row pairs).
Joins without equality keys always use nested loops. `auto` is cost-based
over the algorithms' work: a hash join is linear in both inputs, a merge
join must first sort both inputs (no input arrives sorted in this engine),
so equi-joins get a `HashJoin` built on the smaller input (the right input
for LEFT joins).

**`threads: N`** (default: `--threads`, or automatic, see *Latency
optimization*). With N > 1 the planner wraps
every *pipeline* in a `Gather(partitions = min(N, 64))`. A pipeline is a
chain of streaming operators (Filter, Project, SubqueryScan, join probe
sides) driven by one TableScan or IndexScan. Gathers are inserted below
the operators that can merge partial results, and at the root when the
pipeline is selective (estimated ≤ 25% of the scanned rows). Each
partition reads a disjoint row range of the driving scan:
* `HashAggregate`: partial aggregation per partition, then merge;
* `Sort`: local sort, then a stable re-sort of the concatenated runs;
* `TopN`: local top-N, then merge;
* `Distinct`: local, then global deduplication;
* root: partitions concatenated in order.

Join build sides on the path are built once before in-process or
forked-per-query partitions run; workers of the persistent pool build them
themselves. Partial results are merged in partition order, so group order
and ties do not depend on the partitioning; FLOAT64 sums are `fsum`-based
(a partial state coming from a worker process carries one rounded sum per
group, so they may differ from the serial result in the last bits).
Subquery plans stay serial.

*Why processes:* CPython's GIL serializes threads, so threads cannot make
CPU-bound operators faster. When the driving scan has at least
`--parallel-min-rows` rows (default 200,000), the partitions run in worker
processes: at most one per CPU, each handling every k-th partition. They
are the engine's *persistent worker pool* (`execution/worker_pool.py`,
see *Latency optimization*); when the pool is busy with another query or
cannot take the plan (native kernels), workers are forked for the query
(`execution/parallel.py`): such a child inherits a copy-on-write snapshot
of the immutable tables, the compiled plan and the prepared build sides.
Workers send their partial results back through a pipe as a pickle.
Columnar group states, plain value lists and row lists all pickle cheaply.
The parent waits with `selectors`, observing cancellation and the
deadline, and kills all workers on error, cancel or timeout. Smaller inputs run
their partitions one after the other in the calling thread, through the
same partial/merge code, so the conformance matrix (`threads: 4` on small
tables) exercises the parallel logic. A unit test and `tools/difftest.py`
cover the forked path.

**`optimize: false`** disables all logical rewrites (the optimizer applies
no rule) and the physical planner's two cost-based alternatives (the last
two items):
* constant folding (constant subexpressions become literals; a constant
  whose evaluation fails, like `1/0`, is left alone, so the error is
  raised exactly when a row evaluates it);
* predicate simplification (`TRUE AND x` → `x`, `FALSE OR x` → `x`,
  absorbing literals, `NOT NOT x`, comparisons with NULL, CASE branches
  with constant conditions, duplicate conjuncts, always-true filters
  removed; operands that may raise errors are never dropped);
* predicate pushdown (into join inputs and below derived-table projections);
* projection pushdown (column pruning through derived tables);
* greedy join reordering for chains of ≥ 3 inner/cross joins (start with
  the smallest input, then repeatedly add the connected input giving the
  smallest estimated result; cross products last);
* `ORDER BY … LIMIT` as a `TopN`, which keeps at most ~2·(limit+offset)
  rows in memory and never sorts the whole input.

Index selection, scan column lists and the join algorithm choice are
physical decisions and stay active.

**Memory and allocation.**
* The cyclic GC is paused while engine work runs (`context.gc_paused`:
  nesting across concurrent queries, re-enabled when the last one ends).
  Operators allocate millions of short-lived acyclic objects that
  reference counting frees anyway. The collections those allocations
  trigger traverse every live object, including the millions held by
  loaded tables. That made a 1M-row sort 3.7× slower (2.9 s → 0.78 s)
  and row mode about 1.7× slower.
* Aggregation state is flat lists per aggregate, not objects per group.
* NULL positions of a column chunk are expanded from its bitmap once and
  cached (as `array('i')`); NULLs are applied to decoded values with a
  C-level `map(list.__setitem__, …)`.
* Parallel partitions decode only their row range.

**Cache-aware layouts.** In CPython the dominant cost of memory access is
pointer chasing to boxed values. Gathering 1M floats in random order costs
~130 ms, against ~7 ms in sequential order. So the vectorized engine:
* keeps data columnar end to end;
* gathers by position lists in ascending order wherever the algorithm
  allows (probe order, partition order);
* passes columns through without a gather when positions are the
  identity;
* sorts permutations rather than row tuples (measured 677 ms vs 860 ms for
  a 1M-row, 2-key sort, since tuple comparisons chase pointers).

Radix-partitioned hash tables were not implemented: Python dicts already
hash in C, and partitioning would add a Python-level pass per row that
costs more than the cache misses it saves.

**SIMD.** The standard library offers no SIMD API. The vectorized kernels
are written so that each batch is processed by one tight C loop over
homogeneous values (`map(operator.add, a, b)`, `compress`, `sum`,
`min`/`max`), which is the closest CPython equivalent. Explicit SIMD would
need the optional native kernels.

**`native: true`** (boolean, else `INVALID_REQUEST`) runs the operators
that the kernel library supports with it, see *Native kernels* below.

**Verification.** `tools/difftest.py` generates random queries (joins of
all kinds, grouping, DISTINCT, ORDER BY/LIMIT/OFFSET, IN/EXISTS/scalar/
correlated subqueries, CTEs, NULL-heavy data, row- and column-layout
tables, and expressions that overflow or divide by zero). It checks that
all 32 combinations of `mode` × `join` × `threads ∈ {1, 4}` × `optimize`,
plus forced worker processes, return the baseline's rows or error code.
Several thousand queries were run without a mismatch. It found two bugs
along the way: an unpicklable partial state, and an eagerly evaluated
overflowing constant.

### Measurements (Phase 5)

Setup: `python3 datasets/generators/pqgen.py generate --scale 1m` (1M
transactions, 100k customers, 250k orders, 1M order items, 20k products,
1M sort keys; CSV with the generated schemas, column layout), CPython 3.14
(GIL build) on a 32-core Linux machine that was shared with other jobs
(about ±20% run-to-run noise). Times are medians of 5 runs of
`tools/bench.py` in ms, wall clock per `query` request with
`result: "count"`, so serialization is excluded. *Before* is the accepted
Phase 4 engine (commit `053c137`), the same machine and data. Its executor
passed batches of row tuples and grouped by collecting rows per group.

| query | what | before | row | vectorized | vect. 2 thr | vect. 4 thr | vect. 8 thr |
|---|---|---:|---:|---:|---:|---:|---:|
| Q1 | `COUNT(*)` with 2-predicate filter | 221 | 129 | 96 | 75 | 58 | 65 |
| Q2 | GROUP BY category (8 groups), 5 aggregates | 2864 | 446 | 217 | 159 | 121 | 100 |
| Q3 | GROUP BY customer_id (100k groups) | 1923 | 486 | 212 | 190 | 179 | 199 |
| Q4 | 1M ⋈ 100k hash join + GROUP BY | 1655 | 580 | 241 | 173 | 132 | 140 |
| Q5 | filter + `ORDER BY … LIMIT 10` (TopN) | 566 | 185 | 121 | 115 | 95 | 109 |
| Q6 | 3-way join + filter + GROUP BY | 604 | 603 | 268 | 202 | 162 | 182 |
| Q7 | `SUM(amount * 2 + fee)` with filter | 318 | 339 | 190 | 145 | 121 | 134 |
| Q8 | full sort of 1M rows on 2 keys | 3798 | 985 | 727 | — | 728¹ | — |
| Q9 | non-selective filter returning 840k rows | 2096 | 341 | 205 | 200 | 207 | 200 |
| Q10 | selective filter returning few rows | 301 | 255 | 151 | 117 | 71 | 106 |
| R1 | comma join `products, orders, items` + GROUP BY | fails² | 520 | 258 | — | 165 | — |

¹ Measured after the change that makes full sorts parallelize only selective
pipelines. Before that change, local sorts plus the merge re-sort made
Q8 slower with threads (971 ms at 4). ² `RESOURCE_LIMIT`: without join
reordering, the first join is the 20k × 250k cross product
(`--max-join-rows`).

Main effects, in order of impact:

* **GC pause** (all modes). Q8 vectorized went from 2,878 to 775 ms, row
  mode Q2 from 783 to 456 ms. Most of the old engine's Q8 / Q9 time was
  garbage collection.
* **Vectorized execution** is 1.3–2.4× faster than row mode, and up to
  13× faster than the old engine (Q2). The gains come from C-level kernels,
  columnar group state and positional joins.
* **Parallel pipelines** (forked workers) give a further 1.6–2.2× at 4–8
  threads for scans, filters, joins and low-cardinality aggregation (Q1,
  Q2, Q4, Q6, Q7, Q10). They give little for high-cardinality grouping
  (Q3: merging 100k-group partial states in the parent is serial), full
  sorts (Q8) and non-selective scans (Q9). The last two are therefore not
  parallelized. Beyond 4–8 workers, fork and pickle overheads dominate on
  1M rows.
* **Optimizer** (`optimize: true` vs `false`, vectorized). Q5 121 vs 245 ms
  (TopN instead of a full sort). Q6 268 vs 346 ms (pushdown of
  `o.status = 'delivered'` below the joins). Q4 241 vs 282 ms. R1 on the
  fixture-scale tables (50 products, 500 orders, 2,000 items): 1 ms vs
  7,647 ms (join reordering + pushdown versus a cross product filtered
  afterwards).

Join algorithms (100k scale: 100k transactions ⋈ 10k customers (J1),
8k items ⋈ 2k products (J2), 25k orders ⟕ 100k items (J3); ms):

| query | row hash | row merge | vectorized hash | vectorized merge | row nested loop | vectorized nested loop |
|---|---:|---:|---:|---:|---:|---:|
| J1 | 38 | 79 | 19 | 36 | — | — |
| J2 | 13 | 15 | 6 | 8 | 1003 | 723 |
| J3 | 21 | 29 | 15 | 17 | — | — |

Hash joins beat sort-merge joins by 1.1–2× in both modes, since no input
arrives sorted and the merge join pays two sorts. This is why `auto`
picks hash joins. Nested loops are quadratic: the vectorized block nested
loop evaluates 16M pairs of J2 in 0.7 s.

Reproduce with:

```sh
python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata
python3 tools/bench.py --data /tmp/pqdata/1m --repeat 5 \
    --variant row --variant vectorized --variant vec4 --variant '{"mode":"vectorized","threads":8}'
python3 tools/bench.py --data /tmp/pqdata/1m --repeat 5 --variant auto --engine <phase-4 checkout>/bin/polyquery
```

### Latency optimization (analytics workload)

**Workload.** The task names `benchmarks/workloads/analytics.json`, which
does not exist anywhere in the workspace. The engine therefore defines the
workload itself in `benchmarks/analytics.json`: 22 analytical queries over
the pqgen tables at scale 1m (transactions, customers, orders, order_items,
products, sensor_readings, nulls_heavy, sort_keys) covering filtered counts,
low- and high-cardinality grouping, joins of 2–3 tables, LEFT JOIN, TopN
with and without OFFSET, COUNT(DISTINCT), HAVING, CASE, LIKE, uncorrelated
`IN` and correlated `EXISTS` subqueries, a CTE, DISTINCT and a selective
projection. The queries run with **default options** (no `threads`, `mode`
etc.), as a client would send them.

**Method.** `python3 datasets/generators/pqgen.py generate --scale 1m --jobs 1`
(multiprocessing semaphores are not available in this sandbox, hence
`--jobs 1`), then

    python3 tools/workload.py --data <out>/1m --repeat 7 --before <baseline>/bin/polyquery

`tools/workload.py` loads the workload's tables (CSV with the generated
schemas, column layout) into one `bin/polyquery session` per engine, then
for every query runs one warm-up per engine and 7 timed repetitions,
**alternating between the two engines** (the machine is shared with other
jobs; interleaving exposes both engines to the same noise). A time is the
wall clock from writing the request line to reading the complete response
line, *rows included* (`result: rows`, so serialization and transfer count).
The tables show medians. *Before* is the engine at the start of this task
(commit `326a5a0`, extracted with `git archive`), *after* is this commit;
both on CPython 3.14 on a 32-CPU Linux machine with background load
(medians fluctuate by roughly ±20% between runs; the speedups are stable).
Every result is compared with the baseline's: identical, except where marked.

| query | what | before (ms) | after (ms) | speedup |
|---|---|---:|---:|---:|
| A01 | COUNT(*) with a 2-predicate filter | 109 | 25 | 4.3x |
| A02 | GROUP BY category (20 groups), 5 aggregates | 239 | 52 | 4.6x |
| A03 | GROUP BY customer_id (80k groups returned) | 410 | 297 | 1.4x |
| A04 | 1M ⋈ 100k hash join + GROUP BY | 387 | 91 | 4.2x |
| A05 | filter + ORDER BY … LIMIT 10 | 129 | 34 | 3.8x |
| A06 | 3-way join + filter + GROUP BY, INT64×DECIMAL | 383 | 121 | 3.2x |
| A07 | SUM of an expression with a filter | 189 | 40 | 4.7x |
| A08 | GROUP BY YEAR(ts), MONTH(ts) | 223 | 46 | 4.8x |
| A09 | COUNT(DISTINCT) per category | 198 | 97 | 2.0x |
| A10 | GROUP BY customer_id, top 20 | 247 | 133 | 1.9x |
| A11 | GROUP BY merchant_id HAVING | 224 | 67 | 3.4x |
| A12 | IN (uncorrelated subquery) | 97 | 36 | 2.7x |
| A13 | correlated EXISTS | 330 | 30 | 11.1x |
| A14 | CTE aggregate (250k groups) ⋈ orders + GROUP BY | 317 | 149 | 2.1x |
| A15 | LEFT JOIN with a 1M-row build side + GROUP BY | 282 | 229 | 1.2x |
| A16 | 1000 groups, FLOAT64 AVG/MIN/MAX | 343 | 70 ¹ | 4.9x |
| A17 | GROUP BY CASE expression | 232 | 48 | 4.8x |
| A18 | LIKE suffix on 100k rows | 11 | 11 | 1.0x |
| A19 | NULL-heavy GROUP BY | 264 | 50 ¹ | 5.3x |
| A20 | ORDER BY float LIMIT 100 OFFSET 5000 | 312 | 45 | 6.9x |
| A21 | selective filter returning 15k rows | 214 | 51 | 4.2x |
| A22 | DISTINCT on 100k rows | 5 | 5 | 1.0x |
| **total** | sum of medians | **5145** | **1727** | **3.0x** |

¹ FLOAT64 sums/averages equal the baseline's within 1–2 ulps (max relative
difference 3·10⁻¹⁶): parallel partial states are summed per partition (see
below). All other results are identical (same rows; same order where the
query has ORDER BY). Raw numbers: `benchmarks/results-1m.json` (after, with
the baseline medians), `benchmarks/baseline-1m.json` (an earlier run of
the baseline alone).

**What changed, in order of impact.**

1. **Persistent worker pool** (`execution/worker_pool.py`). Parallel
   pipelines used to fork their workers per query. With the 1m tables
   loaded the engine has ~750 MB resident, and `fork` copies its page
   tables: ~10 ms per child, so 8–16 workers cost 80–160 ms before doing
   any work, plus copy-on-write faults in every child. Measured with
   explicit `threads`, the old engine got only 1.25× at 4 threads and was
   *slower* than serial at 16 (total 4319 → 3482 ms at 4, 4960 ms at 16).
   The pool forks its workers once and reuses them:
   * plans are pickled with every `Table` / `Index` replaced by a reference
     (`persistent_id`); the workers inherited those objects at fork time,
     so no table data is copied. A plan that references a table or index
     the workers do not have (loaded, replaced or indexed after the fork)
     makes the pool fork fresh workers first;
   * the per-partition work is a picklable `PartitionTask` (engine,
     consumer kind — aggregate / sort / distinct / collect —, consumer
     operator, argument). Both engines register their consumer functions,
     so the worker runs exactly the code of the in-process path; it builds
     the pipeline's join build sides itself;
   * one query at a time uses the pool (a lock taken without blocking);
     another concurrent parallel query, or one with native kernels, uses
     the fork-per-query path. Cancellation, timeouts and protocol failures
     kill the workers (the next query forks new ones); errors raised in a
     worker are returned like results and the workers stay. Workers ignore
     the engine's stdin/stdout, close every inherited pipe and socket (in
     `serve` mode a worker forked while another thread runs a
     fork-per-query pipeline would otherwise keep that pipeline's result
     pipe open, and its reader would wait for EOF forever; likewise client
     connections), freeze the inherited objects out of the cyclic GC and
     exit when the engine exits (EOF on their task pipe).
   With the same explicit `threads: 8`, the workload total went from 4244
   to 1728 ms.
2. **Automatic parallelism.** `--threads` used to default to 1, so a client
   that sends no `threads` option got no parallelism at all. Now, unless
   `--threads` is given, a query without `threads` uses min(CPUs, 8)
   partitions, but only for pipelines whose driving scan is expected to
   read at least `--parallel-min-rows` (200,000) rows; smaller pipelines
   are planned exactly as before (no `Gather`), so plans and results on
   small tables do not change. An explicit `threads` (option or flag)
   behaves as before (concurrency.md: `threads` bounds the parallelism).
   8 rather than more: on this machine 12–16 partitions gave ~5% overall
   but made join pipelines with large build sides markedly slower (A15:
   201 → 297 ms at 16), since every worker builds them.
3. **Correlated `EXISTS` as a hash semi-join** (`execution/semi_join.py`).
   A13 ran its subquery once per outer row (100k LookupScan executions).
   When the subquery is Project/Distinct over Filters over the LookupScan
   and none of its conditions can fail (`bound.may_fail`) or read another
   outer column, `EXISTS` is "the outer key is in the set of inner keys
   satisfying the conditions"; the set is built once per statement with
   vectorized evaluation (lazily, on first use). Errors cannot change:
   only conditions that cannot raise are evaluated eagerly, all others keep
   the per-row path. Both compilers use it (vector kernel: one set
   membership `map` per batch). 11×.
4. **Vectorized rescaling casts.** `INT64 → DECIMAL` (and DECIMAL
   up-scaling) was a Python call plus range check per value — e.g.
   `quantity * unit_price` in A06/A14. It is now one `map(mul)` per batch
   with one min/max range check (same error).
5. **TopN prefilter.** Once the TopN buffer has been trimmed to `limit +
   offset` rows, batch rows whose first sort key is strictly worse than the
   last kept row are dropped with one C-level comparison `map` (ties and
   NULLs per the key's NULL ordering pass through to the stable sort).
   A20 re-sorted a 10k-row buffer ~120 times before: 6.9×.
6. **Parent-side merge and output.** Merging partial group states maps
   keys with `filterfalse`/`map` and merges states with C-level
   gather/`map(add)`/scatter (all-new keys are appended); SUM/AVG results are
   range-checked once per state; result columns are converted column-wise
   (DECIMAL via `str.format` over quotient/remainder `map`s); a unique hash
   probe whose rows all match skips building a mask. FLOAT64 SUM/AVG
   partials leaving a worker carry one `fsum` per group instead of every
   value (A16: 105 → 62 ms alone), which is where the last-bit differences
   come from (FLOAT64 is compared with tolerance, concurrency.md §6).

**Where the time still goes.** A03/A10 (high-cardinality grouping) and A14
are bounded by serial work in the parent: merging 8 partial states of
~70k groups each, serializing 80k result rows, and (A14) the join and
aggregation above a 250k-group CTE, which has no table scan to partition.
A15 builds a 1M-row hash side in every worker (see *Known limitations*).
Inside the workers per-row costs dominate (measured: workers start
together, finish within ~20% of each other, and the pool adds 1–2 ms per
query); they run ~15–30% slower per row than a lone serial process
(shared caches and clock speed).

**Tried and rejected.** Larger vector batches (16k / 64k rows): no gain,
up to 13% slower (cache effects). Bucketing non-unique hash-join build
sides only for repeated keys: 10% slower on A15 (measured interleaved).

**Verification.** Conformance 660/660 and the HTTP suite 18/18 before and
after; `make test` (new unit tests: `tests/test_worker_pool.py`,
`tests/test_semi_join.py`, `tests/test_topn.py`); `tools/difftest.py`
over 7 seeds × 300 random queries × the whole option matrix including
forced worker processes: no mismatch; every workload result checked
against the baseline engine's (above); `serve` with the 1m transactions
table and 4 threads each sending 4 parallel queries concurrently (pool and
fork-per-query paths at once): correct results, clean SIGTERM shutdown, no
worker left behind.

### Native kernels (M9)

`--native-kernels PATH` loads `libpqkernels` (built with
`make -C native-kernels`); queries with `native: true` then use it for the
operations below. Results are identical with and without it — same rows,
same row order, same errors — and without the library (or with
`native: false`) the engine runs exactly its Phase 5 code.

**FFI design** (`polyquery/native/kernels.py`).
* The library is opened with `ctypes.CDLL`. `argtypes`/`restype` are
  declared for all 21 functions of the ABI (`pq_kernels.h`). The ABI version
  is checked, then `pqk_init()` picks the CPU variant (honouring
  `PQ_KERNELS_VARIANT`). The variant is logged at `info`. A missing or
  incompatible library is a `warn` log line, never a startup failure: the
  engine continues without it. `native.kernels` is claimed statically
  (`capabilities` runs without options).
* **Zero copy.** The column storage already has the ABI's layout:
  INT64 / DECIMAL (unscaled) / TIMESTAMP values are `array('q')`, FLOAT64
  `array('d')`, and validity bitmaps are LSB-first with 1 = non-NULL (the PQCF
  convention). The binding passes `buffer_info()` addresses of arrays and the
  buffer address of `bytes` bitmaps, plus offsets for the window being
  processed. Nothing is converted per query. DATE values (`array('i')`) and
  dictionary codes (`array('I')`) get a widened int64 copy, made once and
  cached on the immutable vector (`ColumnVector.int64_view`).
* Kernel status codes are honoured exactly. A `(size_t)-1` / `PQK_EINVAL`
  return is a `NativeKernelError` (a caller bug, never expected).
  `PQK_OVERFLOW` from `pqk_sum_i64` makes the engine recompute that sum with
  Python integers. `PQK_OVERFLOW` from `pqk_group_sum_i64` (a conservative
  "may have wrapped") makes the operator rerun in the engine's own exact code
  (`NativeFallback`). So an overflowing SUM still raises `NUMERIC_OVERFLOW`,
  and a sum whose partial results overflow but whose total fits is still
  returned.
* `ctypes` releases the GIL during a call, and the kernels are thread-safe
  and allocation-free. HTTP worker threads share one binding, and forked
  parallel workers inherit it. Shared scratch buffers (zeros, hash masks)
  are only ever replaced, never mutated, and every caller holds the buffer
  it got for the duration of the call.
* Physical plans and `EXPLAIN` are unchanged. `ExecutionContext.native` is
  set when the query has `native: true` and the library is loaded. Each
  operator then decides at run time, from the actual storage, whether a
  kernel applies.

**Where kernels are used** (`polyquery/execution/native_ops.py`; both
`mode: row` and `mode: vectorized`, since the paths sit at the scan). The
physical planner decides: with `native: true` and the library loaded it
offers every Filter and HashAggregate to `native_ops.kernel_plan` and keeps
the kernel plan on the operator; the executors run the kernel path of an
operator exactly when it has one:

| situation | kernels | what the engine still does |
|---|---|---|
| Filter on a TableScan (column layout): conjuncts `col op constant` (`=`, `<>`, `<`, `<=`, `>`, `>=`, `BETWEEN`, `IN`) on INT64 / DECIMAL / DATE / TIMESTAMP columns | `pqk_filter_i64_bitmap` (constants normalised to closed int64 intervals: EQ / NE / LE / GE / BETWEEN), `pqk_bitmap_or` for IN lists, `pqk_bitmap_and` to combine conjuncts, `pqk_bitmap_popcount` | converts constants exactly to the column's representation (same rules as index selection; inexact ones such as `int_col = 1.5` stay with the engine) |
| … on dictionary-encoded STRING columns | `pqk_filter_i64_bitmap` on the codes (the predicate evaluated once per dictionary entry gives code ranges), `pqk_bitmap_andnot` when the complement has fewer ranges | > 32 scattered ranges: one Python pass over the window |
| `col op col` on two columns of the same integer-represented type | `pqk_compare_i64`, `pqk_bitmap_and` with both validities | |
| the selected rows | `pqk_filter_i64` turns a bitmap into positions (an always-true predicate over a zero buffer with the bitmap as validity); `pqk_gather_i64` fetches 8-byte values (INT64, DECIMAL, TIMESTAMP, FLOAT64, widened DATE / dictionary codes); `pqk_bitmap_andnot` + popcount find selected NULLs | turns only the selected values into Python objects; evaluates the remaining conjuncts on them |
| aggregation without GROUP BY over a (filtered) scan, arguments are columns | popcount (COUNT), `pqk_sum_i64` (SUM/AVG of INT64/DECIMAL), `pqk_minmax_i64` (INT64/DECIMAL/DATE/TIMESTAMP), `pqk_minmax_f64` (FLOAT64), `pqk_count_i64` (`COUNT(*)` with a single comparison), the selection bitmap ∧ validity as validity | float SUM/AVG (`math.fsum`), MIN/MAX of strings, DISTINCT aggregates over gathered values |
| GROUP BY one low-cardinality (≤ 64 estimated groups) STRING column directly over a scan | per dictionary code `pqk_filter_i64_bitmap` (code = c) ∧ selection gives the group's bitmap; then the kernels of the previous row per group | orders groups by first row |
| other GROUP BY columns directly over a scan, with COUNT / integer SUM / AVG | `pqk_group_sum_i64` reading the value columns straight from storage (or natively gathered when filtered) | maps keys to dense group ids with dict lookups |
| … with `threads` > 1, ≥ `--parallel-min-rows` rows and one integer key | `pqk_hash_i64`, `pqk_bitmap_and` (mask to the low 16 bits), `pqk_filter_i64_bitmap` (BETWEEN: the worker's share of the hash range): **hash-partitioned** aggregation | merges the workers' disjoint groups by concatenation, ordered by first row |
| vectorized hash aggregation over any other input (joins, expressions) | `pqk_group_sum_i64` on buffered (group id, value) pairs, folded every 1M rows | everything else |

Not used: `pqk_sum_f64` (its reassociated sum may differ from the
engine's exactly rounded `fsum` in the last bit, and results must be
identical) and `pqk_compare_fixed` (the engine has no fixed-width binary
columns; strings are variable-length `str`). Joins, sorts, DISTINCT and
expression evaluation have no matching kernel. They profit only from
natively filtered inputs below them.

**Exactness rules.**
* *Overflow:* see the FFI design notes above.
* *Float MIN/MAX* results equal to zero are recomputed in Python: `0.0`
  and `-0.0` compare equal, and the engine returns the first one seen.
* *NULLs and errors.* Conjuncts are only evaluated natively if they come
  before the first conjunct that may raise an error (`may_fail`: arithmetic,
  casts, functions, subqueries). If such a conjunct exists, the native
  conjuncts keep rows where they are NULL ("not FALSE"), and the engine
  evaluates the whole original predicate on the remaining rows. So an error
  is raised for exactly the rows on which the engine's own left-to-right AND
  would raise it.
* *Storage errors.* Native scans load every scanned column of each row group,
  like the engine's scan. A corrupt chunk of a memory-mapped file therefore
  fails the query (`STORAGE_CORRUPT`) even when the kernels select no row of
  that group.
* *Order and accounting.* Rows come out in scan order. Groups are numbered by
  their first row, also across hash partitions. Memory accounting of groups
  matches the engine's.

**Parallelism.** Native scan aggregations run serially in the calling
process: they leave so little per-row work that forking workers costs more
than the whole scan. The exception is the hash-partitioned high-cardinality
case above. For pipelines whose scan is filtered natively, the
fork-or-not decision (`--parallel-min-rows`) uses the estimated number of
*selected* rows, because only those become Python objects.

**Verification.**
* `tests/test_native.py`: binding against Python reference computations
  (including `fmix64`, overflow flags and invalid ops); native vs. engine on
  CSV, PQCF (odd row groups, mmap) and row-layout tables in row, vectorized,
  partitioned and forked modes; overflow, `-0.0`, NULL / error parity,
  corrupt chunks; fallback without the library.
* `tools/native_difftest.py`: random filters and aggregations over 40k–150k-row
  tables spanning several kernel windows (CSV plus PQCF with 777- to
  65,536-row groups and forced PLAIN / DICT / RLE encodings). Each query is
  compared, rows *in order*, with and without `native` in 4 option sets plus
  forked workers. More than 2,500 queries, including 250 under each of the
  `reference`, `x86_scalar`, `x86_avx2` and `x86_avx512` variants, gave
  no mismatch.
* `tools/bench.py --check` verifies that all variants of every benchmark
  query return the same rows.
* The conformance runner with `--native` (and `--native --modes`, and
  `--native --transport http`) passes 100%.

#### Measurements (M9)

Same setup as the Phase 5 measurements: the `pqgen.py --scale 1m` datasets,
CSV loaded into the column layout, CPython 3.14 on the shared 32-core
x86-64 machine (AVX-512 available, so `pqk_init` picks `x86_avx512`).
There is about ±20% noise between runs. Times are medians of 5 runs of
`tools/bench.py` in ms, wall clock per `query` request with
`result: "count"`. *Before* is the accepted Phase 5 engine (baseline commit
`8f5d63f`, run from a separate worktree). The other columns are this
engine with `native: false` / `native: true`. `--check` confirmed that all
six variants of this engine return the same rows for every query.

| query | what | before: row | before: vect. | before: 4 thr | row | **row native** | vect. | **vect. native** | 4 thr | **4 thr native** |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Q1 | `COUNT(*)` with 2-predicate filter | 130 | 95 | 52 | 175 | **<1** | 104 | **<1** | 63 | **<1** |
| Q2 | GROUP BY category (8 groups), 5 aggregates | 417 | 214 | 89 | 483 | **8** | 232 | **8** | 104 | **9** |
| Q3 | GROUP BY customer_id (100k groups) | 353 | 190 | 179 | 476 | **115** | 215 | **83** | 160 | **103** |
| Q4 | 1M ⋈ 100k hash join + GROUP BY | 583 | 259 | 143 | 564 | **619** | 291 | **253** | 164 | **173** |
| Q5 | filter + `ORDER BY … LIMIT 10` | 177 | 122 | 98 | 234 | **44** | 131 | **34** | 103 | **35** |
| Q6 | 3-way join + filter + GROUP BY | 532 | 261 | 182 | 704 | **589** | 284 | **287** | 189 | **181** |
| Q7 | `SUM(amount * 2 + fee)` with filter | 327 | 179 | 78 | 372 | **222** | 192 | **103** | 115 | **81** |
| Q8 | full sort of 1M rows on 2 keys | 1049 | 703 | 702 | 1037 | **919** | 769 | **834** | 834 | **821** |
| Q9 | non-selective filter returning 946k rows | 297 | 188 | 188 | 317 | **170** | 150 | **123** | 152 | **146** |
| Q10 | selective filter returning 15k rows | 242 | 151 | 82 | 182 | **3** | 128 | **2** | 106 | **2** |
| J1 | same as Q4 | 629 | 268 | 143 | 603 | **616** | 273 | **233** | 159 | **157** |
| J2 | 8k-row filter on 1M items ⋈ products | 204 | 81 | 88 | 158 | **5** | 72 | **3** | 72 | **3** |
| R1 | comma join + GROUP BY | 584 | 256 | 148 | 681 | **849** | 223 | **243** | 155 | **130** |
| J3 | LEFT join + GROUP BY | 395 | 377 | 410 | 371 | **218** | 230 | **144** | 220 | **132** |

("<1": below 0.5 ms.) The effects follow from where the kernels apply:

* **Selective filters over scans** (Q1, Q5, Q10, J2) gain 4× (Q5) to
  over 100× (Q1). The
  predicate runs over the stored arrays, and only the selected rows are
  turned into Python values. The engine's own path decodes every row of
  every referenced column and evaluates the predicate in Python, so the
  cost now scales with the *output* instead of the input. Q1 needs no
  Python values at all (`COUNT(*)` is a popcount).
* **Aggregation directly over a scan** (Q2: 232 → 8 ms; Q3: 215 → 83 ms).
  Q2 groups by an 8-entry dictionary: per code one bitmap, then one
  `pqk_sum_i64` / `pqk_minmax_i64` call per group and aggregate. Q3
  (100k groups) still maps every key with a dict lookup, but the sums come
  from `pqk_group_sum_i64` over the stored `amount` array. With 4–8
  threads, hash partitioning keeps the parent's merge a concatenation
  (Q3 at 8 threads: 53 ms in a quieter run, against 80 ms serial).
* **Filters followed by Python work** (Q7, Q9) gain less (1.2–1.9×): the
  arithmetic over the selected rows (Q7) or the materialization of 946k
  result rows (Q9) is still the engine's.
* **Joins and sorts** (Q4, Q6, J1, R1, J3, Q8) have no matching kernel.
  Their filtered inputs and the group sums above them gain a little; the
  rest is unchanged, within noise. For example, R1 in row mode took 681 vs
  849 ms in this run, but 365 vs 330 ms in a 9-run re-measurement. J3
  profits from the LEFT join input `quantity > 8` being filtered natively.
* **Parallel workers.** The native paths remove most per-row work, so
  forking rarely pays off any more. Native scan aggregations always run in
  the calling process. For natively filtered pipelines, the fork decision
  counts a selected row as half a scanned row (`NATIVE_ROW_COST`). With
  that, Q7 still forks (81 ms), while Q5 / Q10 stay serial (forked they
  took 92 / 68 ms against 35 / 2 ms serial).

Kernel micro-benchmarks, from the engine's point of view
(`tools/native_bench.py`: 1M int64 values, one kernel call through
`ctypes` against the CPython code the engine runs without it; median ms):

| operation | kernel(s) | CPython | native | speedup |
|---|---|---:|---:|---:|
| filter `x > 900000` → values (10%) | `filter_i64_bitmap + filter_i64 + gather_i64` | 10.87 | 0.90 | 12× |
| count `x BETWEEN …` | `count_i64` | 22.48 | 0.11 | 205× |
| SUM | `sum_i64` | 2.59 | 0.10 | 27× |
| MIN + MAX | `minmax_i64` | 10.16 | 0.10 | 103× |
| popcount of a selection | `bitmap_popcount` | 0.05 | 0.00 | 35× |
| SUM + COUNT by 1024 groups | `group_sum_i64` | 43.29 | 0.41 | 105× |
| hash (fmix64) | `hash_i64` | 150.40 | 0.53 | 283× |
| column < column | `compare_i64` | 11.26 | 0.17 | 67× |
| gather 10% of the rows | `gather_i64` | 2.20 | 0.69 | 3× |

With `--variant x86_scalar` the speedups are about half of these (for
example 85× instead of 205× for counting, 19× instead of 103× for
MIN+MAX). That is still far above CPython, because the gain comes from
not creating Python objects, not from SIMD. Gathers gain least: their
output must become Python objects (`array.tolist()`) anyway.

The library's own C-level benchmark (`native-kernels/build/x86_64/kernel_bench
1048576 9`, ns per element) for reference:

| kernel | reference | x86_scalar | x86_avx2 | x86_avx512 |
|---|---:|---:|---:|---:|
| filter_i64 (10% selected) | 0.746 | 0.318 | 0.150 | 0.089 |
| filter_i64_bitmap | 2.833 | 0.214 | 0.054 | 0.048 |
| count_i64 (BETWEEN) | 0.341 | 0.262 | 0.056 | 0.049 |
| sum_i64 | 0.196 | 0.192 | 0.065 | 0.062 |
| sum_i64 with validity | 0.334 | 0.324 | 0.109 | 0.065 |
| minmax_i64 | 0.546 | 0.551 | 0.101 | 0.063 |
| bitmap_popcount | 0.114 | 0.014 | 0.002 | 0.001 |
| hash_i64 | 0.608 | 0.568 | 0.347 | 0.128 |
| compare_i64 | 2.844 | 0.234 | 0.142 | 0.132 |
| group_sum_i64 (1024 groups) | 0.662 | 0.561 | 0.408 | 0.413 |
| gather_i64 | 0.572 | 0.546 | 0.516 | 0.504 |

The `ctypes` call overhead (about 1 µs) is negligible: kernels are called
once per 65,536-row window, conjunct and aggregate, never per row.

Reproduce with:

```sh
make -C native-kernels
python3 tools/bench.py --data /tmp/pqdata/1m --repeat 5 --check \
    --native-kernels ../../native-kernels/build/x86_64/libpqkernels.so \
    --variant row --variant row-native --variant vectorized --variant native --variant vec4 --variant vec4-native
python3 tools/native_bench.py --lib ../../native-kernels/build/x86_64/libpqkernels.so [--variant x86_scalar]
python3 tools/native_difftest.py --lib ../../native-kernels/build/x86_64/libpqkernels.so [--variant reference]
```


### HTTP server (Phase 4)

* **Threads.** `http.server.ThreadingHTTPServer` with one (daemon) thread
  per connection, HTTP/1.1 keep-alive. A query executes in its connection's
  thread; Python threads share the GIL, so concurrency gives responsiveness
  and overlap of waiting (e.g. `PQ_SLEEP`, socket I/O), not CPU parallelism.
* **Snapshot isolation.** Tables and indexes are immutable values. Every
  query binds and plans against `Catalog.snapshot()` (a copy of the name →
  table / index maps taken under the catalog lock), and the physical plan
  holds direct references to the table objects, so a query keeps reading the
  versions it started with even if they are replaced or dropped meanwhile.
  `load`/`open` parse outside the lock and publish with one atomic
  `Catalog.put`; all catalog mutations are serialized by that lock.
* **Admission control** (`server/queries.py`). Each query is registered under
  its `query_id` (client-supplied or `q-<n>`; a duplicate of an active id is
  `409 ALREADY_EXISTS`), then admitted: it runs immediately if fewer than
  `--workers` queries run and nobody is waiting, else it waits in a FIFO queue
  of at most `--queue-depth` entries, else it is rejected immediately with
  `503 OVERLOADED`. Waiting observes cancellation and the deadline. Queries
  are the `query` op (from `/v1/query`, `/v1/query/stream` and
  `/v1/request`); all other requests (catalog ops, `/health`, `/metrics`,
  `/v1/queries`, cancellation, `explain`) bypass admission and stay
  responsive.
* **Timeouts.** The deadline is fixed when the query arrives
  (`options.timeout_ms`, else `--query-timeout-ms`), so queueing time counts.
  It is passed to the execution context as an absolute monotonic time.
* **Cancellation.** `DELETE /v1/queries/{id}` sets the query's cancel event
  (waking it if queued). Operators check cancel/deadline per batch (≤ 2048
  rows) and, inside nested-loop joins and per-group aggregation, at least
  every 65,536 rows; `PQ_SLEEP` sleeps in 10 ms slices. A single background
  thread (`server/watcher.py`) polls the sockets of connections with an
  executing query and cancels the query when the peer hangs up (EOF / HUP).
* **Streaming.** `/v1/query/stream` parses, plans and pulls the first batch
  before committing to `200`, so errors up to that point get a normal error
  response with its HTTP status. Afterwards the result is written as chunked
  NDJSON (`header`, `rows` lines of ≤ 10,000 rows, `end`, or a final `error`
  line). Execution is a pull-based generator pipeline driven by the writer:
  exactly one batch is in flight, writes are non-blocking sends that wait for
  socket writability, and while waiting the writer still observes
  cancellation and the deadline. A send failure cancels the query.
* **Metrics** (`/metrics`): the required families plus
  `polyquery_http_requests_total{code}`. `polyquery_queries_total` counts
  every finished query request by outcome (rejected, timed-out and cancelled
  ones are `error`); the duration summary includes queueing time.
* **Logs**: JSON lines on stderr (`ts`, `level`, `msg` + structured fields).
  Every query emits `query finished` at `info` with `query_id`, `status`
  (`ok`/`error`), `error_code`, `duration_ms`, `rows` — never SQL text,
  values or bodies. Per-request access logs are at `debug`.
* **Shutdown** on SIGTERM/SIGINT: new queries get `503 SHUTTING_DOWN`,
  `/health` answers `503`, the listening socket is closed, active (running
  and queued) queries get `--shutdown-grace-ms` to finish; the rest are
  cancelled and given up to 2 s to deliver their `CANCELLED` responses; the
  process exits with status 0.

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
  scale 0 (`DECIMAL(W,0)`, as `1.5 * 2` → `DECIMAL(18,1)` requires); in
  comparisons INT64 and DECIMAL values compare exactly (CR-2 §4, see above),
  never raising `NUMERIC_OVERFLOW`. Two DECIMALs compare exactly by value. The untyped `NULL` literal in arithmetic
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
* **Query options**: `mode` is `auto` (= `vectorized`), `row` or
  `vectorized`; `join` is `auto`, `hash`, `merge` or `nested_loop`; unknown
  values of these enum options are `UNSUPPORTED`; ill-typed option values
  (also `threads` < 1) are `INVALID_REQUEST`. A query without `threads`
  uses the engine's `--threads`; without that flag, pipelines driven by at
  least `--parallel-min-rows` rows use min(CPUs, 8) partitions and all
  others stay serial. `native: true` uses the native kernels
  when `--native-kernels` loaded them and is a no-op otherwise.
* **Phase 5 result order**: without ORDER BY the row order may differ
  between join algorithms (a merge join emits in key order); for a given
  plan it is the same in row and vectorized mode and with any number of
  threads (partitions are merged in scan order).
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
  (two different DECIMALs → `DECIMAL(W,max(s))`), DATE+TIMESTAMP → TIMESTAMP.
  IN lists and BETWEEN compare the operand and all items exactly in one
  comparison type.
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
* **HTTP**: `PUT /v1/tables/{name}` accepts the query parameters `format`,
  `replace`, `header`, `delimiter` and `layout` (booleans as
  `true`/`false`/`1`/`0`); a body that is not UTF-8 is `INGEST_ERROR`.
  Successful `/v1/request` responses are `200` regardless of the op. Request
  bodies may use `Content-Length` or chunked transfer encoding; an oversized
  body (> `--max-request-bytes`) is answered `413 RESOURCE_LIMIT` (bodies up to
  64 MiB are drained first so the client sees the response). Unknown HTTP
  methods are answered like wrong methods (`405 INVALID_REQUEST`). JSON
  responses of the REST endpoints carry `"id": null`. `--workers 0` is
  treated as 1.
* Responses are serialized with ASCII escaping (`\uXXXX`) so the output is always
  valid UTF-8 JSON on one line.

* **UNION ALL typing** follows the CASE rule literally (semantics.md §13,
  as CR-1 requires): numeric promotion, otherwise identical types, untyped
  NULL columns adopt the other branches' type. Unlike this engine's CASE /
  COALESCE, `DATE` and `TIMESTAMP` branches are therefore *not* unified
  (`TYPE_ERROR`). Identical DECIMAL types are kept as they are
  (`DECIMAL(5,2)` ∪ `DECIMAL(5,2)` = `DECIMAL(5,2)`); different DECIMALs or
  INT64 with DECIMAL become `DECIMAL(W, max scale)`.
* **UNION ALL ORDER BY**: an output name that occurs more than once in the
  first branch (`SELECT a, a … UNION ALL … ORDER BY a`) is ambiguous
  (`SEMANTIC_ERROR`); a position is always accepted. Rows are concatenated in
  branch order, but without ORDER BY the order is unspecified (parallel
  branches keep partition order).
* `spec_version` stays `1.0.0` although CR-1 names `1.1.0-cr1` for engines
  that claim the change: the Phase 1 conformance case
  `phase1/catalog.pqt` asserts `"spec_version":"1.0.0"`, and earlier phases
  must keep passing. The adopted change is visible as capability
  `change.union_all`.

## Known limitations

* UNION ALL branches are not merged into partial aggregation / top-N: an
  aggregate or ORDER BY over a union consumes the concatenated branch rows
  (each branch can still run partitioned in parallel).

* The GIL serializes CPU work: concurrent queries interleave rather than run
  in parallel, so throughput does not scale with `--workers`. Intra-query
  parallelism (`threads`) uses forked worker processes instead, which needs
  `os.fork` (POSIX) and pays a pickle round-trip per pipeline (hence
  `--parallel-min-rows`). The persistent worker pool serves one query at a
  time; concurrent parallel queries fork workers per query.
* Each pool worker builds the hash-join build sides of its pipeline itself:
  a pipeline whose build side is larger than its driving scan (a LEFT JOIN
  probing a small table against a large one, A15 below) gains nothing from
  parallelism. Pool workers keep the copy-on-write pages they touched (about
  60–70 MB each after the whole analytics workload).
* Parallel speedups are limited by the serial parts: the merge of partial
  results in the parent (high-cardinality GROUP BY), returning many rows
  from workers (non-selective scans are therefore not parallelized at the
  root), and full sorts, whose re-sort of the merged runs is serial.
  Hash-join build sides and subquery plans are always built serially.
* Worker processes each enforce `--max-query-memory-mb` on their own
  partition, so a parallel query may use up to (workers + 1) × the budget.
* The native kernels only cover the work listed under *Native kernels*:
  joins, sorts, DISTINCT, expressions and row-layout tables run the
  engine's own code with `native: true` too (they profit only from
  natively filtered inputs). Without the library there is no explicit SIMD.
* A single in-memory sort (`ORDER BY`) runs `list.sort` without interruption,
  so cancellation/timeouts take effect only after the sort of a large input
  finishes; all other operators check at least every 65,536 rows.
* Backpressure for streams relies on TCP: the server never buffers more than
  the batch being written, but whatever the kernel accepts into socket
  buffers is produced ahead of the client (in this sandbox, loopback sockets
  accept very large amounts before blocking).
* The `sleep` protocol op is not cancellable.
* In-memory tables loaded from CSV/JSON are a single row group without
  min/max zone maps, so row-group skipping applies to PQCF-backed tables only.
* Decoded vectors of memory-mapped files are cached once read, so a fully
  scanned mmap table ends up resident like an eagerly opened one.
* `save` materializes each column of the table as a Python list while
  writing (memory ≈ one decoded copy of the table).
* Indexes are used for single-table predicates only (no index nested-loop
  joins) and never to produce ordered output.
* Correlated subqueries are executed per distinct parameter tuple (with the
  LookupScan optimisation for equality correlation, and `EXISTS` of that
  form as a hash semi-join); correlation through non-equality predicates is
  evaluated by re-running the subquery and can be slow on large inputs.
* The CSV/JSON readers hold the whole input in memory.
* Errors are identical across modes for every query whose rows raise at
  most one kind of error. When different rows would raise *different*
  errors, the one reported can depend on the mode, because row mode
  evaluates row by row and vectorized mode expression by expression
  (the spec leaves this open).
