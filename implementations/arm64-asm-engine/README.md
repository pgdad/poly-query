# PolyQuery — AArch64 assembly engine (`arm64-asm-engine`, Track A)

An analytical database engine written entirely in hand-written AArch64
assembly (GNU as `.S` files, preprocessed and linked by gcc). It implements
PolyQuery **Phase 1** (CLI and JSON-lines session protocol, catalog
operations, CSV/JSON/JSONL ingestion, all data types, resource limits, test
functions) and **Phase 2**: the complete SQL grammar and semantics — GROUP BY /
HAVING / DISTINCT / COUNT(DISTINCT), INNER / LEFT / CROSS joins, all scalar
functions, CASE / LIKE / BETWEEN / IN, uncorrelated **and correlated**
subqueries (scalar, IN, EXISTS), derived tables, CTEs, and `EXPLAIN`
(statement and `explain` op) — with distinct lexer, parser/AST, semantic
analysis, logical plan, physical plan and execution stages — and **Phase 3**:
row- and column-oriented in-memory layouts, dictionary encoding, null
bitmaps, the PQCF v1 file format (`save` / `open`, PLAIN / DICT / RLE,
CRC-32, atomic crash-safe writes, memory-mapped reads), table statistics
(`stats`), HASH and BTREE indexes (`CREATE` / `DROP INDEX`), cost-based
index selection, predicate pushdown with PQCF row-group skipping, column
pruning, join build-side selection and EXPLAIN plans with `IndexScan` — and
**Phase 4**: the multi-threaded `serve` HTTP/1.1 server with every endpoint
of protocol.md §7, chunked NDJSON streaming with backpressure, Prometheus
metrics, structured JSON logs, snapshot-isolated concurrent readers over a
versioned catalog, worker limits with a bounded FIFO queue and `OVERLOADED`
rejection, query timeouts (queued time included), cancellation (explicit or
by client disconnect) and graceful shutdown.

## Build prerequisites

* AArch64 Linux host
* GNU binutils (`as`) and gcc (used only as preprocessor/assembler driver and
  linker) — tested with gcc 13.3 / binutils 2.42
* glibc (libc, libm, libpthread), dynamically linked

```
make build        # -> build/polyquery
make test         # assembly unit tests (tests/unit) + CLI smoke tests (tests/sh)
make lint         # checks every object has a non-executable .note.GNU-stack
make fmt          # whitespace normalisation
bin/polyquery session --data-dir DIR
bin/polyquery serve --port 8080 [--workers N --queue-depth Q ...]
```

## Libraries

None besides glibc (`ENGINE.json`: `"libraries": []`). From glibc the engine
uses: malloc/realloc/free, memcpy/memcmp/memset/strlen/strcmp, strtod and
snprintf (float text conversion), qsort/qsort_r, setjmp/longjmp, getline,
open/read/write/fstat/close/fsync/rename/unlink/mmap/munmap/getpid,
clock_gettime, usleep; for the server (libpthread / libc): pthread_create,
mutexes and condition variables, sem_* (unit test), socket/bind/listen/
accept4/setsockopt/getsockname/inet_pton, send/read/poll/shutdown, pipe2,
signal, gmtime_r, get_nprocs.

## Design overview

Layered modules (one `.S` file each, shared definitions in `include/pq.inc`,
frame macros in `include/frame.inc`, the internal API contract in
`include/API.md`):

| layer | files | role |
|---|---|---|
| runtime | `rt.S` | error raising (setjmp/longjmp), arenas, strings, byte buffers, JSON string/number output, clock |
| protocol | `main.S`, `protocol.S` | CLI options, session loop, exec mode, request dispatch, all ops (incl. `explain`) |
| JSON | `json.S` | strict RFC 8259 parser into a DOM, serializer |
| values | `values.S`, `decimal.S`, `datetime.S`, `types.S` | text parsing/formatting of every type, CAST matrix, comparisons, type names |
| storage | `catalog.S`, `ingest.S`, `storage.S`, `pqcf.S`, `index.S` | catalog of immutable tables; CSV/JSON/JSONL ingestion; row / column layouts, dictionary encoding, statistics; PQCF v1 reader/writer; HASH / BTREE indexes |
| lexer / parser | `lexer.S`, `parser.S` | tokenizer and recursive-descent parser for the full v1 grammar into an AST |
| semantic analysis | `binder.S`, `functions.S`, `strfuncs.S` | scopes (range variables, outer scopes, CTEs), name resolution, typing with implicit casts, aggregate / GROUP BY validation, subquery binding; scalar functions, CASE, LIKE, BETWEEN, IN lists |
| planning | `plan.S`, `access.S` | logical plan, physical rewrite (predicate pushdown, hash-join keys, join algorithm, column pruning, build side), access paths (simple predicates, selectivity estimates, index selection, row-group skipping), EXPLAIN JSON |
| execution | `exec.S`, `eval.S` | plan operators (scan, filter, hash / nested-loop join, sort-based aggregation, project, distinct, sort, limit), subquery evaluation, batched projection for streaming; expression evaluator and aggregate accumulators |
| server | `http.S`, `server.S`, `log.S` | HTTP/1.1 listener and connection threads, routing, request framing, streaming, shutdown; query registry, admission control, cancellation, disconnect watchdog, metrics; structured logs |

Query processing: `parse_sql` → `bind_query` (BoundQuery per query level,
SubPlans for every subquery / derived table / CTE) → `plan_statement`
(PlanNode trees) → `exec_plan` (ResultSet).

### Concurrency and the server (Phase 4)

* **Threads.** `serve` runs one accept thread (poll on the listening socket
  and a self-pipe written by the SIGTERM/SIGINT handler), one thread per
  connection (requests on a keep-alive connection are processed in order)
  and a watchdog thread. A query executes on its connection's thread once
  admitted; non-query endpoints (`/health`, `/metrics`, `/v1/queries`,
  cancellation, catalog operations) never wait for a worker slot.
* **Per-thread state.** All per-request runtime state (request arena,
  response buffer, `setjmp` buffer, error record, deadline, PQCF writer /
  reader scratch, current catalog version, log line) is thread-local
  (`.tbss`/`.tdata`, local-exec TLS model, macros `TLS_ADDR`/`TLS_LDR` in
  `pq.inc`), so the single-threaded engine code runs unchanged on any number
  of threads. Process-wide settings are written once before threads start.
* **Versioned catalog (snapshot isolation).** The catalog is a sequence of
  immutable, reference-counted versions (`CV_*`): a request pins the current
  version for its whole duration (`cat_read_begin`); a mutation (`load`,
  `open`, `drop`, `reset`, `CREATE/DROP INDEX`) takes the writer mutex,
  edits a private copy and publishes it atomically on success (`cat_end`),
  or discards it on error, so failed requests never change anything and
  readers never see half a mutation. Tables and indexes are reference
  counted by the versions that contain them and freed with the last one:
  a dropped or replaced table stays readable by queries already using it.
  Parsing a `load` happens before the publish and never blocks readers
  (only other mutations, which are serialised). Table statistics are
  computed when a table is published, so published tables are never
  written again (no lazy caches shared between threads).
* **Admission control** (`server.S`). Queries are registered (id, state,
  arrival time, cancellation flag) in arrival order. At most `--workers`
  run; up to `--queue-depth` wait FIFO on a condition variable; further
  queries fail at once with `OVERLOADED`. A query's snapshot is taken when it
  starts executing (after admission). The timeout is measured from the
  arrival of the request, so queued time counts; a queued query gives up
  with `TIMEOUT` or `CANCELLED` while waiting.
* **Cancellation / timeouts.** The executor's existing interruption point
  `check_deadline` (every 4096 rows in operator loops, every ≤10 ms slice of
  `PQ_SLEEP`, between streamed batches and while a streamed write is
  blocked) also polls the query's cancellation flag. `DELETE
  /v1/queries/{id}`, a client disconnect (the watchdog polls the sockets of
  registered queries for `POLLRDHUP` every 20 ms) and the end of the shutdown
  grace period set the flag; the query unwinds with `CANCELLED` (409).
* **Streaming.** `/v1/query/stream` answers with chunked NDJSON. When the
  plan ends in a projection (optionally under LIMIT/OFFSET),
  `exec_plan_stream` projects the rows in batches of 1000 and hands each
  batch to the HTTP sink, which writes it before the next batch is computed:
  the header line goes out before any row is evaluated, a runtime error after
  the header becomes a final `{"type":"error",…}` line, and a client that
  stops reading blocks the query in `send` (backpressure; one batch is
  buffered). Sorted, grouped and DISTINCT results are materialised first
  (they need all rows) and then written in batches the same way.
* **HTTP framing.** Content-Length and chunked bodies (strict chunk-size
  syntax: `1*HEXDIG`, optional extensions; anything else is `400` and the
  connection is closed), `Expect: 100-continue`, keep-alive (HTTP/1.1
  default, `Connection: close`), pipelining. Bodies over
  `--max-request-bytes` are `413` (a declared Content-Length body up to
  64 MiB is read and discarded so the connection stays usable). When the
  server closes a connection with unread input it half-closes and drains
  briefly so the client still receives the response.
* **Shutdown.** SIGTERM/SIGINT: the listening socket is closed, `/health`
  answers 503 and new queries `SHUTTING_DOWN`; the server waits for all
  in-flight requests up to `--shutdown-grace-ms`, then cancels the remaining
  queries, waits up to 2 s for their responses and exits with status 0.
* **Logs** (`log.S`): JSON lines on stderr (`ts` RFC 3339 UTC with
  milliseconds, `level`, `msg`); `info`: startup, one `query finished` event
  per query (`query_id`, `status`, `code`, `duration_ms`, `rows`), shutdown;
  `debug`: one event per HTTP request (method, path, status, duration). No
  SQL text, data values or bodies are logged. Each line is written with one
  `write(2)`.
* **Metrics**: the required families plus HELP/TYPE lines; durations are a
  summary in seconds.

Key decisions:

* **Error handling.** Every request runs under `setjmp`; any error anywhere
  calls `pq_raise*` which longjmps back to the dispatcher. All per-request
  memory comes from a bump arena that is released after each response, so
  unwinding never leaks. Half-built tables are registered and freed on error,
  which makes `load` atomic.
* **Values.** A runtime value is a pair (64-bit payload, null flag) returned in
  `x0`/`x1`; the type is static (from the AST). DECIMAL is a scaled `i64`
  (precision ≤ 18) with exact 128-bit intermediates; DATE is days and
  TIMESTAMP microseconds since the epoch; strings are length-prefixed objects.
* **Storage.** Every table lives in its own arena (freed on drop/replace).
  Two in-memory layouts (`load`/`open` option `layout`, default `column`):
  *column*: per column a vector of 64-bit payloads, or for STRING columns a
  dictionary encoding (u32 codes + dictionary of distinct strings; applied
  automatically when distinct values ≤ rows/2, or forced with
  `"dictionary":true`), plus a null bitmap (absent when the column has no
  NULL); *row*: a row store of fixed-size records (payloads followed by the
  row's null bitmap). Tables are built column-wise by ingestion / the PQCF
  reader and then converted (`table_finalize`). The evaluator's column access
  (`ev_col`) and the generic accessor `tbl_get` handle every representation.
* **PQCF v1 (`pqcf.S`).** `save` builds the whole file in memory (8-byte
  aligned chunks, metadata JSON with per-chunk min/max for every type,
  CRC-32 via the ARMv8 `crc32` instructions with a table fallback) and writes
  it atomically: temporary file `.<name>.tmp-<pid>-<n>` in the target's
  directory, `fsync`, `rename`, `fsync` of the directory; on failure the
  temporary file is removed. Encodings per chunk: forced `plain` / `dict`
  (STRING) / `rle` (BOOLEAN, INT64, DECIMAL, DATE, TIMESTAMP), or `auto`: RLE
  when runs < n/4, DICT when distinct < n/2, else PLAIN. Default row group
  size 65536 (`row_group_size` option). `open` validates everything at open
  time — header, footer, metadata CRC, JSON structure and consistency rules,
  every chunk CRC, exact decoded sizes, null counts, value validity (UTF-8,
  decimal precision, date/timestamp ranges, finite floats, RLE booleans,
  dictionary codes) — then decodes into a plain columnar table which is
  finalized like a loaded one (`layout` option honoured). Index entries of the
  metadata are recreated (names checked for conflicts before anything
  changes), and the row groups' min/max/null statistics are kept for
  row-group skipping. **mmap:** with `"mmap":true` the file is memory-mapped
  (`mmap(PROT_READ, MAP_PRIVATE)`) instead of `read()` into a buffer; it is
  decoded eagerly and unmapped before `open` returns (no lazy decoding).
  Error precedence: header magic, version/flags (`0` ⇒ CORRUPT, `>1` or
  flags ≠ 0 ⇒ VERSION_UNSUPPORTED), footer, metadata CRC, JSON, structure;
  an unknown encoding name ⇒ VERSION_UNSUPPORTED.
* **Statistics.** `table_stats` computes per column null count, min, max and
  the exact distinct count (hash set) once, when the table is published to
  the catalog, and caches them (tables are immutable).
* **Indexes.** Single-column, global names. HASH: chained hash table over row
  ids (heads per bucket, next per row). BTREE: the "equivalent ordered
  structure" of the spec — a sorted permutation of the non-NULL row ids with
  the sorted values, searched by binary search for equality and ranges.
  NULLs are never indexed. Indexes are rebuilt from the table data when
  created / opened and dropped with their table.
* **Access paths.** Pushed-down scan filters are split into conjuncts;
  `column op constant` (op `= < <= > >=`, `BETWEEN` → two bounds) and
  `column IN (constants)` become *simple predicates* with the constant
  evaluated at planning time (literals, negation and the binder's implicit
  casts only, so planning never raises). Selectivity: equality 1/distinct,
  IN k/distinct, ranges by linear interpolation between min and max for
  numeric/temporal columns (both bounds of a column combined), 1/3 otherwise.
  The most selective indexable predicate is executed through its index when
  its selectivity is ≤ 10%, or when it is an equality / IN lookup expected to
  return at most 16 rows (cheaper than any scan). An index scan sorts and
  de-duplicates the candidate row ids and still evaluates the complete filter,
  so results never depend on the access path (`use_indexes:false` disables
  indexes). For PQCF-backed tables, row groups whose min/max/null statistics
  exclude a simple predicate are skipped.
* **Joins (Phase 3).** Scan and join cardinalities are estimated bottom-up;
  an inner hash join builds on the input with the smaller estimate (the
  inputs are swapped — tuples keep one slot per range variable, so the
  output does not depend on the order); LEFT joins build on the right.
* **Typing.** The binder inserts explicit CAST nodes for numeric promotion and
  DATE→TIMESTAMP, so the evaluator only ever combines operands of one kind.
* **Execution.** Selection vectors (row ids) from the filtered scan; result
  rows are materialised as cell matrices including hidden ORDER BY keys;
  sorting uses `qsort_r`. Without ORDER BY, OFFSET/LIMIT are applied before
  projection.
* **Tuples.** Below aggregation, operators exchange tuple sets: one u32 row
  id per range variable (`ROW_NULL` marks the NULL-padded side of a LEFT
  JOIN). Expressions read columns through the evaluation context
  (`EC_TABLES[rv]`, `EC_TUPLE`), so joins never copy column data.
* **Correlation.** Column references carry an outer depth; evaluation
  contexts are chained (`EC_OUTER`) like the binder scopes, so a correlated
  subquery is simply re-executed with the current row as its outer context.
  Uncorrelated subqueries, derived tables and CTEs are executed once per
  statement and cached (derived tables / CTEs are materialised as columnar
  tables; IN-subquery values are sorted for binary search).
* **Joins.** Equality conjuncts between the two sides with identical payload
  encoding become hash keys (build on the right input; NULL keys never
  match); everything else is a residual or nested-loop condition. WHERE
  conjuncts are pushed to the lowest scan/join covering their range
  variables, never below the NULL-padded side of a LEFT JOIN.
* **Aggregation.** Sort-based grouping (key cells per tuple, `qsort_r`, runs
  of equal keys; NULL keys group together). DISTINCT aggregates sort and
  de-duplicate each group's values. GROUP BY expressions inside SELECT /
  HAVING / ORDER BY are replaced by group-key references after a structural
  equality check, which also enforces the grouping rule.
* **EXPLAIN.** Plan JSON with `TableScan` (`table`, `alias`, pruned
  `columns`, `filter`), `SubqueryScan`, `HashJoin` / `NestedLoopJoin`
  (`join_type`, `hash_keys`), `Filter`, `Aggregate`, `Project`, `Distinct`,
  `Sort`, `Limit`, `Values`.

## Implementation-defined choices

* FLOAT64 output uses the shortest of `%.15g`/`%.16g`/`%.17g` that round-trips.
* CAST(FLOAT64 AS STRING) uses the same text.
* `LIMIT NULL` / `OFFSET NULL` are treated as absent.
* An unknown type name in a `load` schema is `INVALID_REQUEST`.
* JSON keys that differ only in case map to the same column (first spelling
  wins); the same key twice within one object is `INGEST_ERROR`.
* A CSV field consisting only of spaces/tabs is ignored by type inference and
  is NULL in non-STRING columns.
* CAST(FLOAT64 AS DECIMAL) rounds half away from zero on the exact binary
  value of the double (so `2.5e0` → `3`, but the double nearest 1.005 → `1.00`).
* DECIMAL ± DECIMAL with different scales is aligned exactly in 128-bit
  arithmetic (no spurious overflow); INT64 operands are promoted to
  DECIMAL(18,s) as the spec requires.
* SQL nesting deeper than 256 levels is `RESOURCE_LIMIT`.
* `serve` without `--port` is a usage error (exit 2); `--workers 0` (or
  absent) means the number of online CPUs.
* HTTP: `GET /v1/tables/{name}` with another method than PUT/DELETE, and
  any other method on a known path, is `405 INVALID_REQUEST`. Table names
  and query ids in paths are percent-decoded. `PUT /v1/tables/{name}` also
  accepts `delimiter=`; `replace` / `header` accept `true`/`1` (anything else
  is false).
* Server-assigned query ids are `q-<n>`. OVERLOADED and duplicate-id
  rejections are counted only in `polyquery_queries_rejected_total` /
  not at all; every admitted query is counted once in
  `polyquery_queries_total` (`ok` or `error`).
* Every query op is subject to admission control, including `CREATE/DROP
  INDEX` statements and queries sent through `/v1/request`; `explain` is not.
* `CREATE INDEX` without `USING` creates a BTREE index.
* An unknown table or column in `CREATE INDEX` is `SEMANTIC_ERROR`.
* EXPLAIN shows `estimated_rows` on scans and joins, `index`/`kind` on
  `IndexScan`, and `row_groups` / `row_groups_skipped` on scans of
  PQCF-backed tables; `schema` reports `layout`.
* `UPPER`/`LOWER` map ASCII letters only, and leave a whitespace-delimited
  word that contains a non-ASCII character unchanged as a whole
  (`UPPER('abc Ünï')` = `'ABC Ünï'`, as the conformance suite requires).
* `COALESCE`/`CASE` unify any two DECIMALs (or INT64 + DECIMAL) to
  DECIMAL(18, max scale); a single DECIMAL branch keeps its type. DATE and
  TIMESTAMP are not promoted to a common CASE/COALESCE type (TYPE_ERROR).
* `-NULL`, `ABS/ROUND/FLOOR/CEIL(NULL)` keep the null type (reported as
  STRING); binary arithmetic on two untyped NULLs is INT64.
* `CAST(string AS TIMESTAMP)` requires the timestamp syntax (a bare date is a
  CONVERSION_ERROR); ingestion still accepts dates for TIMESTAMP columns.
* An ORDER BY expression that is structurally equal to a select-list
  expression refers to that output column (so it is also allowed with
  SELECT DISTINCT).
* An `ON` condition sees only the range variables of its own `from_item`
  (inside parentheses: only those within the parentheses).
* In an aggregated query, a subquery in SELECT / HAVING / ORDER BY may refer
  to an outer column only if that column is a GROUP BY expression.
* EXPLAIN shows the plans of expression subqueries (scalar / IN / EXISTS) as
  additional children of the node whose expression uses them.

## Known limitations

* Correlated subqueries are re-executed per outer row (no decorrelation).
* Single-threaded execution of each query (no intra-query parallelism;
  `threads` is validated but ignored). Phase 5 options are not supported.
* One thread per HTTP connection (no connection limit besides the OS).
* Sorting (`qsort_r`) is not interruptible: a cancelled / timed-out query
  stops at the next check after a large sort finishes.
* Streaming materialises sorted / grouped / DISTINCT results before the
  first row is sent; projections stream incrementally, but values computed
  for earlier batches (strings) stay in the request arena until the query
  ends.
* Temporary files left behind by a crash during `save` are not cleaned up by
  later saves (they are ignored by readers).
* PQCF format_version 2 (the DECIMAL(38) change) is not supported.
* Ingestion builds a plain columnar table first; converting it (row layout,
  dictionary encoding) rebuilds it into a fresh arena, so loading needs
  transient memory for both representations.
