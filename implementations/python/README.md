# PolyQuery — Python engine

An analytical database engine implementing the PolyQuery specification
(`spec/`) in pure Python. Current status: **Phase 5** (SQL v1 query engine
with row/column in-memory layouts, persistent PQCF v1 storage, statistics,
hash and ordered indexes, cost-based access-path selection, an HTTP/1.1
server with streaming results, admission control, timeouts, cancellation,
Prometheus metrics, structured logs and graceful shutdown; plus two execution
engines — row-at-a-time and vectorized —, hash / sort-merge / nested-loop
joins, parallel partitioned pipelines and a switchable logical optimizer).

Capabilities reported: `phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`,
`sql.basic`, `test.functions`, `phase2`, `sql.groupby`, `sql.join`,
`sql.functions`, `sql.subquery`, `sql.cte`, `sql.correlated_subquery`,
`phase3`, `storage.pqcf`, `storage.mmap`, `index.hash`, `index.btree`,
`phase4`, `http.streaming`, `phase5`, `exec.row`, `exec.vectorized`,
`exec.parallel`, `join.hash`, `join.merge`, `join.nested_loop`
(`native.kernels` is not claimed, see Phase 5 below).

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
bin/polyquery serve --port N [--workers N --queue-depth Q --query-timeout-ms T ...]
bin/polyquery version | capabilities
python3 tools/bench.py --data DIR       # Phase 5 benchmarks over pqgen.py datasets
python3 tools/difftest.py --seed N      # random queries under the whole option matrix
```

Engine-specific flag: `--parallel-min-rows N` (default 200,000): parallel
pipelines whose driving scan has fewer rows run their partitions in-process
(see Phase 5).

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
| `polyquery/planner/` | `planner.py` (bound query → logical plan), `logical.py` (Scan, Values, SubqueryScan, Filter, Join, Aggregate, Project, Distinct, Sort, Limit), `optimizer.py` (expression rewrites, predicate pushdown, join-condition extraction, column pruning), `rewrite.py` (constant folding, predicate simplification), `physical.py` (algorithm and access-path choice: TableScan, IndexScan, LookupScan, HashJoin, MergeJoin, NestedLoopJoin, HashAggregate, TopN, Gather, … with cardinality estimates, join reordering, parallel pipelines, and the EXPLAIN JSON), `access.py` (index-usable predicates, selectivity estimation, index selection, row-group skipping), `explain.py` (expression rendering) |
| `polyquery/execution/` | `compiler.py` (bound expression → row closure, incl. subquery evaluation), `vcompiler.py` (bound expression → vector function over column batches), `row_engine.py` (row-at-a-time Volcano operators, `mode:"row"`), `vector_engine.py` (column-batch operators, `mode:"vectorized"`/`auto`), `parallel.py` (partitioned execution of `Gather` pipelines, in-process or in forked workers), `common.py` (algorithms shared by both engines: merge pairing, sort orders, join limits, LookupScan tables), `group_states.py` (columnar aggregation state of the vectorized engine), `aggregates.py` (accumulators of the row engine), `functions.py` (scalar function kernels), `casts.py`, `executor.py` (mode dispatch, result streaming), `context.py` (timeout / cancellation / memory budget / join-row limit, correlation parameters, per-statement caches, GC pausing) |
| `polyquery/service.py` | `Engine` facade: owns the catalog, runs `load`, SQL and `explain` |
| `polyquery/protocol/` | Transport-independent request handler (validation, path safety, responses, streaming cursor), JSON-lines session loop, exec mode, canonical value serialization |
| `polyquery/server/` | `serve` mode: `http.py` (HTTP/1.1 routing, bodies, JSON / NDJSON responses, query lifecycle), `queries.py` (query registry + admission control), `watcher.py` (client-disconnect detection), `metrics.py` (Prometheus text), `app.py` (server lifecycle, signals, graceful shutdown) |
| `polyquery/cli.py` | Command line (`version`, `capabilities`, `session`, `exec`, `serve`), JSON-lines log formatter |

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

**`threads: N`** (default `--threads`, 1). With N > 1 the planner wraps
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

Join build sides on the path are built once before the partitions run.
Partial results are merged in partition order, so group order, ties and
float sums (`fsum`-based) do not depend on the partitioning. Subquery
plans stay serial.

*Why processes:* CPython's GIL serializes threads, so threads cannot make
CPU-bound operators faster. When the driving scan has at least
`--parallel-min-rows` rows (default 200,000), the partitions run in forked
worker processes (`execution/parallel.py`): at most one per CPU, each
handling every k-th partition. A child inherits a copy-on-write snapshot
of the immutable tables, the compiled plan and the prepared build sides.
It sends its partial result back through a pipe as a pickle. Columnar
group states, plain value lists and row lists all pickle cheaply. The
parent waits with `selectors`, observing cancellation and the deadline,
and kills all workers on error, cancel or timeout. Smaller inputs run
their partitions one after the other in the calling thread, through the
same partial/merge code, so the conformance matrix (`threads: 4` on small
tables) exercises the parallel logic. A unit test and `tools/difftest.py`
cover the forked path.

**`optimize: false`** disables all logical rewrites:
* constant folding (constant subexpressions become literals; a constant
  whose evaluation fails, like `1/0`, is left alone, so the error is
  raised exactly when a row evaluates it);
* predicate simplification (`TRUE AND x` → `x`, `FALSE OR x` → `x`,
  absorbing literals, `NOT NOT x`, comparisons with NULL, CASE branches
  with constant conditions, duplicate conjuncts, always-true filters
  removed; operands that may raise errors are never dropped);
* predicate pushdown;
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

**`native: true`** is accepted (boolean, else `INVALID_REQUEST`) and has
no effect: no native kernel library is built or loaded (`--native-kernels`
is accepted and ignored), so `native.kernels` is not claimed. That is
allowed, since native kernels are optional (native-kernels.md).

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
* **Vectorized execution** is 1.4–2.5× faster than row mode, and up to
  13× faster than the old engine (Q2). The gains come from C-level kernels,
  columnar group state and positional joins.
* **Parallel pipelines** (forked workers) give a further 1.5–2.4× at 4–8
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
* **Query options**: `mode` is `auto` (= `vectorized`), `row` or
  `vectorized`; `join` is `auto`, `hash`, `merge` or `nested_loop`; unknown
  values of these enum options are `UNSUPPORTED`; ill-typed option values
  (also `threads` < 1) are `INVALID_REQUEST`. A query without `threads`
  uses the engine's `--threads`. `native` is validated and has no effect
  (no native kernels).
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

## Known limitations

* The GIL serializes CPU work: concurrent queries interleave rather than run
  in parallel, so throughput does not scale with `--workers`. Intra-query
  parallelism (`threads`) uses forked worker processes instead, which needs
  `os.fork` (POSIX) and pays a fork plus a pickle round-trip per pipeline
  (hence `--parallel-min-rows`).
* Parallel speedups are limited by the serial parts: the merge of partial
  results in the parent (high-cardinality GROUP BY), returning many rows
  from workers (non-selective scans are therefore not parallelized at the
  root), and full sorts, whose re-sort of the merged runs is serial.
  Hash-join build sides and subquery plans are always built serially.
* Worker processes each enforce `--max-query-memory-mb` on their own
  partition, so a parallel query may use up to (workers + 1) × the budget.
* No native kernels (`native: true` has no effect) and no explicit SIMD:
  the standard library provides neither.
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
  LookupScan optimisation for equality correlation); correlation through
  non-equality predicates is evaluated by re-running the subquery and can be
  slow on large inputs.
* The CSV/JSON readers hold the whole input in memory.
* Errors are identical across modes for every query whose rows raise at
  most one kind of error. When different rows would raise *different*
  errors, the one reported can depend on the mode, because row mode
  evaluates row by row and vectorized mode expression by expression
  (the spec leaves this open).
