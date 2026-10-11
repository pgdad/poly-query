# PolyQuery — Java engine

An analytical database engine implementing the PolyQuery specification (`spec/`), at
**Phase 5**: protocol, catalog, CSV/JSON/JSONL ingestion, all data types, the complete
SQL v1 grammar (GROUP BY/HAVING, DISTINCT, INNER/LEFT/CROSS joins, all scalar functions,
CASE/LIKE/BETWEEN/IN, uncorrelated **and correlated** subqueries, derived tables, CTEs,
EXPLAIN), structured errors, resource limits and test functions; row- and column-oriented
in-memory layouts with dictionary encoding and null bitmaps, the persistent PQCF v1 columnar
file format (PLAIN/DICT/RLE, CRC-32, atomic crash-safe writes, memory-mapped reads), table
statistics, hash and ordered indexes, index selection, predicate pushdown with row-group
skipping, column pruning and cost-based join build-side selection; and the `serve` HTTP/1.1
server with every endpoint of protocol.md §7, streaming NDJSON results with backpressure,
Prometheus metrics, structured JSON logs, snapshot-isolated concurrent readers, a worker
limit with a bounded FIFO queue (`OVERLOADED` beyond it), query timeouts, cancellation
(explicit and on client disconnect) and graceful shutdown; and (Phase 5) a retained
row-at-a-time baseline plus a **vectorized** batch engine with **morsel-driven parallel** scans,
aggregation, DISTINCT and top-N, hash / sort-merge / nested-loop joins selectable per query, an
error-preserving logical optimizer (constant folding, predicate simplification and pushdown,
join reordering), top-N sorting, SIMD-friendly kernels and cache-conscious data structures —
see [Phase 5: optimization](#phase-5-optimization).

Capabilities: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic test.functions phase2
sql.groupby sql.join sql.functions sql.subquery sql.cte sql.correlated_subquery phase3
storage.pqcf storage.mmap index.hash index.btree phase4 http.streaming phase5 exec.row
exec.vectorized exec.parallel join.hash join.merge join.nested_loop`.

## Prerequisites and build

* OpenJDK 27 (`java`, `javac`, `jar` on `PATH`, or `JAVA_HOME` set). No other tools,
  no network, no third-party libraries (Track A: standard library only).
* `make build` — compiles with `javac --release 27` into `build/polyquery.jar`.
* `make test` — builds and runs the unit tests (`src/test/java`, plain Java with a small
  runner in `polyquery.TestMain`; JUnit is not used).
* `make lint` — compiles with `-Xlint:all -Werror`.
* `make fmt` — no-op (the JDK has no formatter); code follows standard Java style,
  4-space indentation, 120 columns.
* `make clean`.

`bin/polyquery` is a POSIX shell launcher that works from any directory (it resolves its
own location). Extra JVM flags can be passed with `POLYQUERY_JAVA_OPTS`.

```
bin/polyquery version | capabilities
bin/polyquery session [--data-dir DIR] [--enable-test-functions] [--log-level LEVEL] ...
bin/polyquery exec --request FILE|- [options]
bin/polyquery serve --port N [--host H] [--workers N] [--queue-depth N] [--query-timeout-ms N]
                    [--shutdown-grace-ms N] [--max-request-bytes N] [common options]
```

## Libraries

None. `ENGINE.json`: `{"language": "java", "track": "A", "libraries": []}`.

## Architecture

Source lives in `src/main/java/polyquery/`, one package per layer:

| Package | Responsibility |
|---|---|
| `common` | `ErrorCode`, `PolyQueryException` (code + message + details), ASCII name folding |
| `types` | `DataType`, value representation, exact DECIMAL arithmetic (`Decimals`), DATE/TIMESTAMP (`DateTimes`), strict text parsers, `Casts`, ordering/text (`Values`) |
| `json` | Strict RFC 8259 parser (keeps number literal text, optional duplicate-key rejection) and writer |
| `sql.lexer` | Tokenizer with line/column positions, reserved keywords, comments |
| `sql.ast` | Immutable AST (sealed interfaces + records) for the full v1 grammar |
| `sql.parser` | Recursive-descent parser (WITH, joins, subqueries, CASE, IN, LIKE, BETWEEN, EXPLAIN, CREATE/DROP INDEX); `PARSE_ERROR` carries `line`/`column` |
| `sql.analyzer` | Semantic validation: `Scope` (range variables, correlation), `ExpressionBinder` + `TypeCoercion` + `ScalarFunctionBinder` (typing), `Analyzer` (per query level: FROM/joins/derived tables/CTEs, GROUP BY rewriting, ORDER BY resolution → `BoundQuery`), `LogicalPlanner` (`BoundQuery` → logical plan) |
| `plan` | Bound (typed) expressions (`BoundExpr`, `BoundExprs` traversal), aggregate calls, subqueries, logical plan nodes, expression formatter |
| `optimizer` | `LogicalOptimizer`: constant folding, predicate simplification, error-preserving predicate pushdown into joins and scans, CROSS→INNER join conversion; `JoinReorder` (inner-join trees). All disabled by `optimize: false` |
| `physical` | `PhysicalPlan` nodes, `PhysicalPlanner` (table vs index scans, hash / merge / nested-loop joins and build side, top-N, hash lookup for correlated filters), `ColumnPredicates` (sargable conjuncts → key predicates), `Cardinality` (estimates from statistics), `ColumnPruner`, `PlanExplainer` (EXPLAIN JSON) |
| `exec` | Row engine (`mode: row`): Volcano operators (table/index scans, filter, project, hash aggregate, distinct, hash/merge/nested-loop joins, sort, top-N, limit, hash-lookup filter), `OperatorBuilder` (physical plan → operators), `ExpressionCompiler` (bound expression → closures), `ScalarFunctions`, `SubqueryRunner`, `ExecContext` (timeout, memory budget, row/join limits, correlation frames) |
| `exec.vector` | Vectorized engine (`mode: vectorized`): `Vec`/`Batch` (column vectors + selection vectors), `VecCompiler` + `Kernels` (batch expression kernels), `BatchExprs` (row-exact error semantics), scan/filter/project/limit, `AggregateBatches` + `GroupKeys` + `AggState` (hash aggregation, DISTINCT), `JoinBatches` (hash join), `SortBatches` (sort, top-N), `ColumnStore`, `Parallel` (morsel-driven workers), `BatchBuilder` (plan → batch operators), `VectorExecutor` |
| `storage` | Immutable table snapshots (`Table` = schema + `TableData` + indexes + statistics); `ColumnarData` (`ColumnVector`s: primitive arrays + null bitmaps, dictionary-encoded strings), `RowData` (row tuples), `Layouts` (conversions, dictionary policy), `TableStatistics`/`DistinctCounter`, thread-safe `Catalog` (tables and global index names) |
| `storage.pqcf` | PQCF v1: `PqcfWriter` (atomic save), `ChunkEncoder`, `PqcfReader` (header/footer/metadata validation), `ChunkDecoder` (CRC + value validation), `PqcfTableData` (row groups, lazy chunks over a memory-mapped file) |
| `index` | `HashIndex`, `OrderedIndex` (sorted permutation), `KeyDomain`/`KeyPredicate` (typed lookup keys and predicates) |
| `ingest` | CSV parser + type inference, JSON / JSON Lines ingestion |
| `engine` | `Engine` façade used by every front-end; config; path safety |
| `protocol` | JSON request handling/validation (`RequestHandler`, `QueryRequest`), the `QueryRunner` policy hook, result serialization, structured logger |
| `server` | HTTP/1.1 server (Phase 4): `HttpServer` (accept loop, connection threads, graceful shutdown), `HttpConnection` (request parsing, fixed/chunked responses, disconnect detection), `ApiRouter` (endpoints → protocol ops), `QueryStream` (NDJSON streaming with backpressure), `QueryManager` (query registry, timeouts, metrics, logs), `Admission` (worker limit + FIFO queue), `Metrics` (Prometheus text) |
| `Main` | CLI (`version`, `capabilities`, `session`, `exec`, `serve`) |

Query pipeline (each stage is a separate class and data structure):

```
SQL text ─Lexer→ tokens ─Parser→ AST (Statement/Query/Expr)
   ─Analyzer/ExpressionBinder→ BoundQuery per query level (typed BoundExpr, resolved names)
   ─LogicalPlanner→ LogicalPlan ─LogicalOptimizer→ LogicalPlan
   ─PhysicalPlanner→ PhysicalPlan ─┬─ OperatorBuilder/ExpressionCompiler→ Operator tree ─Executor→ rows      (mode: row)
                                   └─ BatchBuilder/VecCompiler→ BatchOperator tree ─VectorExecutor→ rows   (mode: vectorized)
```

`EXPLAIN` renders the physical plan (`TableScan`/`IndexScan` with `table`, `index`, `kind` and
the `columns` actually read, `Filter`, `Project`, `Aggregate`, `Distinct`,
`HashJoin`/`MergeJoin`/`NestedLoopJoin` with `join_type` (and `build_side` for hash joins),
`Sort`, `TopN`, `Limit`, `Values`, `HashLookupFilter`); the physical plan is the same in both
execution modes; plans of subqueries appear under a `subqueries` property of the node that
evaluates them. Scans also show `row_group_filters` (predicates used to skip row groups),
`layout` and `estimated_rows`.

### Storage (Phase 3)

A `Table` is an immutable snapshot; its rows live in a `TableData` partitioned into row
groups:

* **Column layout** (default): one `ColumnVector` per column — `long[]`/`int[]`/`double[]`/
  `BitSet` values plus a `BitSet` null bitmap, `String[]` or a dictionary-encoded string vector
  (`int[]` codes into a table of distinct strings). STRING columns are dictionary-encoded
  automatically when at most half of the values are distinct, always with
  `{"dictionary":true}`, never with `false`.
* **Row layout** (`{"layout":"row"}` on `load`/`open`): an `Object[][]` of row tuples.
* **PQCF-backed** (`open`): the file's row groups are kept, with their chunk min/max
  statistics, so scans can skip row groups. With `{"mmap":true}` the file is mapped with
  `FileChannel.map` into a `MemorySegment` (FFM API, `Arena.ofAuto`) and each chunk is
  CRC-checked and decoded on first access (a corrupt chunk fails the query that reads it
  with `STORAGE_CORRUPT`). Without mmap the file is read and every chunk is verified and
  decoded at `open`, so corruption is reported by `open` itself. `{"layout":"row"}` converts
  the file to row tuples at `open`.

Scans produce rows of the table's full width but fill only the slots the query reads (column
pruning keeps slot positions stable, so no expression has to be rewritten). The pruner walks
the physical plan top-down collecting the slots each operator reads, including outer
references of correlated subqueries; unused pass-through outputs of projections (plain
columns/literals of derived tables and CTEs) are not computed.

**PQCF writer:** chunks are 8-byte aligned (zero padding), row groups hold
`row_group_size` rows (default 65536). `encoding: auto` picks RLE when the run count is
below n/4 (BOOLEAN/INT64/DECIMAL/DATE/TIMESTAMP; NULL slots extend the current run), DICT
when fewer than n/2 strings are distinct, PLAIN otherwise; `plain`/`dict`/`rle` force the
encoding where it applies (PLAIN elsewhere). min/max statistics are written for every
non-STRING chunk with a non-null value. Saves write `.<target>.tmp-<pid>-<nanos>-<n>` in the
target directory, `fsync` it, `rename` it over the target (atomic replace) and `fsync` the
directory; temporaries left by crashed processes (dead pid) are deleted by the next save to
the same target.

**PQCF reader** validation (`STORAGE_CORRUPT` unless noted): magic, version (0 corrupt,
>1 `STORAGE_VERSION_UNSUPPORTED`), flags (≠0 `STORAGE_VERSION_UNSUPPORTED`), trailer,
metadata bounds, CRC and strict UTF-8 JSON, required keys and their types, unique non-empty
column names, valid types, Σ row counts, one chunk per column, chunk ranges, null counts,
encodings (unknown name → `STORAGE_VERSION_UNSUPPORTED`; known but inapplicable to the
type → corrupt), index entries; per chunk: CRC, exact decoded length, bitmap null count,
string offsets, UTF-8, DECIMAL precision, DATE/TIMESTAMP range, finite FLOAT64, BOOLEAN RLE
values, dictionary codes, RLE run lengths. Bytes between the header and the metadata that
belong to no chunk must be zero (the format only allows zero padding), so damage to padding
is detected too. Unknown metadata keys are ignored; malformed chunk min/max values are
treated as unknown. All of this was cross-checked with an independent reader and with
random bit-flip/truncation fuzzing.

### Indexes and planning (Phase 3)

`CREATE INDEX … USING HASH` builds a hash map key → row ids; `BTREE` (the default) builds a
sorted permutation of the non-null rows (`long[]`/`double[]`/`String[]` keys + `int[]` row
ids, stable merge sort) searched by binary search — equality, IN and ranges. Index keys are
mapped to a per-type key domain (`KeyDomain`: BOOLEAN/INT64/DECIMAL/DATE/TIMESTAMP → `long`,
FLOAT64 → `double`, STRING → `String`). Lookups return ascending row ids, so index scans
return rows in table order. Indexes belong to a table snapshot: CREATE/DROP INDEX publish a
new snapshot sharing the data; replacing or dropping a table drops its indexes; `save`
records them and `open` rebuilds them (failing with `ALREADY_EXISTS`, before the catalog is
touched, if a name is taken by another table).

For a filter directly over a scan, the planner extracts *sargable* conjuncts
(`col op constant`, `constant op col`, `col BETWEEN c1 AND c2`, `col IN (constants)`, also
through the exact implicit casts INT64→DECIMAL and DATE→TIMESTAMP) and converts them to a
`KeyPredicate` per column (points, range or empty), intersecting several conjuncts on one
column. Constants of another DECIMAL scale (or TIMESTAMP constants against a DATE column)
are converted exactly with rational floor/ceil, so `int_col > 2.5` becomes `int_col >= 3`.
Selectivity follows the spec: equality ≈ k/distinct, ranges by linear interpolation between
min and max (1/3 for strings). The most selective usable index is chosen when its
selectivity is ≤ 10% — or when it is expected to return at most 3 rows (on tiny tables a
lookup returning a handful of rows is never worse than a scan); otherwise a table scan is
used, which skips row groups whose min/max exclude a sargable predicate. The complete filter
is still evaluated above the access path, so results never depend on the choice.

Hash joins build on the input with the smaller estimated cardinality for INNER joins (the
right input for LEFT joins). Estimates: table rows × selectivity of the sargable conjuncts
(× 1/3 per other conjunct) for filtered scans, max(left, right) for equi-joins, product for
cross joins.

Statistics (`stats`): row count and per column null count, min, max and distinct count —
computed on first use per column and cached with the table data; distinct counts are exact
up to 100,000 distinct values and HyperLogLog estimates (2^14 registers) beyond.

### Subqueries and correlation

Every query level gets a *correlation frame* id. A column that does not resolve in the current
level is looked up in enclosing levels (derived tables and CTE bodies cannot see the range
variables of the level that contains them) and bound as `OuterRef(frame, index)`; the
reference is recorded in every level between the reference and its target, so each subquery
knows exactly which outer values it depends on. At run time a subquery expression sets its
frame to the row it is evaluated on, runs (or re-opens) its operator tree and restores the
frame. Uncorrelated subqueries run once; correlated ones are memoized by the values of their
outer references. A filter inside a correlated subquery of the form `inner_expr = outer_ref`
becomes a `HashLookupFilter`: the uncorrelated input is hashed once and each execution only
probes it, which turns the usual O(outer × inner) evaluation into O(outer + inner).
In aggregated queries, correlated subqueries in SELECT/HAVING/ORDER BY see a frame row rebuilt
from the group keys; referencing an ungrouped column there is a `SEMANTIC_ERROR`.

### Joins

Joins associate left to right. ON conditions are split into equi-join keys
(`left_expr = right_expr`) and a residual. With at least one key the join is a hash join (hash
table on the input with the smaller estimated cardinality; for LEFT JOIN the right side must be
the build side) — or, with `join: "merge"`, a sort-merge join (both inputs materialized with
their key tuples, sorted stably, runs of equal keys paired; LEFT JOIN pads unmatched rows,
including rows with NULL keys) — or, with `join: "nested_loop"`, a nested-loop join. Joins
without equi keys (and CROSS joins) are always nested-loop joins. `auto` (default) picks a
hash join. NULL keys never match. Equal values of different DECIMAL scales match. Every join
operator counts its output rows against `--max-join-rows` (`RESOURCE_LIMIT`).

### HTTP server and concurrency (Phase 4)

The server is written directly on `java.net.ServerSocket` (no `com.sun.net.httpserver`), which
gives full control over keep-alive, chunked output, request size limits and — importantly —
noticing a client disconnect while a query runs.

* **Threads.** Each connection is served by its own platform thread; each query runs on a
  thread of a separate cached pool (both with large stacks, as in session mode, for deeply
  nested SQL). While a query runs, the connection thread polls the socket (1 ms reads between
  5 ms waits on the query's future); end-of-stream means the client went away and the
  query is cancelled. Bytes of a pipelined next request are simply buffered.
* **Query lifetime.** A `QueryControl` (deadline + cancellation flag) is created per query and
  checked by `ExecContext` (every 1024 operator calls, every 5 ms inside `PQ_SLEEP`, and on
  every 1024th comparison of a sort). The deadline is set on arrival — `options.timeout_ms`
  if > 0, else `--query-timeout-ms` — so queueing time counts.
* **Admission** (`Admission`): at most `--workers` queries execute; up to `--queue-depth`
  wait in FIFO order on a monitor (timed waits, so queued queries also observe timeouts and
  `DELETE /v1/queries/{id}`); anything beyond is rejected at once with `OVERLOADED` (503).
  Health, metrics, listing, cancellation and catalog requests never go through admission.
* **Registry** (`QueryManager`): queued/running queries by `query_id` (client-assigned or a
  generated UUID, returned in `X-PolyQuery-Query-Id` and in the response body's `query_id`);
  an id in use ⇒ 409 `ALREADY_EXISTS`. Queries are unregistered before their response is
  written, so cancelling a finished query is 404. Queries sent through `POST /v1/request`
  (`op: query`) are treated exactly like `POST /v1/query`.
* **Snapshot isolation.** The catalog is a copy-on-write immutable map behind a volatile
  reference; mutations are serialized by a lock and publish a new map atomically. A query
  takes one `Catalog.Snapshot` before analysis and resolves every table reference (including
  subqueries and CTEs) against it; tables are immutable values, so replaced or dropped tables
  stay readable by queries holding them. Loads parse outside the lock and only publish under it.
* **Streaming** (`QueryStream`): the worker serializes rows into
  `{"type":"rows",…}` lines (≤ 4096 rows or 1 MiB per batch; the first row, and later a batch
  at least every 50 ms, is sent immediately) and hands them to the connection thread, which
  writes one HTTP chunk per line. A semaphore of 16 credits bounds the batches in flight, so a
  client that stops reading blocks the query (which still observes cancellation and its
  timeout while blocked). The header line is sent with the first batch, at the end, or 100 ms
  after execution started, whichever comes first: errors raised before that (parse, semantic,
  admission, early runtime errors) get a normal HTTP error response; later errors end the
  stream with an `{"type":"error",…}` line and no `end` line.
* **Graceful shutdown.** SIGTERM/SIGINT run a JVM shutdown hook: close the listening socket,
  reject new queries with `SHUTTING_DOWN` (503; `/health` answers 503 and responses carry
  `Connection: close`), wait until all in-progress requests have completed or
  `--shutdown-grace-ms` elapsed, then cancel the remaining queries (`CANCELLED`), give their
  responses up to 3 s to be written, close all connections and `Runtime.halt(0)` (exit status 0).
* **Metrics** (`GET /metrics`, Prometheus text 0.0.4): all required families plus
  `polyquery_http_requests_total`. Every finished query (including rejected ones) counts in
  `polyquery_queries_total{status="ok"|"error"}` and in the duration summary (measured from
  arrival). **Logs** are JSON lines on stderr (`ts`, `level`, `msg`, + fields); each finished
  query logs `query_id`, `status`, `error_code`, `duration_ms`, `rows` — never SQL text or data.

### Runtime value representation

BOOLEAN → `Boolean`, INT64 → `Long`, DECIMAL(p,s) → `Long` unscaled value (scale from
the static type), FLOAT64 → `Double`, STRING → `String`, DATE → `Integer` days since
1970-01-01, TIMESTAMP → `Long` microseconds since epoch, NULL → `null`. Types are always
known statically, so values carry no tags.

DECIMAL arithmetic is exact: 64-bit fast paths with `Math.*Exact`, falling back to
`BigInteger` for intermediates; any result beyond 18 digits is `NUMERIC_OVERFLOW`.
SUM/AVG over INT64/DECIMAL accumulate exactly (widening to `BigInteger`); only the final
INT64/DECIMAL result is range-checked.

## Phase 5: optimization

Every query runs in one of two execution models, selected per query (`mode`):

* **`row`** — the unoptimized baseline, kept permanently: the Volcano operators of Phases 1–4
  (`polyquery.exec`), one boxed `Object[]` row at a time, single-threaded.
* **`vectorized`** (also `auto`, the default) — batch execution over column vectors
  (`polyquery.exec.vector`), parallel when `threads` > 1.

Both run the same physical plan, so `EXPLAIN` is identical; `optimize` and `join` act on
planning and apply to both. Every combination of `mode` × `join` × `threads` × `optimize`
returns the same rows (multiset; ordered queries in the same order; FLOAT64 sums within
rounding) **and the same errors** — the one exception being queries whose outcome depends on
the unspecified row order of a join (see Known limitations).

### Vectorized execution

* **Batches** (`Batch`, 2048 rows by default) hold one `Vec` per slot of the operator's row
  layout plus a **selection vector** of active positions; filters only narrow the selection
  (no copying), evaluating the conjuncts of a WHERE one after the other on the rows still
  undecided, so most rows are discarded by the first, cheapest loops. A `Vec` is struct-of-arrays: `long[]` (INT64, DECIMAL unscaled, DATE, TIMESTAMP,
  BOOLEAN 0/1), `double[]` or `Object[]`, a `boolean[]` null mask, or — for dictionary-encoded
  STRING columns — `int[]` codes into the table's dictionary, which flow through scans, joins,
  sorts and parallel exchange unchanged, so string predicates (`=`, `LIKE`, `IN`) are evaluated
  once per distinct value and GROUP BY maps codes to group ids through a per-dictionary cache.
* **Expressions** are compiled by `VecCompiler` into batch kernels (`Kernels`): column refs,
  constants (folded at compile time), arithmetic with exact overflow checks, comparisons, AND /
  OR / NOT with the row engine's short-circuit (the right side is evaluated only on undecided
  rows), IS NULL, IN lists (hash sets), BETWEEN, LIKE, CASE (each branch only on its rows),
  NULLIF, `||`, numeric/temporal casts. Scalar functions and CASTs without a kernel apply the row
  engine's compiled code to one vectorized argument; subqueries and anything else fall back to
  row-at-a-time evaluation of that subexpression — so every expression is supported.
* **Operators**: table/index scans, filter, project, LIMIT/OFFSET, hash aggregation, DISTINCT,
  hash join, sort and top-N are batch operators; sort-merge and nested-loop joins and correlated
  hash lookups are the row engine's operators, connected through `BatchToRow`/`RowToBatch`
  adapters (so `join: merge`/`nested_loop` work in vectorized mode too).
* **Row-exact errors.** Batch-wise evaluation must not change *which* error a query raises, or
  whether it raises one (e.g. `SELECT 1/(x-3) FROM t LIMIT 2`). `BatchExprs` runs the kernels;
  if one raises a data error the batch is re-evaluated row by row with the row engine's code to
  find the first failing row; the batch is truncated before it and the error is attached to the
  batch (`Batch.error`) and raised by the consumer only when it needs the next row. Since every
  later pipeline stage only sees the rows before the error, the error raised is exactly the one
  of row-at-a-time execution, and a LIMIT satisfied earlier never raises it. Timeouts,
  cancellation and resource limits are never deferred.

### Parallel execution (`threads`)

`Parallel` runs *pipelines* — a table scan followed by filters, projections and hash-join
probes (with their hash tables built first and then shared read-only) — on a shared pool of
daemon worker threads. Row groups are cut into **morsels** (65,536 rows) handed out in scan
order; each worker compiles its own copy of the pipeline (expressions have per-instance
buffers). Pipelines with subqueries or correlated references stay on the query thread, and a
pipeline over fewer than two morsels is not parallelized.

* **Aggregation**: each worker aggregates whole morsels into a private partial table and
  records, per group, the position (morsel, row) of its first row. The partial tables are
  partitioned by key hash (hashes are computed from the values, so they agree across tables)
  and the partitions are merged in parallel, each with a k-way merge in first-position order;
  the output interleaves the partitions by first position — so groups come out in exactly the
  order of sequential execution. INT64/DECIMAL sums merge exactly (BigInteger on overflow).
* **DISTINCT** runs as a keys-only parallel aggregation when no pipeline expression can fail;
  otherwise workers drop duplicates within their morsels and the final DISTINCT streams over
  the rest. **Top-N**: workers keep the best `offset + limit` rows of each morsel (stable), the
  final top-N picks among them.
* **Everything else** is gathered **in morsel order** with a bounded number of morsels in
  flight, so row order (and therefore LIMIT without ORDER BY) is the same as sequential.
* **Errors**: a data error of morsel *m* is raised only after the results of all earlier
  morsels — workers skip later morsels once an earlier one failed — i.e. the error of the
  first failing row in scan order, as in sequential execution.

### Joins

* **Hash join** (vectorized): the build input is materialized in a `ColumnStore` (presized
  when the input is a plain table scan); a single integer-like key uses `LongIndex`, an
  open-addressing table with the key stored inline in the slot (one cache miss per probe) — for
  large build sides (≥ 131,072 rows) with several threads, built as hash partitions in parallel;
  other keys use the generic tuple table. Rows with equal keys
  are chained in input order. The probe emits (probe row, build row) pairs in probe order and,
  per probe row, in build order, gathering only the columns some consumer reads; LEFT JOIN
  padding rows are placed right after their row's candidates — the row engine's exact order.
* **Sort-merge join** and **nested-loop join**: row operators (see Joins above).
* `join: auto` chooses a hash join for equi-joins; the build side is the smaller estimated input.

### Logical optimizer (`optimize`)

* **Constant folding** of every constant subexpression (once, at planning) — unless its
  evaluation fails; then it is left for the rows that evaluate it.
* **Predicate simplification**: `TRUE AND x → x`, `FALSE AND x → FALSE`, `x OR FALSE → x`,
  `NOT NOT x → x`, … (`x AND FALSE → FALSE` only when `x` cannot fail), always-TRUE filters vanish.
* **Predicate pushdown** into join inputs and scans (also enabling index scans and row-group
  skipping), CROSS→INNER join conversion. **Error-preserving**: moving a predicate changes the
  rows the others are evaluated on, so a conjunct moves only if it precedes every conjunct that
  may raise an error — and, when such a conjunct exists, only if it can never be NULL (a NULL
  conjunct does not stop the evaluation of the following ones; a pushed-down filter would) —
  and nothing moves across a join condition that may fail. `ExprSafety` decides both, using
  column statistics: interval arithmetic over min/max proves e.g. that `price * 2` cannot
  overflow or that a divisor range excludes 0; null counts prove columns non-NULL. So
  `optimize: true` and `false` agree on errors too, while the usual shapes (comma joins with
  the join condition first, arithmetic on stored values) are still fully optimized.
* **Join reordering** (`JoinReorder`) of inner-join trees with ≥ 3 inputs: start with the
  connected pair with the smallest estimated join result, then repeatedly add the connected
  input with the smallest estimated result (equi-join selectivity 1/max(distinct counts) from
  table statistics); conditions are placed at the lowest join where their inputs are available
  and a projection restores the original column order. Only when all conditions are free of
  subqueries and cannot fail.
* **Projection pushdown**: the column pruner (Phase 3) reads only referenced columns.
* **Top-N** (physical planning, also disabled by `optimize: false`): `ORDER BY … LIMIT n`
  keeps only the best `offset + n` rows (row engine: bounded heap; vectorized: column store
  re-sorted and truncated whenever it doubles). Ties keep input order, exactly like the stable
  full sort.

### Sorting

The vectorized sort materializes its input in a `ColumnStore` and sorts row indices stably: an
**LSD radix sort** (8-bit digits, constant digits skipped) on an order-preserving 64-bit key of
the first sort key — the value for numbers (sign-flipped; doubles via their IEEE bits with
-0.0 = 0.0), a 4-UTF-16-unit prefix for strings (mapped to code-point order) — then a merge
sort with full typed comparisons only within runs of equal radix keys.

### SIMD, memory and cache

* **SIMD**: kernels are counted loops over primitive arrays without branches in the common
  null-free case — comparisons produce 0/1 with bit arithmetic (`(d ^ ((x ^ y) & (d ^ x))) >>> 63`
  for `x < y`), overflow checks OR flags across the loop instead of branching, SUM over INT64/
  DECIMAL without GROUP BY is two overflow-free reductions over the 32-bit halves (exact),
  MIN/MAX use `Math.min/max` reductions — which HotSpot's SuperWord pass compiles to AVX2/
  AVX-512 instructions. The JDK's explicit SIMD API (`jdk.incubator.vector`) was evaluated and
  rejected: it is an incubator module whose use makes the JVM print an unsuppressible
  non-JSON `WARNING: Using incubator modules` line on stderr, violating the structured-log
  contract (every stderr line is JSON; checked by the HTTP suite).
* **Memory pooling**: operators and expression kernels own their output vectors and reuse them
  for every batch (no per-row and almost no per-batch allocation); rows are boxed only at the
  very end (result rows) — `result: count` boxes nothing.
* **Cache-aware layouts**: aggregate states are primitive arrays indexed by group id (no
  per-group objects); group keys are stored flat in a `long[]` with the full hash kept per group
  and an `int[]` open-addressing index (linear probing), so most probes touch one index slot and
  one hash; the join index stores keys inline; parallel aggregation merges hash partitions
  independently.

### Measurements

Generated data at scale `1m` (`python3 datasets/generators/pqgen.py generate --scale 1m`:
transactions 1,000,000 rows, customers 100,000, orders 250,000, order_items 1,000,000,
products 20,000, sensor_readings / nulls_heavy / sort_keys 1,000,000), loaded as in-memory
column tables. `tools/bench.py` loads them into one session and reports the median wall time
(ms, client side, `result: count`) of 7 runs after 2 warm-up runs. Machine: AMD Ryzen 9 9950X3D
(16 cores / 32 threads, AVX-512), OpenJDK 27, default JVM flags of `bin/polyquery`.

Queries (tables `tx` = transactions, `cust` = customers, `items` = order_items, `sensor`,
`nh` = nulls_heavy, `sk` = sort_keys; the exact SQL is in `tools/bench.py`):

* **Q1** (filter+agg): `SELECT COUNT(*), SUM(amount), AVG(fee) FROM tx WHERE status = 'approved' AND amount > 100`
* **Q2** (group by, low cardinality): `SELECT category, COUNT(*), SUM(amount), MIN(ts), MAX(amount) FROM tx GROUP BY category` (20 groups)
* **Q3** (group by, high cardinality): `SELECT customer_id, COUNT(*), SUM(amount) FROM tx GROUP BY customer_id` (80,777 groups)
* **Q4** (join+group): `SELECT c.segment, COUNT(*), SUM(t.amount) FROM tx t JOIN cust c ON c.customer_id = t.customer_id GROUP BY c.segment`
* **Q5** (3-way join): orders ⋈ order_items ⋈ products, `WHERE o.status = 'delivered'`, `GROUP BY p.category`
* **Q6** (top-N): `SELECT tx_id, amount FROM tx WHERE status = 'approved' ORDER BY amount DESC, tx_id LIMIT 10`
* **Q7** (sort): `SELECT id, float_key FROM sk ORDER BY float_key` (1,000,000 rows out)
* **Q8** (sensor avg): `SELECT sensor_id, AVG(temperature), MAX(humidity) FROM sensor GROUP BY sensor_id`
* **Q9** (distinct): `SELECT DISTINCT merchant_id, category FROM tx` (181,642 rows)
* **Q10** (string filter): `SELECT COUNT(*) FROM cust WHERE email LIKE '%1@example.com' AND country IN ('US', 'GB')` (100,000 rows)
* **Q11** (projection): `SELECT tx_id, amount * 2 + fee, UPPER(currency) FROM tx WHERE bucket < 500` (499,822 rows out)
* **Q12** (nulls): `SELECT n50 % 10, COUNT(*), SUM(n90), COUNT(f95) FROM nh GROUP BY 1` (50–95% NULLs)
* **Q13** (join order): items ⋈ orders ⋈ products ⋈ customers written in a bad order, selective filters on products and customers
* **Q14** (conjunctive filter): `SELECT COUNT(*) FROM tx WHERE bucket < 500 AND merchant_id > 10 AND customer_id <> 7`
* **Q15** (reductions): `SELECT SUM(tx_id), MIN(bucket), MAX(merchant_id), COUNT(*) FROM tx`

Median milliseconds. *Before* is the Phase-4 engine this phase started from (row-at-a-time,
its default optimizations); the other columns are this engine with the given options
(`join: auto`); speed-up = before ÷ best vectorized time.

| query | before (Phase 4) | row, `optimize:false` (baseline) | row | vectorized, 1 thread | vectorized, 4 threads | vectorized, 16 threads | speed-up |
|---|---:|---:|---:|---:|---:|---:|---:|
| Q1 filter+agg | 24.7 | 33.5 | 33.3 | 2.7 | 1.0 | 1.0 | 25× |
| Q2 group by (low card.) | 44.3 | 28.0 | 27.5 | 9.2 | 3.7 | 4.3 | 12× |
| Q3 group by (high card.) | 60.4 | 65.2 | 73.7 | 15.3 | 13.5 | 16.8 | 4× |
| Q4 join+group | 61.3 | 62.0 | 64.1 | 23.6 | 13.8 | 15.9 | 4× |
| Q5 3-way join | 50.7 | 109.3 | 48.3 | 12.5 | 6.9 | 5.4 | 9× |
| Q6 top-N | 117.3 | 107.0 | 17.7 | 5.2 | 1.9 | 1.8 | 65× |
| Q7 sort | 358.5 | 391.8 | 409.6 | 24.0 | 22.5 | 22.3 | 16× |
| Q8 sensor avg | 29.8 | 31.4 | 30.8 | 8.2 | 2.6 | 4.5 | 11× |
| Q9 distinct | 78.8 | 77.5 | 77.4 | 19.7 | 21.4 | 17.5 | 5× |
| Q10 string filter | 4.2 | 6.3 | 4.0 | 3.3 | 2.9 | 2.6 | 2× |
| Q11 projection | 46.0 | 43.7 | 42.9 | 5.3 | 2.1 | 1.2 | 38× |
| Q12 nulls | 33.7 | 34.7 | 32.7 | 17.6 | 5.2 | 2.0 | 17× |
| Q13 join order | 52.4 | 111.3 | 39.9 | 11.6 | 11.1 | 12.4 | 5× |
| Q14 conjunctive filter | 32.5 | 32.5 | 32.4 | 3.0 | 1.0 | 0.5 | 65× |
| Q15 reductions | 24.8 | 24.2 | 24.0 | 0.8 | 0.4 | 0.2 | 124× |

Observations:

* Vectorized execution alone (1 thread) is 2–30× faster than row-at-a-time (except the tiny
  Q10, where both are a few milliseconds): no boxing,
  no per-row `Object[]`, primitive hash tables and accumulators, dictionary codes for strings.
  Largest single-thread gains: reductions and filters (Q14/Q15: tight loops over primitive
  arrays), sorting (Q7: radix sort instead of a boxed comparator sort, 16×), projection (Q11).
* Threads add another 2–10× where the work is per row (Q1, Q8, Q11, Q12, Q14). Small or
  already-fast queries are bounded by fixed costs (thread hand-off, merging) — Q10 is a
  100,000-row table, i.e. two morsels. High-cardinality grouping/DISTINCT (Q3, Q9) gain
  little: each worker's partial table holds most groups, so merging costs about as much as
  the aggregation saved. Q4/Q13 are limited by the single-threaded hash-table build.
* Logical optimization matters most for multi-way joins written in a poor order: Q13 runs
  111 → 40 ms in row mode (pushdown + join reordering), Q5 109 → 48 ms (pushdown).
  Top-N turns Q6 from a full sort (107 ms) into a 18 ms heap scan even in row mode.
* Results are identical in every configuration (`tools/bench.py` asserts equal row counts;
  the conformance `--modes` matrix and `tools/difftest.py` compare contents).

**SIMD.** The same vectorized runs (1 thread) with HotSpot's auto-vectorizer disabled
(`-XX:-UseSuperWord`) show where the SIMD-friendly loops pay off; elsewhere the costs are
hashing, memory access and selection-vector bookkeeping, which do not vectorize:

| query | SuperWord on | SuperWord off |
|---|---:|---:|
| Q15 reductions | 0.8 | 2.1 |
| Q14 conjunctive filter | 3.0 | 3.8 |
| Q7 sort | 24.0 | 34.6 |
| Q6 top-N | 5.2 | 7.9 |
| Q1 filter+agg | 2.7 | 2.8 |
| Q11 projection | 5.3 | 5.5 |
| Q2 group by (low card.) | 9.2 | 9.0 |

### Configuration for experiments

`-Dpolyquery.batchSize=N`, `-Dpolyquery.morselRows=N` and `-Dpolyquery.parallelBuildRows=N` (via
`POLYQUERY_JAVA_OPTS`) change the batch and morsel sizes and the build size from which hash-join
indexes are built in parallel. Tiny values (e.g. 3 and 5) make every batch boundary, adapter, parallel
worker and deferred-error path run on the small conformance fixtures; the conformance suite,
the `--modes` matrix and the unit tests pass that way too.

## Design decisions / interpretations

Where the spec leaves room, these choices were made:

* `UNION`, `RIGHT JOIN` and `FULL JOIN` are `UNSUPPORTED`. Unknown function names are
  `SEMANTIC_ERROR`. `CREATE INDEX` checks the table and column (`SEMANTIC_ERROR`) before the
  index name (`ALREADY_EXISTS`, or a no-op with `IF NOT EXISTS`). Index names are matched
  case-insensitively. `EXPLAIN` (statement or `explain` op) of `CREATE/DROP INDEX` is a
  `SEMANTIC_ERROR`.
* `load`/`open` option `layout` must be `"row"` or `"column"` (default column) and
  `dictionary` a boolean; `save` option `row_group_size` must be an integer ≥ 1 and
  `encoding` one of `auto`/`plain`/`dict`/`rle`; violations are `INVALID_REQUEST`. `open`
  of a directory and `save` into a missing directory are `IO_ERROR`; a file with more rows
  than `--max-table-rows` is `RESOURCE_LIMIT`. `schema` responses also report `layout`.
* `UPPER`/`LOWER` map ASCII letters only. Following the public conformance suite
  (`UPPER('abc Ünï')` = `'ABC Ünï'`), a *word* (maximal run of letters/digits) that contains a
  non-ASCII character is left unchanged as a whole.
* Common type of CASE results / COALESCE arguments: identical types are kept
  (`DECIMAL(10,2)` stays `DECIMAL(10,2)`); otherwise numeric promotion (INT64 with DECIMAL
  gives `DECIMAL(18,s)`), any other mix (including DATE with TIMESTAMP) is `TYPE_ERROR`.
* `ROUND(x, n)`, `DATE_TRUNC(unit, t)` and `DATE_DIFF(unit, a, b)` require constant `n`/`unit`
  (`SEMANTIC_ERROR` otherwise), evaluated during analysis; units are case-insensitive;
  a NULL constant yields NULL. `DATE_DIFF` supports `'day'` only (`INVALID_ARGUMENT` else).
  `ROUND` of an INT64 with negative `n` rounds half away from zero (`ROUND(15, -1)` = 20).
* Numeric functions applied to a NULL literal keep the null type (`ABS(NULL)` is reported as
  STRING), functions with a fixed result type use it (`LENGTH(NULL)` is INT64).
* GROUP BY ordinals and aliases refer to select items after `*` expansion; an identifier is
  only treated as an alias if it does not name an input column. SELECT aliases are not visible
  in WHERE or HAVING (`SEMANTIC_ERROR`), only in GROUP BY and ORDER BY as specified.
* A parenthesized join nested on the right of another join may not reference range variables
  outside the parentheses in its ON condition (`UNSUPPORTED`).
* A CTE body is analyzed where it is defined, even if the CTE is never referenced.
* `PQ_SLEEP` exists only with `--enable-test-functions` (otherwise it is an unknown
  function). It sleeps in ≤5 ms slices and checks the query deadline, so `timeout_ms`
  is honoured within a few ms. Operators check the deadline every 1024 rows.
* Comparing INT64 with DECIMAL(p,s) promotes the integer to DECIMAL(18,s) as types.md
  §2 says, so an integer that needs more than 18 digits at that scale is
  `NUMERIC_OVERFLOW`. In arithmetic, INT64 becomes DECIMAL(18,0) (so `1.5 * 2` is
  DECIMAL(18,1)).
* A NULL literal in arithmetic takes the type family of the other operand (`1 + NULL` is
  INT64); `NULL + NULL`, `-NULL` and `MIN(NULL)` keep the null type (reported as STRING).
  `SUM(NULL)` is INT64 and `AVG(NULL)` is FLOAT64.
* `LIMIT NULL` / `OFFSET NULL` mean "no limit" / 0. Non-INT64 constants are
  `TYPE_ERROR`, non-constant expressions `SEMANTIC_ERROR`, negative values
  `INVALID_ARGUMENT`. `ORDER BY 0` is out of range (`SEMANTIC_ERROR`).
* `TIMESTAMP '…'` literals need a time part. `CAST('YYYY-MM-DD' AS TIMESTAMP)` is
  accepted (midnight), as in ingestion. CAST from STRING trims all whitespace.
* FLOAT64 → DECIMAL rounding uses the shortest decimal representation of the double
  (`2.675e0` → `2.68`). FLOAT64 → STRING uses Java's shortest round-trip text
  (`1.0E20`); FLOAT64 JSON output uses the same (valid JSON), with `-0.0` as `0.0`.
* CSV: a quote inside an unquoted field, or text after a closing quote, is
  `INGEST_ERROR` (strict RFC 4180). A whitespace-only field is ignored for type inference
  and becomes NULL in non-STRING columns (kept verbatim in STRING columns). An empty
  input with `header: true` yields an empty table with no columns (or with the explicit
  schema's columns). `header: false` without a schema is `INVALID_REQUEST`.
* JSON: keys that differ only in case are duplicate column names → `INGEST_ERROR`.
  Inferred FLOAT64 numbers that overflow are `INGEST_ERROR`.
* An invalid type name in a `load` schema is `INVALID_REQUEST`; duplicate or empty
  schema column names are `INGEST_ERROR`.
* Query options: `mode` is `auto` (= `vectorized`), `row` or `vectorized`; `threads` (1–1024,
  default `--threads`, which defaults to the number of CPUs) bounds the worker threads of a
  query; `optimize: false` disables logical optimization and top-N; `join` selects the join
  algorithm (see Joins); `use_indexes: false` disables index scans; `native` is validated and
  ignored (the engine does not load native kernels and does not claim `native.kernels`);
  `query_id` names the query in the HTTP server (session mode only echoes it in the response's
  `query_id`). Ill-typed option values (and `threads` outside 1–1024) are `INVALID_REQUEST`;
  unknown values of known enum options are `UNSUPPORTED`.
* The per-query memory budget (`--max-query-memory-mb`, default 4096, capped at 70% of
  the JVM heap) is enforced approximately for sort buffers, aggregation groups and
  result materialization. `OutOfMemoryError` and `StackOverflowError` are reported as
  `RESOURCE_LIMIT`. Requests run on a thread with a 512 MiB stack, and parser nesting is
  limited to depth 1000 (`PARSE_ERROR` beyond).
* HTTP: `PUT /v1/tables/{name}` defaults to `format=csv`; `replace`/`header` accept
  `true`/`false` (also `1`/`0`, `yes`/`no`), `delimiter` is passed through; the body must be
  UTF-8 (`INGEST_ERROR` otherwise). A request body over `--max-request-bytes` is answered with
  413 `RESOURCE_LIMIT` without reading it, and the connection is closed. Request bodies may be
  `Content-Length` or chunked; `Expect: 100-continue` is honoured. Wrong methods get 405 with
  an `Allow` header. Responses of non-`/v1/request` endpoints carry `"id": null`.
* `/v1/queries` lists queries oldest first; `elapsed_ms` counts from arrival (including
  queueing). Cancelling a queued query removes it from the queue at once (`CANCELLED`).
* A query that is rejected (`OVERLOADED`, `ALREADY_EXISTS`, `SHUTTING_DOWN`) counts as an
  error query in the metrics; non-query requests are not counted as queries.
* Names (tables, columns, aliases) are matched with ASCII-only case folding.

## Testing

```
make -C implementations/java build test
python3 tests/conformance/runner.py --engine implementations/java/bin/polyquery
python3 tests/conformance/runner.py --engine implementations/java/bin/polyquery --modes
python3 tests/conformance/runner.py --engine implementations/java/bin/polyquery --transport http
python3 tests/concurrency/http_suite.py --engine implementations/java/bin/polyquery
# Phase 5 stress: every batch boundary, worker and deferred-error path on the small fixtures
POLYQUERY_JAVA_OPTS="-Dpolyquery.batchSize=3 -Dpolyquery.morselRows=5" \
    python3 tests/conformance/runner.py --engine implementations/java/bin/polyquery --modes
# randomized differential testing of all option combinations (data dir with a copy of fixtures/)
python3 implementations/java/tools/difftest.py --engine implementations/java/bin/polyquery \
    --data /tmp/dtdata --queries 300 --seed 1
# benchmarks (see Phase 5: Measurements)
python3 implementations/java/tools/bench.py --engine implementations/java/bin/polyquery --data /tmp/pqdata
```

`tools/difftest.py` generates random queries (expressions of every type, predicates, CASE,
IN/BETWEEN/LIKE, failing divisions and casts, grouping with all aggregates incl. DISTINCT,
2- to 3-way inner/left joins, subqueries, derived tables, ORDER BY/LIMIT/OFFSET) over the
generated fixtures — in-memory, row-layout, and PQCF files with small row groups opened with
mmap (several dictionaries per column) — and compares every one of the 32 option combinations
in two engines (default and tiny batch/morsel sizes) with the row-mode, unoptimized baseline:
rows (FLOAT64 with the spec's tolerance) or error codes. Several thousand queries were run
during development; every mismatch found was fixed (a few early ones were deferred-error and
empty-input edge cases).

Unit tests (`src/test/java`, run by `make test`) cover the Phase 5 engine — `Phase5Test` runs
a set of queries (grouping, joins of every kind, DISTINCT, sorts, top-N, subqueries, failing
expressions) under every combination of mode × join × threads × optimize, also with tiny
batches and morsels, and checks row-exact error semantics; `VectorTest` covers the kernels
(branch-free comparisons), group-key tables, exact sums (single-group SIMD path, overflow
widening, partial merges), stable radix/merge sorting, the join index and the k-way merge —
and the lexer, parser, types, ingestion,
protocol, the HTTP layer (admission/queueing/timeouts, query control, metrics, endpoints
over a real socket incl. streaming), and end-to-end SQL (grouping, joins with every join strategy and with optimization
disabled, functions, subqueries, CTEs, EXPLAIN), PQCF round trips with every encoding and
row-group size, corruption detection, layouts, statistics, index structures, key predicates,
index selection, column pruning and build-side choice. During development the conformance suite was
also run with `optimize: false` and with each forced join algorithm, and randomized queries
(joins, grouping, IN/EXISTS/scalar subqueries, correlated or not, derived tables, CTEs) were
cross-checked against SQLite. For Phase 3, files written by the engine were validated with
an independent strict PQCF reader (alignment, zero padding, trailing bitmap bits, min/max,
decoded values); random bit flips/truncations and targeted structural corruptions were
checked to yield `STORAGE_CORRUPT`; saves were killed with SIGKILL at random points (the
target was always absent or complete); and random predicates were compared across column/
row/dictionary layouts, hash/btree indexes, PQCF-backed tables (lazy mmap, small row groups)
and `use_indexes`/`optimize` off.

## Known limitations

* Native kernels (`native: true`, `--native-kernels`) are not used: the option is accepted and
  ignored, `native.kernels` is not claimed.
* In vectorized mode, sort-merge and nested-loop joins and correlated hash lookups are the row
  engine's operators behind adapters. Hash join build inputs are materialized by one thread
  (their input pipelines and, for single integer keys, the index may run in parallel).
* Parallelism applies to pipelines that start with a table scan and contain no subqueries;
  index scans and pipelines over fewer than two morsels (131,072 rows) run on one thread.
  High-cardinality GROUP BY / DISTINCT scale only moderately (partial aggregation reduces
  little when most keys are distinct; there is no radix-partitioned exchange).
* Row order without ORDER BY depends on the join algorithm (hash vs merge vs build side), so
  `LIMIT` without `ORDER BY` over joins may pick different rows — or, if a failing expression
  is evaluated on the rows read before the limit is reached, differ in raising that error.
  Everything else (row order of scans/filters/aggregations, errors) is identical in all modes.
* The HTTP server uses one platform thread per connection (plus one per running/queued
  query); it is meant for tens to a few hundreds of concurrent clients, not tens of thousands.
  Idle keep-alive connections are closed after 5 minutes.
* Non-streamed query responses are built in memory before being sent (use
  `/v1/query/stream` for large results). Request bodies are buffered in memory.
* Index builds (`CREATE INDEX`) and ingestion are not cancellable.
* Indexes are used only for filters directly over a scan (no index nested-loop joins, no
  index-ordered output); OR-ed predicates are not used for index lookups or row-group
  skipping. In-memory tables are a single row group, so row-group skipping applies to
  PQCF-backed tables only. STRING chunk min/max are not written (they are read and used).
* Decoded chunks of memory-mapped files stay cached for the lifetime of the table.
* Each ingestion reads the whole input into memory before parsing.
