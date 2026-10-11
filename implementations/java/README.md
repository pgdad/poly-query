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
see [Phase 5: optimization](#phase-5-optimization); and (M9) the optional **native kernel
library** `libpqkernels` bound through the Java FFM API and used for filtering, aggregation,
bitmap and hashing work with `native: true` — see [Native kernels (M9)](#native-kernels-m9);
and the requirement change **CR-1 `UNION ALL`** (`spec/changes/union-all.md`) — see
[Change CR-1: UNION ALL](#change-cr-1-union-all).

Capabilities: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic test.functions phase2
sql.groupby sql.join sql.functions sql.subquery sql.cte sql.correlated_subquery phase3
storage.pqcf storage.mmap index.hash index.btree phase4 http.streaming phase5 exec.row
exec.vectorized exec.parallel join.hash join.merge join.nested_loop native.kernels
change.union_all`.

## Prerequisites and build

* OpenJDK 27 (`java`, `javac`, `jar` on `PATH`, or `JAVA_HOME` set). No other tools,
  no network, no third-party libraries (Track A: standard library only).
* `make build` — compiles with `javac --release 27` into `build/polyquery.jar`.
* `make test` — builds and runs the unit tests (`src/test/java`, plain Java with a small
  runner in `polyquery.TestMain`; JUnit is not used). The native-kernel tests use
  `NATIVE_LIB` (default `../../native-kernels/build/<arch>/libpqkernels.so`, built with
  `make -C native-kernels`) and are skipped, with a note, if it does not exist.
* `make bench-kernels` — micro-benchmark of the native kernels through FFM vs the engine's
  Java loops (needs the library).
* `make lint` — compiles with `-Xlint:all -Werror`.
* `make fmt` — no-op (the JDK has no formatter); code follows standard Java style,
  4-space indentation, 120 columns.
* `make clean`.

`bin/polyquery` is a POSIX shell launcher that works from any directory (it resolves its
own location). Extra JVM flags can be passed with `POLYQUERY_JAVA_OPTS`.

```
bin/polyquery version | capabilities
bin/polyquery session [--data-dir DIR] [--enable-test-functions] [--log-level LEVEL]
                      [--native-kernels PATH/libpqkernels.so] ...
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
| `optimizer` | `LogicalOptimizer`: constant folding, predicate simplification, error-preserving predicate pushdown into joins and scans, CROSS→INNER join conversion; `ExprSafety` (can an expression fail / be NULL — with interval arithmetic over column statistics); `JoinReorder` (inner-join trees). All disabled by `optimize: false` |
| `physical` | `PhysicalPlan` nodes, `PhysicalPlanner` (table vs index scans, hash / merge / nested-loop joins and build side, top-N, hash lookup for correlated filters), `ColumnPredicates` (sargable conjuncts → key predicates), `Cardinality` (estimates from statistics), `ColumnPruner`, `PlanExplainer` (EXPLAIN JSON) |
| `exec` | Row engine (`mode: row`): Volcano operators (table/index scans, filter, project, hash aggregate, distinct, hash/merge/nested-loop joins, sort, top-N, limit, hash-lookup filter), `OperatorBuilder` (physical plan → operators), `ExpressionCompiler` (bound expression → closures), `ScalarFunctions`, `SubqueryRunner`, `ExecContext` (timeout, memory budget, row/join limits, correlation frames) |
| `exec.vector` | Vectorized engine (`mode: vectorized`): `Vec`/`Batch` (column vectors + selection vectors), `VecCompiler` + `Kernels` (batch expression kernels), `BatchExprs` (row-exact error semantics), scan/filter/project/limit, `AggregateBatches` + `GroupKeys` + `AggState` (hash aggregation, DISTINCT), `JoinBatches` (hash join), `SortBatches` (sort, top-N), `ColumnStore`, `Parallel` (morsel-driven workers), `BatchBuilder` (plan → batch operators), `VectorExecutor`; with `native: true`, `NativeFilter` (WHERE conjuncts) and `NativeAgg` (aggregate states) call the native kernels |
| `ffi` | `NativeKernels`: FFM binding of `libpqkernels` (C ABI v1) — loading, ABI check, critical downcall handles over Java arrays, argument checks; the only class that touches `java.lang.foreign` |
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
`Sort`, `TopN`, `Limit`, `Values`, `HashLookupFilter`, `UnionAll` with the branch plans as
`children`); the physical plan is the same in both
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
* **Q16** (left join): `SELECT o.status, COUNT(i.order_id), SUM(i.quantity) FROM orders o LEFT JOIN items i ON i.order_id = o.order_id GROUP BY o.status` (builds on the 1M-row side)

Median milliseconds. *Before* is the Phase-4 engine this phase started from (row-at-a-time,
its default optimizations); the other columns are this engine with the given options
(`join: auto`); speed-up = before ÷ best vectorized time.

| query | before (Phase 4) | row, `optimize:false` (baseline) | row | vectorized, 1 thread | vectorized, 4 threads | vectorized, 16 threads | speed-up |
|---|---:|---:|---:|---:|---:|---:|---:|
| Q1 filter+agg | 23.3 | 24.0 | 32.3 | 5.0 | 1.0 | 1.1 | 23× |
| Q2 group by (low card.) | 44.7 | 28.4 | 28.0 | 8.6 | 3.4 | 4.6 | 13× |
| Q3 group by (high card.) | 58.8 | 58.7 | 59.9 | 14.9 | 14.4 | 13.5 | 4× |
| Q4 join+group | 61.0 | 64.2 | 66.6 | 19.5 | 10.7 | 12.7 | 6× |
| Q5 3-way join | 48.5 | 74.7 | 65.3 | 13.4 | 7.0 | 6.1 | 8× |
| Q6 top-N | 99.6 | 99.2 | 18.5 | 5.3 | 1.7 | 1.5 | 66× |
| Q7 sort | 397.5 | 405.5 | 406.3 | 24.1 | 24.9 | 23.5 | 17× |
| Q8 sensor avg | 30.2 | 29.0 | 28.9 | 8.0 | 2.4 | 1.6 | 19× |
| Q9 distinct | 86.1 | 79.6 | 80.5 | 19.6 | 24.7 | 19.0 | 5× |
| Q10 string filter | 4.2 | 3.9 | 3.9 | 3.3 | 2.1 | 2.0 | 2× |
| Q11 projection | 44.2 | 44.6 | 43.8 | 5.1 | 1.9 | 1.4 | 32× |
| Q12 nulls | 33.6 | 33.7 | 32.2 | 17.4 | 5.4 | 2.7 | 12× |
| Q13 join order | 53.7 | 109.5 | 38.1 | 11.0 | 6.9 | 10.6 | 8× |
| Q14 conjunctive filter | 30.9 | 32.0 | 30.9 | 2.9 | 0.9 | 0.6 | 52× |
| Q15 reductions | 23.9 | 23.3 | 23.6 | 1.0 | 0.4 | 0.2 | 119× |
| Q16 left join | 72.8 | 47.3 | 47.0 | 29.8 | 17.9 | 16.8 | 4× |

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
  the aggregation saved. Joins (Q4, Q13, Q16) are limited by materializing the build side
  (one thread; the single-key index itself is built in parallel for large inputs).
* Logical optimization matters most for multi-way joins written in a poor order: Q13 runs
  110 → 38 ms in row mode (pushdown + join reordering), Q5 75 → 65 ms (pushdown).
  Top-N turns Q6 from a full sort (99 ms) into an 18 ms heap scan even in row mode.
* Results are identical in every configuration (`tools/bench.py` asserts equal row counts;
  the conformance `--modes` matrix and `tools/difftest.py` compare contents).

**SIMD.** The same vectorized runs (1 thread) with HotSpot's auto-vectorizer disabled
(`-XX:-UseSuperWord`) show where the SIMD-friendly loops pay off; elsewhere the costs are
hashing, memory access and selection-vector bookkeeping, which do not vectorize:

| query | SuperWord on | SuperWord off |
|---|---:|---:|
| Q6 top-N | 5.3 | 8.5 |
| Q7 sort | 24.1 | 36.5 |
| Q14 conjunctive filter | 2.9 | 3.7 |
| Q15 reductions | 1.0 | 2.2 |

End-to-end queries dominated by hashing or row output (Q1, Q2, Q11, …) show no difference
beyond the run-to-run variance of a few milliseconds (JIT compilation varies between JVM runs;
e.g. Q1 single-threaded measured 2.7–5.0 ms across runs).

### Configuration for experiments

`-Dpolyquery.batchSize=N`, `-Dpolyquery.morselRows=N` and `-Dpolyquery.parallelBuildRows=N` (via
`POLYQUERY_JAVA_OPTS`) change the batch and morsel sizes and the build size from which hash-join
indexes are built in parallel. Tiny values (e.g. 3 and 5) make every batch boundary, adapter, parallel
worker and deferred-error path run on the small conformance fixtures; the conformance suite,
the `--modes` matrix and the unit tests pass that way too.

## Native kernels (M9)

The native kernel library (`native-kernels/`, C ABI `pq_kernels.h` version 1: C reference,
runtime dispatch, x86-64 scalar/AVX2/AVX-512 and AArch64 assembly) is optional. It is loaded
with `--native-kernels PATH` and used by queries that run with `native: true`; results with
and without it are identical, and without it (or with `native: false`, the default) the engine
runs exactly its own code. The engine claims `native.kernels`.

### FFI design

* **Binding** (`polyquery.ffi.NativeKernels`, the only class using `java.lang.foreign`): the
  library is opened with `SymbolLookup.libraryLookup(path, Arena.global())` (once per process),
  `pqk_abi_version()` must be 1, `pqk_init()` runs the library's CPU dispatch (which honours
  `PQ_KERNELS_VARIANT=reference|scalar|avx2|avx512|…`), and the selected and available
  variants are logged (`{"msg":"native kernels loaded","variant":"x86_avx512",…}`). A library
  that cannot be loaded (missing file, missing symbol, other ABI version, big-endian CPU) is
  logged as a warning and the engine runs without it — kernels are optional, so this is not a
  startup error.
* **Zero-copy calls on Java arrays.** All 15 kernels are bound as downcall handles with
  `Linker.Option.critical(true)`: the kernels are short, never block and never call back, so
  they may run without the Java→native thread-state transition and receive **heap** segments
  (`MemorySegment.ofArray(long[])`) — the engine's own `long[]`/`int[]`/`double[]` vectors are
  passed as they are, nothing is copied to off-heap memory. The handles are `static final`
  fields, so the JIT inlines the downcall stubs; a call costs a few nanoseconds (measured:
  ~4 ns for a popcount of one word), which batches of 2,048 rows amortize.
* **Data layout.** `size_t` is bound as `long` (checked against the linker's canonical layout),
  `uint32_t` index vectors are `int[]`, LSB-first validity bitmaps are `long[]` words — the same
  bytes on a little-endian CPU (the binding refuses big-endian ones). The Java wrappers check
  every array length against the element count before calling, so an engine bug raises an
  exception instead of corrupting memory.
* **Native access** is enabled by the jar manifest (`Enable-Native-Access: ALL-UNNAMED`), so no
  JVM warning is printed (stderr carries only JSON log lines). `make test` passes
  `--enable-native-access=ALL-UNNAMED` itself.
* **Per query.** `EngineConfig` holds the loaded library; `Engine` gives a query's
  `ExecContext` the kernels only if the query has `native: true` and runs vectorized. The
  vectorized operators ask the context when they are built (each parallel worker builds its
  own pipeline, so the per-instance scratch buffers are thread-confined; the kernels
  themselves are thread-safe).
* **Validity bitmaps.** Table scans already turn a chunk's null bitmap into the batch's null
  mask; they now also keep it as a validity bitmap in the batch vector (`Vec.validity`, n/64
  word operations), which is what the kernels consume. Any other way of producing a null mask
  invalidates it, so the kernels only see bitmaps that are exact for the batch.

### Which kernels are used where

| Engine operation (vectorized, `native: true`) | Kernels | Applies when |
|---|---|---|
| WHERE conjuncts `col op constant`, `constant op col`, `col BETWEEN c1 AND c2` | `pqk_filter_i64` (one conjunct: writes the selection vector directly), else `pqk_filter_i64_bitmap` per conjunct | INT64, DECIMAL, DATE, TIMESTAMP, BOOLEAN columns; DECIMAL constants of another scale are rescaled exactly (`x > 1.555` on scale 2 becomes `x > 155` unscaled) |
| WHERE `col op col` | `pqk_compare_i64` (+ `pqk_bitmap_and` with the validity bitmaps) | both columns of one scale |
| WHERE `col IS [NOT] NULL` | validity bitmap (+ `pqk_bitmap_andnot`) | |
| combining conjuncts | `pqk_bitmap_and`, `pqk_bitmap_andnot` (rows where a conjunct is FALSE), then bitmap → selection vector in Java | |
| `SUM`/`AVG` of INT64/DECIMAL without GROUP BY | `pqk_sum_i64` with validity, `pqk_bitmap_popcount` for the count, `pqk_gather_i64` for filtered batches | `PQK_OVERFLOW` (exact batch sum outside INT64) → the engine's exact BigInteger-widening path for that batch |
| `SUM`/`AVG` of INT64/DECIMAL with GROUP BY | `pqk_group_sum_i64` (+ `pqk_gather_i64`) | `PQK_OVERFLOW` → the wrapped additions are undone (wrapping subtraction is the exact inverse) and the batch is redone exactly |
| `MIN`/`MAX` without GROUP BY | `pqk_minmax_i64` (INT64-like), `pqk_minmax_f64` (+ `pqk_gather_i64`) | FLOAT64 result ±0.0 → the engine's loop (which zero is kept depends on row order) |
| `COUNT(x)` without GROUP BY | `pqk_bitmap_popcount` of the validity bitmap | |
| GROUP BY / DISTINCT / hash-join keys of one column | `pqk_hash_i64` (`fmix64(value ^ seed)`) | — the engine's own single-column hash is now the same `fmix64`, so tables are identical with and without the library |

Filter semantics are kept exact (see `NativeFilter`): the leading conjuncts of a WHERE that
cannot raise an error (comparisons, IS NULL, LIKE, IN, BETWEEN over columns and constants) may
be evaluated in any order — three-valued AND is commutative — so the eligible ones among them
run natively first over the whole batch and the others (e.g. `status = 'approved'` on a
dictionary column) on the survivors. A row is dropped only where a conjunct is FALSE; if
conjuncts that may fail follow, rows where the native conjuncts are NULL stay selected for
them (the row engine evaluates them on those rows too, and may raise their error) and are
flagged so they never pass. Native filtering applies to dense batches (straight from table
scans); filters over joins or selections use the engine's kernels.

Not used: `pqk_sum_f64` (lane-wise reassociation makes FLOAT64 sums differ in the last bits
from the engine's sequential sums — results must be identical); `pqk_count_i64` (every
filter consumer needs the selected rows, not only their number; COUNT(*) of a filter costs
nothing extra); `pqk_compare_fixed` (strings are Java `String`s / dictionary codes, never
fixed-width byte records). Row mode (`mode: row`) is the unoptimized baseline and never uses
the kernels.

### Measurements

**End to end** (generated `1m` datasets, the queries of [Phase 5: Measurements](#measurements)
plus Q17–Q20 below, loaded as in-memory column tables). Method: `tools/bench.py --fresh
--rounds 3 --warmup 20 --reps 15 --native-pairs` — every configuration runs in its own engine
process (so neither configuration inherits the other's JIT profile), each query is warmed up 20
times (a fresh JVM needs ~20 runs before the timings settle) and timed 15 times
(`result: count`, client-side wall time including the protocol round trip); the table shows
the best of the three rounds' medians in milliseconds. *Before* = `native: false` (the
engine's own vectorized code), *after* = `native: true` with the AVX-512 variant selected by
the library's dispatch. Machine: AMD Ryzen 9 9950X3D (16 cores / 32 threads), OpenJDK 27,
shared with other jobs (load average ≈ 5 during the runs): differences below ~15% are noise —
Q7 (a sort, which uses no kernel) shows the size of it.

* **Q17** (range filter): `SELECT COUNT(*), SUM(merchant_id) FROM tx WHERE tx_id BETWEEN 100000 AND 900000 AND bucket >= 100 AND customer_id <> merchant_id`
* **Q18** (integer group sums): `SELECT merchant_id, SUM(tx_id), SUM(bucket), COUNT(*) FROM tx GROUP BY merchant_id`
* **Q19** (aggregates over NULLs): `SELECT COUNT(n50), COUNT(n90), MIN(n50), MAX(n90), SUM(n50), MIN(d99) FROM nh`
* **Q20** (filter on NULL-heavy columns): `SELECT COUNT(*), SUM(id) FROM nh WHERE n50 > 100 AND n90 IS NOT NULL`

| query | 1 thread | 1 thread, native | speed-up | 4 threads | 4 threads, native | 16 threads | 16 threads, native |
|---|---:|---:|---:|---:|---:|---:|---:|
| Q1 filter+agg | 3.6 | 2.0 | 1.8× | 1.0 | 1.0 | 0.7 | 0.7 |
| Q2 group by (low card.) | 11.1 | 8.2 | 1.4× | 3.2 | 2.9 | 4.1 | 3.9 |
| Q3 group by (high card.) | 18.1 | 14.0 | 1.3× | 10.6 | 10.1 | 13.7 | 12.0 |
| Q4 join+group | 22.5 | 18.6 | 1.2× | 12.1 | 12.6 | 15.0 | 14.9 |
| Q5 3-way join | 14.7 | 12.1 | 1.2× | 6.8 | 6.7 | 5.1 | 5.0 |
| Q6 top-N | 7.2 | 7.7 | 0.9× | 1.9 | 1.8 | 1.6 | 1.7 |
| Q7 sort | 28.2 | 23.0 | 1.2× | 22.6 | 22.2 | 27.1 | 23.2 |
| Q8 sensor avg | 9.2 | 7.6 | 1.2× | 2.4 | 2.2 | 1.7 | 1.9 |
| Q9 distinct | 24.2 | 21.7 | 1.1× | 21.5 | 20.8 | 18.5 | 18.6 |
| Q10 string filter | 3.9 | 3.3 | 1.2× | 3.0 | 3.5 | 2.9 | 3.5 |
| Q11 projection | 7.6 | 4.9 | 1.6× | 1.5 | 1.9 | 1.2 | 1.4 |
| Q12 nulls | 21.8 | 18.8 | 1.2× | 5.6 | 5.4 | 2.3 | 2.0 |
| Q14 conjunctive filter | 3.6 | 1.2 | 3.0× | 0.9 | 0.4 | 0.4 | 0.4 |
| Q15 reductions | 0.9 | 0.9 | 1.0× | 0.3 | 0.4 | 0.3 | 0.3 |
| Q16 left join | 31.5 | 26.7 | 1.2× | 16.0 | 18.0 | 16.3 | 16.0 |
| Q17 range filter | 7.7 | 1.9 | 4.1× | 2.0 | 1.0 | 0.9 | 0.8 |
| Q18 int group sums | 13.4 | 9.7 | 1.4× | 4.7 | 4.2 | 5.3 | 5.7 |
| Q19 null aggregates | 11.6 | 1.7 | 6.8× | 2.9 | 0.7 | 1.1 | 0.6 |
| Q20 filter on nulls | 9.7 | 1.4 | 6.9× | 2.5 | 0.6 | 0.9 | 0.6 |
| Q13 join order | 11.9 | 11.5 | 1.0× | 4.7 | 5.4 | 5.7 | 5.9 |

Observations:

* The kernels pay off where the engine's Java loops are branchy or byte-wise: predicates over
  integer columns (Q14 3×, Q17 4×: comparisons become AVX-512 mask operations and conjuncts are
  combined as bitmaps instead of narrowing a selection vector conjunct by conjunct; Q1 1.8×,
  where `amount > 100` now runs natively before the dictionary-string comparison), and anything
  over NULL-able columns (Q19, Q20 ≈ 7×: the engine walks a `boolean[]` null mask row by row
  with a branch per row, while the kernels consume the validity bitmap — COUNT(x) becomes a
  popcount, SUM/MIN/MAX/filters a masked SIMD loop).
* Grouped integer sums (Q2, Q3, Q18: 1.3–1.4×) gain a little from `pqk_group_sum_i64`, whose
  overflow check is one flag per batch instead of a branch per row.
* Where HotSpot already vectorizes the Java loop the kernels change nothing measurable: plain
  SUM/MIN/MAX of non-NULL columns (Q15 — the engine's split 32-bit-halves sum is already SIMD)
  and the `fmix64` key hash (the JIT vectorizes the multiply). Joins, sorts, string
  operations and projections (Q4–Q7, Q9–Q13, Q16) are dominated by work no kernel covers
  (hash-table probes, materialization, sorting, string handling); their differences are noise.
* With 4 and 16 threads each worker processes only 1/4 or 1/16 of the rows, so per-query fixed
  costs (planning, thread hand-off, the protocol round trip of ≈ 0.3 ms) dominate and the
  absolute gains shrink to fractions of a millisecond; filter- and NULL-heavy queries still gain
  up to 4× at 4 threads (Q19, Q20).
* Results are identical: `tools/bench.py --verify` compares every query's full result with and
  without `native` (1, 4 and 16 threads; exact at 1 thread — with several threads FLOAT64 sums
  vary in the last bits from run to run whether or not native kernels are used, since they
  depend on how morsels were distributed over the workers, so they are compared with a 1e-9
  relative tolerance).

**Kernel micro-benchmarks.** `make bench-kernels` calls each kernel through the FFM binding on
Java heap arrays, at the engine's batch size (2,048 rows) and morsel size (65,536 rows), and
times the equivalent Java loop of the vectorized engine (median ns per row; same machine,
AVX-512 variant):

| kernel (via FFM) | Java ns/row | native ns/row (2,048 rows/call) | speed-up | native ns/row (65,536 rows/call) |
|---|---:|---:|---:|---:|
| `filter_i64` (x < c → selection vector) | 0.234 | 0.078 | 3.0× | 0.068 |
| `filter_i64_bitmap` ×2 + `bitmap_and` (two conjuncts) | 0.585 | 0.074 | 7.9× | 0.090 |
| `sum_i64` (exact, no NULLs) | 0.044 | 0.026 | 1.7× | 0.030 |
| `sum_i64` with validity (25% NULL) | 0.238 | 0.045 | 5.3× | 0.035 |
| `minmax_i64` | 0.044 | 0.025 | 1.8× | 0.045 |
| `bitmap_popcount` (COUNT(x) vs `boolean[]` loop) | 0.182 | 0.003 | 66× | 0.001 |
| `hash_i64` (`fmix64`) | 0.070 | 0.067 | 1.0× | 0.089 |
| `group_sum_i64` (1,000 groups) | 0.426 | 0.382 | 1.1× | 0.386 |
| `gather_i64` (50% selection) | 0.079 | 0.078 | 1.0× | 0.088 |

The FFM call itself costs a few ns (≈ 0.002 ns/row at 2,048 rows), so per-batch calls lose
nothing against whole-morsel calls. The library's own benchmark
(`native-kernels/build/x86_64/kernel_bench 1048576 9`, 2^20 elements, ns per element) shows the
variants the dispatch chooses from:

| kernel | reference C | x86 scalar | AVX2 | AVX-512 |
|---|---:|---:|---:|---:|
| `filter_i64` (10% selected) | 0.976 | 0.393 | 0.145 | 0.092 |
| `filter_i64_bitmap` | 3.454 | 0.266 | 0.072 | 0.062 |
| `sum_i64` | 0.246 | 0.234 | 0.074 | 0.060 |
| `sum_i64` with validity | 0.421 | 0.384 | 0.104 | 0.061 |
| `minmax_i64` | 0.686 | 0.599 | 0.096 | 0.051 |
| `bitmap_popcount` | 0.142 | 0.015 | 0.002 | 0.001 |
| `hash_i64` | 0.751 | 0.562 | 0.331 | 0.129 |
| `compare_i64` | 3.597 | 0.231 | 0.138 | 0.108 |
| `group_sum_i64` (1,024 groups) | 0.821 | 0.543 | 0.398 | 0.396 |
| `gather_i64` | 0.653 | 0.501 | 0.501 | 0.502 |

The unit tests and the conformance suite pass with every variant
(`PQ_KERNELS_VARIANT=reference|scalar|avx2|avx512`).

## Change CR-1: UNION ALL

`spec/changes/union-all.md` (capability `change.union_all`): `UNION ALL` of any number of
plain `select_core`s, wherever a query is allowed (top level, CTE bodies, derived tables,
scalar / `IN` / `EXISTS` subqueries, `EXPLAIN`), identical under every `mode`, `threads`,
`join`, `optimize` and `native` setting.

The change is a new relational operator carried through every layer of the pipeline — no
layer special-cases it beyond its own responsibility:

| Module | Change |
|---|---|
| `sql.ast.Query` | A query has a list of `branches` (`Select` cores) instead of one `select`; `ORDER BY`/`LIMIT`/`OFFSET` stay on the query and apply to the whole compound (`compound()` = two or more branches) |
| `sql.parser.Parser` | `query = [WITH] select_core {UNION ALL select_core} [ORDER BY] [LIMIT]`. `UNION` without `ALL` (incl. `UNION DISTINCT`) stays `UNSUPPORTED`; `UNION ALL` after a branch's `ORDER BY`/`LIMIT` is a `PARSE_ERROR`; parenthesized branches are `PARSE_ERROR`s by the grammar (a statement / branch must start with `SELECT`) |
| `sql.analyzer.Analyzer` | `planUnionAll`: each branch is bound as its own query level (`bindQuery` now takes a branch plus optional ORDER BY/LIMIT) in a `Scope` nested in the compound's scope, so CTEs of the `WITH` and outer (correlated) columns are visible but other branches' range variables are not; outer references from any branch are collected on the compound's scope, so a subquery whose body is a `UNION ALL` is correlated iff some branch is. Column counts must match (`SEMANTIC_ERROR`); column *i* gets `TypeCoercion.commonType` over the branches (the CASE rule: numeric promotion, untyped NULL adopts the other type, all-NULL stays the untyped NULL type, reported as STRING like `SELECT NULL`; else `TYPE_ERROR`); names are the first branch's. ORDER BY items must be output names or positions (`resolveCompoundOrderItem`, else `SEMANTIC_ERROR`); then `Sort` and `Limit` over the union |
| `plan.LogicalPlan` | `UnionAll(inputs, columns)` |
| `optimizer` | `LogicalOptimizer` (folding, pushdown) and `JoinReorder` recurse into every branch; a union is an opaque input of joins above it |
| `physical` | `PhysicalPlan.UnionAll`; `PhysicalPlanner` plans each branch independently (index scans, join algorithms, hash lookups per branch); `ColumnPruner` passes the consumer's required slots to every branch; `Cardinality` = sum of the branches; `PlanExplainer` renders `{"op":"UnionAll","columns":[…],"children":[branch plans in order]}` |
| `exec` | `Operators.UnionAll` (row engine) |
| `exec.vector` | `BatchOperators.UnionAll` (vectorized; passes the branches' batches through unchanged, incl. a pending row-exact error); `BatchBuilder` builds each branch with `build`, so a branch that is a scan pipeline still runs morsel-parallel and with native filters/aggregates |
| `engine.Version` | claims `change.union_all` |

Design decisions:

* **Conversions live in the branches.** Values are converted to the output type by implicit
  casts folded into the branch's final projection (so INT64→DECIMAL(18,s) overflow raises
  `NUMERIC_OVERFLOW` exactly like promotion elsewhere, in every mode). After `SELECT DISTINCT`
  the casts go into a projection *above* the branch's `Distinct`, because converting first could
  merge values that are distinct in the branch's own type (e.g. large INT64s as FLOAT64).
  Every branch therefore produces exactly the union's column types, and the union operators
  just concatenate — no per-row work, no type dispatch.
* **Branches run one after the other**, each opened only when the previous one is exhausted
  (and closed then). Row order without ORDER BY is branch 1's rows, then branch 2's, … in every
  mode; a `LIMIT` that is satisfied early never evaluates later branches (so it cannot raise
  their errors), consistently in row and vectorized execution.
* **ORDER BY over a compound**: an unqualified name matching several output columns is
  ambiguous (`SEMANTIC_ERROR`) unless those columns are the same expression in every branch
  (mirroring the single-SELECT rule). `NULLS FIRST/LAST`, `ASC/DESC`, `ORDER BY … LIMIT`
  (top-N) work as for single queries. Error precedence: branch errors (in branch order), then
  column count, then column types, then ORDER BY, then LIMIT/OFFSET.
* **`spec_version` stays `1.0.0`.** CR-1 says engines claiming the change report
  `1.1.0-cr1`, but the phase-1 conformance case `catalog.pqt` (which must keep passing) requires
  `"spec_version":"1.0.0"`; the capability `change.union_all` signals the change instead.

Conformance note: one public case cannot pass on a spec-conformant engine.
`changes/union_all.pqt:51` (`SELECT order_id AS v FROM orders … UNION ALL SELECT amount FROM
orders …`) expects `DECIMAL(18,2)`, but that file loads `orders.csv` *without* a schema, and
CSV inference "NEVER yields DECIMAL" (ingestion.md §1.1) — `amount` is FLOAT64 there (the
phase-2 files that expect DECIMAL amounts load it with `schema=…amount:DECIMAL(10,2)…`). By
CR-1 §2, INT64 ∪ FLOAT64 is FLOAT64, which is what the engine returns (`[99.99], [101.0]`); the
very next case checks exactly that rule (`age` ∪ `score`). Making the case pass would require
violating the ingestion spec (breaking that next case and phase-1 inference tests) or
special-casing the test, so it was left failing. With an explicit DECIMAL schema the same query
returns the expected `DECIMAL(18,2)` rows `["99.99"], ["101.00"]` in every mode (checked
during development; the INT64 ∪ DECIMAL rule itself is covered by `EngineTest.testUnionAll`).

## Design decisions / interpretations

Where the spec leaves room, these choices were made:

* `UNION` / `UNION DISTINCT` (without `ALL`), `RIGHT JOIN` and `FULL JOIN` are `UNSUPPORTED`
  (`UNION ALL` is supported, see [Change CR-1](#change-cr-1-union-all)). Unknown function names are
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
  algorithm (see Joins); `use_indexes: false` disables index scans; `native: true` uses the
  native kernels when `--native-kernels` loaded them, in vectorized execution (incl. `auto`;
  the row engine is the baseline and never uses them) — without a loaded library it is a no-op;
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
# native kernels (M9): build the library, then every query with native: true
make -C native-kernels
python3 tests/conformance/runner.py --engine implementations/java/bin/polyquery \
    --native native-kernels/build/x86_64/libpqkernels.so [--modes | --transport http]
# … also with each variant: PQ_KERNELS_VARIANT=reference|scalar|avx2|avx512 python3 …
# Phase 5 stress: every batch boundary, worker and deferred-error path on the small fixtures
POLYQUERY_JAVA_OPTS="-Dpolyquery.batchSize=3 -Dpolyquery.morselRows=5" \
    python3 tests/conformance/runner.py --engine implementations/java/bin/polyquery --modes
# randomized differential testing of all option combinations (data dir with a copy of fixtures/)
python3 implementations/java/tools/difftest.py --engine implementations/java/bin/polyquery \
    --data /tmp/dtdata --queries 300 --seed 1 [--native-kernels native-kernels/build/x86_64/libpqkernels.so]
# benchmarks (see Phase 5: Measurements); native before/after with result verification
python3 implementations/java/tools/bench.py --engine implementations/java/bin/polyquery --data /tmp/pqdata
python3 implementations/java/tools/bench.py --engine implementations/java/bin/polyquery --data /tmp/pqdata \
    --native-kernels native-kernels/build/x86_64/libpqkernels.so --native-pairs --verify \
    --fresh --rounds 3 --warmup 20 --reps 15 --config '1 thread={"mode":"vectorized","threads":1}'
make -C implementations/java bench-kernels
```

Native kernels are tested on three levels: `NativeKernelsTest` checks every binding against a
Java reference of the header's semantics (random data with NULLs and extreme values, lengths
around byte and word boundaries, overflow flags incl. overflow that cancels out, out-of-range
group ids, aliasing bitmap outputs, argument checks); `NativeVectorTest` compares the native
filter, aggregate states and key hashing with the engine's own code on scan-produced batches
(DECIMAL constants of other scales, NULLs, conjuncts that fail after NULL-able native ones,
selections, ±0.0 extremes; mutations of the rescaling and NULL-handling code were checked to be
caught); and an end-to-end test runs the Phase 5 query set plus native-specific queries
(overflowing grouped and ungrouped sums, failing conjuncts after NULL comparisons, DATE/DECIMAL
ranges, IS NULL) under the whole option matrix with `native: true`, also with tiny batches and
morsels, against the row engine.

`tools/difftest.py` generates random queries (expressions of every type, predicates, CASE,
IN/BETWEEN/LIKE, failing divisions and casts, grouping with all aggregates incl. DISTINCT,
2- to 3-way inner/left joins, subqueries, derived tables, ORDER BY/LIMIT/OFFSET) over the
generated fixtures — in-memory, row-layout, and PQCF files with small row groups opened with
mmap (several dictionaries per column) — and compares every one of the 32 option combinations
in two engines (default and tiny batch/morsel sizes) with the row-mode, unoptimized baseline:
rows (FLOAT64 with the spec's tolerance) or error codes; with `--native-kernels` every vectorized
combination also runs with `native: true` (800 random queries with two seeds × 48 option
combinations × two engines: no mismatch). Several thousand queries were run
during development; every mismatch found was fixed (a few early ones were deferred-error and
empty-input edge cases). Since CR-1 the generator also emits `UNION ALL` queries (2–3 branches
over different FROM clauses with promoted numeric types, NULL columns, DISTINCT branches,
ORDER BY/LIMIT over the compound, aggregation over a union): 550 queries with two seeds, no
mismatch.

Unit tests (`src/test/java`, run by `make test`) cover the Phase 5 engine — `Phase5Test` runs
a set of queries (grouping, joins of every kind, DISTINCT, sorts, top-N, subqueries, failing
expressions, `UNION ALL` with mixed branch types / under aggregation and joins / in IN and
correlated EXISTS subqueries / with LIMIT before a failing branch) under every combination of mode × join × threads × optimize, also with tiny
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

* Native kernels serve the vectorized engine only, and within it: filters over dense batches
  from table scans (not over joins, index scans or row-layout tables, whose vectors carry no
  validity bitmap), aggregation without GROUP BY (SUM/AVG/MIN/MAX/COUNT) and grouped
  INT64/DECIMAL SUM/AVG, and single-column key hashing. Grouped MIN/MAX/COUNT, FLOAT64 sums,
  string predicates, joins and sorts use the engine's code (no kernel exists for them, or —
  FLOAT64 sums — the kernel's result would not be bit-identical). The library is loaded once
  per process; a different path cannot be loaded later.
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
* `UNION ALL`: filters above a union (e.g. `WHERE` over a derived table that is a union) are not
  pushed into the branches (the optimizer does not push predicates through projections at
  all); the branches of a union run sequentially (each branch's own pipeline may be parallel),
  and an aggregation over a union is not parallelized.
* Indexes are used only for filters directly over a scan (no index nested-loop joins, no
  index-ordered output); OR-ed predicates are not used for index lookups or row-group
  skipping. In-memory tables are a single row group, so row-group skipping applies to
  PQCF-backed tables only. STRING chunk min/max are not written (they are read and used).
* Decoded chunks of memory-mapped files stay cached for the lifetime of the table.
* Each ingestion reads the whole input into memory before parsing.
