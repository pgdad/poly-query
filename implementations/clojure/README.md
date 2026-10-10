# PolyQuery — Clojure engine

An analytical database engine implementing the PolyQuery specification
(`spec/`) in Clojure. Status: **Phase 4** — Phase 1 (protocol, catalog,
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
disconnect detection and graceful shutdown).

Reported capabilities: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic
test.functions phase2 sql.groupby sql.join sql.functions sql.subquery sql.cte
sql.correlated_subquery phase3 storage.pqcf storage.mmap index.hash
index.btree phase4 http.streaming`.

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
`POLYQUERY_JAVA_OPTS` (e.g. `-Xmx16g` for very large tables).

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
        ─physical planner→ physical plan ─operators→ rows ─protocol→ JSON
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
| Optimization | `polyquery.plan.optimizer`, `polyquery.plan.pruning` | predicate pushdown below joins, WHERE equalities of comma joins become join conditions (`optimize: false` disables it); column pruning |
| Physical planning | `polyquery.plan.physical`, `polyquery.plan.access`, `polyquery.plan.cost`, `polyquery.plan.explain` | access paths (index selection, row-group skip predicates), hash join vs nested-loop join and hash-join build side (cardinality estimates), hash lookup for correlated equality predicates, planning of nested subquery plans; EXPLAIN JSON |
| Execution | `polyquery.exec.operators`, `polyquery.exec.join`, `polyquery.exec.skipping`, `polyquery.exec.expr`, `polyquery.exec.functions`, `polyquery.exec.aggregate`, `polyquery.exec.context` | operators compiled once into re-reducible row sources (table/index scans over segments); row-group skipping; expression compiler (bound expr → specialised closure); scalar functions and LIKE; aggregate accumulators; query context (timeout, cancellation, memory budget) |
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

### Execution

Each physical operator is compiled once into a *re-reducible*
(`clojure.lang.IReduceInit` that recomputes its rows on every `reduce`); rows
are pushed through transducers (`filter`, `map`, `drop`/`take`) without
intermediate collections. Blocking operators (sort, hash aggregate, distinct,
hash-join build) materialize with memory accounting and periodic
timeout/cancellation checks.

* **Joins**: hash join (build side = right input; NULL keys never match;
  INT64/DECIMAL/FLOAT64/DATE/TIMESTAMP keys are hashed in their comparison
  type) whenever the ON condition (after pushdown) has an equality between
  the two inputs, else nested loops. LEFT joins pad unmatched rows with
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
  `Filter`, `HashJoin` (`join_type`, `build` side)/`NestedLoopJoin`
  (`join_type`), `HashLookup` (correlated hash lookup over its `TableScan`
  child), `SubqueryScan`, `Aggregate`, `Project`, `Distinct`, `Sort`, `Limit`,
  `Values`. The plans of subqueries evaluated by a node are appended to its
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
* **Query options.** `mode` accepts `auto`/`row`; `join` accepts its
  documented values (`nested_loop` forces nested-loop joins, the others use
  the automatic choice); `optimize: false` skips the logical optimizer;
  `threads` ≥ 1 is accepted and ignored (execution is single-threaded); other
  values of known options are `UNSUPPORTED`, ill-typed values
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
* Storage unit tests: column vectors and layouts, statistics, index lookups,
  PQCF round trips for every encoding/row-group size/mmap, corrupt and
  unsupported files; Phase 3 planning (pruning, index selection, build side).
* Conformance: `python3 tests/conformance/runner.py --engine
  implementations/clojure/bin/polyquery --phase 1 --phase 2 --phase 3`
  (add `--transport http` to run the same cases through `serve`), and
  `python3 tests/concurrency/http_suite.py --engine
  implementations/clojure/bin/polyquery`.

## Known limitations

* No Phase 5 execution modes (vectorized/parallel execution, forced join
  algorithms, native kernels).
* HTTP: one platform thread per open connection (no NIO multiplexing);
  no TLS, no HTTP/2, no compression. Request bodies are held in memory
  (bounded by `--max-request-bytes`). Loads are not cancellable and do not
  observe timeouts.
* Rows flowing between operators are boxed `Object[]` tuples (typed columnar
  storage is converted per value at the scan); very large inputs need a
  correspondingly large heap (`POLYQUERY_JAVA_OPTS=-Xmx…`). JSON (array)
  inputs are parsed from a single in-memory string.
* Indexes are used for single-table scans only (no index nested-loop joins,
  no index use for `OR`/`NOT IN`/`<>`, no ordered output from BTREE indexes).
* A PQCF chunk must be smaller than 2 GiB (Java buffer limit).
* Correlated subqueries other than equality lookups over a single table scan
  are re-executed per outer row (correct, but O(outer × inner)).
