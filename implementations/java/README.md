# PolyQuery — Java engine

An analytical database engine implementing the PolyQuery specification (`spec/`), at
**Phase 5**: protocol, catalog, CSV/JSON/JSONL ingestion, all data types, the complete
SQL v1 grammar (GROUP BY/HAVING, DISTINCT, INNER/LEFT/CROSS joins, all scalar functions,
CASE/LIKE/BETWEEN/IN, uncorrelated **and correlated** subqueries, derived tables, CTEs,
EXPLAIN), structured errors, resource limits and test functions; row- and column-oriented
in-memory layouts with dictionary encoding and null bitmaps, the persistent PQCF v1/v2 columnar
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
[Change CR-1: UNION ALL](#change-cr-1-union-all); the refactoring **CR-3 logical/physical
plan separation** (`spec/changes/refactor-plan-separation.md`) — see
[Change CR-3](#change-cr-3-logicalphysical-plan-separation); and the architectural change
**CR-2 DECIMAL precision 38** with PQCF v2 (`spec/changes/decimal38.md`) — see
[Change CR-2](#change-cr-2-decimal-precision-38); and the requirement change **CR-6
expression size limits** (`spec/changes/expression-limits.md`: minimum statement sizes in every
execution mode, `RESOURCE_LIMIT` beyond the engine's limits, the timeout in every stage) — see
[Change CR-6](#change-cr-6-expression-size-limits). Earlier, query **latency** on the
`analytics` benchmark workload was optimized (parallel sorting with normalized keys, top-N
cutoff, parallel DISTINCT aggregates, shared CTE aggregations, cheaper parallel merges and join
builds, JIT warm-up through an AOT cache) — see
[Latency optimization](#latency-optimization-analytics-workload).

Capabilities: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic test.functions phase2
sql.groupby sql.join sql.functions sql.subquery sql.cte sql.correlated_subquery phase3
storage.pqcf storage.mmap index.hash index.btree phase4 http.streaming phase5 exec.row
exec.vectorized exec.parallel join.hash join.merge join.nested_loop native.kernels
change.union_all change.decimal38 change.expression_limits`.

Statement size limits (CR-6): SQL text 64 MiB, expression nesting depth 4,096, 200,000
operands — beyond them `RESOURCE_LIMIT` (see [Change CR-6](#change-cr-6-expression-size-limits)).

## Prerequisites and build

* OpenJDK 27 (`java`, `javac`, `jar` on `PATH`, or `JAVA_HOME` set). No other tools,
  no network, no third-party libraries (Track A: standard library only).
* `make build` — compiles with `javac --release 27` into `build/polyquery.jar`, then runs a
  ~10 s JIT training run (`bin/aot-train`, all cores) that writes the JVM AOT cache
  `build/polyquery.aot` used by the launcher (see JIT warm-up in
  [Latency optimization](#latency-optimization-analytics-workload)); if training fails, the
  build still succeeds and the engine runs without the cache (log: `build/aot-training.log`).
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
own location); its JVM options (shared with `bin/aot-train`) are in `bin/jvm-options`. Extra
JVM flags can be passed with `POLYQUERY_JAVA_OPTS`; `POLYQUERY_AOT=off` disables the AOT cache.

```
bin/polyquery version | capabilities
bin/polyquery session [--data-dir DIR] [--enable-test-functions] [--log-level LEVEL]
                      [--native-kernels PATH/libpqkernels.so] ...
bin/polyquery exec --request FILE|- [options]
bin/polyquery serve --port N [--host H] [--workers N] [--queue-depth N] [--query-timeout-ms N]
                    [--shutdown-grace-ms N] [--max-request-bytes N] [common options]
```

## Embedding API and the pqledger application

The engine is also a **library**: `make build` produces the modular jar `build/polyquery.jar`
whose exported package `polyquery.api` (`Database`, `Result`, `DatabaseException`, …) lets any
Java program use the engine in-process (`spec/apps/embedding.md`). On top of it:

* [**EMBEDDING.md**](EMBEDDING.md) — developer guide: depending on the jar (javac/java, Maven),
  API reference, value-type mapping, errors, resource management, thread safety, a complete
  minimal program. Minimal example: `examples/embed-demo` (`bin/pq-embed-demo DATA_DIR CSV SQL`).
* [**APP.md**](APP.md) — user guide of **`pqledger`** (`bin/pqledger`, source in `app/`), a
  personal-finance command-line application (`spec/apps/pqledger.md`): bank-statement CSV
  import with duplicate detection, rule-based categories, reports, budgets, ad-hoc SQL, and a
  ledger stored as PQCF files.

`make test` also runs the API tests (`ApiTest`) and the application's unit tests
(`app/src/test/java`). Working notes for this task: [NOTES.md](NOTES.md).

## Libraries

None. `ENGINE.json`: `{"language": "java", "track": "A", "libraries": []}`.

## Architecture

Source lives in `src/main/java/polyquery/`, one package per layer:

| Package | Responsibility |
|---|---|
| `common` | `ErrorCode`, `PolyQueryException` (code + message + details), ASCII name folding, `Checkpoint` (timeout/cancellation polls of every stage) |
| `types` | `DataType`, value representation, exact DECIMAL arithmetic for narrow (`long`) and wide (`BigInteger`) values (`Decimals`), DATE/TIMESTAMP (`DateTimes`), strict text parsers, `Casts`, ordering/text (`Values`) |
| `json` | Strict RFC 8259 parser (keeps number literal text, optional duplicate-key rejection) and writer |
| `sql.lexer` | Tokenizer (tokens on demand) with line/column positions, reserved keywords, comments |
| `sql.ast` | Immutable AST (sealed interfaces + records) for the full v1 grammar |
| `sql.parser` | Recursive-descent parser (WITH, joins, subqueries, CASE, IN, LIKE, BETWEEN, EXPLAIN, CREATE/DROP INDEX); `PARSE_ERROR` carries `line`/`column`; enforces the statement size limits (`StatementLimits`, CR-6) |
| `sql.analyzer` | Semantic validation: `Scope` (range variables, correlation), `ExpressionBinder` + `TypeCoercion` + `ScalarFunctionBinder` (typing), `Analyzer` (per query level: FROM/joins/derived tables/CTEs, GROUP BY rewriting, ORDER BY resolution → `BoundQuery`), `LogicalPlanner` (`BoundQuery` → logical plan) |
| `plan` | Bound (typed) expressions (`BoundExpr`, `BoundExprs` traversal and input-slot analysis), aggregate calls, subqueries, the logical plan (`LogicalPlan`: `Scan`, `SingleRow`, `Filter`, `Project`, `Join`, `Aggregate`, `Distinct`, `Sort`, `Limit`, `UnionAll`), `LogicalPlanPrinter` (debug text), expression formatter |
| `optimizer` | Rule-based logical optimizer on the logical plan only: `OptimizerRule`, `LogicalOptimizer` (`STANDARD` rule sequence, `DISABLED` for `optimize: false`), rules `ConstantFolding`, `PredicateSimplification`, `PredicatePushdown` (below projections, into join inputs, CROSS→INNER), `JoinReorder` (inner-join trees), `ProjectionPruning`; `ExprSafety` (can an expression fail / be NULL — with interval arithmetic over column statistics) |
| `cost` | Estimates shared by both planning layers: `Cardinality` (rows and selectivities from statistics), `ColumnPredicates` (sargable conjuncts → key predicates) |
| `physical` | `PhysicalPlan` nodes, `PhysicalPlanner` (table vs index scans, hash / merge / nested-loop joins and build side, top-N, hash lookup for correlated filters, execution model / threads / native kernels → `PhysicalQuery`), `ColumnPruner` (columns each scan reads), `PlanExplainer` (EXPLAIN JSON), `PlanKeys` (structural keys of invariant subplans, for reusing a result within a query) |
| `exec` | Row engine (`mode: row`): Volcano operators (table/index scans, filter, project, hash aggregate, distinct, hash/merge/nested-loop joins, sort, top-N, limit, hash-lookup filter), `OperatorBuilder` (physical plan → operators), `ExpressionCompiler` (bound expression → closures), `ScalarFunctions`, `SubqueryRunner`, `ExecContext` (timeout, memory budget, row/join limits, correlation frames) |
| `exec.vector` | Vectorized engine (`mode: vectorized`): `Vec`/`Batch` (column vectors + selection vectors), `VecCompiler` + `Kernels` (batch expression kernels), `BatchExprs` (row-exact error semantics), scan/filter/project/limit, `AggregateBatches` + `GroupKeys` + `AggState` (hash aggregation, DISTINCT), `JoinBatches` (hash join), `SortBatches` (sort, top-N), `ColumnStore`, `Parallel` (morsel-driven workers), `BatchBuilder` (plan → batch operators), `VectorExecutor`; with `native: true`, `NativeFilter` (WHERE conjuncts) and `NativeAgg` (aggregate states) call the native kernels |
| `ffi` | `NativeKernels`: FFM binding of `libpqkernels` (C ABI v1) — loading, ABI check, critical downcall handles over Java arrays, argument checks; the only class that touches `java.lang.foreign` |
| `storage` | Immutable table snapshots (`Table` = schema + `TableData` + indexes + statistics); `ColumnarData` (`ColumnVector`s: primitive arrays + null bitmaps, dictionary-encoded strings), `RowData` (row tuples), `Layouts` (conversions, dictionary policy), `TableStatistics`/`DistinctCounter`, thread-safe `Catalog` (tables and global index names) |
| `storage.pqcf` | PQCF v1 and v2 (wide DECIMAL columns as i128): `PqcfWriter` (atomic save, v2 exactly for tables with a wide column), `ChunkEncoder`, `PqcfReader` (header/footer/metadata validation), `ChunkDecoder` (CRC + value validation), `PqcfTableData` (row groups, lazy chunks over a memory-mapped file) |
| `index` | `HashIndex`, `OrderedIndex` (sorted permutation), `KeyDomain`/`KeyPredicate` (typed lookup keys and predicates) |
| `ingest` | CSV parser + type inference, JSON / JSON Lines ingestion |
| `engine` | `Engine` façade used by every front-end; `QueryPlanner` (optimizer + physical planner per query); config; path safety |
| `protocol` | JSON request handling/validation (`RequestHandler`, `QueryRequest`), the `QueryRunner` policy hook, result serialization, structured logger |
| `server` | HTTP/1.1 server (Phase 4): `HttpServer` (accept loop, connection threads, graceful shutdown), `HttpConnection` (request parsing, fixed/chunked responses, disconnect detection), `ApiRouter` (endpoints → protocol ops), `QueryStream` (NDJSON streaming with backpressure), `QueryManager` (query registry, timeouts, metrics, logs), `Admission` (worker limit + FIFO queue), `Metrics` (Prometheus text) |
| `Main` | CLI (`version`, `capabilities`, `session`, `exec`, `serve`) |
| `Training` | JIT training run for the build-time AOT cache (synthetic tables, a broad query mix through the session request path) |

Query pipeline (each stage is a separate class and data structure):

```
SQL text ─Lexer→ tokens ─Parser→ AST (Statement/Query/Expr)
   ─Analyzer/ExpressionBinder→ BoundQuery per query level (typed BoundExpr, resolved names)
   ─LogicalPlanner→ LogicalPlan ─LogicalOptimizer (rules; none with optimize: false)→ LogicalPlan
   ─PhysicalPlanner→ PhysicalQuery (PhysicalPlan + mode, threads, native)
        ─┬─ OperatorBuilder/ExpressionCompiler→ Operator tree ─Executor→ rows      (mode: row)
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
  `BitSet` values plus a `BitSet` null bitmap, `String[]`, `BigInteger[]` (wide DECIMAL) or a
  dictionary-encoded string vector (`int[]` codes into a table of distinct strings). STRING columns are dictionary-encoded
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
>2 `STORAGE_VERSION_UNSUPPORTED`; header and metadata versions must agree; a v1 file must not
declare a wide DECIMAL column), flags (≠0 `STORAGE_VERSION_UNSUPPORTED`), trailer,
metadata bounds, CRC and strict UTF-8 JSON, required keys and their types, unique non-empty
column names, valid types, Σ row counts, one chunk per column, chunk ranges, null counts,
encodings (unknown name → `STORAGE_VERSION_UNSUPPORTED`; known but inapplicable to the
type → corrupt), index entries; per chunk: CRC, exact decoded length, bitmap null count,
string offsets, UTF-8, DECIMAL precision (i64 or i128 values), DATE/TIMESTAMP range, finite FLOAT64, BOOLEAN RLE
values, dictionary codes, RLE run lengths. Bytes between the header and the metadata that
belong to no chunk must be zero (the format only allows zero padding), so damage to padding
is detected too. Unknown metadata keys are ignored; malformed chunk min/max values are
treated as unknown. All of this was cross-checked with an independent reader and with
random bit-flip/truncation fuzzing.

### Indexes and planning (Phase 3)

`CREATE INDEX … USING HASH` builds a hash map key → row ids; `BTREE` (the default) builds a
sorted permutation of the non-null rows (`long[]`/`double[]`/`Object[]` keys + `int[]` row
ids, stable merge sort) searched by binary search — equality, IN and ranges. Index keys are
mapped to a per-type key domain (`KeyDomain`: BOOLEAN/INT64/narrow DECIMAL/DATE/TIMESTAMP →
`long`, wide DECIMAL → `BigInteger`, FLOAT64 → `double`, STRING → `String`). Lookups return ascending row ids, so index scans
return rows in table order. Indexes belong to a table snapshot: CREATE/DROP INDEX publish a
new snapshot sharing the data; replacing or dropping a table drops its indexes; `save`
records them and `open` rebuilds them (failing with `ALREADY_EXISTS`, before the catalog is
touched, if a name is taken by another table).

For a filter directly over a scan, the planner extracts *sargable* conjuncts
(`col op constant`, `constant op col`, `col BETWEEN c1 AND c2`, `col IN (constants)`, also
through exact implicit casts — INT64/DECIMAL to a DECIMAL that holds all their values, e.g.
to the wide type of a comparison with a wide DECIMAL — and DATE→TIMESTAMP) and converts them to a
`KeyPredicate` per column (points, range or empty), intersecting several conjuncts on one
column. INT64/DECIMAL constants of another scale or width (or TIMESTAMP constants against a
DATE column) are converted exactly with rational floor/ceil, so `int_col > 2.5` becomes `int_col >= 3`.
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

BOOLEAN → `Boolean`, INT64 → `Long`, narrow DECIMAL(p,s) (p ≤ 18) → `Long` unscaled value,
wide DECIMAL(p,s) (19 ≤ p ≤ 38) → `java.math.BigInteger` unscaled value (scale from the
static type), FLOAT64 → `Double`, STRING → `String`, DATE → `Integer` days since 1970-01-01,
TIMESTAMP → `Long` microseconds since epoch, NULL → `null`. Types are always known
statically, so values carry no tags; the precision alone decides the representation (see
[Change CR-2](#change-cr-2-decimal-precision-38)).

DECIMAL arithmetic is exact: narrow results use 64-bit fast paths with `Math.*Exact`, falling
back to `BigInteger` for intermediates; wide results are computed with `BigInteger`. A result
needing more digits than its type's precision (18, or 38 with a wide operand) is
`NUMERIC_OVERFLOW`. SUM/AVG over INT64/DECIMAL accumulate exactly (widening to `BigInteger`);
only the final INT64/DECIMAL result is range-checked.

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
  undecided, so most rows are discarded by the first, cheapest loops. A `Vec` is struct-of-arrays: `long[]` (INT64, narrow DECIMAL unscaled, DATE, TIMESTAMP,
  BOOLEAN 0/1), `double[]` or `Object[]` (STRING, wide DECIMAL as `BigInteger`), a `boolean[]` null mask, or — for dictionary-encoded
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
  and the partitions are merged in parallel, each group keeping its earliest first position;
  the groups of all partitions are then radix-sorted by first position — so they come out in
  exactly the order of sequential execution. INT64/DECIMAL sums merge exactly (BigInteger on
  overflow; wide DECIMAL sums are BigInteger throughout). Aggregates over DISTINCT values are
  parallel without GROUP BY: workers deduplicate their morsels' values, the merge unions the
  workers' value sets in parallel by hash partition (each partition feeding a fresh plain
  state) and merges the partition states (see [Latency optimization](#latency-optimization-analytics-workload)).
* **DISTINCT** runs as a keys-only parallel aggregation when no pipeline expression can fail;
  otherwise workers drop duplicates within their morsels and the final DISTINCT streams over
  the rest. **Top-N**: workers keep the best `offset + limit` rows of each morsel (stable,
  dropping rows that cannot make it — see Sorting), the final top-N picks among them.
* **Full sorts** over a pipeline: workers materialize their morsels into column stores of
  their own, concatenated in morsel order, then sorted in parallel (see Sorting).
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

`LogicalOptimizer.STANDARD` applies these rules (`OptimizerRule`s), in this order, each once;
`optimize: false` applies none (`LogicalOptimizer.DISABLED`):

* **Constant folding** (`ConstantFolding`, `constant_folding`) of every constant subexpression
  (once, at planning) — unless its evaluation fails; then it is left for the rows that evaluate it.
* **Predicate simplification** (`PredicateSimplification`, `predicate_simplification`):
  `TRUE AND x → x`, `FALSE AND x → FALSE`, `x OR FALSE → x`,
  `NOT NOT x → x`, … (`x AND FALSE → FALSE` only when `x` cannot fail), always-TRUE filters vanish.
* **Predicate pushdown** (`PredicatePushdown`, `predicate_pushdown`) below projections (derived
  tables, CTEs: column references are replaced by the projected expressions; only if no
  projected expression can fail), into join inputs and scans (also enabling index scans and
  row-group skipping), CROSS→INNER join conversion. **Error-preserving**: moving a predicate changes the
  rows the others are evaluated on, so a conjunct moves only if it precedes every conjunct that
  may raise an error — and, when such a conjunct exists, only if it can never be NULL (a NULL
  conjunct does not stop the evaluation of the following ones; a pushed-down filter would) —
  and nothing moves across a join condition that may fail. `ExprSafety` decides both, using
  column statistics: interval arithmetic over min/max proves e.g. that `price * 2` cannot
  overflow or that a divisor range excludes 0; null counts prove columns non-NULL. So
  `optimize: true` and `false` agree on errors too, while the usual shapes (comma joins with
  the join condition first, arithmetic on stored values) are still fully optimized.
* **Join reordering** (`JoinReorder`, `join_reordering`) of inner-join trees with ≥ 3 inputs: start with the
  connected pair with the smallest estimated join result, then repeatedly add the connected
  input with the smallest estimated result (equi-join selectivity 1/max(distinct counts) from
  table statistics); conditions are placed at the lowest join where their inputs are available
  and a projection restores the original column order. Only when all conditions are free of
  subqueries and cannot fail.
* **Projection pruning** (`ProjectionPruning`, `projection_pruning`): projected column
  references and constants nobody reads (unused derived-table / CTE columns) become NULL
  constants, so the columns they pass through are not read either; computed expressions are
  kept (they may raise errors). Independently of the optimizer, the physical planner's column
  pruner (Phase 3) makes every scan read only the columns its plan references, with the same
  pass-through criterion — so scans read the same columns with `optimize: false`.
* **Top-N** (physical planning, also disabled by `optimize: false`): `ORDER BY … LIMIT n`
  keeps only the best `offset + n` rows (row engine: bounded heap; vectorized: column store
  re-sorted and truncated whenever it doubles). Ties keep input order, exactly like the stable
  full sort.

### Sorting

The vectorized sort materializes its input in a `ColumnStore` and sorts row indices stably.
Every sort key is first **normalized** to an unsigned 64-bit key per row whose order is the
value order: the value for numbers (sign-flipped; doubles via their IEEE bits with -0.0 = 0.0),
the rank of the value for dictionary-encoded strings (the dictionary is sorted once), for other
strings 7 Latin-1 characters plus min(length, 8) — or, if some string has a non-Latin-1
character among its first 7, 3 UTF-16 units in code point order plus min(length, 4) — and the
high 64 bits for wide DECIMALs. Equal keys imply equal values for numbers, ranks and strings
of at most 7 (3) characters, so values are only compared for longer strings. Rows are sorted
by an **LSD radix sort** (8-bit digits, digits constant over the range skipped) on the first
key, then runs of equal first keys by a merge sort comparing the normalized keys (and the
values only where needed).

Inputs of 131,072 rows or more are sorted **in parallel** (when the query may use several
threads): a regular sample of the first key gives up to 16 × threads splitters; rows go to the
key-range buckets by a stable parallel counting scatter (per-chunk counts, prefix sums), and
the workers radix-sort and refine the buckets independently, largest first. Sorted rows are
moved into sort order by the workers too, so the output is read sequentially.

**Top-N** keeps the best `offset + limit` rows seen so far; once it has that many, the first
sort key of the last of them is a cutoff: later rows whose first key ranks strictly after it
(INT64-like and FLOAT64 keys; NULLs by their NULLS FIRST/LAST position) are dropped before
they are materialized — equal keys are kept, as later keys and input order decide.

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

`-Dpolyquery.batchSize=N`, `-Dpolyquery.morselRows=N`, `-Dpolyquery.parallelBuildRows=N` and
`-Dpolyquery.parallelSortRows=N` (via `POLYQUERY_JAVA_OPTS`) change the batch and morsel sizes,
the build size from which hash-join indexes are built in parallel and the input size from which
sorts run in parallel. Tiny values (e.g. 3, 5 and 4) make every batch boundary, adapter, parallel
worker, parallel sort and deferred-error path run on the small conformance fixtures; the
conformance suite, the `--modes` matrix and the unit tests pass that way too.
`POLYQUERY_AOT=off` starts the engine without its AOT cache (see JIT warm-up below).

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
| `optimizer` | The optimizer rules (folding, pushdown, join reordering, pruning) recurse into every branch; a union is an opaque input of joins above it |
| `physical` | `PhysicalPlan.UnionAll`; `PhysicalPlanner` plans each branch independently (index scans, join algorithms, hash lookups per branch); `ColumnPruner` passes the consumer's required slots to every branch; `Cardinality` = sum of the branches; `PlanExplainer` renders `{"op":"UnionAll","columns":[…],"children":[branch plans in order]}` |
| `exec` | `Operators.UnionAll` (row engine) |
| `exec.vector` | `BatchOperators.UnionAll` (vectorized; passes the branches' batches through unchanged, incl. a pending row-exact error); `BatchBuilder` builds each branch with `build`, so a branch that is a scan pipeline still runs morsel-parallel and with native filters/aggregates |
| `engine.Version` | claims `change.union_all` |

Design decisions:

* **Conversions live in the branches.** Values are converted to the output type by implicit
  casts folded into the branch's final projection (so INT64→DECIMAL(W,s) overflow raises
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

Conformance note: an earlier version of the public case `changes/union_all.pqt:51` loaded
`orders.csv` without a schema while expecting `DECIMAL(18,2)` (CSV inference never yields
DECIMAL); the case now loads the table with an explicit DECIMAL schema (`ordersd`) and passes.

## Change CR-2: DECIMAL precision 38

`spec/changes/decimal38.md` (capability `change.decimal38`, in addition to
`change.union_all`): `DECIMAL(p,s)` with `1 ≤ p ≤ 38`. Decimals with `p ≤ 18` are *narrow* and
behave exactly as before; decimals with `p > 18` are *wide*. Every rule that produced
precision 18 now produces `W` — 18 if all DECIMAL operands are narrow, 38 if one is wide
(INT64 operands do not count): common types (CASE, COALESCE, `UNION ALL`, INT64 ⊕ DECIMAL),
`+ - *`, the overflow limit, `SUM`, `ROUND`, `FLOOR`/`CEIL`. Literals with a decimal point are
DECIMAL up to 38 significant digits; comparisons between INT64/DECIMAL values are exact;
CAST, ingestion and the protocol accept 38 digits; tables with a wide column are saved as
PQCF v2.

### Wide-decimal representation

* **Values:** a wide DECIMAL is its unscaled value as a `java.math.BigInteger` (|v| < 10³⁸,
  so it always fits 128 bits); a narrow DECIMAL stays an unscaled `long`. The *static type
  alone* decides the representation (`DataType.isWideDecimal()`, i.e. `precision > 18`), so
  no value carries a tag and every narrow code path is untouched — narrow queries run the same
  64-bit code (incl. SIMD-friendly kernels and native kernels) as before the change.
* **Columns:** `ColumnVector.WideDecimalVector` (`BigInteger[]`, null elements are NULL); in
  the vectorized engine wide values travel in the `Object[]` representation of a `Vec`
  (`Vec.kindOf` = `OBJECT`), like plain strings.
* **Storage:** PQCF v2 stores wide values as 128-bit two's-complement little-endian integers
  (PLAIN: n × i128; RLE: `{i128 value, u32 run_length}` runs); narrow columns keep the v1 i64
  layout. The writer emits v2 exactly when the table has a wide column (`PqcfWriter.formatVersion`),
  else v1. The reader accepts v1 and v2, requires header and metadata versions to agree,
  rejects wide columns in v1 files and values with |v| ≥ 10ᵖ (`STORAGE_CORRUPT`), and
  `format_version` > 2 (`STORAGE_VERSION_UNSUPPORTED`). Chunk min/max stay canonical decimal
  strings; DICT never applies to DECIMAL columns.
* **Index keys:** `BigInteger` in the key domain of wide columns (B-tree on `Object[]` keys,
  hash index on `BigInteger.equals/hashCode`), persisted like any index.

### How narrow and wide arithmetic is dispatched

Dispatch happens once, at analysis/compile time, on the static types — never per value:

* **Analyzer** (`TypeCoercion`): computes `W` (`resultPrecision`), so an `Arithmetic` /
  `Function` / aggregate node has a narrow or a wide result type. An INT64 operand of DECIMAL
  arithmetic is cast to `DECIMAL(W,0)` (exact for W = 38). For comparisons (`= <> < <= > >=`,
  `BETWEEN`, `IN`, simple `CASE`, `NULLIF`, join conditions, `IN (subquery)`): INT64 and narrow
  DECIMAL operands are compared *as they are* (any scales — no more INT64→DECIMAL(18,s)
  promotion that could overflow); if exactly one side is wide, the other side is cast to the
  wide type of its own scale (`DECIMAL(38,s)`, INT64 → `DECIMAL(38,0)`, both exact), so both
  sides of every comparison share one representation (scales may still differ). DECIMAL vs
  FLOAT64 still converts the decimal to the nearest FLOAT64.
* **Row engine** (`ExpressionCompiler`, `ScalarFunctions`, `Accumulator`): a wide arithmetic
  node compiles to `BigInteger` code (`Decimals.addExact/subtractExact/multiplyExact`, exact
  intermediates of up to 76 digits, then `Decimals.value` checks the 38-digit limit); narrow
  nodes keep the `long` code. Comparisons between exact numbers of different scales or
  representations use `Decimals.compare(Object, scale, Object, scale)` (long fast path,
  `BigInteger` otherwise). `SUM`/`AVG` accumulators take either representation;
  `MIN`/`MAX`/`ABS`/`ROUND`/`FLOOR`/`CEIL` keep or derive the representation from the type.
* **Vectorized engine** (`VecCompiler`): wide `+ - *` compile to `Kernels.WideArith`, wide
  comparisons to `Kernels.WideCompare` (exact across scales), INT64-vs-narrow DECIMAL
  comparisons of different scales to the existing `DecimalCompare` kernel; wide negation and
  casts from/to wide types apply the row engine's code per value. Aggregation uses `WideSum`
  (per-group `BigInteger`, mergeable for parallel partial aggregation) and `ObjectMinMax`;
  GROUP BY / DISTINCT / join keys intern wide values like strings in `GroupKeys`
  (value-based hashes, so parallel partial tables agree); sorts use the high 64 bits of the
  128-bit value as the radix key and refine ties with `BigInteger.compareTo`; hash joins with
  key scales that differ rescale the `BigInteger` keys exactly (`JoinBatches.normalize`).
* **Native kernels** are never given wide data: `NativeFilter` rejects wide vectors (also for
  IS NULL), aggregate states over wide arguments are created without the kernels (`AggState.create`),
  and `GroupKeys` hashes object keys in Java. Narrow columns keep using the kernels.

### Modules touched

| Module | Change |
|---|---|
| `types.DataType` | `MAX_DECIMAL_PRECISION` 38, `NARROW_DECIMAL_PRECISION` 18, `isWideDecimal`, `isExactNumeric`, `exactScale`; `DECIMAL` without parameters is still `DECIMAL(18,0)` |
| `types.Decimals` | `BigInteger` API: `addExact`/`subtractExact`/`multiplyExact`, `value` (precision check + representation), `rescale` (half away from zero), `compare` across representations and scales, `toString`/`toDouble`; `fromDouble` uses the exact binary value of the double |
| `types.Casts`, `TextParsers`, `Values` | casts INT64/DECIMAL/FLOAT64/STRING ↔ wide (DECIMAL → INT64 range check), 38-digit parsing, ordering and text of wide values |
| `sql.parser`, `sql.lexer.Token` | `FULL`/`RIGHT` accepted as an alias after an explicit `AS` (see decisions) |
| `sql.analyzer` | literals up to 38 digits, `W` in `TypeCoercion` (arithmetic, common types) and for `SUM`/`ROUND`/`FLOOR`/`CEIL`, exact comparison typing |
| `exec` | wide arithmetic/negation/comparison in `ExpressionCompiler`, `ABS`/`ROUND`/`FLOOR`/`CEIL` in `ScalarFunctions`, wide sums in `Accumulator`, `HashKeys.normalize` canonical across INT64/narrow/wide (hash joins, IN lists, IN subqueries, correlated lookups), merge-join key comparison |
| `exec.vector` | `Vec.kindOf`, `VecCompiler`, `Kernels` (`WideArith`, `WideCompare`), `AggState` (`WideSum`, `ObjectMinMax`), `GroupKeys`, `SortBatches`, `ColumnStore`, `JoinBatches`, `ScanBatches`, `NativeFilter` |
| `storage` | `ColumnVector.WideDecimalVector` + builder, `DistinctCounter` |
| `storage.pqcf` | v2 writer rule, i128 PLAIN/RLE encode/decode and validation, version checks |
| `index`, `cost` | `BigInteger` key domain (`KeyDomain`, `OrderedIndex`); `ColumnPredicates` converts any INT64/DECIMAL constant exactly into the column's key domain |
| `optimizer.ExprSafety` | overflow analysis against the result precision (18 or 38); wide DECIMAL → INT64 can fail |
| `protocol`, `physical` | wide values in results and EXPLAIN keys |
| `engine.Version` | claims `change.decimal38` |

### Decisions

* **`BigInteger` rather than a hand-made 128-bit type.** Values need at most 127 bits, but
  products need up to 76 digits before the overflow check and every conversion (text, double,
  rescaling with rounding) is already exact in `BigInteger`/`BigDecimal`. Wide values cost an
  object per value; narrow values — the common case and everything the performance work
  targeted — are untouched, so the cost is paid only by queries that use wide types.
* **One representation per comparison.** Casting the narrow side of a narrow-vs-wide
  comparison to `DECIMAL(38,s)` keeps every consumer of comparisons (join key extraction,
  hash/merge joins, index and row-group predicates, native filters) dealing with operands of
  one representation; INT64-vs-narrow comparisons need no cast because both are `long`s whose
  scales the comparison kernels already reconcile exactly.
* **Spec version** stays `1.0.0` (as for CR-1: `catalog.pqt` requires it); the capability
  `change.decimal38` signals the change.
* **`AS full`.** The grammar lists `FULL` (and `RIGHT`) as reserved "for future use", but the
  public CR-2 case uses `… AS full` as a column alias. Directly after an explicit `AS` an
  identifier is the only possible meaning, so these two future-use keywords are accepted
  there (keeping their written spelling); everywhere else they stay reserved
  (`FULL JOIN`/`RIGHT JOIN` remain `UNSUPPORTED`).
* **FLOAT64 → DECIMAL** uses the exact binary value of the double for every precision (CR-2
  §5 amends the CAST rule as a whole), so narrow casts changed too (`2.675e0` → `2.67`).

## Change CR-3: logical/physical plan separation

`spec/changes/refactor-plan-separation.md`: a behaviour-preserving refactoring. The engine
already planned in two stages (logical plan → physical plan); the refactoring closed the gaps:
the optimizer was one class with hard-wired passes, the logical layer depended on the physical
package (cardinality estimates, slot analysis), there was no projection-pruning rule at the
logical level, predicates were not pushed below projections, and the execution model, thread
count and native kernels were chosen by `Engine` outside planning.

### Module map (before → after)

| Concern | Before | After |
|---|---|---|
| Logical plan | `plan/LogicalPlan.java` (records, no generic traversal, no printer) | `plan/LogicalPlan.java` — `Scan`, `SingleRow`, `Filter`, `Project`, `Join` (kind + condition), `Aggregate` (keys + calls), `Distinct`, `Sort`, `Limit`, `UnionAll`; subqueries are `plan/Subquery.java` inside expressions, derived tables / CTEs are inlined plans; `children` / `withChildren` / `transformUp`; `plan/LogicalPlanPrinter.java` (debug text, incl. subquery plans); `Engine.logicalPlan(sql)` (internal API) |
| Optimizer driver | `optimizer/LogicalOptimizer.java`: static `optimize` = fold → pushdown → `JoinReorder.reorder` | `optimizer/OptimizerRule.java` (`name`, `apply`); `optimizer/LogicalOptimizer.java`: list of rules, `STANDARD`, `DISABLED` (`optimize: false` applies no rules), `forOption` |
| Constant folding | inside `LogicalOptimizer.fold` (together with simplification) | `optimizer/ConstantFolding.java` (`constant_folding`) |
| Predicate simplification | inside `LogicalOptimizer.fold` | `optimizer/PredicateSimplification.java` (`predicate_simplification`) |
| Predicate pushdown | `LogicalOptimizer.pushdown` (joins and scans only) | `optimizer/PredicatePushdown.java` (`predicate_pushdown`): also **below projections** |
| Join reordering | `optimizer/JoinReorder.java` (static, imported `physical.Cardinality`) | `optimizer/JoinReorder.java` (`join_reordering`), an `OptimizerRule` |
| Projection / column pruning | only `physical/ColumnPruner.java` | `optimizer/ProjectionPruning.java` (`projection_pruning`, logical) + `physical/ColumnPruner.java` (columns each scan reads) |
| Shared helpers | `LogicalOptimizer.canFail` (also used by `exec.vector.Parallel`); slot analysis `ColumnPruner.references` (used by `exec.vector`) | `ExprSafety.mayFail`; `BoundExprs.inputSlots` / `addInputSlots`; `optimizer/PlanExpressions.java`; `ExprFormatter.aggregate` / `sortKey` |
| Estimates | `physical/Cardinality.java`, `physical/ColumnPredicates.java` | `cost/Cardinality.java`, `cost/ColumnPredicates.java` (used by both layers) |
| Physical planner | `physical/PhysicalPlanner.java` (access paths, join algorithms, build side, top-N, hash lookups, column pruning) | the same, configured by `PhysicalPlanner.Options`, plus the **execution strategy**: `planQuery` → `physical/PhysicalQuery.java` (operator tree, `mode`, `threads`, `nativeKernels`) |
| Execution strategy | `Engine.execute` / `Engine.newContext` (`mode`, `threads`, native only in vectorized mode) | `PhysicalPlanner.planQuery`; `Engine` only dispatches on the `PhysicalQuery` |
| Planning pipeline | lambda in `Engine.planner` | `engine/QueryPlanner.java` (optimizer, then physical planner; also plans subqueries when the executor needs them) |
| EXPLAIN | `physical/PlanExplainer.java` from the physical plan | unchanged |
| Tests | — | `optimizer/OptimizerRulesTest` (every rule on its own, the rule sequence, `optimize: false`, the printer), `physical/PhysicalPlannerTest` (access path, join algorithm per option, build side, top-N, execution strategy); new derived-table queries in the `Phase5Test` option matrix |

### Decisions

* **Rules run once each, in a fixed order** (folding → simplification → pushdown → join
  reordering → projection pruning), exactly the passes of the previous optimizer plus the new
  steps; no fixpoint iteration, so plans stay predictable and planning cost is linear.
  Folding and simplification are separate rules; a simplification that leaves a literal-only
  expression folds it, so the pair is equivalent to the former combined pass.
* **Physical decisions only in the physical planner.** The logical layer uses statistics for
  estimates (join order, error analysis) but never chooses an access path, join algorithm,
  build side, top-N, mode, thread count or kernel. Top-N stays a physical choice and is still
  disabled by `optimize: false` (the unoptimized baseline). Subqueries are planned on first
  execution through the same `QueryPlanner` and run in their enclosing query's strategy.
* **Phase 3 planning works without the optimizer.** Index selection and row-group skipping
  for a filter directly over a scan, and scan column pruning, are physical-planning tasks, so
  `optimize: false` still uses indexes and reads only the needed columns (conformance
  `--modes` checks this).
* **Pushdown below projections** is error-preserving like the rest: only when no projected
  expression can fail (it is then computed on fewer rows) and only for movable conjuncts.
  This is the one place where plans change: a filter on a derived table or CTE column
  (`WITH s AS (SELECT … GROUP BY …) SELECT … FROM s WHERE n > 1`) now appears in `EXPLAIN`
  below the projection (on the aggregate, or on the scan, where it can now also use an index).
  Results and errors are unchanged. Of the 1,884 EXPLAIN outputs of all public conformance
  queries under four option sets (default, `optimize: false`, `join: merge`,
  `join: nested_loop` + `use_indexes: false`), only the 6 plans of the two queries of this
  shape changed; with `optimize: false` all are identical.
* **Projection pruning** uses the physical pruner's pass-through criterion (column references
  and constants), so scans read the same columns with and without `optimize`.

## Change CR-6: expression size limits

`spec/changes/expression-limits.md` (capability `change.expression_limits`): every statement
within the minimum sizes executes in every execution mode, a statement beyond the engine's
limits fails with `RESOURCE_LIMIT` naming the measure, and the query timeout covers parsing,
binding, planning and execution.

### The engine's limits

| measure | limit of this engine | CR-6 minimum |
|---|---|---|
| text length (UTF-8 bytes of the SQL text) | 67,108,864 (64 MiB) | 1,048,576 |
| nesting depth | 4,096 | 1,000 |
| operand count (literals, column references, `*` arguments) | 200,000 | 25,000 |

Beyond a limit the statement fails with `RESOURCE_LIMIT` and a message naming the measure —
`statement text length exceeds 67108864 bytes`, `expression nesting depth exceeds 4096`,
`statement operand count exceeds 200000` — with `details` `{"measure": "text_length" |
"nesting_depth" | "operand_count", "limit": N}` (over HTTP: status 413, like every
`RESOURCE_LIMIT`). The limits are checked while parsing, so `RESOURCE_LIMIT` takes precedence
over a `PARSE_ERROR` later in the text and over semantic errors (CR-6 §3 allows this). Valid
SQL within the limits never fails with `PARSE_ERROR` because of its size. Over HTTP,
`--max-request-bytes` (default 1 GiB) still applies to the request body first. The constants
are in `sql/parser/StatementLimits.java`.

**How nesting depth is counted** (CR-6 §1): one level for each parenthesized expression, unary
`+`/`-` (also when folded into a numeric literal, `-5`), `NOT`, function call (also
aggregates), `CAST`, `CASE`, `IN (…)`, `BETWEEN`, `LIKE`, comparison, `IS [NOT] NULL` (counted as a
comparison) and subquery (scalar, `EXISTS`, `IN`, derived table, CTE body); `x IN (SELECT …)`
counts the `IN` and the subquery. A chain of binary operators of one precedence level (`OR`;
`AND`; `||`; `+`/`-`; `*`/`/`/`%`) counts once, whatever its length; the parenthesized
operand of a chain is a level of its own. A parenthesized join in `FROM` (`(a JOIN b ON …)`)
also counts. The clauses of the statement's own query are at depth 0. The depth of a statement
is the most constructs enclosing any expression, so `x >= 0` inside 998 parentheses has depth
999, and so do `NOT NOT … x >= 0` with 998 `NOT`s and 998 nested `ABS` calls around `x` in
`… >= 0`.

Statement shapes that none of the three measures covers — many FROM items or joins, many
`UNION ALL` branches, long chains of CTEs that reference each other — have no limit of their
own besides memory and time: their planning and execution observe the timeout like everything
else (a 2,000-table join chain plans and runs in 4.5–9 s), and a stack overflow anywhere is
reported as `RESOURCE_LIMIT` (see below).

### Parsing within the limits

* **Tokens on demand.** The lexer (`Lexer.next`) produces one token at a time; the parser keeps
  a four-token ring buffer instead of a token list, so a large statement never exists as a
  token array, and a statement beyond a limit is rejected as soon as the limit is crossed
  (a 100,000-term `OR` chain fails after 200,000 operands, in ~30 ms).
* **Exact depth with an early stop.** A construct's left operand is parsed before the construct
  is recognized (`a = b`, `a OR b`), so the depth is computed bottom-up: every parse method
  leaves the *height* of what it parsed (the most constructs enclosing any expression inside
  it, counting itself) in a field, and constructs add one to the largest height of their parts.
  To bound the recursion, a top-down counter of the constructs entered on the current path —
  never more than the true depth — stops the parse as soon as it passes the limit (100,000
  nested parentheses are rejected after 4,097 levels, in under 10 ms).
* **Operands** are counted as literals, column references and `count(*)`'s `*` are parsed.
* **Text length** is checked before lexing (UTF-8 bytes, computed only when the text could
  exceed the limit).

### Deep recursion and stacks

Every later stage (binder, optimizer rules, physical planner, both expression compilers, the
evaluators) walks the binary expression trees recursively, and a left-deep chain of 100,000
operators is 100,000 levels deep. The AST and the bound expressions stay binary (no n-ary
nodes): every rule, kernel and the row-exact error semantics depend on that shape, and the
chains fit the stacks. Query code runs only on threads with large stacks: the session/exec
thread and the HTTP connection and query threads have 512 MiB, parallel workers 256 MiB
(address space reserved, committed only as used). The statements at the engine's limits
(a 99,999-term `OR` chain, a 199,990-term sum or `||` chain, 4,090 nested `ABS` calls, scalar
subqueries or derived tables) run in every mode with several-fold headroom. Should a stack
overflow anyway — in any thread — it is reported as `RESOURCE_LIMIT` (session/exec handler,
HTTP query manager/streamer, parallel worker results) and the process continues.

### Linear work in the size of the statement

Long chains exposed several stages whose work grew quadratically or worse; all are now linear
(or close to it) in the size of the statement:

* **Constant folding / predicate simplification** asked "is this subtree constant?" at every
  node by scanning the subtree (10,000-term `OR`: 1.6 s, 100,000 terms: > 30 s). `Constness`
  memoizes the answer per node (by identity — expression records compare structurally, which is
  a subtree walk itself). A constant subexpression whose evaluation fails stays in place (its
  error belongs to the rows that evaluate it) and is no longer re-evaluated by each ancestor:
  `ConstantEvaluator` gets the recorded failures and compiles such a node to raise its error.
* **Vectorized compilation** folded constants with the same per-node subtree scan; it is
  memoized too, and a constant subtree whose folding fails is compiled to row-at-a-time code
  for the whole subtree instead of being re-tried at each of its nodes.
* **Predicate pushdown** recomputed the stored-column origins of a plan at every level it
  descended (cubic for nested derived tables with filters: 999 levels took 6 s, now 0.3 s);
  `ExprSafety.OriginCache` memoizes them per pass. `LogicalPlan.width()` and single-pass
  join schemas (logical and physical) avoid rebuilding column lists per level of deep join
  trees; join reordering indexes conjuncts per input.
* **`||` chains** are evaluated by one n-ary loop in both engines (`BoundExprs.concatOperands`;
  `Kernels.Concat` takes all operands) instead of copying the growing prefix at every link,
  with the same NULL semantics (the row engine stops at the first NULL operand, as the nested
  operators did).
* **Kernel memory.** Every vectorized kernel owns a result vector of the batch size, so a
  200,000-node expression with 2,048-row batches held ~3.6 GB per pipeline instance (and per
  parallel worker). `BatchBuilder` now chooses the batch size per query so that batch size ×
  expression nodes stays within 4 Mi positions (at least 16 rows per batch); queries with up to
  2,048 expression nodes — every ordinary query — keep the default batches.

### The timeout covers every stage

`common.Checkpoint` installs the query's timeout/cancellation check for the current thread;
the stages poll it (`Checkpoint.poll()`, a thread-local counter that reads the clock every 256
polls) inside every loop or recursion whose work grows with the statement:

* `Engine.execute` installs it around parsing, binding, planning and execution (and checks
  explicitly between the stages); subqueries planned on first execution and the `explain` op
  run under it too;
* polls: the lexer (per token), the parser (per construct and chain link), the binder (per
  expression), `BoundExprs.children` (every generic expression traversal of the optimizer and
  planner), `LogicalPlan.transformUp` (every rule over every node), join reordering, both
  expression compilers;
* evaluation: one row or batch through a 100,000-level expression can take seconds, so the
  row compiler wraps every 32nd nesting level in a closure that polls, and `VecCompiler`
  inserts a polling kernel (`Kernels.Polling`) every 32 levels; parallel worker tasks run with
  the query's check installed (`Parallel.submit`), so workers stop within milliseconds too.

Measured (session mode, `timeout_ms` 2,000, 200,000-row table, statements at the engine's limits —
a 99,999-term `OR`/`AND` chain, a 199,990-term sum and `||` chain, a 66,000-branch `CASE`,
4,090 nested `ABS` calls; each in row, vectorized, parallel and auto mode): every `TIMEOUT`
arrived 0.00–0.10 s after the deadline (before: up to 62 s late in parallel mode). Planning
timeouts (2,000-table join chain, 4,000 chained CTEs) arrive within 0.3 s.

### Results

`python3 tests/regression/robustness_probe.py --only expression_limits --require-pass`: pass —
all 40 minimum cases correct in row, vectorized, parallel and auto mode (each ≤ 0.2 s); beyond
the minimums, 100,000 nested parentheses and the 100,000-term `OR` chain fail with
`RESOURCE_LIMIT` within 50 ms, the 100,000-item `IN` list (100,002 operands) computes the
correct result. The whole probe takes ~2.5 s (before: 169 s, with `PARSE_ERROR` for the
nested parentheses and hangs past the timeout for the long `OR` chain). Statements at the
engine's own limits take at most 1.8 s in every mode (99,999-term `OR`/`AND` chains,
199,990-term sum and `||` chain, 199,990-item `IN` list, 4,090 nested parentheses / `ABS` /
`NOT` / unary minus / `CAST` / `CASE` / scalar subqueries / derived tables / `EXISTS` /
chained CTEs). `ExpressionLimitsTest` covers the depth measure (exactly at and one past the
limit, chains, left operands, every kind of construct), the operand and text limits (also
multi-byte UTF-8), timeout polling during parsing, large statements in every execution mode
(really parallel: 16-row morsels), n-ary `||` NULL semantics and failing constant chains.

### Modules touched

| Module | Change |
|---|---|
| `common.Checkpoint` (new) | per-thread timeout/cancellation check for the stages before and around execution |
| `sql.lexer.Lexer` | on-demand `next()` (`tokenize` kept for tests) |
| `sql.parser.Parser`, `StatementLimits` (new) | token ring buffer, depth (height + early-stop counter), operand count, text length, `RESOURCE_LIMIT` errors; polls |
| `sql.analyzer.ExpressionBinder` | polls; no line/column details added to `TIMEOUT`/`CANCELLED` |
| `plan.BoundExprs`, `plan.LogicalPlan` | `isRowInput`, `concatOperands`; polls in `children`/`transformUp`; `width()`, single-pass join schema |
| `optimizer` | `Constness` (new), `ConstantFolding.Folder` (memo + recorded failures), `PredicateSimplification`, `PredicatePushdown.Pass` (memoized origins), `ExprSafety.OriginCache`, `JoinReorder` (per-input conjuncts, binary search, polls), `ProjectionPruning` (`width()`) |
| `physical` | `PhysicalPlan` single-pass join schemas; `PhysicalPlanner` (`width()`) |
| `exec` | `ExpressionCompiler` (polling every 32 levels, n-ary `||`, recorded failures), `ConstantEvaluator` |
| `exec.vector` | `VecCompiler` (memoized folding, failed folds as row code, polling kernels), `Kernels` (`Polling`, n-ary `Concat`), `BatchBuilder` (batch size per query), `VectorExecutor`, `Parallel` (workers run under the query's checkpoint) |
| `engine.Engine` | installs the checkpoint for every stage, checks between stages; `explain` under the timeout |
| `engine.Version` | claims `change.expression_limits` |
| tests | `ExpressionLimitsTest` (new) |

### Decisions

* **Limits well above the minimums** (×4 depth, ×8 operands, ×64 text): far enough that no
  realistic statement meets them, low enough that recursion at the limits has several-fold
  stack headroom and that one statement's kernels and plans stay within a few hundred MB.
  The 100,000-item `IN` list of the probe is within the limits (and answered correctly); the
  100,000-term `OR` chain (200,002 operands) is not.
* **Limits enforced in the parser only.** Every later stage sees a bounded statement, so no
  other stage needs its own depth guard; the work they do is linear and observes the timeout.
* **Binary trees, big stacks** instead of n-ary AND/OR/arithmetic nodes or rebalanced trees:
  rebalancing would change overflow behaviour of arithmetic and the evaluation order that
  error semantics depend on, and n-ary nodes would touch every rule and kernel. Only `||`
  got an n-ary evaluator, as a pure execution optimization (the tree is unchanged).
* **Cooperative checks, no watchdog thread.** Each stage stops itself at its next poll, so no
  abandoned computation keeps running after a `TIMEOUT` and session mode stays strictly
  sequential. Checks are cheap enough (a thread-local counter) to sit in the hot recursion of
  every stage.
* **`spec_version` stays `1.0.0`** (as for CR-1/CR-2: `catalog.pqt` requires it); the
  capability `change.expression_limits` signals the change.
* The probe's environment variables `PQ_PAR_MIN`/`PQ_PARALLEL_MIN_ROWS` are not used by this
  engine (it splits tables into 65,536-row morsels; `-Dpolyquery.morselRows` changes that), so
  the probe's 100-row "parallel" cases run on one thread; parallel evaluation of the same
  statements was verified on a 200,000-row table and by `ExpressionLimitsTest` with 16-row
  morsels.

## Latency optimization (analytics workload)

Task: lower the latency of the queries of `benchmarks/workloads/analytics.json` at scale `1m`
(`python3 datasets/generators/pqgen.py generate --scale 1m`), keeping every result and error
identical.

### How it was measured

`tools/workload_bench.py` drives `bin/polyquery session` exactly like a client: per round it
starts a fresh session, loads the workload's nine tables from the generated CSV files (with
their schema files), creates the workload's two indexes, then runs every query with the
default options (`result: count` where the workload says so, otherwise the rows are returned
and serialized). The **first** execution of each query is recorded as its *cold* time (JIT
compilation included); then 5 unmeasured and 10 measured runs give the round's *warm* median.
The tables report the median over rounds (client-side wall time, ms). A digest of every result
(FLOAT64 values rounded to 9 significant digits) is compared between all runs, rounds and both
engines — they are identical for all 20 queries.

```
python3 tools/workload_bench.py --engine bin/polyquery --baseline-engine /tmp/base/implementations/java/bin/polyquery \
    --workload ../../benchmarks/workloads/analytics.json --data ../../datasets/generated --scale 1m --rounds 7
```

*Before* is the engine as this task started (commit `35418c3`, built in a separate git
worktree), *after* is the final engine. The rounds alternate — baseline session, new session,
baseline, … (7 each) — so both see the same machine load. Machine: 32 hardware threads,
250 GB RAM, OpenJDK 27, default options of `bin/polyquery` (all cores). The machine was
**shared**: other jobs kept a load average of 8–12 throughout, so single measurements of the
parallel queries vary by ±30% or more (a descheduled worker thread delays a whole query), and
whole runs drifted by up to 25% within an hour; medians over the interleaved rounds are
reasonably stable, but differences below ~1 ms (or ±20% on the few-millisecond queries) are
noise.

| query | what it does | warm before (ms) | warm after (ms) | speed-up | cold before (ms) | cold after (ms) | speed-up |
|---|---|---:|---:|---:|---:|---:|---:|
| q01_filter_selective | selective filter (hash index) | 0.3 | 0.3 | 0.9× | 69.7 | 34.1 | 2.0× |
| q02_filter_low_selectivity | filter, 3 aggregates | 1.1 | 1.0 | 1.1× | 68.8 | 54.0 | 1.3× |
| q03_range_filter_time | timestamp range (B-tree index) | 2.0 | 0.9 | 2.3× | 33.9 | 23.9 | 1.4× |
| q04_arith_aggregate | DECIMAL arithmetic aggregates | 1.3 | 1.2 | 1.0× | 117.0 | 177.3 | 0.7× |
| q05_groupby_low_card | GROUP BY 5 currencies | 4.7 | 6.0 | 0.8× | 88.4 | 15.2 | 5.8× |
| q06_groupby_high_card | GROUP BY 10k merchants, top 10 | 10.2 | 9.8 | 1.0× | 165.6 | 35.7 | 4.6× |
| q07_groupby_skewed | GROUP BY 81k customers, top 10 | 19.1 | 8.5 | 2.3× | 28.3 | 10.2 | 2.8× |
| q08_groupby_uniform_multi | GROUP BY expression × category | 3.5 | 3.0 | 1.2× | 56.2 | 11.6 | 4.8× |
| q09_distinct_count | 2 × COUNT(DISTINCT) | 27.0 | 4.9 | 5.5× | 39.2 | 39.5 | 1.0× |
| q10_join_customers | join 1M × 100k, GROUP BY | 18.2 | 5.0 | 3.6× | 146.9 | 20.3 | 7.2× |
| q11_join_star | 3-way join, GROUP BY | 6.7 | 3.5 | 1.9× | 139.1 | 50.8 | 2.7× |
| q12_left_join_anti | LEFT JOIN … IS NULL | 10.1 | 8.4 | 1.2× | 43.6 | 12.3 | 3.6× |
| q13_sort_topn | ORDER BY … LIMIT 100 | 6.4 | 0.7 | 9.4× | 83.3 | 1.6 | 50.8× |
| q14_sort_full_string | full sort, 1M strings | 166.1 | 28.9 | 5.7× | 333.4 | 80.3 | 4.2× |
| q15_sort_multi_key | full sort, 3 keys, 1M rows | 140.8 | 30.8 | 4.6× | 183.3 | 36.2 | 5.1× |
| q16_timeseries_hourly | DATE_TRUNC grouping, top 100 | 1.4 | 1.3 | 1.0× | 56.1 | 47.2 | 1.2× |
| q17_wide_projection | 100-column table | 0.8 | 1.5 | 0.5× | 3.5 | 5.4 | 0.7× |
| q18_nulls | NULL-heavy, OR filter | 2.5 | 2.4 | 1.1× | 93.0 | 133.4 | 0.7× |
| q19_cte_subquery | CTE used twice + scalar subquery | 26.8 | 13.4 | 2.0× | 49.8 | 16.0 | 3.1× |
| q20_string_functions | UPPER/LENGTH/LIKE | 2.1 | 3.0 | 0.7× | 169.7 | 46.4 | 3.7× |
| **total** | | **451.0** | **134.4** | **3.4×** | **1969.0** | **851.4** | **2.3×** |

Warm = steady state (median of 10 runs after 5 warm-up runs); cold = the query's first
execution in a fresh session (after loading, with all earlier workload queries run before it,
in workload order). The result digests of all 20 queries are identical before and after.

Reading the table:

* The big wins are the sorts (q13–q15: 5–9× warm), COUNT(DISTINCT) (q09: 5.5×), the
  high-cardinality grouping and joins (q07, q10, q11, q19: 2–3.6×), and first executions
  across the board (2.3× in total, up to 7× for joins and aggregations) from the AOT cache.
* Sub-2-ms queries (q01, q02, q04, q16, q17, q20) are dominated by fixed costs (request
  handling, waking worker threads) and host noise. q05, q17 and q20 are ~1 ms slower warm in
  this run. Mostly this is the cost of starting from training profiles — the JIT compiles some
  kernels for the training's broader mix of types and branches: without the AOT cache they
  measured q05 4.5 ms, q17 1.1 ms, q20 2.2 ms (before: 4.3, 0.7, 2.0 in that run). Over the
  whole workload the cache still wins on warm times too (see below); q17's remaining ~0.4 ms
  is the parallel aggregation over a 100,000-row table (two morsels) — not addressed.
* Cold times of individual queries vary a lot between sessions (q04's first execution measured
  32–185 ms in different runs; q18's 89–133 ms), as they depend on what the JIT compiles
  concurrently; q04, q17 and q18 came out slower cold in this run. The totals are stable.

Effect of the JIT warm-up alone (an earlier back-to-back measurement, 5 rounds each, same
code except the cache): with `POLYQUERY_AOT=off` the warm total was 130.0 ms and the cold
total 1756.6 ms, against 116.8 ms and 719.5 ms with the cache (baseline in that run: 407.4 ms
warm, 1939.3 ms cold) — the engine changes give the warm speed-up, the AOT cache most of the
cold one.


### What changed, and why

Profiles (JFR with `-XX:+DebugNonSafepoints`, plus timing instrumentation of operator phases)
showed where the time went; the changes, by the queries they target:

* **Sorting (q14, q15).** The full sorts of 1,000,000 rows were single-threaded, and string
  sorts compared `String`s scattered over the heap (cache misses) whenever the 4-character
  radix prefix tied. Now every sort key is normalized to a 64-bit key per row: dictionary
  strings get the rank of their value (the dictionary is sorted once), other strings 7 Latin-1
  characters + min(length, 8) (or 3 UTF-16 units + min(length, 4) if some string needs them)
  — equal keys imply equal strings up to 7 (3) characters, so short strings are never
  compared; numbers are exact. Large sorts are a parallel sample sort: splitters from a sample
  of the first key, a stable parallel counting scatter into key-range buckets, then radix sort
  and refinement per bucket on the workers (stable, so ties keep input order exactly). The
  input of a full sort over a pipeline is materialized by the workers (each morsel into its own
  store, memory reserved with the same estimate as before, then concatenated in parallel in
  morsel order) instead of being appended batch by batch on the query thread, and the sorted
  rows are moved into order by the workers so the output is read sequentially.
* **Top-N (q13; q06/q07 over their groups).** `ORDER BY … LIMIT n` kept every row of a morsel
  and sorted it. Now, once the best `offset + n` rows are known, the first sort key of the
  last of them is a cutoff: rows whose first key ranks strictly after it are dropped before
  they are copied (equal keys are kept — later keys and input order decide). Per-morsel top-N
  of the workers compacts as it goes.
* **COUNT(DISTINCT) (q09).** DISTINCT aggregates went through the row engine's accumulators
  (`HashSet<Object>` of boxed values) on one thread. Now a vectorized state keeps a primitive
  open-addressing set of (group, value) pairs (objects only for strings and wide DECIMALs) and
  feeds first occurrences to the plain aggregate's state, in input order. Without GROUP BY,
  the aggregation is parallel: workers deduplicate their morsels, the merge unions the workers'
  sets in parallel by hash partition (each partition feeding a fresh plain state) and merges
  the partition states — exact for COUNT/MIN/MAX and INT64/DECIMAL sums; FLOAT64 SUM/AVG of
  DISTINCT values may differ in the last bits like any parallel float sum.
* **CTE referenced twice (q19).** CTEs are inlined, so `per_c` aggregated the 1M-row table
  twice. Physical subplans now have a structural key (`PlanKeys`: records compared
  component-wise, tables and indexes of the query's snapshot by identity); an aggregation
  whose key matches one already completed in the same query, and which cannot depend on
  anything but the snapshot (no outer references, no subqueries, no `PQ_SLEEP`), emits the
  completed tables of the first one with its own emitter (aggregation is blocking, and
  emitting only reads the tables). Errors raised while emitting (e.g. SUM overflow of a group)
  are raised at the same group by both.
* **Parallel aggregation merge (q06, q07, q19).** Every merged group did a k-way heap step
  across all partials and a reservation on the query's shared memory counter (contended by all
  merging threads). Partitions now merge the partials in worker order keeping each group's
  earliest first position, reserve memory in 64 KiB steps, and the final group order (order of
  first appearance, as in sequential execution) is a radix sort of first positions.
* **Joins (q10, q11, q12).** The join row limit (`--max-join-rows`) was counted with one
  atomic increment per output row on a counter shared by all probing workers — the top item of
  the q10 profile; it is now counted once per output batch, with the same row-exact cut-off.
  The single-integer-key join index is presized for the build side's row count instead of
  growing (and rehashing) from 64 slots.
* **JIT warm-up (cold times).** A query's first execution was dominated by interpretation and
  JIT compilation of the engine's kernels (the cold total was ~4× the warm total). `make build`
  now runs a training workload (`polyquery.Training`: synthetic tables of the usual analytical
  shapes — integer keys of low/high cardinality, DECIMAL amounts, FLOAT64, timestamps,
  dictionary and free-text strings, NULL-heavy columns — loaded through the protocol, and ~40
  generic query shapes — filters, grouping, DISTINCT, joins, sorts, top-N, CTEs/subqueries —
  run through the session request path) under `-XX:AOTCacheOutput` (JEP 483/515: the
  classes loaded and linked and the method profiles are stored). `bin/polyquery` starts the JVM
  with `-XX:AOTCache` when the cache exists, so hot methods are compiled much sooner. The
  cache is an optimization only: if training fails the build still succeeds, a stale or
  mismatching cache is ignored by the JVM, and `-Xlog:disable` keeps the JVM's messages about
  it off stdout (which carries only protocol responses). The training is not the benchmark: it
  uses its own tables and query texts.
* **Memory settings.** The JVM started with an 8 MB heap that grew in steps, with frequent
  young collections (6–50 ms pauses) while the loaded tables were still young. On machines
  with at least 16 GiB (the smaller of physical memory and a cgroup limit), the launcher now
  uses a 4 GiB initial heap with a fixed 2 GiB young generation (`bin/jvm-options`); otherwise
  JVM defaults apply.

### Tried and rejected

* **Partition-first ("radix") parallel aggregation** for high-cardinality GROUP BY (workers
  hash-partition their rows, every partition aggregated by one thread, decided adaptively from
  the rate of new groups): correct, but on this machine slower or equal for q06/q07/q19 than
  pre-aggregation with the cheaper merge (the scatter costs about as much as the duplicated
  aggregation it saves, and late-starting partition threads dominate). Removed.
* **Smaller morsels** (16,384 rows, for better load balancing): no clear difference.
* **Fewer default threads** (16 instead of all 32): within noise; the default stays all cores.
* **Eager AOT compilation** (`-XX:+AOTCompileEagerly`, experimental): worse cold and warm
  totals; and no experimental options are used.
* **A very large initial heap** (6% of RAM, 15 GB young generation): fewer collections, but
  slower queries — every allocation touched fresh pages (page-fault cost); a moderate fixed
  young generation that stays mapped is better. `-XX:+AlwaysPreTouch` made no difference.

### Correctness

Every change keeps results, row order and errors identical (the result digests of all 20
workload queries match the original engine's). New tests: the parallel sort and the
normalized string keys (Latin-1 and UTF-16, short and long strings, dictionary ranks, NULLs
first/last, descending, several keys) against the reference comparator, with 1 and 8 threads;
store concatenation (shared/different dictionaries, plain strings, NULLs, empty parts); and in
the Phase 5 option matrix (every mode × join × threads × optimize, also with tiny batches and
morsels): top-N with NULLS FIRST/LAST, descending, ties broken against input order, DECIMAL and
FLOAT64 keys; DISTINCT aggregates without GROUP BY (strings, DECIMAL, FLOAT64, overflow
widening); CTEs referenced twice (scalar subquery, self-join, an overflow raised while
emitting). Mutations of the top-N cutoff (dropping equal keys) and of the DISTINCT merge were
checked to be caught. The conformance suite, `--modes`, `--transport http`, the HTTP
concurrency suite and the stress configuration (`-Dpolyquery.batchSize=3
-Dpolyquery.morselRows=5 -Dpolyquery.parallelSortRows=4`) pass.

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
  gives `DECIMAL(W,s)`, W = 18, or 38 with a wide DECIMAL), any other mix (including DATE with TIMESTAMP) is `TYPE_ERROR`.
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
* Comparisons between INT64 and DECIMAL values compare exact values and never overflow
  (CR-2 §4, resolving SPEC-Q-001; e.g. `9223372036854775807 > 1.5` is TRUE). In arithmetic,
  INT64 becomes DECIMAL(W,0) (so `1.5 * 2` is DECIMAL(18,1)).
* A NULL literal in arithmetic takes the type family of the other operand (`1 + NULL` is
  INT64); `NULL + NULL`, `-NULL` and `MIN(NULL)` keep the null type (reported as STRING).
  `SUM(NULL)` is INT64 and `AVG(NULL)` is FLOAT64.
* `LIMIT NULL` / `OFFSET NULL` mean "no limit" / 0. Non-INT64 constants are
  `TYPE_ERROR`, non-constant expressions `SEMANTIC_ERROR`, negative values
  `INVALID_ARGUMENT`. `ORDER BY 0` is out of range (`SEMANTIC_ERROR`).
* `TIMESTAMP '…'` literals need a time part. `CAST('YYYY-MM-DD' AS TIMESTAMP)` is
  accepted (midnight), as in ingestion. CAST from STRING trims all whitespace.
* FLOAT64 → DECIMAL uses the exact binary value of the double, rounded half away from zero
  (CR-2 §5; `CAST(0.1e0 AS DECIMAL(38,30))` is `0.100000000000000005551115123126`, and
  `2.675e0` → `2.67` because the double is 2.67499999…). FLOAT64 → STRING uses Java's shortest round-trip text
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
# CR-6 statement size limits (minimums in every mode, beyond the limits, timeout lateness)
python3 tests/regression/robustness_probe.py --engine implementations/java/bin/polyquery \
    --only expression_limits --require-pass
# native kernels (M9): build the library, then every query with native: true
make -C native-kernels
python3 tests/conformance/runner.py --engine implementations/java/bin/polyquery \
    --native native-kernels/build/x86_64/libpqkernels.so [--modes | --transport http]
# … also with each variant: PQ_KERNELS_VARIANT=reference|scalar|avx2|avx512 python3 …
# Phase 5 stress: every batch boundary, worker and deferred-error path on the small fixtures
POLYQUERY_JAVA_OPTS="-Dpolyquery.batchSize=3 -Dpolyquery.morselRows=5 -Dpolyquery.parallelSortRows=4" \
    python3 tests/conformance/runner.py --engine implementations/java/bin/polyquery --modes
# randomized differential testing of all option combinations (data dir with a copy of fixtures/)
python3 implementations/java/tools/difftest.py --engine implementations/java/bin/polyquery \
    --data /tmp/dtdata --queries 300 --seed 1 [--native-kernels native-kernels/build/x86_64/libpqkernels.so]
# latency of the benchmark workload (see Latency optimization): cold and warm times, result digests
python3 implementations/java/tools/workload_bench.py --engine implementations/java/bin/polyquery \
    --workload benchmarks/workloads/analytics.json --data datasets/generated --scale 1m --rounds 5
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

For CR-2, `difftest.py` writes a table `wd` of wide DECIMALs (NULLs, duplicates, extreme
values, small values equal to narrow/integer values) next to INT64 and narrow DECIMAL columns,
saves it as PQCF v2 with 64-row groups (`wd_p`, memory-mapped, with B-tree and hash indexes)
and generates wide arithmetic (incl. overflowing products), `ABS`/`ROUND`/`FLOOR`/`CEIL`/
`COALESCE`/`NULLIF`/`CASE`/casts, comparisons of wide values with wide, narrow, INT64 and
FLOAT64 operands, `IN`/`BETWEEN` with mixed constants, joins on wide, mixed narrow/wide and
INT64/DECIMAL keys, wide GROUP BY keys and `SUM`/`AVG`/`MIN`/`MAX`/`COUNT(DISTINCT)`/
`SUM(DISTINCT)` (550 queries with two seeds under all 32 combinations, plus `native: true`:
no mismatch after fixing the one bug it found — narrow-vs-wide join keys of the same kind were
not brought to one representation). `WideDecimalTest` checks the arithmetic, casts, parsing
and text of wide values, the W typing rules, exact comparisons (also INT64 columns against
narrow DECIMAL constants that cannot hold them), PQCF v2 round trips with every encoding and
row-group size (header version 2 exactly for tables with a wide column, version mismatch /
v3 rejected), indexes on wide columns, and a wide query set under the whole option matrix
(also with tiny batches/morsels and with native kernels).

Unit tests (`src/test/java`, run by `make test`) cover the Phase 5 engine — `Phase5Test` runs
a set of queries (grouping, joins of every kind, DISTINCT, sorts, top-N, subqueries, failing
expressions, `UNION ALL` with mixed branch types / under aggregation and joins / in IN and
correlated EXISTS subqueries / with LIMIT before a failing branch) under every combination of mode × join × threads × optimize, also with tiny
batches and morsels, and checks row-exact error semantics; `VectorTest` covers the kernels
(branch-free comparisons), group-key tables, exact sums (single-group SIMD path, overflow
widening, partial merges), stable radix/merge sorting (also the parallel bucket sort and the
normalized string keys against a reference comparator), store concatenation, the join index —
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

* Statement sizes (CR-6): SQL text up to 64 MiB, nesting depth up to 4,096, up to 200,000
  operands; beyond, `RESOURCE_LIMIT`. Joins, `UNION ALL` branches and CTE chains have no
  separate limit; very wide join results (hundreds of tables, i.e. rows of thousands of
  columns) are bounded by memory: a 4,000-way cross join exhausts the heap and fails with
  `RESOURCE_LIMIT` ("out of memory") rather than reaching the join-row limit, and garbage
  collection can then delay its answer past the timeout. The `explain` op's plan JSON nests two
  levels per plan node, so plans of statements nested hundreds of levels deep exceed the
  nesting depth some JSON parsers accept (Python's default ≈ 1,000).

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
  little when most keys are distinct; a radix-partitioned exchange was tried and was not
  faster here — see Latency optimization). Aggregates over DISTINCT values run in parallel
  only without GROUP BY.
* Sharing of identical subplan results within a query covers aggregations only (e.g. a CTE
  with GROUP BY referenced twice); other repeated subplans (joins, sorts, plain scans of a
  CTE) are executed once per reference. The top-N cutoff applies to INT64-like and FLOAT64
  first sort keys (strings and wide DECIMALs are only compacted, not pre-filtered).
* The AOT cache (`build/polyquery.aot`) belongs to the JVM build and the jar it was trained
  with; `make build` recreates it whenever the jar changes. Another JVM, a moved jar without
  its cache, or different heap-limit settings (compressed oops) make the JVM ignore it — the
  engine then just warms up more slowly. First executions still include JIT compilation (the
  cache holds profiles, not compiled code).
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
  pushed into the branches (predicates move below projections and into joins, but not through
  unions, aggregations, DISTINCT, sorts or limits); the branches of a union run sequentially (each branch's own pipeline may be parallel),
  and an aggregation over a union is not parallelized.
* Indexes are used only for filters directly over a scan (no index nested-loop joins, no
  index-ordered output); OR-ed predicates are not used for index lookups or row-group
  skipping. In-memory tables are a single row group, so row-group skipping applies to
  PQCF-backed tables only. STRING chunk min/max are not written (they are read and used).
* Decoded chunks of memory-mapped files stay cached for the lifetime of the table.
* Each ingestion reads the whole input into memory before parsing.
* Wide DECIMAL values (CR-2) are `BigInteger` objects: their arithmetic, comparisons, hashing
  and sorting work per value (no SIMD, no native kernels), and they take more memory than the
  `long` of a narrow DECIMAL. Wide negation and casts to/from wide types use the row engine's
  code per value inside vectorized expressions.
