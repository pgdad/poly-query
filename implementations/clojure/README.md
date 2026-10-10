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
measurements).

Reported capabilities: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic
test.functions phase2 sql.groupby sql.join sql.functions sql.subquery sql.cte
sql.correlated_subquery phase3 storage.pqcf storage.mmap index.hash
index.btree phase4 http.streaming phase5 exec.row exec.vectorized
exec.parallel join.hash join.merge join.nested_loop`.

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

Development tools (Python, not part of the build): `bench/bench.py DATA_DIR`
times a fixed query set on the generated datasets under several option
combinations (`--verify` compares full results instead), `bench/fuzz.py`
is a differential fuzzer of the option matrix (random expressions,
predicates, aggregates, joins, sorts over the generator fixtures).

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
* Storage unit tests: column vectors and layouts, statistics, index lookups,
  PQCF round trips for every encoding/row-group size/mmap, corrupt and
  unsupported files; Phase 3 planning (pruning, index selection, build side).
* Conformance: `python3 tests/conformance/runner.py --engine
  implementations/clojure/bin/polyquery` (add `--transport http` to run the
  same cases through `serve`, `--modes` for the Phase 5 option matrix), and
  `python3 tests/concurrency/http_suite.py --engine
  implementations/clojure/bin/polyquery`.

## Known limitations

* No native kernels (`native: true` is ignored); no explicit SIMD (see
  [Phase 5](#phase-5-optimization) for why).
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
