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
a query runs with `native: true` — see [Native kernels](#native-kernels-m9))
and the **architectural change CR-1 `UNION ALL`** (`spec/changes/union-all.md`
— see [UNION ALL](#change-cr-1-union-all)) and the **refactoring CR-3
logical/physical plan separation** (`spec/changes/refactor-plan-separation.md`
— see [Plan separation](#change-cr-3-logicalphysical-plan-separation)) and
the **architectural change CR-2 `DECIMAL` precision 38 / PQCF v2**
(`spec/changes/decimal38.md` — see [DECIMAL(38)](#change-cr-2-decimal-precision-38))
and the **latency optimization of the analytics workload** (direct JSON
result encoding, precomputed subqueries and semi-joins, primitive DISTINCT
aggregation, parallel merges, DISTINCT as aggregation, per-dictionary
function evaluation, a primitive multi-key group table — see [Latency optimization](#latency-optimization-analytics-workload))
and the **Track B build and start-up tuning** (JDK AOT cache trained on a
synthetic workload, JIT and memory flags, boxing and dispatch removed from
hot loops, a faster ORDER BY — see [Build and start-up tuning](#build-and-start-up-tuning-track-b)).

Reported capabilities: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic
test.functions phase2 sql.groupby sql.join sql.functions sql.subquery sql.cte
sql.correlated_subquery phase3 storage.pqcf storage.mmap index.hash
index.btree phase4 http.streaming phase5 exec.row exec.vectorized
exec.parallel join.hash join.merge join.nested_loop native.kernels
change.union_all change.decimal38`.

## Prerequisites and build

* OpenJDK (tested with 27) — `JAVA_HOME` or `java` on `PATH`
* Clojure CLI (tools.deps) with Clojure 1.12.3 in the local Maven cache
* GNU make

```sh
make build    # AOT-compiles src/ into target/classes, packs target/polyquery.jar,
              # writes target/classpath and trains the JDK AOT cache target/polyquery.aot
make test     # clojure.test unit tests (test/)
make lint     # compiles with *warn-on-reflection* and *unchecked-math* :warn-on-boxed;
              # fails on reflection, boxed-math or performance warnings
make fmt      # whitespace normalisation (no third-party formatter is allowed)
make clean
bin/polyquery session --data-dir DIR    # JSON-lines protocol on stdin/stdout
bin/polyquery serve --port 0 --data-dir DIR [--workers N --queue-depth Q ...]
```

`bin/polyquery` works from any directory; extra JVM flags can be passed via
`POLYQUERY_JAVA_OPTS` (e.g. `-Xmx16g` for very large tables). `--threads N`
sets the default worker threads per query. The launcher uses the AOT cache
when `make build` produced one and ignores a missing, stale or unusable
cache silently (see [Build and start-up tuning](#build-and-start-up-tuning-track-b)).

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
`bench/tuning.py` measures start-up, first-run (cold) and warm latency and
RSS of several engine variants side by side (see
[Build and start-up tuning](#build-and-start-up-tuning-track-b)).

## Libraries

None besides Clojure itself (`org.clojure/clojure 1.12.3`, which pulls in its
own `spec.alpha`/`core.specs.alpha`). Everything else — JSON, CSV, the SQL
front end, decimal and calendar arithmetic — is implemented here on top of
`clojure.core` and the JDK. See `ENGINE.json`.

## Architecture

Every statement goes through distinct, inspectable stages:

```
SQL text ─lexer→ tokens ─parser→ AST ─analyzer/binder→ bound query
        ─logical planner→ logical plan ─column pruning→ ─optimizer rules→ logical plan
        ─physical planner→ physical plan (+ parallelizer, execution mode, native kernels)
        ─dispatcher→ row / vectorized / parallel operators → rows ─protocol→ JSON
```

| Layer | Namespaces | Responsibility |
|---|---|---|
| CLI / protocol | `polyquery.main`, `polyquery.protocol` | argument parsing, session/exec loops, request validation, op dispatch (`handle-op` multimethod), response objects |
| HTTP server (Phase 4) | `polyquery.server`, `polyquery.server.http`, `polyquery.server.admission`, `polyquery.server.metrics` | endpoints and routing, query lifecycle (registry, admission, timeouts, cancellation, streaming), graceful shutdown; HTTP/1.1 wire format; worker limit + FIFO queue; Prometheus exposition |
| Engine pipeline | `polyquery.engine`, `polyquery.result` | drives the stages per statement, EXPLAIN; executes a physical plan as its `:execution` says (precomputing subqueries while planning outside row mode); collects results into sinks — JSON values, or JSON text written directly by per-type encoders (the protocol's path) |
| Lexer | `polyquery.sql.lexer` | tokens with line/column positions, comments, quoted identifiers, reserved words |
| Parser / AST | `polyquery.sql.parser`, `polyquery.sql.ast` | recursive descent over the full v1 grammar producing a plain-map AST |
| Semantic analysis | `polyquery.sql.analyzer` (queries: FROM/CTE/derived-table resolution, `*` expansion, GROUP BY/ORDER BY rules, output names), `polyquery.sql.binder` (expressions: name resolution incl. correlation, typing, coercions, aggregates), `polyquery.sql.functions` (scalar function signatures), `polyquery.sql.bound` (bound-expression shapes and helpers) | produces a *bound query*: typed expressions whose column references are row indices |
| Planning pipeline | `polyquery.plan.planner` | bound query → logical plan → column pruning → optimizer → physical plan |
| Logical planning | `polyquery.plan.logical` | the logical plan data structure: relational operator tree values/scan/derived/join → filter → aggregate → filter (HAVING) → project → distinct → sort → limit → project, union-all; subquery expressions carry their logical plans; generic traversal; debug rendering (`format-plan`) |
| Optimization | `polyquery.plan.optimizer` (rule registry), `polyquery.plan.rules.{constant-folding,predicate-pushdown,join-reordering,column-pruning}`, `polyquery.plan.cost` | named logical rewrite rules: constant folding and predicate simplification, predicate pushdown into join inputs and below renaming projections (WHERE equalities of comma joins become join conditions), join reordering of inner-join chains, column pruning (`optimize: false` applies no rule; column pruning is also applied before the optimizer, see [CR-3](#change-cr-3-logicalphysical-plan-separation)); cardinality estimates |
| Physical planning | `polyquery.plan.physical`, `polyquery.plan.parallel`, `polyquery.plan.access`, `polyquery.plan.explain` | access paths (index selection, row-group skip predicates), join algorithm (`join` option) and hash-join build side (cardinality estimates), top-N for ORDER BY … LIMIT, hash lookup for correlated equality predicates, execution mode / threads / native kernels, parallelization (partitioned aggregation/sort, Gather), physical plans of subqueries; EXPLAIN JSON |
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
since 1970-01-01, `TIMESTAMP` → `Long` microseconds, `DECIMAL(p,s)` → the
unscaled value (the scale is static, carried by the type): a `Long` for
*narrow* decimals (p ≤ 18) and a `java.math.BigInteger` for *wide* ones
(19 ≤ p ≤ 38, see [CR-2](#change-cr-2-decimal-precision-38)). Decimal
arithmetic is exact: long fast paths with `BigInteger` fallbacks wherever an
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
* **PQCF writer**: a table with a wide DECIMAL column is written as PQCF v2
  (128-bit values), every other table as v1 (see
  [CR-2](#change-cr-2-decimal-precision-38)). Chunks are written column by
  column, 8-byte aligned;
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
* **Logical optimizer** (`optimize`, `polyquery.plan.optimizer`, rules in
  `polyquery.plan.rules.*`): constant
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

## Latency optimization (analytics workload)

Task: lower the query latency of the analytics workload at scale 1m while
keeping every result identical.

**The workload.** The task names `benchmarks/workloads/analytics.json`, but
that file is not in the workspace (there is no `benchmarks/` directory).
Only `implementations/clojure/` may be changed, so a stand-in was written:
[`bench/workloads/analytics.json`](bench/workloads/analytics.json). It has 30
queries over the pqgen 1m tables (`transactions` 1M rows, `order_items` 1M,
`sensor_readings` 1M, `sort_keys` 1M, `nulls_heavy` 1M, `orders` 250K,
`customers` 100K, `products` 20K). They cover the usual analytics shapes:
selective filters, low- and high-cardinality GROUP BY, joins of 2–4 tables,
top-N, a full sort, COUNT DISTINCT, HAVING, CTEs, derived tables,
uncorrelated IN/scalar subqueries, a correlated EXISTS, SELECT DISTINCT,
date/string functions, and queries returning 68K–1M rows. If the real file
turns up, `bench/workload.py --workload FILE` runs it unchanged, as long as
it uses the same `{"tables": {alias: table}, "queries": [{"id", "name",
"sql"}]}` layout.

**Methodology.** `bench/workload.py DATA_DIR --baseline OLD_LAUNCHER` starts
two `bin/polyquery session` processes, one per engine, both with
`POLYQUERY_JAVA_OPTS=-Xmx24g`. Each process loads the CSV tables with their
schemas. Then, for every query, the runs of the two engines alternate
(old, new, old, new, …): 3 warm-ups, then the median of 9 runs each. The
time is the wall clock measured by the client for a default `query` request
(full `rows` result, default options): planning, execution, JSON
serialization, the pipe, and the client's `json.loads`. Alternating the runs
matters because the machine is shared: other processes kept the load
average around 9, so single runs vary by ±30%. "Before" is the baseline
commit `0de2185`, built in a separate git worktree; "after" is this
commit. Setup: 32-core x86-64, OpenJDK 27, data from `pqgen.py generate
--scale 1m`.

**Before / after** (median latency in ms per workload query, default
options, full results; `bench/workload.py /tmp/pq1m/1m --baseline
<baseline>/bin/polyquery`):

| id | query | rows | before | after | speed-up |
|---|---|---:|---:|---:|---:|
| A1 | filter + count | 1 | 3.2 ms | 3.1 ms | 1.0x |
| A2 | group by, low cardinality | 20 | 6.2 ms | 6.5 ms | 1.0x |
| A3 | group by, 80K groups | 80777 | 44.7 ms | 35.0 ms | 1.3x |
| A4 | projection + filter, 200K rows | 199765 | 84.0 ms | 53.9 ms | 1.6x |
| A5 | join 1M x 100K + group by | 4 | 12.4 ms | 12.5 ms | 1.0x |
| A6 | join 1M x 250K + group by | 6 | 17.6 ms | 19.3 ms | 0.9x |
| A7 | top-N | 10 | 5.3 ms | 5.6 ms | 0.9x |
| A8 | full sort, 1M rows | 1000000 | 523.9 ms | 440.8 ms | 1.2x |
| A9 | filter + group by (sensor) | 1000 | 4.6 ms | 4.8 ms | 0.9x |
| A10 | 3-way join, comma syntax | 1 | 21.2 ms | 21.8 ms | 1.0x |
| A11 | CASE / LIKE / IN + group by | 5 | 8.0 ms | 9.0 ms | 0.9x |
| A12 | integer filters + global aggregates | 1 | 5.7 ms | 5.5 ms | 1.0x |
| A13 | NULL-heavy filter | 1 | 4.3 ms | 4.1 ms | 1.0x |
| A14 | COUNT DISTINCT | 20 | 118.9 ms | 29.4 ms | 4.1x |
| A15 | group by + HAVING + ORDER BY aggregate + LIMIT | 20 | 5.4 ms | 4.8 ms | 1.1x |
| A16 | date functions + group by | 24 | 13.0 ms | 8.4 ms | 1.6x |
| A17 | DATE_TRUNC group by | 144 | 4.3 ms | 3.5 ms | 1.2x |
| A18 | multi-key group by | 400 | 8.5 ms | 7.0 ms | 1.2x |
| A19 | LEFT JOIN + COUNT | 30 | 18.5 ms | 19.8 ms | 0.9x |
| A20 | IN subquery | 1 | 53.3 ms | 4.9 ms | 10.8x |
| A21 | CTE + join of aggregates | 4 | 27.2 ms | 29.3 ms | 0.9x |
| A22 | 4-way join + group by + top-N | 10 | 22.0 ms | 23.2 ms | 0.9x |
| A23 | string functions + group by | 20 | 23.0 ms | 22.4 ms | 1.0x |
| A24 | derived table + filter on aggregate | 1 | 33.0 ms | 27.6 ms | 1.2x |
| A25 | scalar subquery comparison | 1 | 43.9 ms | 4.7 ms | 9.4x |
| A26 | DISTINCT | 20 | 22.4 ms | 3.0 ms | 7.4x |
| A27 | top-N on string key | 25 | 1.5 ms | 1.5 ms | 1.0x |
| A28 | EXISTS (correlated) | 1 | 263.6 ms | 6.0 ms | 43.7x |
| A29 | wide result, 100K rows | 68226 | 77.9 ms | 44.3 ms | 1.8x |
| A30 | sensor time buckets | 100 | 16.0 ms | 12.7 ms | 1.3x |
| | **total** | | **1494 ms** | **874 ms** | **1.7x** |

How to read the table:
* Rows within about ±10% are noise. Repeat runs of single queries with 15
  runs each confirmed A5–A7, A9–A11, A19, A21 and A22 at 1.0× (±0.1). A8
  ranged from 1.2× to 1.4× across full runs.
* The large wins come from removing serial row-at-a-time work: A28 44×,
  A20 11×, A25 9×, A26 7×, A14 4×.
* Big results gain 1.3–1.8× from the direct JSON encoding (A3, A4, A8,
  A29). What remains for them is mostly the client's own JSON parsing.
* Multi-key GROUP BYs gain 1.2–1.6× from the primitive key-tuple table
  (A16–A18, A30).
* Queries that were already vectorized and parallel are unchanged within
  noise.

The A8 ceiling is the client: on its 28.8 MB response, Python's `json.loads`
alone takes ~170 ms and reading the pipe ~30 ms.

**Correctness.** `bench/workload.py DATA_DIR --digest FILE` stores a digest
of every query's complete result (column names and types, rows; sorted
unless the query has ORDER BY; FLOAT64 to 9 significant digits).
`--check FILE` compares against it. The digests of the baseline and of
every optimization step are identical. The conformance suite (660/660) and
the Phase 5 option matrix (`--modes`, 3870/3870) still pass. The unit test
`engine_phase5_test` gained ~45 queries for the new paths, each run under
seven option combinations and compared with row mode. These cover IN/NOT
IN with NULLs and empty subqueries, mixed numeric/date key types, EXISTS
with NULL keys, LIMIT 0, a failing projection or residual, deferred
cardinality and division errors, DISTINCT aggregates of every kind, and
SELECT DISTINCT. `result_test` checks that the direct JSON encoder matches
the generic writer for every type and edge value.

### What changed

1. **Results are encoded straight to JSON text** (`polyquery.result`).
   Before, every result value was first converted to a JSON value (a
   string for DECIMAL/DATE/TIMESTAMP, built with `str`/`format`) inside a
   new `Object[]` per row. The response map was then serialized into one
   string, which was copied again through a `BufferedWriter` → UTF-8
   encoder → `System.out`. Now the protocol collects rows into a *sink*.
   The JSON-text sink appends each value to a single `StringBuilder`
   through an encoder specialized for the column's type. Dates,
   timestamps and narrow decimals are formatted digit by digit, with no
   intermediate strings, and strings that need no escaping are appended
   whole. The response embeds the text as `json/raw`, and session/exec
   write it as UTF-8 bytes with one `write` to stdout. The engine API (tests,
   HTTP streaming) still gets JSON values through the `:values` sink. The
   calendar helpers (`year-of-days`, …) are also allocation-free now, which
   helps `YEAR`/`MONTH`/`DAY`/`DATE_TRUNC`. Gains: A4, A8, A29, A3.
2. **Uncorrelated subqueries are evaluated once, while planning**
   (`physical/plan-expr`, `engine/execution-plan`). Before, a Filter
   containing a subquery could be neither vectorized nor parallelized: the
   whole 1M-row pipeline ran row at a time on one thread, even though the
   subquery's value was memoized. Now, outside row mode, the physical
   planner executes each uncorrelated subquery's plan (vectorized,
   parallel) and replaces the expression. A scalar subquery becomes a
   literal. EXISTS becomes TRUE/FALSE. `x [NOT] IN (subquery)` becomes the
   new bound node `:in-set`, which holds the precomputed hash keys and a
   has-NULL flag and implements IN's three-valued logic exactly. The
   expression is then an ordinary vectorizable, partitionable predicate.
   Error semantics are kept:
   * a scalar subquery with more than one row is left in place, so
     `SUBQUERY_CARDINALITY` is raised only if a row actually evaluates it;
   * if precomputing fails in any way the fallback covers (runtime error,
     resource limit), the query is planned again without precomputation,
     and its outcome comes from regular execution;
   * row mode (the baseline) never precomputes.

   Gains: A20, A25.
3. **Correlated EXISTS semi-joins become key sets.** A correlated EXISTS
   qualifies when its plan projects plain columns or literals from a hash
   lookup with one equality key, its probe reads only the enclosing row,
   and its residual is uncorrelated. Most EXISTS subqueries look like
   this. EXISTS is then true exactly when the probe value is among the keys
   of the inner rows that satisfy the residual. Those keys are computed
   once by a parallel filtered scan, and the subquery becomes an `:in-set`
   with `:exists?` semantics (a NULL probe gives FALSE, never NULL, so NOT
   EXISTS stays correct). Before, the subquery was re-run once per outer
   row, serially. Gain: A28.
4. **DISTINCT aggregates over integer-like values** (INT64, DATE,
   TIMESTAMP, narrow DECIMAL) use one primitive open-addressing `long` set
   per group (`grouping/DistinctLongState`). Before, they used a boxed
   `HashSet` per group, and merging those sets across parallel partitions
   (`addAll` of boxed sets) was the bottleneck. COUNT reads the set size.
   SUM/AVG/MIN/MAX feed the sorted values to the ordinary accumulator, so
   the arithmetic is exact as before. Gain: A14.
5. **Partial aggregates are merged pairwise in parallel**
   (`parallel/merge-tree`). The merge appends the later partition's new
   groups and is associative, so groups keep their serial order of first
   appearance. Gains: A3, A14, A21, A24.
6. **SELECT DISTINCT is planned as a hash aggregation** that groups by all
   projected columns and computes no aggregates. Outside row mode, this
   replaces the row-at-a-time DISTINCT operator. It returns the same rows
   (NULLs equal, first appearance order) and is vectorized and parallel.
   Gain: A26.
7. **Function calls on dictionary-encoded strings run once per dictionary
   entry.** This applies to calls whose only non-constant argument is a
   STRING (`UPPER(SUBSTR(category, 1, 3))`, `LENGTH(currency)`,
   `REPLACE(s, 'a', 'b')`, …). The result is cached per dictionary. A
   STRING result stays dictionary-encoded, so a GROUP BY on it keeps the
   per-dictionary code → group fast path. This holds only when no entry,
   and no NULL input, maps to NULL; `CONCAT` and `NULLIF` are handled
   correctly. For A23 the gain is within noise: most of its time goes to the
   two-key GROUP BY and to computing two string functions per batch.
8. **A primitive multi-key group table** (`grouping/MultiKeyTable`) for
   GROUP BY on 2–30 keys. Each key value becomes a long code: the value
   for integer-like keys, the normalized bits for FLOAT64, 0/1 for
   BOOLEAN, or an interned id for strings and wide decimals (dictionary
   codes are mapped once per dictionary). Groups are found by open
   addressing over the code tuples, which are stored in one `long[]`, plus
   a NULL bitmask per group. Before, every row allocated an `Object[]`
   and a key list for a `HashMap` lookup. Group order (first appearance)
   and key values (`-0.0` = `0.0`, NULLs grouped) are unchanged. Gains:
   A16, A17, A18, A30.

Not done (candidates, in order of expected gain):
* **Columnar sort output.** A8 materializes rows before sorting and then
  visits them in sorted order, which is a cache miss per row: in-process,
  JSON encoding of the sorted 1M rows costs ~150 ms against ~35 ms
  unsorted.
* **Radix-partitioned aggregation for high-cardinality GROUP BY** (A3,
  A21, A24). Every partition currently builds a table with nearly all
  groups.
* **Decorrelating correlated scalar subqueries** into grouped joins.

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

## Change CR-1: UNION ALL

`core UNION ALL core …` with ORDER BY/LIMIT/OFFSET over the whole compound,
allowed wherever a query is (top level, CTE bodies, derived tables, scalar /
`IN` / `EXISTS` subqueries, EXPLAIN), consistently under every execution
option. The change follows the existing layer boundaries; the modules
touched are:

| layer | module | change |
|---|---|---|
| AST / parser | `sql/ast.clj`, `sql/parser.clj` | a query keeps its first select core in `:select` and the following ones in `:union-all`; `UNION` without `ALL` (also `UNION DISTINCT`) ⇒ `UNSUPPORTED`; a branch is a plain select core, so a parenthesized branch or a branch with its own ORDER BY/LIMIT is a `PARSE_ERROR` |
| semantic analysis | `sql/analyzer.clj` | each branch is analyzed as a SELECT in the same environment (CTEs, enclosing queries for correlation); column-count check (`SEMANTIC_ERROR`); per-column common type with the CASE rule (`types/common-type`, `TYPE_ERROR` otherwise); each branch's outputs are wrapped in the implicit conversion to the column type (an INT64 that does not fit DECIMAL(18,s) ⇒ `NUMERIC_OVERFLOW` at execution); ORDER BY items must be output names of the first branch or positions. Result: a *bound compound query* `{:union [bound-query …] :order-by :limit :offset :columns}` |
| logical plan | `plan/logical.clj` | new node `{:op :union-all :inputs [P …]}` under the shared sort/limit construction |
| optimizer | `plan/optimizer.clj`, `plan/pruning.clj`, `plan/cost.clj` | branches are optimized as independent queries (like derived tables); column pruning passes the required output positions to every branch; the cardinality estimate is the sum of the branches |
| physical plan | `plan/physical.clj`, `plan/parallel.clj` | `:union-all` physical node; ORDER BY … LIMIT over it becomes a TopN; with `threads` > 1 each branch is parallelized on its own (e.g. a Gather per branch) |
| execution | `exec/operators.clj` | `:union-all` concatenates the branch re-reducibles (`eduction cat`, which stops early under LIMIT). Branches are built through the dispatcher, so each runs row-wise, vectorized, parallel and/or with native kernels exactly as a standalone query would |
| EXPLAIN | `plan/explain.clj` | `UnionAll` node whose children are the branch plans in order |
| protocol | `protocol.clj` | capability `change.union_all` |

Decisions:

* **Concatenation order.** Without ORDER BY the rows of branch 1 come
  first, then branch 2, … (the spec leaves the order unspecified).
* **ORDER BY in a compound** resolves bare names case-insensitively against
  the first branch's output names; a name matching several output columns
  is ambiguous (`SEMANTIC_ERROR`), as is anything that is not a name or an
  in-range position (qualified names, expressions, aggregates).
* **All-NULL columns** have the type of `SELECT NULL` (reported as STRING,
  as before).
* **DECIMAL widening.** As for CASE, two DECIMAL columns always combine to
  `DECIMAL(W,max(s))` (W = 18, or 38 with a wide operand — CR-2), even if
  identical.
* **Branches run one after another.** Parallelism is inside branches, not
  across them, which keeps the row order deterministic and memory bounded.
* **`spec_version`** stays `1.0.0`: the CR says engines claiming the change
  report `1.1.0-cr1`, but the Phase 1 conformance case `catalog.pqt:10`
  requires `1.0.0`, and earlier phases must keep passing.
* **Public case `union_all.pqt` (INT64 ∪ DECIMAL).** An earlier version of
  the case read `amount` from `orders.csv` without a schema (inferred
  FLOAT64, so it could not be `DECIMAL(18,2)`); the current suite loads the
  table as `ordersd` with `amount:DECIMAL(10,2)`, and the engine returns
  the expected `DECIMAL(18,2)` rows.

## Change CR-2: DECIMAL precision 38

`DECIMAL(p,s)` accepts `1 ≤ p ≤ 38` everywhere (CAST, explicit load
schemas, PQCF metadata, result metadata); `p > 38` or `s > p` is
`SEMANTIC_ERROR` in CAST and `INVALID_REQUEST` in a load schema. Decimals
with p ≤ 18 (*narrow*) behave exactly as before; only expressions with a
*wide* operand (p > 18) use the new rules.

### Wide-decimal representation

A wide value is its unscaled integer as a `java.math.BigInteger` (|u| <
10ᵖ); the scale stays static in the type, exactly like the narrow `Long`
representation. A value's Java class is therefore fixed by its static type:
every `DECIMAL(p,s)` with p ≤ 18 holds `Long`s and every one with p > 18
holds `BigInteger`s, so equality/hashing of values of one type (GROUP BY,
DISTINCT, HASH indexes) needs no normalization. Conversions between the two
happen only where the type changes (implicit coercions of CASE / COALESCE /
UNION ALL, CAST, arithmetic results).

`BigInteger` was chosen over a hand-rolled 128-bit pair of longs: the spec
needs exact intermediates of up to 76 digits (a product of two wide
operands before the overflow check), exact rounding (`BigDecimal`
`HALF_UP` = half away from zero), exact FLOAT64 conversion in both
directions and canonical text, all of which the JDK provides; wide
decimals are expected to be rare compared with narrow ones, which keep
their primitive fast paths untouched.

### Narrow/wide dispatch

Dispatch is static: after binding every expression has a type, and the
compilers choose the implementation once per expression, not per row.

* **Result precision W** (`types/result-precision`): 38 if any DECIMAL
  operand is wide, else 18 (INT64 operands do not count). Used by `+ - *`,
  SUM, ROUND, FLOOR/CEIL and the common type of CASE, COALESCE, UNION ALL
  and comparisons; `*` with result scale > W is `TYPE_ERROR`; results with
  more than W digits are `NUMERIC_OVERFLOW`. A literal with a decimal point
  and 19–38 significant digits is a wide DECIMAL (more than 38 → FLOAT64).
* **Arithmetic** (`exec/expr.clj`): a narrow result type compiles to the
  existing long code (`values/dec-add`, `dec-mul`); a wide one to
  `values/wide-add`/`wide-sub`/`wide-mul`, which accept `Long` or
  `BigInteger` operands, compute exactly and check the 38-digit bound.
  Unary minus/ABS keep the operand type (`negate`/`abs` cannot overflow).
* **Comparisons are exact** (SPEC-Q-001 resolved): INT64/DECIMAL operands
  are compared by mathematical value (`values/dec-compare-any`, a long fast
  path, else `BigInteger` after rescaling to the common scale), never
  raising `NUMERIC_OVERFLOW` — for `=`/`<`/…, BETWEEN, IN, simple CASE,
  NULLIF, join keys, MIN/MAX, ORDER BY, GROUP BY and DISTINCT.
  **Hash keys** (`values/key-fn`, used by hash joins, IN lists/subqueries
  and HASH index probes) are the value rescaled to the comparison type's
  scale: for a narrow comparison type a `Long` (a `BigInteger` only when the
  rescaled value exceeds 64 bits, as before), for a wide comparison type
  always a `BigInteger`, so both sides of a comparison produce equal keys
  for equal values. A HASH index is probed only when the predicate's
  comparison type has the column's scale *and* width.
* **Aggregates** (`exec/aggregate.clj`, `exec/grouping.clj`): SUM/AVG of a
  wide argument accumulate in a `BigInteger` (`BigSum`, mergeable for
  parallel aggregation); SUM checks 38 digits at the end, AVG divides the
  exact sum. SUM of a narrow argument is still checked against 18 digits.
  MIN/MAX use the type's comparator.
* **CAST** (`values/cast-fn`): INT64 → wide is exact; DECIMAL → DECIMAL
  in any width combination rescales with half-away-from-zero rounding and
  checks the target precision (`values/dec-convert`); wide → INT64
  truncates toward zero and checks the INT64 range; DECIMAL → FLOAT64 is
  the nearest double (`BigDecimal.doubleValue`); FLOAT64 → DECIMAL rounds
  the exact binary value of the double.
* **Vectorized and parallel execution**: wide columns travel in `ObjVec`
  batches (`batch/vec-kind` → `:obj`) and in-memory/storage vectors hold
  `Object[]` of `BigInteger`s. Every primitive `long[]` fast path is keyed
  on `types/long-repr?` (INT64, DATE, TIMESTAMP, *narrow* DECIMAL), so wide
  values never reach the long kernels, long group tables, long sort keys,
  long join tables or long aggregate states; they use the generic
  object paths instead (object group tables, comparator sorts, generic
  aggregate states). Arithmetic, negation, comparisons and BETWEEN whose
  operand, comparison or result type is wide are evaluated by the row
  closure inside the vectorized pipeline (`kernels/wide-operands?`).
* **Native kernels** are never given wide columns or wide constants: the
  native filter compiler only accepts long-represented columns and narrow
  comparison constants (`exec/native.clj`), and grouping/join hooks only
  engage for `LongVec` inputs.

### PQCF v2

`storage/pqcf.clj` writes a table as **v2 exactly when it has a wide
DECIMAL column** (header and metadata `format_version` 2), otherwise as v1.
Wide values are 128-bit two's-complement little-endian integers: `PLAIN`
n × 16 bytes, `RLE` `u32 R` + R × {i128, u32} (20 bytes per run; `auto`
picks RLE when it is smaller, as for the other types); narrow DECIMAL
columns keep the v1 i64 layout inside v2 files. The reader accepts v1 and
v2; it rejects a v1 file that declares a wide column and wide values with
|u| ≥ 10ᵖ (`STORAGE_CORRUPT`, the latter also on lazily decoded mapped
chunks), a header/metadata version mismatch (`STORAGE_CORRUPT`) and
versions > 2 or non-zero flags (`STORAGE_VERSION_UNSUPPORTED`). Chunk
`min`/`max` stay canonical decimal strings; mapped wide chunks are decoded
into object vectors on first access (no zero-copy view). Indexes on wide
columns are persisted like any other.

### Modules touched

| layer | module | change |
|---|---|---|
| types | `types.clj` | max precision 38, `wide?`, `long-repr?`, `result-precision`; common numeric type `DECIMAL(W,…)` |
| values | `values.clj` | `BigInteger` arithmetic (`wide-add/sub/mul`), exact `dec-compare-any`, `dec-convert`, generic `dec->string`/`dec->double`/`bigdec->unscaled`, wide comparators, hash keys and CASTs, exact parsing of up to 38 digits |
| lexer / parser | `sql/lexer.clj`, `sql/parser.clj` | keyword tokens keep their spelling; `FULL`/`RIGHT` accepted as select-item aliases after `AS` (see decisions) |
| binder / functions | `sql/binder.clj`, `sql/functions.clj` | literals up to 38 digits, W for `+ - *`, SUM, ROUND, FLOOR/CEIL |
| row execution | `exec/expr.clj`, `exec/functions.clj`, `exec/aggregate.clj`, `exec/sort.clj`, `exec/operators.clj` | wide arithmetic/negation, ABS/ROUND/FLOOR/CEIL, `BigSum`, long sort paths limited to long-represented types |
| vectorized / native | `exec/batch.clj`, `exec/kernels.clj`, `exec/grouping.clj`, `exec/vjoin.clj`, `exec/native.clj` | wide → `ObjVec`; row-closure fallback for wide arithmetic/comparisons; long aggregate states, long join keys and native predicates exclude wide types |
| planning | `plan/access.clj` | HASH index probing requires matching width |
| storage | `storage/column.clj`, `storage/pqcf.clj` | object vectors for wide columns; PQCF v2 writer/reader |
| protocol | `protocol.clj` | capability `change.decimal38` |

Ingestion (`ingest/*`) needed no change of its own: it parses with
`values/parse-decimal-exact`, which now yields `BigInteger`s for wide
columns, and JSON numbers keep their literal text.

Decisions:

* **`AS full`.** grammar.md §1 lists `FULL` (and `RIGHT`, `UNION`) as
  reserved "for future use", but the public CR-2 case
  `SELECT … AS full` expects an output column named `full`. After an
  explicit `AS` neither `FULL` nor `RIGHT` can start any construct, so the
  parser accepts them there as select-item (output column) aliases, keeping
  their spelling; everywhere else they stay reserved (`l FULL JOIN r` is
  still `UNSUPPORTED`; `SELECT x full`, `SELECT x AS union` and the table
  alias `FROM t AS full` are `PARSE_ERROR`s, the latter because such an
  alias could never be referenced as `full.col`).
* **`spec_version`** stays `1.0.0` (the CR names `1.2.0-cr2`), for the same
  reason as for CR-1: the Phase 1 case `catalog.pqt:10` requires `1.0.0`.
* **Wide literals in mixed comparisons** (`narrow_col = 12345678901234567890.5`)
  have a wide comparison type; they are evaluated exactly by the generic
  paths (no long kernels, no HASH index probe on the narrow column; BTREE
  ranges and row-group skipping use the exact comparator).

## Change CR-3: logical/physical plan separation

A behaviour-preserving refactoring: same responses, errors, EXPLAIN output
and capabilities. The engine already planned in stages, but the stages
were not cleanly separated: the physical planner drove the whole pipeline
(it called the logical planner, the optimizer and column pruning, also for
every subquery), the optimizer was one function whose pushdown pass
re-ran the full optimizer on derived tables and UNION ALL branches, rules
were not separately addressable, and execution mode, threads and native
kernels were decided in `engine.clj` next to execution. Now:

* **Logical plan** (`plan/logical.clj`) — a plain-data operator tree
  (`:scan :values :derived :join :filter :aggregate :project :distinct
  :sort :limit :union-all`, joins with `:kind` and `:condition`, aggregates
  with `:group-keys`/`:aggregates`). Subquery expressions carry their own
  logical plan (`:logical`), so the whole query is one logical structure;
  CTE references are `:derived` nodes. Generic traversal helpers
  (`inputs`, `map-inputs`, `exprs`, `map-exprs`, `walk`,
  `map-subquery-plans`) and `format-plan`, an indented text rendering for
  debugging and tests.
* **Optimizer** (`plan/optimizer.clj`) — `rules`, a vector of named rules
  `{:name :rewrite}` applied in order; each rewrite is a function from a
  logical plan to a logical plan, lives in its own namespace and is unit
  tested on its own. `apply-rule` applies a rule to a plan and the plans
  of its subqueries; `optimize` with `optimize: false` returns the plan
  untouched.
* **Physical planner** (`plan/physical.clj`) — maps the optimized logical
  plan to physical operators and takes every physical decision; nothing
  physical remains in the logical layer. Its root `:execution {:mode
  :threads :native?}` is what the engine executes.
* **Pipeline** (`plan/planner.clj`) — `plan-query` = logical plan → column
  pruning → optimizer → physical plan.

Module map (namespaces under `src/polyquery/`):

| concern | before | after |
|---|---|---|
| logical plan representation | `plan/logical.clj` (builder only; subqueries planned later by the physical planner) | `plan/logical.clj` (builder incl. subquery plans, traversal, `format-plan`) |
| pipeline driver | `plan/physical.clj` `plan-query` (logical → optimizer → pruning → physical, recursively per subquery) | `plan/planner.clj` `plan-query` |
| optimizer | `plan/optimizer.clj` (`optimize` = simplify → pushdown → reorder, pushdown re-optimizing derived tables) | `plan/optimizer.clj` (rule registry, `apply-rule`, `optimize`) |
| rule: constant folding / predicate simplification | `plan/rewrite.clj` | `plan/rules/constant_folding.clj` — `constant-folding` |
| rule: predicate pushdown | inside `plan/optimizer.clj` | `plan/rules/predicate_pushdown.clj` — `predicate-pushdown` (also below renaming projections) |
| rule: join reordering | `plan/reorder.clj` | `plan/rules/join_reordering.clj` — `join-reordering` |
| rule: projection / column pruning | `plan/pruning.clj` (called by the physical planner) | `plan/rules/column_pruning.clj` — `column-pruning` |
| cardinality estimates | `plan/cost.clj` | `plan/cost.clj` (unchanged; used by join reordering and the hash-join build side) |
| physical planner | `plan/physical.clj` (+ `plan/access.clj`, `plan/parallel.clj`) | `plan/physical.clj` — access paths, join algorithms, top-N, execution mode, threads, native kernels (+ `plan/access.clj`, `plan/parallel.clj`, unchanged) |
| execution mode / threads / native decision | `engine.clj` (`exec-mode`, `threads`) | `plan/physical.clj` (`:execution` of the physical plan) |
| EXPLAIN | `plan/explain.clj` over the physical plan | unchanged |
| tests | `plan/planner_test.clj` | + `plan/logical_test.clj`, `plan/optimizer_test.clj`, `plan/rules/*_test.clj` (one per rule), execution decisions in `plan/planner_test.clj` |

Decisions:

* **Column pruning runs even with `optimize: false`.** The optimizer
  honours `optimize: false` by applying no rule. Column pruning, however,
  is mandatory (indexes-and-planning.md §3.2: scans only materialize
  referenced columns, visible in EXPLAIN) and decides that outputs nobody
  reads are never evaluated — so `optimize` cannot change results or
  errors. The planner therefore establishes column requirements once
  before the optimizer (as before, where pruning was outside the
  switchable optimizer), and the optimizer's `column-pruning` rule
  re-establishes them after the rules that restructure the plan. The rule
  is idempotent.
* **Top-N stays physical.** Replacing Sort + Limit by a bounded heap is an
  operator choice, made by the physical planner; it still honours
  `optimize: false` as before.
* **Join reordering is logical.** It changes the join order (with a
  projection restoring the column order), not an algorithm, using the
  same cardinality estimates as the hash-join build side.
* **Pushdown below projections** applies only to projections of column
  references and literals (such as the one join reordering creates):
  pushing below computed values would skip evaluating them for filtered
  rows, which could turn an error into rows. The plans built from SQL never
  have a filter directly above such a projection (WHERE filters sit on the
  FROM clause, derived tables are scans of their own), so no EXPLAIN
  output changes; filters are not moved into derived tables for the same
  reason.
* **Rules handle nested query blocks themselves.** Each rule recurses into
  derived tables and UNION ALL branches (join reordering before
  estimating the cluster that contains them), and `apply-rule` into
  subquery plans, so a rule applied once rewrites the whole query.
* **Equivalence check.** Besides the conformance suites, every query and
  EXPLAIN of the public cases under nine option combinations, and an extra
  set of queries aimed at the refactored paths (multi-way joins, derived
  tables, nested/EXISTS/correlated subqueries, CTEs, UNION ALL, unread
  failing outputs, indexes), were compared between the engine before and
  after the refactoring: identical.

## Build and start-up tuning (Track B)

Task: tune the build and runtime for start-up time (process spawn to first
protocol response), first-query (cold) latency and warm latency on
`benchmarks/workloads/analytics.json` at scale 1m, without changing results.
Every kept technique is listed in `ENGINE.json` under `"tuning"`.

(The workload file is in the workspace now; the 30-query
`bench/workloads/analytics.json` of the earlier
[latency optimization](#latency-optimization-analytics-workload) was a
stand-in written when it was missing.)

### Results

Setup: 32-core x86-64, 249 GB RAM, OpenJDK 27, Clojure 1.12.3, data from
`pqgen.py generate --scale 1m`. "Base" is the accepted engine (commit
`4dd7eee`, built in a separate worktree), "final" is this commit, both with
the launcher's default flags (no `POLYQUERY_JAVA_OPTS`). The machine was
shared (load average 5–12 during the runs), hence the interleaving below.

**Start-up** — `bench/tuning.py startup --runs 40`: a fresh
`bin/polyquery session` per run, timed from spawn to the response of
`{"op":"version"}`; base and final spawns alternate:

| engine | start-up median | min | max | RSS at first response |
|---|---:|---:|---:|---:|
| base | 354 ms | 341 ms | 377 ms | 135 MB |
| final | **117 ms** | 108 ms | 138 ms | 144 MB |

**Workload** — `bench/tuning.py workload /tmp/pqdata/1m --sessions 5
--runs 9 --warmup 3`: each session loads the workload's nine tables from CSV
with their schemas and creates its two indexes; then every query runs once
(**cold**: its first run in that session, after the queries before it),
3 warm-ups and 9 timed runs (**warm**: median). Each engine has its own
session and the runs of a query alternate between them. Cold = median of the
5 sessions' first runs, warm = median of the 5 session medians; ms, measured
by the client including the protocol round trip, `result` as the workload
specifies:

| query | base cold | final cold | base warm | final warm |
|---|---:|---:|---:|---:|
| q01_filter_selective | 10.4 | 3.2 | 1.2 | 1.0 |
| q02_filter_low_selectivity | 297.2 | 44.5 | 3.0 | 3.7 |
| q03_range_filter_time | 23.3 | 7.5 | 3.2 | 2.4 |
| q04_arith_aggregate | 244.2 | 27.4 | 4.1 | 2.8 |
| q05_groupby_low_card | 143.4 | 11.5 | 2.9 | 1.5 |
| q06_groupby_high_card | 167.4 | 15.8 | 5.6 | 4.2 |
| q07_groupby_skewed | 11.0 | 11.0 | 11.0 | 10.1 |
| q08_groupby_uniform_multi | 223.8 | 41.5 | 6.1 | 4.7 |
| q09_distinct_count | 130.4 | 19.0 | 8.2 | 7.7 |
| q10_join_customers | 211.6 | 42.7 | 15.5 | 14.1 |
| q11_join_star | 263.8 | 21.7 | 12.5 | 10.7 |
| q12_left_join_anti | 108.3 | 16.4 | 15.2 | 12.6 |
| q13_sort_topn | 33.9 | 5.0 | 5.5 | 4.6 |
| q14_sort_full_string | 523.5 | 92.9 | 275.1 | 60.5 |
| q15_sort_multi_key | 140.2 | 64.7 | 125.3 | 55.5 |
| q16_timeseries_hourly | 146.5 | 7.9 | 2.9 | 2.7 |
| q17_wide_projection | 20.8 | 4.1 | 0.8 | 0.6 |
| q18_nulls | 208.8 | 27.9 | 5.7 | 4.6 |
| q19_cte_subquery | 57.0 | 25.3 | 22.1 | 19.4 |
| q20_string_functions | 220.9 | 7.4 | 3.9 | 2.8 |
| **total** | **3186** | **497** | **530** | **226** |

| engine | table loading | cold total | warm total | peak RSS |
|---|---:|---:|---:|---:|
| base | 11.2 s | 3186 ms | 530 ms | 5370 MB |
| final | 7.8 s | **497 ms** (6.4×) | **226 ms** (2.3×) | 5140 MB |

Start-up is 3.0× faster; cold latency improves on every query except q07,
whose first run was already warm-fast; warm latency improves most on the
sorts (q14 4.5×, q15 2.3×). The remaining warm differences of a few tenths
of a millisecond are within noise (q02's 3.0 → 3.7 ms reversed in an earlier
run: 3.3 → 3.5). Results are unchanged: `bench/tuning.py verify` compares a
digest of the complete result of every workload query (FLOAT64 to 9
significant digits, sorted unless the query orders) between base and final —
all 20 identical. The raw numbers are in `bench/results/final-workload.json`.

**Noise.** A/A runs (the same engine as two variants) differed by up to
2.5% in warm total and 15% in cold total (3 sessions); a cold value is a
single run per session. Changes were therefore judged on warm totals within
±3% as "no effect", and cold effects only with ≥5 sessions or with
focused probes (`bench/tuning.py cold`: a fresh session per run that loads
one table and runs the queries once, 7–9 runs).
Single-query timings below come from sessions running one query
repeatedly.

### Techniques

Effects are before → after of that step, measured with `bench/tuning.py`
(interleaved variants) unless stated otherwise. RSS: at first response for
start-up, peak (VmHWM) of a workload session otherwise.

| technique | status | start-up | cold | warm | RSS |
|---|---|---|---|---|---|
| **Run from a jar** (`target/polyquery.jar`) | kept (needed by the AOT cache) | 346 → 352 ms (no effect alone) | – | – | – |
| **JDK AOT cache** trained by `make build` | kept | 343 → 119 ms | total 3416 → 1370 ms | total 623 → 561 ms | start-up 135 → 124 MB; peak within noise |
| … share of the *training* in it (cache recorded from a `version`-only session instead) | – | 125 vs 127 ms (classes alone give the start-up gain) | 1597 vs 600 ms (the profiles give the cold gain) | 244 vs 251 ms | 133 vs 149 MB |
| … training data with NULLs in every column type | kept | – | total 596 → 513 ms (q18 78 → 36, q04 66 → 29, q05 35 → 12) | 254 → 228 ms (q08 outlier in the old run; others equal) | equal |
| `-XX:CompileThresholdScaling=0.3` | kept | 138 vs 138 ms | total 1367 → 847 ms (−38%) | 407 vs 414 ms (noise) | start-up +22 MB (132 → 154 MB), peak equal |
| `-XX:+UseTransparentHugePages` (kernel THP mode `madvise`) | kept | 135 vs 129 ms (noise) | full workload 812 vs 819 ms; sort/group subset 544 → 483 ms | 368 → 337 ms; subset 266 → 251 ms (q14 139 → 124) | peak +120 MB (+2.5%); subset +230 MB (+9%) |
| `-XX:+UseParallelGC` (already in the base launcher) | kept | – | see G1/Serial | – | – |
| `-XX:+UseG1GC` instead | dropped | 135 → 138 ms | 1391 → 1438 ms | 375 → 388 ms | peak 4887 → 10474 MB |
| `-XX:+UseSerialGC` instead | dropped | 135 → 140 ms | 1391 → 1298 ms (noise) | 375 → 358 ms (noise) | peak 4197 MB; loading 8.6 → 11.8 s |
| ZGC | not measurable | – | – | – | the AOT cache cannot be used with ZGC (0 classes from the cache) |
| `-XX:-UsePerfData` | dropped | 135 → 132, 141 → 138 ms (noise) | 1278 → 1273 ms | 341 → 348 ms | equal |
| `-Xms8g` | dropped | 135 → 134 ms | 812 → 796 ms | 368 → 361 ms | peak 4907 → 9101 MB |
| `-Xmn4g` | dropped | – | 812 → 790 ms | 368 → 342 ms; subset 266 → 256 ms (−4%) | peak −120 MB, subset +1550 MB |
| `-Xms8g -XX:+AlwaysPreTouch` | dropped | 135 → 144 ms (pre-touch alone) | 812 → 745 ms (noise range) | 368 → 361 ms | peak 4907 → 15045 MB |
| `-XX:ReservedCodeCacheSize=64m` (code cache) | dropped | 141 → 140 ms | – | – | equal; the code cache peaks at 14 MB of 240 MB, never full |
| `-XX:+AOTCompileEagerly` | dropped | 135 → 139 ms | 3 queries 511 → 560 ms | – | +12 MB |
| `-XX:CICompilerCount=24` (default 15) | dropped | – | 4 queries 188 → 181 ms (noise) | – | – |
| `:elide-meta [:doc :file :line :column :added]` | dropped | 129 → 128, 133 → 135 ms | – | – | −6 MB; jar 3.05 → 2.97 MB |
| Boxed math removed from every namespace; lint gate | kept (required by the lint gate) | – | – | see below | – |
| Sort: one comparator type, no boxing, UTF-8 prefixes | kept | – | – | q14 ≈ 320 → 145 ms, q15 ≈ 130 → 100 ms | – |
| Sort: merge-path parallel merges, parallel key extraction | kept | – | – | q14 ≈ 145 → 62 ms, q15 ≈ 100 → 62 ms | – |
| Kernels: `positions-where` macro, no `not=` on primitives, MIN/MAX without `*` | kept | – | q18 alone 55 vs 60 ms (noise) | 6 filter/aggregate queries 24.1 → 21.4 ms (−11%) | equal |
| CSV reader: `^:const` character constants | kept | – | – | – | loading 12.2 → 8.0 s |
| Aggregate merges reading primitive sums/counts | dropped | – | 221 → 215 ms | 54.1 → 54.1 ms | – |
| `Math/addExact`, `subtractExact`, `multiplyExact` in arithmetic kernels | dropped | – | 297 → 285 ms | 27.5 → 39.9 ms (q08 outlier; arithmetic queries 3.3 → 3.4, 3.2 → 3.2 ms) | – |
| `-XX:TieredStopAtLevel=1` | not tried (excluded by the task: trades steady-state speed for start-up) | | | | |

### Compilation

* **Fully AOT-compiled.** `make build` compiles `polyquery.main` and
  everything it requires into class files. Checked with
  `POLYQUERY_JAVA_OPTS=-Xlog:class+load:file=…`: every `polyquery.*` and
  `clojure.*` class comes from the jar (without the AOT cache) or from the
  cache ("shared objects file", 5411 classes); the only dynamically defined
  classes are 7 JDK `LambdaForm`s — no `fn__` class from a
  `DynamicClassLoader`, i.e. nothing is compiled or loaded from source at
  run time. (`clojure.core.server`, `clojure.main` and `clojure.spec.alpha`
  are loaded by Clojure's own runtime initialization — `RT` starts the
  socket-server machinery — from their AOT classes in the Clojure jars.)
  The runtime classpath excludes `src/`, so a launcher started inside the
  project cannot pick up sources either.
* **Direct linking** (`:direct-linking true`) is in effect on every call
  site where it applies. `javap -c` shows calls between namespaces as
  `invokestatic …$fn.invokeStatic`, e.g. in `SortKeys.compareIdx`:
  `invokestatic polyquery/exec/sort$compare_strings.invokeStatic:(Ljava/lang/Object;Ljava/lang/Object;JJ)J`
  (about 10,100 such call sites). The remaining `Var.getRawRoot` uses are values,
  not calls: data vars (`identity-sel`, operator tables), functions passed as
  arguments, dynamic vars, and the code that macros run at compile time.
* **`:elide-meta`** was measured and dropped (no start-up effect beyond
  noise; the AOT cache already removes class loading cost, and the remaining
  start-up time is Clojure namespace initialization, mostly `clojure.core`).
* **Lint.** `make lint` (`script/lint.clj`) compiles every namespace with
  `*warn-on-reflection*` and `*unchecked-math* :warn-on-boxed` into
  `target/lint-classes` and fails on any reflection, boxed-math or
  performance warning (e.g. a `case` on a non-primitive). The gate covers all
  namespaces, a superset of the hot ones (`exec.*`, `storage.*`, `values`,
  `result`, `native.*`, `util.*`); the 145 boxed-math sites found at the
  start were all removed (primitive coercions of loop results and
  destructured locals, `^:const` for numeric constants, a top-level
  primitive function instead of a local one). Only the lint classes use
  unchecked math; the release build (`script/compile.clj`) keeps Clojure's
  checked arithmetic, and `*warn-on-reflection*` stays on in both.

### Boxing and dispatch in hot loops

The boxed-math lint only sees arithmetic on `Object`s. JFR execution and
allocation samples of the warm workload (`-XX:StartFlightRecording`,
recording started with `jcmd … JFR.start` after the tables were loaded) and
`javap -c` of the hot classes found boxing the lint cannot see:

* **Local primitive functions are not primitive.** A `(fn ^long [^long i]
  …)` bound in a `let` is called through `IFn.invoke` with boxed arguments
  and result (`javap` shows `Long.valueOf` and `RT.longCast`); only top-level
  functions get `invokePrim`/`invokeStatic`. The sort comparator's NULL
  check, the bitmap-to-selection word reader and the per-row predicate of
  `positions-where` (now a macro that inlines its test) were such calls.
* **`not=` is a plain function**: `(not= a b)` on two primitives boxes both
  and calls `Util.equiv(Object, Object)`. In the sort comparator this was
  44% of q14's samples. Primitive comparisons now use `(not (== a b))` /
  `(not (= a b))`; `not` and `some?` (also not inlined) are avoided in the
  comparator.
* **`cond … :else x` has an implicit `nil` branch**, and `case`/`if`
  branches mixing `int` (`Long/compare`) and `long` are typed `Object`: the
  compiler boxes the result (`Integer.valueOf`, `Numbers.num`) and unboxes
  it again. Hot code uses `if` chains with uniformly `long` branches.
* **Megamorphic dispatch.** The sort compared rows through one `reify` per
  key type, called from a loop over the keys: across queries that call site
  saw every key class and could not be inlined. A single `SortKeys` type now
  switches on the key kind over typed arrays (`long[]`, `double[]`, strings
  with an order-preserving 8-byte UTF-8 prefix compared as an unsigned long,
  `Comparator` only for BOOLEAN and wide DECIMAL), so `merge-ranges!` sees one
  receiver class.
* **Checked multiplication by ±1.** MIN/MAX states and comparators flipped
  signs with `(* sign …)` — `Numbers.multiply(long, long)` with its overflow
  check, per row. They branch on the sign now. These are comparisons of SQL
  values, not SQL arithmetic.
* **Constants held in vars.** `(def x 4096)` holds a boxed `Long`; every use
  in arithmetic or `=` boxes the other operand. The CSV reader compared every
  character with such constants (`Util.equiv` per character); `^:const`
  inlines them as primitives (table loading 12.2 → 8.0 s).

Overflow semantics are unchanged: none of these changes touches SQL
arithmetic. The arithmetic kernels and aggregate states already detect
overflow exactly — `unchecked-add`/`unchecked-subtract` followed by the
sign test of the result (equivalent to `Math.addExact`), `Math/multiplyHigh`
for products, `Math/addExact` in the scalar decimal functions — and raise
`NUMERIC_OVERFLOW` (or switch SUM to `BigInteger`, which the spec allows for
intermediate overflow); nothing wraps silently. Rewriting the kernels with
`Math/*Exact` and a `try` was measured and dropped (no difference).

The sort also stopped scaling at about 8 threads (1 thread 450 ms, 8 threads
150 ms, 32 threads 150 ms for q14) because the upper levels of the pairwise
merge were serial and the key arrays were extracted on the query thread.
Every merge level is now split into equal output slices by binary search on
the merge path, so each level keeps all workers busy, and the key arrays
(values, NULL flags, string prefixes) are filled in parallel row chunks. The
unit test `multi-key-sort-matches-reference-order` compares sorts of 100K
random rows (strings with 1–3-byte UTF-8 characters, surrogate pairs, lone
surrogates and U+0000; ±0.0; NULLs; booleans) under several key orders,
directions, NULL placements and partition counts with a reference sort.

### JVM start-up: the AOT cache

* `make build` packs the classes into `target/polyquery.jar` (the JDK AOT
  cache, like CDS, covers classes loaded from jar files only) and then
  records `target/polyquery.aot` (JEP 483/514/515: classes pre-parsed and
  pre-linked, the loaded-class set, method profiles): it generates a
  synthetic training data set with `script/training.clj` (deterministic
  pseudo-random tables: a 250K-row fact table with every column type and
  NULLs in every type, a 20K-row dimension, a 64-row table, a 40-column wide
  table; small inline JSON/JSONL/CSV loads) and replays a protocol session of
  generic queries over it through `bin/polyquery session` with
  `POLYQUERY_AOT_OUTPUT` set, which makes the launcher pass
  `-XX:AOTCacheOutput` with its own JVM flags. The queries cover the usual
  analytics shapes — filters, global and grouped aggregates over low/high
  cardinality, DISTINCT, joins of 2–3 tables, LEFT/anti joins, top-N and full
  sorts on integer/string/multiple keys, date/string functions, CTEs,
  scalar/IN/EXISTS subqueries, derived tables, UNION ALL, index lookups,
  PQCF save/open, EXPLAIN, errors — eight times under default options and
  once each under `mode`/`threads`/`join`/`optimize`/`result` variations. None of them is a benchmark query, and the data is not the
  benchmark data. Training takes about 15 s.
* If generating the data, the session or the cache dump fails, `make build`
  prints a warning, removes any partial cache and succeeds; the engine then
  runs without a cache. Tested by making `script/training.clj` throw.
* The launcher passes `-XX:AOTCache=target/polyquery.aot` only when the file
  exists. The JVM validates the cache (JDK build, classpath with jar
  modification times, GC and flags) and continues without it when it does
  not match; `-Xlog:aot*=off -Xlog:cds*=off` keeps that silent (stdout carries
  the protocol, and the warnings would otherwise go to stderr). Verified with
  a stale cache (jar touched after training), a truncated cache, a file of
  garbage and a missing file: correct responses, nothing on stdout but the
  protocol, nothing on stderr.
* What remains of start-up (≈ 115 ms) is JVM boot plus Clojure's namespace
  initialization (`clojure.core` and the engine's 61 namespaces), which the
  JDK 27 cache does not snapshot.

### Measuring

```sh
python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata --jobs 1
B=/tmp/base/implementations/clojure/bin/polyquery     # e.g. a git worktree of the base commit
python3 bench/tuning.py startup --runs 40 base=$B final=bin/polyquery
python3 bench/tuning.py workload /tmp/pqdata/1m --sessions 5 --runs 9 --warmup 3 base=$B final=bin/polyquery
python3 bench/tuning.py verify /tmp/pqdata/1m base=$B final=bin/polyquery
python3 bench/tuning.py cold /tmp/pqdata/1m --tables nulls_heavy --runs 9 \
  --sql "SELECT COUNT(*) FROM nulls_heavy WHERE b60 = true" cur=bin/polyquery "c1=bin/polyquery@-XX:CompileThresholdScaling=1"
# a flag variant of the same build: NAME=LAUNCHER@JAVA_OPTS
python3 bench/tuning.py workload /tmp/pqdata/1m cur=bin/polyquery "g1=bin/polyquery@-XX:-UseParallelGC -XX:+UseG1GC"
```

(`--jobs 1`: the generator's process pool needs a writable `/dev/shm`.)
GC variants can be measured through `POLYQUERY_JAVA_OPTS` because the cache
trained with ParallelGC is also used with G1 and Serial (checked with
`-Xlog:class+load`); kept flags are in the launcher, so the training runs
with them.

## Design decisions (where the spec is silent or open)

* **Unsupported features.** `UNION` without `ALL`, `RIGHT`/`FULL` joins
  answer `UNSUPPORTED`.
* **CASE/COALESCE result type.** Types are combined pairwise in order; any two
  DECIMAL types (even identical ones) combine to `DECIMAL(W,max(s1,s2))` as
  semantics.md §13 states (W = 18, or 38 when one is wide — CR-2), INT64
  with DECIMAL(p,s) to `DECIMAL(W,s)`, NULL
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

* `bench/workload.py DATA_DIR` times the analytics workload
  (`bench/workloads/analytics.json`) through `bin/polyquery session`.
  `--baseline LAUNCHER` produces an interleaved before/after table;
  `--digest`/`--check` compare full results across versions (see
  [Latency optimization](#latency-optimization-analytics-workload)).
* `make test` — unit tests for the JSON codec, values/casts/calendar,
  result encoding, lexer,
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
* UNION ALL: parser (compound structure, PARSE_ERROR/UNSUPPORTED forms),
  analyzer (column typing and conversion, compound ORDER BY resolution,
  errors), planner (TopN over UnionAll, per-branch optimization, pruning
  and parallelization) and 11 compound queries in the Phase 5 differential
  matrix (CTEs, derived tables, IN/EXISTS/correlated subqueries, GROUP BY,
  DISTINCT, LIMIT, runtime errors in a branch).
* DECIMAL(38) (CR-2): wide arithmetic, exact comparison, conversions and
  CASTs (`values_test`), literal typing (`analyzer_test`), PQCF v2 version
  selection, 128-bit round trips for every encoding/row-group size/mmap and
  a v1 file with a wide column (`pqcf_test`), and wide typing, arithmetic,
  joins (wide = wide, narrow = wide), grouping, SUM and overflow under seven
  option combinations (`engine_decimal38_test`).
* Plan separation (CR-3): the logical plan (operator tree, subquery plans,
  `format-plan`), the optimizer (rule names and order, `optimize: false`
  applies no rule, rules reach subquery plans), one test namespace per rule
  (`plan/rules/*_test.clj`) and the physical planner's execution decisions.
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
* Track B tuning: `make lint` is a gate (reflection, boxed math,
  performance warnings in any namespace); `vectorized_test` compares the
  multi-key sort with a reference sort on 100K random rows (see
  [Build and start-up tuning](#build-and-start-up-tuning-track-b));
  `bench/tuning.py verify` checks that every workload query returns the same
  complete result as the base engine; the build's cache handling was tested
  with a failing training run and stale, truncated, garbage and missing
  caches.
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
* Vectorized execution covers scans, filters, projections, hash aggregation
  (also SELECT DISTINCT), hash-join probes and sorting; index scans, LIMIT, sort-merge and
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
* Wide DECIMAL values (p > 18) are boxed `BigInteger`s: arithmetic and
  comparisons on them run as row closures inside vectorized pipelines, they
  never use the native kernels, and mapped PQCF v2 chunks of wide columns
  are decoded into object vectors rather than read in place. Narrow
  decimals keep all primitive fast paths.
* Correlated subqueries other than equality lookups over a single table scan
  are re-executed per outer row (correct, but O(outer × inner)); of the
  equality lookups, only EXISTS is turned into a precomputed key set
  (correlated scalar and IN subqueries are probed per outer row).
* Sorted results are materialized as rows before sorting, so emitting a
  large sorted result reads rows in random memory order (see
  [Latency optimization](#latency-optimization-analytics-workload)).
* The AOT cache is valid only for the JDK build and the jar paths and
  modification times it was trained with. After a JDK upgrade or moving the
  directory the JVM ignores it (silently): start-up is back at ≈ 350 ms and
  first queries are slower until `make clean build` retrains it. A plain
  `make build` retrains only when the jar, the training script or the
  launcher changed.
* `-XX:+UseTransparentHugePages` only has an effect when the kernel's THP
  mode is `madvise` or `always` (it is `madvise` on the measurement machine).
