# PolyQuery — Clojure engine

An analytical database engine implementing the PolyQuery specification
(`spec/`) in Clojure. Status: **Phase 5** — Phase 1 (protocol, catalog,
CSV/JSON/JSONL ingestion, all data types, resource limits, test functions),
Phase 2 (the complete SQL language: GROUP BY/HAVING, DISTINCT,
INNER/LEFT/CROSS joins, all scalar functions, CASE/LIKE/BETWEEN/IN,
uncorrelated **and correlated** subqueries, derived tables, CTEs, EXPLAIN) and
Phase 3 (row- and column-oriented in-memory layouts with null bitmaps and
dictionary encoding, the PQCF v1 file format with PLAIN/DICT/RLE encodings,
CRC-32 checksums, atomic crash-safe writes and memory-mapped reads, table
statistics, HASH and BTREE indexes, index selection, predicate pushdown with
row-group skipping, column pruning and cost-based hash-join build sides) and
Phase 4 (the `serve` HTTP/1.1 server with every endpoint of protocol.md §7,
NDJSON streaming with backpressure, Prometheus metrics, structured JSON logs,
snapshot-isolated concurrent readers, worker limits with a bounded FIFO
queue and `OVERLOADED` rejection, query timeouts, cancellation, client
disconnect detection and graceful shutdown) and Phase 5 (row-at-a-time
baseline `mode: row`, vectorized batch execution `mode: vectorized`,
parallel scans/aggregation/sorting `threads: N`, hash, sort-merge and
nested-loop joins selectable with `join`, a switchable logical optimizer
`optimize`, SIMD-friendly kernels, buffer reuse and cache-aware hash
tables — see [Phase 5](#phase-5-optimization) for the design and the
measurements) and **M9 native kernel integration** (the C/assembly library
`libpqkernels` loaded with `--native-kernels PATH` through the Java FFM API
and used by vectorized filters, aggregation, hashing and join gathers when
a query runs with `native: true` — see [Native kernels](#native-kernels-m9)).

Reported capabilities: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic
test.functions phase2 sql.groupby sql.join sql.functions sql.subquery sql.cte
sql.correlated_subquery phase3 storage.pqcf storage.mmap index.hash
index.btree phase4 http.streaming phase5 exec.row exec.vectorized
exec.parallel join.hash join.merge join.nested_loop native.kernels`.

## Prerequisites and build

* OpenJDK (tested with 27) — `JAVA_HOME` or `java` on `PATH`
* Clojure CLI (tools.deps) with Clojure 1.12.3 in the local Maven cache
* GNU make

```sh
make build    # AOT-compiles src/ into target/classes, writes target/classpath
make test     # clojure.test unit tests (test/)
make lint     # compiles with *warn-on-reflection*; fails on reflection warnings
make fmt      # whitespace normalisation (no third-party formatter is allowed)
make clean
bin/polyquery session --data-dir DIR    # JSON-lines protocol on stdin/stdout
bin/polyquery serve --port 0 --data-dir DIR [--workers N --queue-depth Q ...]
```

`bin/polyquery` works from any directory; extra JVM flags can be passed via
`POLYQUERY_JAVA_OPTS` (e.g. `-Xmx16g` for very large tables). `--threads N`
sets the default worker threads per query.

Native kernels are optional: build them with `make -C native-kernels`
(C compiler + assembler; produces `native-kernels/build/x86_64/libpqkernels.so`)
and start the engine with `--native-kernels PATH`; queries then use them
with the option `"native": true`. The engine builds, runs and passes
conformance without them.

Development tools (Python, not part of the build): `bench/bench.py DATA_DIR`
times a fixed query set on the generated datasets under several option
combinations (`--verify` compares full results instead), `bench/fuzz.py`
is a differential fuzzer of the option matrix (random expressions,
predicates, aggregates, joins, sorts over the generator fixtures); both
take `--native LIB` to add `native: true` configurations.

## Libraries

None besides Clojure itself (`org.clojure/clojure 1.12.3`, which pulls in its
own `spec.alpha`/`core.specs.alpha`). Everything else — JSON, CSV, the SQL
front end, decimal and calendar arithmetic — is implemented here on top of
`clojure.core` and the JDK. See `ENGINE.json`.

## Architecture

Every statement goes through distinct, inspectable stages:

```
SQL text ─lexer→ tokens ─parser→ AST ─analyzer/binder→ bound query
        ─logical planner→ logical plan ─optimizer→ logical plan
        ─physical planner→ physical plan ─parallelizer→ physical plan
        ─dispatcher→ row / vectorized / parallel operators → rows ─protocol→ JSON
```

| Layer | Namespaces | Responsibility |
|---|---|---|
| CLI / protocol | `polyquery.main`, `polyquery.protocol` | argument parsing, session/exec loops, request validation, op dispatch (`handle-op` multimethod), response objects |
| HTTP server (Phase 4) | `polyquery.server`, `polyquery.server.http`, `polyquery.server.admission`, `polyquery.server.metrics` | endpoints and routing, query lifecycle (registry, admission, timeouts, cancellation, streaming), graceful shutdown; HTTP/1.1 wire format; worker limit + FIFO queue; Prometheus exposition |
| Engine pipeline | `polyquery.engine` | drives the stages per statement, EXPLAIN, result serialization |
| Lexer | `polyquery.sql.lexer` | tokens with line/column positions, comments, quoted identifiers, reserved words |
| Parser / AST | `polyquery.sql.parser`, `polyquery.sql.ast` | recursive descent over the full v1 grammar producing a plain-map AST |
| Semantic analysis | `polyquery.sql.analyzer` (queries: FROM/CTE/derived-table resolution, `*` expansion, GROUP BY/ORDER BY rules, output names), `polyquery.sql.binder` (expressions: name resolution incl. correlation, typing, coercions, aggregates), `polyquery.sql.functions` (scalar function signatures), `polyquery.sql.bound` (bound-expression shapes and helpers) | produces a *bound query*: typed expressions whose column references are row indices |
| Logical planning | `polyquery.plan.logical` | relational operator tree: values/scan/derived/join → filter → aggregate → filter (HAVING) → project → distinct → sort → limit → project |
| Optimization | `polyquery.plan.optimizer`, `polyquery.plan.rewrite`, `polyquery.plan.reorder`, `polyquery.plan.pruning` | constant folding and predicate simplification, predicate pushdown below joins (WHERE equalities of comma joins become join conditions), join reordering of inner-join chains (all disabled by `optimize: false`); column pruning |
| Physical planning | `polyquery.plan.physical`, `polyquery.plan.parallel`, `polyquery.plan.access`, `polyquery.plan.cost`, `polyquery.plan.explain` | access paths (index selection, row-group skip predicates), join algorithm (`join` option) and hash-join build side (cardinality estimates), top-N for ORDER BY … LIMIT, hash lookup for correlated equality predicates, parallelization (partitioned aggregation/sort, Gather), planning of nested subquery plans; EXPLAIN JSON |
| Execution — dispatch | `polyquery.exec.dispatch` | picks per plan node the row, vectorized or parallel implementation from the query's `mode`/`threads` |
| Execution — row engine | `polyquery.exec.operators`, `polyquery.exec.join`, `polyquery.exec.skipping`, `polyquery.exec.expr`, `polyquery.exec.functions`, `polyquery.exec.aggregate`, `polyquery.exec.context` | operators compiled once into re-reducible row sources (table/index scans over segments); hash, sort-merge and nested-loop joins; top-N; row-group skipping; expression compiler (bound expr → specialised closure); scalar functions and LIKE; mergeable aggregate accumulators; query context (timeout, cancellation, memory budget) |
| Execution — vectorized engine | `polyquery.exec.batch`, `polyquery.exec.kernels`, `polyquery.exec.vectorized`, `polyquery.exec.vjoin`, `polyquery.exec.grouping`, `polyquery.exec.sort` | column batches with selection vectors; vectorized expression kernels; batch scan/filter/project; vectorized hash aggregation (primitive group tables, typed aggregate states); vectorized hash-join probe; primitive-column sorting |
| Execution — parallelism | `polyquery.exec.parallel` | worker pool, partitioned pipelines over table row ranges, partial aggregation + merge, parallel sort/top-N, ordered morsel-driven Gather |
| Execution — native kernels (M9) | `polyquery.native.ffi`, `polyquery.native.bits`, `polyquery.exec.native` (+ hooks in `exec.grouping`, `exec.vjoin`) | FFM binding of libpqkernels; batch ↔ bitmap conversions; native filter compiler; native aggregate updates, key hashing and gathers |
| Storage | `polyquery.storage.column`, `polyquery.storage.table`, `polyquery.storage.stats`, `polyquery.storage.index`, `polyquery.storage.pqcf` | typed column vectors with validity bitmaps, dictionary-encoded strings, row-layout views; tables split into segments; statistics; HASH/BTREE indexes; the PQCF v1 writer and validating reader |
| Catalog | `polyquery.catalog` | immutable catalog value held in an atom (snapshot per query, atomic publication of loads, opens and index changes); global index namespace |
| Ingestion | `polyquery.ingest`, `polyquery.ingest.{csv,json,common}` | streaming RFC 4180 reader, strict JSON reader, inference, explicit-schema conversion |
| Values / types | `polyquery.types`, `polyquery.values` | type model and promotion, exact DECIMAL arithmetic, proleptic Gregorian calendar, CAST matrix, canonical serialization, total order, hash keys |
| Utilities | `polyquery.util.{json,text,log}` | JSON reader/writer, ASCII case folding, code-point string order, stderr JSON logs |

### Value and row representation

Rows are `Object[]`; NULL is `nil` for every type. `BOOLEAN` → `Boolean`,
`INT64` → `Long`, `FLOAT64` → `Double`, `STRING` → `String`, `DATE` → `Long` days
since 1970-01-01, `TIMESTAMP` → `Long` microseconds, `DECIMAL(p,s)` → `Long`
unscaled value (the scale is static, carried by the type). Decimal arithmetic
is exact: long fast paths with `BigInteger` fallbacks wherever an
intermediate (rescaling, sums) may exceed 64 bits; only final results are
range-checked, as the spec requires.

The row a query's expressions see is its *FROM row*: the columns of all
range variables concatenated in FROM order (a join emits left columns then
right columns). After aggregation the row is the GROUP BY keys followed by
the aggregate values; SELECT/HAVING/ORDER BY expressions are bound against
that layout (a GROUP BY expression is replaced by a reference to its key, so
grouping violations are detected structurally).

Because all types are static after analysis, the expression compiler emits
type-specialised closures (e.g. INT64 `+` uses `Math/addExact`, DECIMAL
comparison rescales by the static scale difference), so there is no dynamic
type dispatch per row.

### Execution (row engine)

This describes the row-at-a-time engine (`mode: row`, and the operators the
vectorized mode reuses); see [Phase 5](#phase-5-optimization) for vectorized
and parallel execution. Each physical operator is compiled once into a *re-reducible*
(`clojure.lang.IReduceInit` that recomputes its rows on every `reduce`); rows
are pushed through transducers (`filter`, `map`, `drop`/`take`) without
intermediate collections. Blocking operators (sort, hash aggregate, distinct,
hash-join build) materialize with memory accounting and periodic
timeout/cancellation checks.

* **Joins**: hash join (build side chosen by cardinality estimates, always
  the right input of LEFT joins; NULL keys never match;
  INT64/DECIMAL/FLOAT64/DATE/TIMESTAMP keys are hashed in their comparison
  type) whenever the ON condition (after pushdown) has an equality between
  the two inputs, else nested loops; the `join` option can force sort-merge
  or nested-loop joins. LEFT joins pad unmatched rows with
  NULLs. Output rows are counted against `--max-join-rows`.
* **Subqueries**: uncorrelated scalar/IN/EXISTS subqueries are evaluated once
  (lazily) and cached; IN builds a hash set. A correlated subquery references
  enclosing rows through a *correlation cell*: the subquery expression stores
  the current outer row in its cell and reduces the (compiled-once) subquery
  plan, which reads outer columns from the cell. Correlated equality
  predicates over a table scan (`inner.col = outer.col`) are executed as a
  hash lookup built once, so the common correlated patterns are O(n + m).
* **CTEs** are analyzed once per definition and inlined at each reference.

### Storage (Phase 3)

* **Tables** are immutable values split into *segments* (one per in-memory
  table, one per PQCF row group). A segment holds one `ColumnVector` per
  column (an interface with `valueAt`/`isNull`), optionally behind a `delay`
  for lazily decoded chunks, plus optional chunk statistics.
* **Layouts** (`load`/`open` option `layout`, default `column`):
  `column` stores typed vectors (`long[]` for INT64/DECIMAL/DATE/TIMESTAMP,
  `double[]`, bit-packed BOOLEAN, `String[]` or a dictionary vector
  (`int[]` codes + dictionary) for STRING) each with a validity bitmap
  (`long[]` words, nil when there are no NULLs); `row` stores an array of row
  tuples and exposes columns as views over it. Both are read through the same
  interface, so results never depend on the layout. STRING columns are
  dictionary-encoded automatically when at most half of the values are
  distinct (tables of ≥ 16 rows), always with `dictionary: true`, never with
  `dictionary: false`.
* **Statistics** (`stats`): row count and per column null count, min, max and
  distinct count, computed lazily on first use and cached in the table value.
  Distinct values are counted exactly up to 65,536, then with a HyperLogLog
  sketch (2^14 registers, ~1% error).
* **Indexes** are built from a sorted permutation of the column's non-null
  values (ties by row id). BTREE answers equality and ranges by binary
  search; HASH maps each normalized value to its run in the permutation.
  Lookups return sorted row ids, so index scans produce rows in table order.
  Indexes live in their table value (dropping/replacing a table drops them);
  their names are global and case-insensitive.
* **PQCF writer**: chunks are written column by column, 8-byte aligned;
  default row group size 65,536 (`row_group_size` option). With
  `encoding: auto` each chunk uses the smallest applicable encoding (RLE for
  BOOLEAN/INT64/DECIMAL/DATE/TIMESTAMP, DICT for STRING, else PLAIN); forced
  encodings fall back to PLAIN where not applicable. NULL slots are written
  as zero / empty / extending the current run. `min`/`max` are written for
  all types except STRING. Atomic save: temporary file
  `.<target>.tmp-<pid>-<nanos>-<n>` in the target directory → `fsync` →
  atomic rename → directory `fsync`; stale temporary files of the same target
  are removed by the next save.
* **PQCF reader**: header, footer, metadata checksum, metadata structure and
  every consistency rule of pqcf-v1.md §2 are validated at `open`; unknown
  encodings and versions are `STORAGE_VERSION_UNSUPPORTED`. Without `mmap`
  every chunk is read, checksummed, validated (§3.4) and decoded at `open`.
  **With `mmap: true` the file is memory-mapped** (`FileChannel.map`, one
  mapping per chunk) and each chunk is checksummed, validated and decoded
  lazily on first access; a corrupt chunk makes that query fail with
  `STORAGE_CORRUPT`. Fixed-width PLAIN chunks of mapped files are read in
  place (zero copy). Indexes listed in the metadata are rebuilt at `open`.

### HTTP server and concurrency (Phase 4)

* **Wire layer** (`polyquery.server.http`): blocking sockets, HTTP/1.1 with
  keep-alive (HTTP/1.0 only with `Connection: keep-alive`), `Content-Length`
  and chunked request bodies, `Expect: 100-continue`. A body larger than
  `--max-request-bytes` is answered with `413 RESOURCE_LIMIT`; it is read and
  discarded (up to 64 MiB, so the connection can stay open) or the connection
  is closed. Malformed requests get `400 INVALID_REQUEST` and the connection
  is closed.
* **Threads**: one platform thread per connection parses requests and
  writes responses, so `/health`, `/metrics`, `/v1/queries` and cancellation
  stay responsive however busy the workers are. Queries run on separate
  worker threads; the connection thread waits for the result in 10 ms steps
  and in between peeks at the socket (1 ms read timeout) to detect a client
  disconnect, which cancels the query.
* **Query lifecycle** (`/v1/query`, `/v1/query/stream` and `/v1/request` with
  `op: "query"`): the query is registered under its `query_id` (client's
  `options.query_id` or a generated `pq-<uuid>`; an id in use by a queued or
  running query ⇒ `409 ALREADY_EXISTS`), then admitted by
  `polyquery.server.admission`: a free worker is taken immediately, otherwise
  the query waits in a FIFO queue of `--queue-depth` entries (a released
  worker is handed directly to the oldest waiter), otherwise it is rejected
  at once with `503 OVERLOADED`. Its deadline is fixed at arrival
  (`options.timeout_ms`, else `--query-timeout-ms`), so queueing time counts.
  Cancellation (`DELETE /v1/queries/{id}`, disconnect, shutdown) and the
  deadline are an `AtomicBoolean` and an absolute deadline shared with the
  query context, observed while queued and by the operators' periodic checks
  (every 4,096 rows, every 65,536 sort comparisons; `PQ_SLEEP` every ≤ 5 ms).
  Other requests (loads, DDL via `/v1/request`, explain, catalog reads) run
  directly on the connection thread and are not subject to the worker limit.
* **Snapshot isolation** comes from the immutable catalog value: a query
  analyzes and plans against `@catalog` once, so its plan holds the table
  values it started with; loads parse first and publish with one `swap!`.
* **Streaming**: the worker thread pushes `[:header]`, `[:rows batch]` (1,000
  rows per line), `[:end n]`/`[:error e]` into an `ArrayBlockingQueue` of 8
  batches; the connection thread writes one chunk per message. A client that
  stops reading blocks the socket write, the queue fills up and the producer
  waits (still observing cancellation/timeout). The header is sent as soon as
  the statement is planned, so errors detectable before execution (and
  admission errors) are normal error responses; runtime errors after the
  header become a final `{"type":"error"}` line without an `end` line.
* **Metrics**: `polyquery_queries_total{status}` counts every query request
  that reached the query path (rejections, duplicate ids and shutdown
  refusals count as `error`); the duration summary covers admitted queries,
  including queueing time.
* **Logs**: JSON lines on stderr (`ts`, `level`, `msg`, plus fields); every
  query completion logs `query_id`, `status` (`ok`/`error`), `error_code`,
  `duration_ms` and `rows`. SQL text, data values and request bodies are
  never logged at `info`.
* **Shutdown**: a JVM shutdown hook (SIGTERM/SIGINT) closes the listening
  socket (new connections are refused), answers new queries on existing
  connections with `503 SHUTTING_DOWN` (`/health` ⇒ 503, responses carry
  `Connection: close`), waits up to `--shutdown-grace-ms` for in-progress
  requests and queued/running queries, then cancels the remaining queries
  (`CANCELLED`), gives them up to 2 s to answer, closes all connections and
  halts the JVM with status 0.
* **Defaults**: `--workers` = number of CPUs (0 means the default),
  `--queue-depth` 64, `--query-timeout-ms` 0, `--shutdown-grace-ms` 10000,
  `--max-request-bytes` 1 GiB. `PUT /v1/tables/{name}` accepts the query
  parameters `format`, `replace`, `header`, and additionally `delimiter`,
  `layout` and `dictionary` (as in `load`).

## Phase 5: optimization

### Execution models

* **Row mode (`mode: row`)** — the unoptimized baseline, unchanged since
  Phase 2: Volcano-style re-reducible operators over `Object[]` rows,
  closures compiled per expression, a comparator sort (TimSort).
* **Vectorized mode (`mode: vectorized`, also `auto`)** — operators exchange
  *batches* of up to 1,024 rows (`polyquery.exec.batch`): one typed vector
  per FROM-row position (`long[]` for INT64/DECIMAL/DATE/TIMESTAMP,
  `double[]`, `boolean[]`, `Object[]`, or the dictionary codes of a
  dictionary-encoded column) with a `boolean[]` null mask (absent when a
  vector has no NULLs) and a *selection vector* of the live positions.
  Filters only shrink the selection; projections add vectors.
  * **Kernels** (`polyquery.exec.kernels`) evaluate a bound expression for a
    whole batch. They mirror the row compiler exactly — same NULL
    propagation, same overflow/division checks, and the same laziness: the
    right operand of AND/OR, CASE branches and COALESCE arguments are
    evaluated only on the sub-selection of rows that reach them, and the
    right operand of a NULL-propagating operator only on rows whose left
    operand is not NULL when it could fail. Comparisons with constants are
    pre-converted to the column's domain (e.g. `amount > 500` compares
    unscaled longs); predicates on dictionary-encoded strings (`=`, `<`,
    `IN`, `LIKE`) are evaluated once per dictionary entry. Unsupported
    expressions (subqueries, correlated references) fall back to the row
    closure applied per selected row.
  * **Vectorized hash aggregation** (`polyquery.exec.grouping`): group keys
    are evaluated as vectors and mapped to dense group ids; aggregate states
    are primitive arrays indexed by group id (COUNT `long[]`, exact
    SUM/AVG `long[]` + overflow `BigInteger` per group, FLOAT64 SUM/AVG
    `double[]`, MIN/MAX `long[]`/`double[]`); DISTINCT and string MIN/MAX use
    one row-engine accumulator per group.
  * **Vectorized hash-join probe** (`polyquery.exec.vjoin`): probe keys are
    vectors; matches are written as (probe position, build row) pairs into
    output batches (probe columns gathered from the typed vectors, build
    columns converted lazily). INNER joins and LEFT joins without residual.
  * **Sorting** (`polyquery.exec.sort`): sort keys are extracted into
    primitive columns; a single integer-like key is sorted by an LSD radix
    sort (8-bit digits, constant digits skipped), other keys by a merge sort
    of the index permutation with typed comparisons (parallel chunks +
    pairwise merges). Ties keep input order (stable), as in row mode.
  * Other operators (DISTINCT, LIMIT, index scans, merge and nested-loop
    joins) run row at a time; rows and batches are converted at the
    boundaries (batch columns built from rows are typed lazily, on first
    use by a kernel).
* **Parallelism (`threads: N`)** — in both modes (`polyquery.plan.parallel`,
  `polyquery.exec.parallel`). A *partitionable pipeline* is a table scan
  below filters, projections, derived tables and the probe side of hash
  joins, free of subqueries and correlated references; it is executed on
  disjoint row ranges of the scanned table on a cached daemon worker pool,
  every partition with its own compiled operators. Hash tables of joins in
  the pipeline are built once and shared read-only. Aggregations, sorts and
  top-N over such pipelines get `partitions` (partial aggregation merged
  in partition order — groups keep the serial order of first appearance,
  INT64/DECIMAL sums stay exact; per-partition sorted runs/heaps); other
  maximal partitionable pipelines are wrapped in a `Gather` that keeps up
  to N morsels (≤ 131,072 rows) in flight and emits them in table order
  (not below a LIMIT, where read-ahead would be wasted). Partitions smaller
  than 1,024 rows are not split off. Correlated subqueries run serially.
* **Join algorithms** (`join` option, `polyquery.exec.join`): hash join
  (default, built on the smaller estimated input), sort-merge join (both
  inputs sorted on their keys, equal-key runs joined, NULL keys never
  match, LEFT joins pad unmatched rows) and nested-loop join. For an
  equi-join every algorithm evaluates the residual condition only on pairs
  with equal keys (nested loops test the key equalities first), so all
  three evaluate exactly the same predicates.
* **Logical optimizer** (`optimize`, `polyquery.plan.optimizer`): constant
  folding (constant subexpressions evaluated at planning time; failing ones
  left in place), predicate simplification (TRUE/FALSE operands, double
  negation, duplicate conjuncts — never dropping an operand whose
  evaluation could fail), predicate pushdown (Phase 2), greedy join
  reordering of inner-join chains (smallest estimated relation first, then
  always a relation connected by a join condition; a projection restores
  the column order), and the physical top-N rewrite of `ORDER BY … LIMIT`
  (a bounded heap per partition). `optimize: false` disables all of them.

### Identical results under every option combination

Every combination of `mode` × `join` × `threads` × `optimize` returns the
same rows (FLOAT64 sums up to rounding of the summation order):

* the kernels and the parallel operators compute exactly the row engine's
  values (shared value functions, exact integer/decimal sums, the same
  accumulator semantics; merge order = serial order of first appearance;
  stable sorts);
* errors: vectorized and parallel execution may evaluate rows the row
  engine never reaches (rows of a batch beyond a LIMIT, other partitions
  after the failing row). When such an execution fails with a runtime
  error (or an unexpected exception), the query is re-executed row at a
  time on one thread with the same plan options, and its outcome — rows or
  error — is the answer (`polyquery.engine`). Queries are side-effect free,
  so this only costs time on the error path; streaming responses use it
  only before the first row has been sent.

This is checked by the conformance `--modes` matrix, by
`engine_phase5_test` (seven option combinations over ~60 queries on
generated tables with NULLs in every column), by `bench/bench.py --verify`
on the 1M-row datasets, and by the differential fuzzer `bench/fuzz.py`
(random typed expressions, predicates, aggregations, joins and sorts;
thousands of queries without a mismatch).

### Low-level optimizations

* **SIMD-friendly loops.** With the identity selection every kernel runs a
  plain counted loop over primitive arrays; comparisons of a column with a
  constant use one straight-line loop per operator, which C2
  auto-vectorizes. A micro-benchmark (1,024-element `long` comparison,
  JDK 27) measured 0.18 ns/element for these loops versus 0.16 ns/element
  with the explicit Vector API (`jdk.incubator.vector`) and 0.48
  ns/element for a table-driven loop; explicit SIMD was therefore not
  adopted — it would require an incubator module (flags at compile and run
  time, a startup warning) for a ~10% gain on a step that is not the
  bottleneck of any measured query.
* **JIT-friendly code size.** HotSpot does not compile methods over 8,000
  bytes of bytecode. Kernels are split into one small function per
  operator and comparison outcomes go through a 3-entry lookup table
  instead of a `case` on operator strings (a Clojure `case` on strings
  costs ~7 KB of bytecode); this alone made filters 6× faster.
* **Memory: per-scan buffer arena.** A vectorized scan reuses one set of
  column arrays for all its batches (consumers never retain a scan batch:
  rows, aggregate states and hash tables copy what they keep), removing
  per-batch allocation and zeroing (`PQ_SCAN_ARENA=0` disables it).
* **Cache-aware layouts.** Group tables and the join table for a single
  integer-like key use open addressing over parallel primitive arrays
  (`long[]` keys, `int[]` ids; linear probing, power-of-two capacity), join
  matches are chained through `int[]` arrays — no per-entry objects or
  boxing; aggregate states are column-wise arrays; sort keys are extracted
  into contiguous primitive arrays before sorting.

### Measurements

Setup: 32-core x86-64 machine, OpenJDK 27, `POLYQUERY_JAVA_OPTS=-Xmx24g`,
datasets from `pqgen.py generate --scale 1m` (transactions, order_items,
sensor_readings, sort_keys: 1M rows; orders 250K; customers 100K; products
20K), loaded as CSV with their schemas (column layout). `bench/bench.py`:
one session, every query 3× warm-up then the median of 9 runs, wall clock
measured by the client (including the protocol round trip), `result:
count` (no row serialization). Queries:

| id | query |
|---|---|
| Q1 | `SELECT COUNT(*) FROM tx WHERE amount > 500 AND status = 'approved'` |
| Q2 | `SELECT category, COUNT(*), SUM(amount), AVG(fee), MIN(ts), MAX(ts) FROM tx GROUP BY category` |
| Q3 | `SELECT customer_id, SUM(amount), COUNT(*) FROM tx GROUP BY customer_id` (80K groups) |
| Q4 | `SELECT tx_id, amount * 2 + fee, bucket % 7 FROM tx WHERE bucket < 200 AND NOT is_fraud` (200K rows) |
| Q5 | `SELECT c.segment, COUNT(*), SUM(t.amount) FROM tx t JOIN cust c ON c.customer_id = t.customer_id GROUP BY c.segment` |
| Q6 | `SELECT o.status, SUM(i.quantity), COUNT(*) FROM items i JOIN orders o ON o.order_id = i.order_id GROUP BY o.status` |
| Q7 | `SELECT tx_id, amount FROM tx ORDER BY amount DESC, tx_id LIMIT 10` |
| Q8 | `SELECT id, uniq_key FROM sk ORDER BY uniq_key` (1M rows) |
| Q9 | `SELECT sensor_id, AVG(temperature), MAX(humidity), COUNT(*) FROM sensor WHERE status = 'ok' GROUP BY sensor_id` |
| Q10 | `SELECT COUNT(*), SUM(i.quantity) FROM items i, products p, orders o WHERE o.order_id = i.order_id AND p.product_id = i.product_id AND p.category = 'books'` |
| Q11 | `SELECT currency, SUM(CASE WHEN status = 'approved' THEN amount ELSE 0 END), COUNT(*) FROM tx WHERE category LIKE 'g%' OR category IN ('travel', 'utilities') GROUP BY currency` |
| Q12 | Q10 with `FROM orders o, products p, items i` (the FROM order starts with a cross product) |

**Before / after (default options).** "Before" is the accepted Phase 4
engine (commit `a091351`: row-at-a-time, single-threaded, predicate
pushdown only); "after" is this engine with default options (`mode: auto`
= vectorized, 8 threads, all optimizations):

| query | before | after | speed-up |
|---|---:|---:|---:|
| Q1 filter + count | 23 ms | 3 ms | 7.7× |
| Q2 group by, 20 groups | 49 ms | 3 ms | 16× |
| Q3 group by, 80K groups | 87 ms | 14 ms | 6.2× |
| Q4 projection + filter | 47 ms | 6 ms | 7.8× |
| Q5 join 1M × 100K + group by | 82 ms | 10 ms | 8.2× |
| Q6 join 1M × 250K + group by | 50 ms | 15 ms | 3.3× |
| Q7 top-10 of 1M | 776 ms | 3 ms | 259× |
| Q8 full sort of 1M rows | 686 ms | 48 ms | 14× |
| Q9 filter + group by | 52 ms | 3 ms | 17× |
| Q10 3-way join | 44 ms | 15 ms | 2.9× |
| Q11 CASE/LIKE/IN + group by | 86 ms | 5 ms | 17× |
| Q12 3-way join, bad FROM order | fails (`RESOURCE_LIMIT`: cross product > 100M rows) | 32 ms | — |

**By option (this engine).** `baseline` = `{"mode":"row","threads":1,
"optimize":false}`; `row` = `{"mode":"row","threads":1}`; `vec1` =
`{"mode":"vectorized","threads":1}`; `vec8` = `{"mode":"vectorized",
"threads":8}`; `merge8` = vec8 with `"join":"merge"`:

| query | baseline | row | vec1 | vec8 | merge8 |
|---|---:|---:|---:|---:|---:|
| Q1 | 22 ms | 22 ms | 8 ms | 2 ms | 2 ms |
| Q2 | 48 ms | 47 ms | 12 ms | 3 ms | 2 ms |
| Q3 | 77 ms | 76 ms | 14 ms | 13 ms | 13 ms |
| Q4 | 45 ms | 45 ms | 18 ms | 6 ms | 5 ms |
| Q5 | 79 ms | 75 ms | 31 ms | 10 ms | 229 ms |
| Q6 | 51 ms | 50 ms | 30 ms | 15 ms | 104 ms |
| Q7 | 300 ms | 25 ms | 11 ms | 3 ms | 3 ms |
| Q8 | 311 ms | 322 ms | 44 ms | 49 ms | 48 ms |
| Q9 | 54 ms | 55 ms | 11 ms | 2 ms | 2 ms |
| Q10 | fails (cross product) | 43 ms | 28 ms | 14 ms | 130 ms |
| Q11 | 83 ms | 82 ms | 20 ms | 4 ms | 3 ms |

Reading the table: vectorization alone (row → vec1) gives 2.5–7× on
scans, filters and aggregations; parallelism (vec1 → vec8) another 2–5×
where the work is a scan pipeline (Q3 is dominated by its 80K-group merge,
Q8 by the single sort). The optimizer is what makes Q10/Q12 run at all
(pushdown turns the comma joins into hash joins, reordering avoids the
cross product) and top-N turns Q7's full sort into a 10-row heap
(baseline → row). The sort-merge join is the slowest join algorithm here
(row-at-a-time, both sides materialized and sorted; integer keys are radix
sorted); hash join is the automatic choice.

**Individual optimizations** (measured while developing, same setup;
before → after the change):

| change | query / config | before | after |
|---|---|---:|---:|
| kernels split below HotSpot's 8,000-byte compilation limit | Q1 vec1 | 77 ms | 11 ms |
| comparator without per-comparison allocation | Q8 vec1 | 626 ms | 300 ms |
| primitive-column sort (radix sort) | Q8 vec1 | 300 ms | 52 ms |
| merge of partial aggregates with a group-id mapping | Q3 vec8 | 47 ms | 16 ms |
| vectorized join probe + primitive join table | Q5 vec1 | 63 ms | 33 ms |
| per-scan buffer arena (`PQ_SCAN_ARENA=0` → default) | Q4 vec8 | 7 ms | 5 ms |
| per-scan buffer arena | Q9 vec8 | 6 ms | 4 ms |

Results are identical across all configurations: `bench/bench.py --verify`
compares the full results of every query under every configuration above
(sorted unless ordered, FLOAT64 to 6 significant digits) — all match
(Q10's baseline fails with `RESOURCE_LIMIT` instead).

## Native kernels (M9)

`libpqkernels` (`native-kernels/`, C ABI `include/pq_kernels.h` v1: C
reference, runtime CPU dispatch, x86-64 scalar/AVX2/AVX-512 and AArch64
assembly) is integrated as an optional accelerator of the vectorized
engine. Results with and without it are identical; it is only used when
the engine was started with `--native-kernels PATH` **and** a query runs
with `"native": true` in a vectorized plan (`mode: vectorized`, or `auto`,
the default). Row mode — the baseline — never uses it.

### FFI design

* **Loading** (`polyquery.native.ffi/load!`, called by `polyquery.main` when
  `--native-kernels` is given, in every CLI mode): the library is opened
  with `SymbolLookup.libraryLookup` in the global arena,
  `pqk_abi_version()` must return 1, then `pqk_init()` selects the variant
  (honouring `PQ_KERNELS_VARIANT`). The variant and the available variants
  are logged (stderr) and reported in `version` under
  `build.native_kernels`. A missing/unloadable file, a wrong ABI version
  or a big-endian platform produce a warning and the engine continues on
  its own code paths — the library is never required. `native.kernels` is
  always claimed: with no library, `native: true` simply runs the Java
  kernels (identical results). The launcher passes
  `--enable-native-access=ALL-UNNAMED` (the FFM linker is a restricted
  API), so the JVM prints no warning.
* **Binding.** Each of the 16 C functions becomes a downcall method handle
  (`Linker.nativeLinker().downcallHandle`). Clojure cannot call a method
  handle's signature-polymorphic `invokeExact`, and `invokeWithArguments`
  boxes every argument; so each handle is wrapped by
  `MethodHandleProxies.asInterfaceInstance` into an instance of a
  one-method interface declared with `definterface` in the C signature's
  primitive types (`size_t`→`long`, `int`→`int`, pointers→`MemorySegment`).
  The call wrappers (`ffi/filter-i64`, `ffi/group-sum-i64`, …) are macros
  so every call site compiles to a direct, reflection-free interface call
  with primitive arguments (Clojure fns take at most 4 primitive args).
* **Zero-copy.** The kernels are bound as *critical* downcalls
  (`Linker.Option.critical(true)`: short, non-blocking, no upcalls), which
  allows passing Java arrays as heap segments (`MemorySegment.ofArray`):
  the C code reads the batch's `long[]`/`int[]` vectors and writes the
  engine's arrays in place; nothing is copied to or from native memory and
  nothing is allocated off-heap. Bitmaps are kept as `long[]` words, whose
  bytes on a little-endian machine are exactly the ABI's LSB-first byte
  bitmaps. Measured overhead: one `pqk_filter_i64` call over 1,024 rows
  takes ~95 ns including the downcall, versus ~310 ns for the equivalent
  Java compaction loop.
* **Batches ↔ bitmaps** (`polyquery.native.bits`). The vectorized engine
  keeps `boolean[]` null masks and `int[]` selection vectors (Phase 5);
  kernels run over the batch positions `[0, span)` (span = last selected
  position + 1), with validity bitmaps built from the null masks (or a
  NULL pointer when a full batch has no NULLs), and results are restricted
  to the selection by AND-ing with a selection bitmap. Values at
  unselected positions are harmless (no kernel can fail). Scratch bitmaps
  are per thread (`ThreadLocal`) or per operator; kernels are thread-safe
  after `pqk_init`, so parallel partitions call them concurrently.

### Which kernels are used where

| kernel | used for | namespace |
|---|---|---|
| `pqk_filter_i64` | a WHERE / join residual whose native part is one integer-like column vs constant comparison, on a full batch without NULLs: writes the new selection vector directly | `exec.native` |
| `pqk_filter_i64_bitmap` | every column/constant leaf of a native predicate: `= <> < <= > >=`, `BETWEEN` (`PQK_BETWEEN`), `NOT BETWEEN` (`<` OR `>`), each item of an `IN` list (≤ 16 constants; `NOT IN` = AND of `<>`), with the column's validity | `exec.native` |
| `pqk_compare_i64` | integer-like column vs column comparisons (same domain), AND-ed with both validities | `exec.native` |
| `pqk_bitmap_and` / `_or` / `_andnot` | combining leaves (AND/OR, NOT pushed down to the leaves at compile time), validity of column comparisons and BOOLEAN columns, `IS NULL` (all `andnot` valid), restricting to the batch selection | `exec.native` |
| `pqk_bitmap_popcount` | number of non-NULL values of a batch for SUM/AVG without GROUP BY | `exec.grouping` |
| `pqk_sum_i64` | SUM/AVG of INT64/DECIMAL without GROUP BY: exact 128-bit batch sum; `PQK_OVERFLOW` ⇒ the batch goes through the exact Java path | `exec.grouping` (`LongSumState`) |
| `pqk_group_sum_i64` | grouped SUM/AVG of INT64/DECIMAL (sums and counts per group id); `PQK_OVERFLOW` ⇒ the batch is undone and recomputed exactly (below) | `exec.grouping` (`LongSumState`) |
| `pqk_minmax_i64` | MIN/MAX of INT64/DECIMAL/DATE/TIMESTAMP without GROUP BY | `exec.grouping` (`LongExtremeState`) |
| `pqk_minmax_f64` | MIN/MAX of FLOAT64 without GROUP BY (zero results are left to Java, see below) | `exec.grouping` (`DoubleExtremeState`) |
| `pqk_hash_i64` | hashing a whole batch of single integer-like GROUP BY keys and hash-join probe keys; the tables then use fmix64 (also computed in Java for single lookups and rehashing) | `exec.grouping` (`LongKeyTable`), `exec.vjoin` |
| `pqk_gather_i64` | gathering integer-like probe-side columns into hash-join output batches | `exec.vjoin` |

Not used, deliberately:
* `pqk_sum_f64` — its lane-wise reassociation changes FLOAT64 sums in the
  last bits, and results must be *identical* with and without the library.
* `pqk_count_i64` — a filter must produce the selection anyway (the
  aggregate above it counts it); there is no operator that only counts.
* `pqk_compare_fixed` — the engine has no fixed-width byte records: strings
  are Java strings (compared by code point), sort keys are primitive
  columns.

Not covered by kernels (Java as before): FLOAT64 and STRING predicates
(string equality on dictionary columns is already one lookup per
dictionary entry), arithmetic, grouped MIN/MAX, COUNT, FLOAT64 SUM/AVG,
multi-column keys, sorting.

### Identical results

* **Filters.** A predicate is split into conjuncts; the native ones are
  evaluated as one bitmap, the others by the Java kernels on the rows the
  native part kept. Constants are converted to the column's domain with
  exactly the rules of the Java kernels (DECIMAL constants rescaled to
  the column's scale only when exact; DATE vs TIMESTAMP, scale-reducing or
  FLOAT64 comparisons stay in Java). NOT is pushed to the leaves (De
  Morgan, inverted operators, `NOT BETWEEN` → `<` OR `>`), which is exact
  in three-valued logic since only TRUE rows survive a filter; `x NOT IN
  (…, NULL)` is never TRUE. Native leaves cannot fail, and when a
  remaining conjunct could fail (division, casts, subqueries, …) the
  whole predicate stays in Java — the row engine evaluates a conjunct on
  rows where earlier ones are NULL, so this keeps runtime errors exactly
  those of the baseline.
* **Integer overflow flags are honoured exactly.** `pqk_sum_i64` is exact;
  on `PQK_OVERFLOW` the batch is fed to the Java state, which promotes the
  group to `BigInteger` (the final SUM raises `NUMERIC_OVERFLOW` only if
  the exact total does not fit, as without the library). When
  `pqk_group_sum_i64` returns `PQK_OVERFLOW` ("may have wrapped"), the
  sums/counts it accumulated with wrapping arithmetic are undone by
  subtracting the same values (two's-complement addition is exactly
  invertible) and the batch is recomputed by the Java code; groups already
  in `BigInteger` mode bypass the kernel. `PQK_EINVAL` falls back too.
* **MIN/MAX of FLOAT64.** `0.0` and `-0.0` compare equal, so which one a
  vectorized min/max returns depends on evaluation order; batches whose
  result is a zero are recomputed by the Java loop (same first-seen rule
  as without the library).
* **Hashing** only decides slot positions: group ids are assigned in order
  of first appearance and join matches are chained in build order, so
  results do not depend on the hash function.
* **Verification:** the conformance suite with `--native` (session, HTTP
  and `--modes`, also under `PQ_STRICT_EXECUTION=1`, which disables the
  row-mode re-execution so no native defect can hide behind it);
  `native_test` (bitmap helpers, every binding against a Java
  implementation, the ~60-query Phase 5 matrix and integer-overflow tables
  — wrapping intermediate sums, overflowing totals, NULLs — under four
  native configurations); `bench/fuzz.py --native` (random predicates,
  aggregates and joins over 2,000-row generated tables; 1,600 queries ×
  10 configurations with each of
  `PQ_KERNELS_VARIANT=reference|scalar|avx2|avx512`, no mismatch); and
  `bench/bench.py --native … --verify` on the 1M-row datasets (17 queries,
  identical digests across 9 configurations).

### Measurements

Setup: 32-core x86-64 (Zen 5, `x86_avx512` selected by default), OpenJDK
27, datasets from `pqgen.py generate --scale 1m` loaded as CSV with their
schemas. The host was shared with other jobs (load average ~10), so the
before/after numbers come from an *interleaved* A/B run: one engine
process, every query executed alternately with and without `native: true`
(10 warm-up pairs, then 40 measured pairs), median latency of the
`query` request (`result: count`). Q1–Q12 are the Phase 5 queries; Q13–Q17
were added to exercise the native paths:

| id | query |
|---|---|
| Q13 | `SELECT COUNT(*), SUM(amount), MIN(ts), MAX(ts) FROM tx WHERE bucket BETWEEN 100 AND 400 AND merchant_id <> 7 AND ts >= TIMESTAMP '2024-03-01 00:00:00'` |
| Q14 | `SELECT SUM(amount), SUM(fee), AVG(bucket), MIN(amount), MAX(amount), MIN(tx_id) FROM tx` |
| Q15 | `SELECT COUNT(*), SUM(n50), MAX(n90) FROM nh WHERE n50 IS NOT NULL AND n90 > 100` (nulls_heavy, 1M rows) |
| Q16 | `SELECT merchant_id, SUM(amount), SUM(bucket), COUNT(*) FROM tx WHERE bucket < 500 GROUP BY merchant_id` |
| Q17 | `SELECT COUNT(*), SUM(quantity) FROM items WHERE product_id IN (1, 5, 17, 42, 99, 1000) OR quantity > 9` |

**Before (`native: false`) / after (`native: true`)**, vectorized, median ms:

| query | what runs natively | 1 thread before | after | speed-up | 8 threads before | after | speed-up |
|---|---|---:|---:|---:|---:|---:|---:|
| Q1 filter + count | `amount > 500` (status stays Java) | 10.7 | 4.3 | 2.5× | 2.6 | 2.1 | 1.2× |
| Q2 group by category | grouped SUM/AVG (string key) | 12.3 | 12.6 | 1.0× | 2.2 | 1.9 | 1.2× |
| Q3 group by customer_id (80K groups) | key hashing, group sums | 18.9 | 18.2 | 1.0× | 15.8 | 16.2 | 1.0× |
| Q4 projection + filter | `bucket < 200 AND NOT is_fraud` | 26.5 | 20.2 | 1.3× | 6.1 | 5.2 | 1.2× |
| Q5 join + group | probe hashing, gather, grouped SUM | 41.1 | 43.4 | 0.95× | 11.1 | 11.3 | 1.0× |
| Q6 join 1M × 250K | probe hashing, gather, grouped SUM | 65.7 | 54.4 | 1.2× | 18.4 | 17.9 | 1.0× |
| Q7 top-10 | — | 13.9 | 13.9 | 1.0× | 3.5 | 3.5 | 1.0× |
| Q8 full sort | — | 53.3 | 53.1 | 1.0× | 52.8 | 55.4 | 0.95× |
| Q9 filter + group by sensor_id | key hashing | 13.3 | 13.9 | 0.96× | 2.9 | 3.0 | 0.97× |
| Q10 3-way join | probe hashing, gather, SUM | 35.3 | 37.0 | 0.95× | 14.0 | 14.6 | 0.96× |
| Q11 CASE/LIKE/IN on strings | grouped SUM of the CASE | 23.2 | 23.3 | 1.0× | 4.2 | 4.2 | 1.0× |
| Q13 integer filters + aggregates | whole filter, SUM, MIN/MAX | 28.4 | 6.9 | 4.1× | 3.9 | 1.0 | 3.9× |
| Q14 global sums/min/max | SUM/AVG/MIN/MAX | 12.5 | 8.2 | 1.5× | 2.1 | 1.1 | 1.9× |
| Q15 NULL-heavy filter | `IS NOT NULL AND >`, SUM, MAX | 19.8 | 9.7 | 2.0× | 3.3 | 1.8 | 1.8× |
| Q16 integer-key group by | filter, key hashing, group sums | 13.4 | 10.0 | 1.3× | 6.1 | 5.5 | 1.1× |
| Q17 IN list OR | 6 EQ leaves + GT, OR-ed bitmaps | 28.2 | 4.6 | 6.1× | 4.9 | 1.1 | 4.5× |

(Q12 behaves like Q10.) Reading the table: the kernels pay off where the
Java engine spent its time in integer predicate evaluation and aggregation
— 2–6× on Q1, Q13, Q15, Q17 single-threaded, where the Java path builds a
`boolean[]` per comparison and compacts it, evaluates BETWEEN/IN through
generic code, and checks overflow per row, while the kernels go from the
column straight to a bitmap or selection with AVX-512. With 8 threads the
absolute gains shrink (the scan is split 8 ways) but the ratios on those
queries stay at 2–4.5×. Queries dominated by string work, sorting, hash
table random access (80K groups) or join materialization are unchanged
within noise. Native key hashing is not a win: with the bulk-hashed keys
the tables use fmix64, whose random-like slot distribution has slightly
more collisions on dense sequential integer keys than the engine's own
multiplicative hash (an experiment with fmix64 in both paths made the
native bulk hashing equal or faster) — this costs ~0.4 ms per 1M rows on
Q9/Q10-style queries (≈5%).

**Kernel variants** (same interleaving, variant switched with
`pqk_set_variant` between runs, 1 thread, median ms; "Java" = without the
library):

| query | Java | reference C | x86 scalar | AVX2 | AVX-512 |
|---|---:|---:|---:|---:|---:|
| Q1 | 9.1 | 5.5 | 3.8 | 3.4 | 3.2 |
| Q4 | 19.9 | 14.5 | 13.4 | 13.1 | 13.2 |
| Q13 | 28.5 | 15.5 | 8.9 | 6.2 | 5.8 |
| Q14 | 11.8 | 12.6 | 9.9 | 7.6 | 7.5 |
| Q15 | 18.9 | 9.7 | 8.9 | 8.7 | 8.6 |
| Q16 | 12.0 | 18.4 | 13.0 | 8.8 | 8.3 |
| Q17 | 26.0 | 9.0 | 5.1 | 3.5 | 3.1 |

The portable C reference is already faster than Java for predicates but
slower for exact sums (128-bit accumulation, per-row validity tests) and
grouped sums; the SIMD variants are 1.5–3× faster than the reference.

**End to end through the protocol** (`bench/bench.py … --native LIB
--configs vec1,nvec1,vec8,nvec8`: a `session` process, client-side wall
clock, 11 runs after 8 warm-ups, median of three separate sessions):

| query | vec1 | nvec1 | vec8 | nvec8 |
|---|---:|---:|---:|---:|
| Q1 | 14 ms | 3 ms | 4 ms | 2 ms |
| Q4 | 28 ms | 19 ms | 8 ms | 8 ms |
| Q13 | 31 ms | 7 ms | 5 ms | 2 ms |
| Q14 | 16 ms | 11 ms | 3 ms | 2 ms |
| Q15 | 26 ms | 16 ms | 5 ms | 3 ms |
| Q16 | 16 ms | 13 ms | 8 ms | 7 ms |
| Q17 | 33 ms | 7 ms | 6 ms | 1 ms |

The other queries show no consistent difference (session-to-session
variation on the loaded host was ±20–40% for the join and sort queries);
`--verify` confirmed identical results for all 17 queries in all
configurations.

## Design decisions (where the spec is silent or open)

* **Unsupported features.** `UNION`, `RIGHT`/`FULL` joins answer
  `UNSUPPORTED`.
* **CASE/COALESCE result type.** Types are combined pairwise in order; any two
  DECIMAL types (even identical ones) combine to `DECIMAL(18,max(s1,s2))` as
  semantics.md §13 states, INT64 with DECIMAL(p,s) to `DECIMAL(18,s)`, NULL
  branches are ignored (a single DECIMAL branch keeps its type). DATE and
  TIMESTAMP results do not combine (`TYPE_ERROR`).
* **UPPER/LOWER.** ASCII letters are case-mapped, other characters are
  unchanged. The public conformance suite additionally expects
  `UPPER('abc Ünï') = 'ABC Ünï'` (the ASCII `n` inside the non-ASCII word is
  not mapped), so an ASCII letter enclosed on *both* sides by non-ASCII
  letters is left unchanged. This is the narrowest rule consistent with that
  test; it is the only place where behaviour was derived from a test rather
  than the spec text.
* **Constant arguments.** `ROUND`'s digit count and the unit of
  `DATE_TRUNC`/`DATE_DIFF` must be constant expressions (literals, arithmetic
  on literals) and are folded during validation; non-constant ⇒
  `SEMANTIC_ERROR`, unknown unit (case-insensitive) ⇒ `INVALID_ARGUMENT`,
  NULL ⇒ the call yields NULL. `DATE_DIFF` supports only `'day'`.
* **GROUP BY / ORDER BY resolution.** Exactly as semantics.md §5-§6; aliases
  are not visible in `WHERE`/`HAVING` (only bare GROUP BY / ORDER BY
  identifiers resolve to select aliases). Expressions containing subqueries
  never match GROUP BY expressions structurally.
* **Correlation.** Column references resolve innermost scope first, then
  enclosing queries. When the enclosing query is aggregated, a correlated
  reference must be a GROUP BY column (else `SEMANTIC_ERROR`). Aggregates
  inside a subquery always aggregate over the subquery's rows.
* **EXPLAIN.** The plan JSON uses `TableScan` (with `table`, `alias`,
  `columns` actually read, `layout`, and `skip_predicates` for row-group
  skipping), `IndexScan` (`table`, `index`, `kind`, `columns`, `lookup`),
  `Filter`, `HashJoin` (`join_type`, `build` side, `keys`, `residual`),
  `MergeJoin` (`join_type`, `keys`, `residual`), `NestedLoopJoin`
  (`join_type`, `keys`, `condition`), `HashLookup` (correlated hash lookup
  over its `TableScan` child), `SubqueryScan`, `Aggregate`, `Project`,
  `Distinct`, `Sort`, `TopN` (`keys`, `limit`, `offset`), `Limit`,
  `Gather`, `Values`. Nodes executed in parallel carry `"partitions": N`. The plans of subqueries evaluated by a node are appended to its
  `children` (marked `"subquery": "scalar"|"exists"|"in"`). The `explain` op
  accepts the same SQL as `query` (an `EXPLAIN` prefix is allowed).
* **Column pruning.** Rows keep the full FROM-row width (expressions address
  positions), but scans only read and fill referenced columns. Required
  columns are propagated top-down: outputs of derived tables/CTEs that the
  enclosing query does not use, unused aggregates and the select list of
  `EXISTS` subqueries are replaced by constants, and correlated references
  from subqueries count as references of the enclosing row.
* **Predicate pushdown / row-group skipping.** WHERE conjuncts are pushed to
  the scans (Phase 2 optimizer). Conjuncts of the form `col <op> constant`,
  `col BETWEEN c1 AND c2`, `col IN (constants)`, `col IS [NOT] NULL` (constants
  are folded at planning time) skip PQCF row groups whose `min`/`max`/
  `null_count` exclude them. The complete predicate is always re-evaluated
  on the remaining rows.
* **Index selection.** For the same predicate forms on an indexed column the
  planner estimates selectivity from the index (equality/IN: values /
  distinct; ranges on numeric/temporal columns: linear interpolation between
  the index's min and max, else 1/3; several range bounds on one column are
  combined) and uses the most selective index whose selectivity is ≤ 10%. In
  addition an equality/IN lookup estimated to return at most 16 rows is
  always used (a point lookup of a handful of rows is never more expensive
  than a scan; this makes indexes effective on small tables). HASH indexes
  serve equality/IN when the comparison type has the column's key domain;
  BTREE indexes serve equality, IN and ranges with any comparable constant
  type. `use_indexes: false` disables index scans. The filter above an
  index scan re-checks the whole predicate.
* **Join build side.** Inner hash joins build on the input with the smaller
  estimated cardinality (scans: row count; filters over scans: product of
  per-predicate selectivities from table statistics, 0.5 for other
  conjuncts; joins: max of the inputs; aggregates: 10%); LEFT joins build on
  the right input.
* **Index statements.** `CREATE INDEX` without `USING` creates a BTREE index.
  Unknown table/column ⇒ `SEMANTIC_ERROR`, an existing index name ⇒
  `ALREADY_EXISTS` (no-op with `IF NOT EXISTS`); `DROP INDEX` of an unknown
  name ⇒ `NOT_FOUND` (no-op with `IF EXISTS`).
* **save/open options.** `encoding` other than `auto|plain|dict|rle` ⇒
  `UNSUPPORTED`; `row_group_size` must be an integer ≥ 1. `open` accepts
  `layout`/`dictionary` like `load` (a `row` layout decodes eagerly, so `mmap`
  only applies to the column layout). `open` responds like `load` (`table`,
  `row_count`, `columns`). Index entries in PQCF metadata must name an
  existing column and kind `HASH`/`BTREE` (case-insensitive), otherwise the
  file is `STORAGE_CORRUPT`.
* **CSV whitespace.** For non-STRING columns a field that is empty after
  trimming spaces/tabs is treated like an empty field: it is not considered
  during inference and loads as NULL.
* **CSV structure.** A lone `\r` (not followed by `\n`) is data. Text after a
  closing quote other than a delimiter/record end is an `INGEST_ERROR`; a quote
  inside an unquoted field is literal. A completely empty input with
  `header: true` is an `INGEST_ERROR` (no header).
* **Schemas.** With `header: true` and an explicit schema the reported column
  names are the schema's spellings. An unknown type name in an explicit schema
  is `INVALID_REQUEST`; `header: false` without a schema is `INVALID_REQUEST`.
* **JSON.** A key that collides case-insensitively with another key is an
  `INGEST_ERROR` (duplicate column). A JSON number that is not a finite
  FLOAT64 (e.g. `1e400`) fails conversion (`CONVERSION_ERROR`).
* **CAST from STRING.** All targets trim ASCII spaces/tabs. `TIMESTAMP`
  literals and casts require the time part (date-only text is accepted only by
  ingestion, as the spec says). FLOAT64 → STRING uses Java's shortest
  round-trip text (`1.0`, `1.5E300`).
* **LIMIT/OFFSET.** Must be constant INT64 expressions (`TYPE_ERROR` for other
  types, `SEMANTIC_ERROR` for column references); `NULL` means "no limit".
* **Null type.** Arithmetic on two NULL literals keeps the null type (reported
  as `STRING`); `SUM(NULL)` likewise; `AVG(NULL)` is FLOAT64.
* **Query options.** `mode`: `row` (the baseline), `vectorized`, `auto`
  (default = vectorized). `threads`: workers per query; default the
  `--threads` CLI option, else min(8, CPUs) — except that `mode: row`
  without `threads` runs single-threaded (the baseline). `join`: `hash`,
  `merge` and `nested_loop` force the algorithm of every equi-join (joins
  without an equality between their inputs are always nested loops);
  `auto` (default) is the cost-based choice = hash join building on the
  smaller estimated input. `optimize: false` skips all logical rewrites
  and the top-N rewrite (column pruning stays: it never changes results).
  `native: true` is accepted and ignored (no native kernels are loaded,
  which spec/phases/native-kernels.md allows). Other values of known
  options (including `threads` < 1) are `UNSUPPORTED`, ill-typed values
  `INVALID_REQUEST`.
* **Limits.** Defaults: `--max-ingest-bytes` 4 GiB, `--max-table-rows`
  200,000,000, `--max-query-memory-mb` 4096 (approximate accounting of
  materialised rows in sort/aggregation/result), `--max-join-rows`
  100,000,000 (counted per join operator). `OutOfMemoryError` and stack overflow are
  reported as `RESOURCE_LIMIT`, any other unexpected exception as
  `INTERNAL_ERROR`; the session never dies on a request.
* **Path safety** is lexical (absolute, empty, NUL or `..` component ⇒
  `ACCESS_DENIED`), so symbolic links inside the data directory work.

## Testing

* `make test` — unit tests for the JSON codec, values/casts/calendar, lexer,
  parser, analyzer, planner/optimizer, scalar functions and LIKE, CSV/JSON
  ingestion, the engine pipeline (Phase 1 and Phase 2 features) and the
  protocol.
* Phase 5 unit tests: vectorized kernels (NULL semantics, lazy AND,
  overflow/division errors), group tables and mergeable aggregate states,
  the radix/merge sort (stability, NULL placement, parallel chunks), the
  parallelization planner; and a differential test running ~60 queries
  (every operator, NULLs everywhere, errors, PQCF/mmap row groups, row
  layout) over generated tables larger than a batch and a partition under
  seven option combinations, requiring identical results
  (`engine_phase5_test`). `PQ_STRICT_EXECUTION=1` disables the row-mode
  re-execution after unexpected exceptions, so tests see vectorized
  defects instead of correct fallback results.
* Native kernels (`native_test`; uses
  `../../native-kernels/build/<arch>/libpqkernels.so` or
  `$PQ_NATIVE_KERNELS`, skipped when the library is not built): bitmap
  helpers, every binding against a Java implementation (filters for all
  operators, overflow flags of `sum_i64`/`group_sum_i64`, fmix64, …), the
  Phase 5 differential queries and integer-overflow tables under four
  `native: true` configurations in strict execution, `native: true`
  without a library, and an unloadable library being ignored.
* Storage unit tests: column vectors and layouts, statistics, index lookups,
  PQCF round trips for every encoding/row-group size/mmap, corrupt and
  unsupported files; Phase 3 planning (pruning, index selection, build side).
* Conformance: `python3 tests/conformance/runner.py --engine
  implementations/clojure/bin/polyquery` (add `--transport http` to run the
  same cases through `serve`, `--modes` for the Phase 5 option matrix,
  `--native native-kernels/build/x86_64/libpqkernels.so` to run every
  query with `native: true`), and
  `python3 tests/concurrency/http_suite.py --engine
  implementations/clojure/bin/polyquery`.

## Known limitations

* No explicit SIMD in the Java code (see [Phase 5](#phase-5-optimization)
  for why); SIMD comes from the native kernels with `native: true`.
* Native kernels are used by vectorized operators only (row mode is the
  unmodified baseline); predicates on FLOAT64 and STRING columns, grouped
  MIN/MAX, COUNT and FLOAT64 sums stay on the Java kernels (see
  [Native kernels](#native-kernels-m9) for which kernels are used where
  and why `pqk_sum_f64`, `pqk_count_i64` and `pqk_compare_fixed` are not).
  The native code assumes a little-endian platform (bitmaps are passed as
  `long[]`); on a big-endian JVM the library is not used.
* Vectorized execution covers scans, filters, projections, hash aggregation,
  hash-join probes and sorting; index scans, DISTINCT, LIMIT, sort-merge and
  nested-loop joins and LEFT hash joins with a residual condition run row
  at a time inside vectorized plans (rows ↔ batches are converted at the
  boundaries). Parallelism needs a table scan at the bottom of the
  pipeline; correlated subqueries always run serially.
* Optimizations that evaluate expressions on other rows than the baseline
  (predicate pushdown below joins, vectorized batches beyond a LIMIT) can
  only change *whether* a runtime error occurs in the second case, which
  the row-mode re-execution covers; a WHERE conjunct pushed below a join
  may raise an error (e.g. division by zero) on a row that the unoptimized
  plan would have dropped in the join.
* HTTP: one platform thread per open connection (no NIO multiplexing);
  no TLS, no HTTP/2, no compression. Request bodies are held in memory
  (bounded by `--max-request-bytes`). Loads are not cancellable and do not
  observe timeouts.
* In row mode, rows flowing between operators are boxed `Object[]` tuples
  (typed columnar storage is converted per value at the scan); very large
  inputs need a
  correspondingly large heap (`POLYQUERY_JAVA_OPTS=-Xmx…`). JSON (array)
  inputs are parsed from a single in-memory string.
* Indexes are used for single-table scans only (no index nested-loop joins,
  no index use for `OR`/`NOT IN`/`<>`, no ordered output from BTREE indexes).
* A PQCF chunk must be smaller than 2 GiB (Java buffer limit).
* Correlated subqueries other than equality lookups over a single table scan
  are re-executed per outer row (correct, but O(outer × inner)).
