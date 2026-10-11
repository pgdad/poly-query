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
by client disconnect) and graceful shutdown — and **Phase 5**: per-query
execution options (`mode` row / vectorized, `threads`, `join` hash / merge /
nested_loop, `optimize`), a row-at-a-time baseline next to a vectorized
batch executor (selection vectors, dictionary-code predicates, an explicit
NEON kernel, hash aggregation), intra-query parallelism (parallel scans,
filters, projections, hash-join probes and partitioned aggregation with
merged partial states), sort-merge joins with radix-sorted keys, top-N,
and a logical optimizer (constant folding, predicate simplification, join
reordering). See
[Phase 5](#phase-5-execution-options-and-optimizations) for the design and
the before/after measurements.

## Build prerequisites

* AArch64 Linux host
* GNU binutils (`as`) and gcc (used only as preprocessor/assembler driver and
  linker) — tested with gcc 13.3 / binutils 2.42
* glibc (libc, libm, libpthread), dynamically linked

```
make build        # -> build/polyquery
make test         # assembly unit tests (tests/unit) + shell tests (tests/sh: CLI,
                  # HTTP, storage, Phase 5 option-matrix differential test)
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
signal, gmtime_r, get_nprocs; for intra-query parallelism (Phase 5):
pthread_create / pthread_join, getenv, strncpy.

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
| optimizer | `optimize.S` | logical rewrites (Phase 5, option `optimize`): constant folding, predicate simplification |
| execution | `exec.S`, `eval.S`, `ops.S`, `join.S`, `volcano.S`, `sort.S` | plan operators (scan tasks, filter, project, hash / merge / nested-loop joins, sort-based aggregation, distinct, sort, top-N, limit), subquery evaluation, batched projection for streaming; expression evaluator and aggregate accumulators |
| vectorized execution | `vexec.S`, `vagg.S` | batch expression evaluation over column vectors with selection vectors (`veval`, `vfilter`, join key vectors), hash aggregation with partial tables |
| parallelism | `parallel.S` | worker threads for query tasks (`par_run`), parallel-safety check |
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

## Phase 5: execution options and optimizations

### Options (protocol.md §5.2)

`protocol.S parse_exec_opts` reads the options of every `query` / `explain`
request into thread-local settings (`g_x_mode`, `g_x_join`, `g_x_threads`,
`g_x_optimize` in `exec.S`, `g_use_indexes` in `access.S`); worker threads
inherit them. Unsupported values (`"mode":"quantum"`) are `UNSUPPORTED`.

| option | effect |
|---|---|
| `mode: "row"` | the unoptimized baseline, kept permanently: a Volcano iterator pipeline (`volcano.S`). Scans, filters and join probes return one tuple per `next()` call, expressions go through the tree-walking evaluator `eval` one row at a time; grouping is sort-based (`qsort_r` on key records). Single-threaded. |
| `mode: "vectorized"` (also `auto`) | batch execution: scans, filters, projections, join keys and aggregates evaluate expressions over batches of 1024 tuples as column vectors (`vexec.S`), grouping is hash-based (`vagg.S`). |
| `threads: N` | in vectorized mode, scans, filters, projections, hash-join probes and aggregations run as up to N parallel tasks (default: `--threads`, else the online CPUs, at most 8; capped at 64; values < 1 are `UNSUPPORTED`). The row-mode baseline ignores it. |
| `join: "hash"` / `"merge"` / `"nested_loop"` | forces the algorithm of every equi-join; joins without an equality between the two sides are always nested loops. `auto` = hash join for equi-joins. |
| `optimize: false` | disables the logical rewrites (constant folding, predicate simplification, join reordering), top-N and the cost-based hash-join build side. Predicate pushdown, column pruning and index selection stay on: they are the Phase 3 access-path rules (index use is controlled by `use_indexes`), and the Phase 3 suite checks them under every option combination. |
| `native: true` | accepted and ignored (`native.kernels` is not claimed; no kernel library is loaded). |

Every combination produces the same rows (row order only differs where no
`ORDER BY` fixes it) and raises the same error codes; the planner and the
executor guarantee this structurally:

* the vectorized evaluator computes exactly the same values as `eval`:
  it reuses the same arithmetic / comparison / accumulation routines
  (`arith_int`, `arith_dec`, `cmp_typed`, `agg_accum`, `agg_finish`), and
  every node kind it has no kernel for falls back to `eval` per row;
* AND / OR evaluate their right operand only where the left one does not
  decide the result (the row evaluator's short circuit); a filter evaluates
  the right operand of a conjunction where the left one is TRUE or NULL
  (as the row evaluator does) and keeps the rows where both are TRUE;
* all three join algorithms evaluate the same key expressions (all keys of
  both inputs) and the residual condition only on key-equal pairs;
* parallel tasks work on contiguous windows of their input and their
  outputs are concatenated / merged in window order, so results do not
  depend on the number of threads; group order in hash aggregation is the
  order of first appearance;
* FLOAT64 `SUM` / `AVG` are never split across threads (floating-point
  addition is not associative; INT64 / DECIMAL sums are exact 128-bit and
  merge exactly).

`make test` checks this: `tests/unit/test_exec5.S` runs 30 cases under six
settings (with `g_par_min_rows` = 1, so 4-row tables are split into
parallel tasks) and compares row counts, errors and result checksums;
`tests/sh/run_mode_tests.sh` runs 30 queries over the generated fixture
tables under eight option combinations (`PQ_PARALLEL_MIN_ROWS=37`) and
compares the results as multisets. During development a throw-away random
query generator (outside the repository) compared five option sets on more
than 5000 random queries (2–4-way inner / LEFT / comma joins, grouping,
DISTINCT aggregates, NULL-heavy data, LIKE / IN / BETWEEN / CASE, top-N),
also on 100k-row data with the default parallel thresholds, without a
mismatch.

### Row mode: Volcano iterators (`volcano.S`)

`it_open` turns the tuple operators of a plan into an iterator tree; `it_next`
returns the next tuple (valid until the following call) or 0. A TableScan
iterator walks the candidate rows of `scan_ranges` (whole table, row groups
that are not skipped, index row runs) and returns the rows passing the
pushed-down filter; Filter pulls until its predicate holds; NestedLoopJoin and
HashJoin materialise their right input when opened (the build side: key
records / chained hash table) and pull the left input one tuple at a time;
MergeJoin is blocking (sorts both inputs when opened). Project pulls the rows
one by one and projects only the rows inside OFFSET / LIMIT (it still pulls
the rest of its input, so filters see — and raise errors on — the same rows
in every mode); Aggregate, Distinct and Sort consume their whole input.

### Vectorized execution (`vexec.S`, `vagg.S`, `ops.S`)

* **Batches and vectors.** A batch is up to `VBATCH` = 1024 tuples read in
  place from a tuple set (no copy). A `Vec` holds 1024 payloads and 1024
  NULL bytes (9 KiB: a batch's working set of a few vectors stays in L1/L2);
  a selection vector lists the active positions (u16). Scratch vectors come
  from a per-thread pool (stack discipline), so batches allocate nothing.
* **Kernels** (`veval`): column reads (PLAIN and DICT columns, null
  bitmaps, LEFT JOIN padding), literals, constant subtrees (evaluated once
  and broadcast), comparisons, `+ - * / %` for INT64 / FLOAT64 and `+ - *`
  for DECIMAL, unary minus, NOT, IS [NOT] NULL, the implicit casts, AND/OR.
  Functions, CASE, LIKE, IN lists, subqueries, outer references and
  row-layout tables use the row evaluator per selected position.
* **Explicit SIMD.** A comparison of two signed 64-bit vectors over a dense
  selection runs as a NEON kernel (`cmgt` / `cmeq` on 2 × 64-bit lanes,
  masks combined per operator; NULL bytes OR-ed 16 at a time).
* **Dictionary predicates.** `string_column op 'literal'` on a dictionary
  encoded column evaluates the comparison once per dictionary entry into a
  truth table (cached per batch context) and then reads one byte per row by
  dictionary code.
* **Filters** (`vfilter`) narrow selection vectors conjunct by conjunct
  (the right operand of AND only sees the positions where the left one is
  not FALSE); scans build tuples for whole batches and copy only the
  survivors.
* **Hash aggregation** (`vagg.S`): GROUP BY keys and aggregate arguments
  are evaluated as vectors; every tuple is hashed into an open-addressing
  table (linear probing, load ≤ 1/2) of contiguous group records
  `[hash, first tuple, key cells, aggregate states]` (cache-friendly: one
  record holds everything a group needs). COUNT / SUM / AVG of INT64 and
  DECIMAL are accumulated inline, MIN / MAX and FLOAT64 sums through
  `agg_accum`. Keys that are columns of dictionary-encoded STRING columns
  are hashed and compared by dictionary entry instead of by bytes. Queries
  without GROUP BY use a single group without hashing. DISTINCT aggregates
  use the sort-based path.
* **Projection** evaluates each output column as a vector and scatters it
  into the result rows.
* **DISTINCT** (`vdistinct`) hashes the visible cells of every result row
  into a key-only group table and keeps the first row of every value (O(n)
  instead of sorting); with threads, windows are deduplicated in parallel
  and merged like partial aggregates.
* **ORDER BY** (`sort.S`) uses normalized keys: the leading non-STRING
  ORDER BY keys get exact order-preserving 64-bit codes (biased integers,
  sign-folded floats, inverted for DESC), and a permutation of the rows is
  radix sorted on them (stable LSD, last key first, constant bytes
  skipped); only rows with equal codes go through the comparator. A STRING
  first key is radix sorted on its 8-byte prefix; with threads, such sorts
  (and sorts with a NULL in a radix key) are chunk-sorted in parallel and
  merged pairwise in parallel rounds. The key list ends with every visible
  column as a tie-breaker, so rows that tie on the ORDER BY keys still come
  out in one well-defined order in every mode (row mode: `qsort_r` with the
  same comparator).

### Parallelism (`parallel.S`)

`par_run` starts one thread per task (pthreads) and joins them. A worker
copies the caller's request state (deadline, cancellation flag, memory
budget, execution settings, catalog snapshot), runs its task under its own
`setjmp` error handler and allocates from its own request arena; when it
ends, its arena chunks are moved into the caller's arena (`arena_adopt`), so
results stay valid until the request ends and nothing needs locks. The
first error of any task (in task order) is re-raised in the caller after
all tasks finished. Timeouts and cancellation reach workers through the
copied deadline and flag (`check_deadline` in every loop).

In vectorized mode, parallel operators split their input into contiguous
windows, at most `threads`, each at least `g_par_min_rows` = 16384 rows
(environment variable `PQ_PARALLEL_MIN_ROWS` overrides it, for tests):

* **scans**: the candidate row ranges (whole table, row groups not skipped,
  index row runs) are cut into windows of candidate rows; each task filters
  its window; outputs are concatenated in order;
* **filters / projections** over tuple sets (`ops.S`);
* **join keys**: the key cells and hashes of both join inputs are computed
  by tasks over windows of the input (`vkey_cells`);
* **hash-join probes** (after the build of the chained table, the probe of
  the left tuples is split);
* **aggregation**: each task aggregates its window into its own group table
  (partial aggregation); the partial tables are then merged by parallel
  merge tasks, one per hash partition (each takes its partition's groups
  from every partial table in task order; `merge_states`: counts and
  128-bit sums add, MIN / MAX compare), and the final groups are ordered by
  their first input tuple (radix sort), which is exactly the serial group
  order; finishing the groups, HAVING and the projection of the result
  rows run as parallel tasks over windows of the groups.

Expressions containing subqueries are never evaluated on workers (subquery
results are cached in shared plan nodes on first use).

### Joins (`join.S`)

* **HashJoin**: chained hash table over the build input's key cells and
  hashes (computed as vectors in vectorized mode), parallel probe. With
  `optimize` the smaller input (estimate) is the build side of an inner
  join.
* **MergeJoin**: both inputs' key cells, an index array of the tuples with
  non-NULL keys sorted by key — an 8-bit LSD radix sort (stable, constant
  bytes skipped) for one integer-like key, `qsort_r` otherwise — then runs
  of equal keys are joined pairwise; LEFT JOIN padding for unmatched and
  NULL-key tuples.
* **NestedLoopJoin**: every pair; forced for an equi-join it compares the
  precomputed key cells before the residual condition.

All three enforce `--max-join-rows` and return identical multisets.

### Optimizer (`optimize.S`, `plan.S`, `exec.S`)

With `optimize` (default) the planner rewrites every expression of a query
level before building the logical plan:

* **constant folding**: constant subtrees (no columns, aggregates,
  subqueries, `PQ_SLEEP`) are evaluated at planning time under a nested
  error handler and replaced by literals. A constant that raises (`1/0`) is
  left in place, so the error appears at run time exactly as without
  optimization (e.g. not at all if no row is evaluated);
* **predicate simplification** (three-valued logic): `x AND TRUE`,
  `TRUE AND x` → `x`; `FALSE AND x` → `FALSE`; `x OR FALSE`, `FALSE OR x`
  → `x`; `TRUE OR x` → `TRUE`; `NOT NOT x` → `x`. A WHERE / HAVING / ON
  condition that becomes TRUE disappears from the plan;
* **join reordering** (`opt_join_order`): a region of three or more inputs
  connected by INNER / CROSS joins (a LEFT JOIN is one input of its region;
  regions inside its inputs are reordered separately) is rebuilt as a
  left-deep tree in greedy order — the input with the smallest estimated
  cardinality (access-path estimate after predicate pushdown) first, then
  always the smallest input connected to the joined set by a condition.
  Every condition of the region (ON conditions and pushed-down WHERE
  conjuncts) is attached to the lowest join covering its range variables.
  Tuples keep one slot per range variable and joins merge them slot-wise,
  so the order never changes results (two-input joins only choose the
  hash-join build side);
* **top-N**: `ORDER BY … LIMIT n [OFFSET m]` keeps a bounded max-heap of
  `n + m` rows (O(N log k)) instead of sorting all rows;
* **build side** selection for hash joins (Phase 3).

Also in place from earlier phases: predicate pushdown, projection pushdown
(column pruning), index selection and PQCF row-group skipping.

### Memory

All per-request memory is bump-allocated from arenas (no `free` per
object; a whole request is released at once), worker arenas are adopted
without copying, vectors are pooled per thread, group tables and hash join
tables are flat arrays, and batches read tuple sets in place.

### Measurements

Hardware: NVIDIA GB10 (Arm Cortex-X925 / A725, 20 cores), Linux, glibc.
Data: `python3 datasets/generators/pqgen.py generate --scale 1m` —
`transactions` 1,000,000 rows, `order_items` 1,000,000, `orders` 250,000,
`customers` 100,000, loaded as CSV with the generated schemas (column
layout). `bench/bench.sh DATA_DIR 5` runs every query five times per option
set in one session and reports the best engine-measured time
(`stats.elapsed_us`). "before" is the Phase 4 executor (commit `d21cf39`:
the Phase 4 engine plus option parsing, `bench/baseline-before.txt`); the
other columns are this engine (`bench/results-after.txt`). Times in ms.

| query | before | row | row, optimize=false | vectorized | vectorized, optimize=false | vectorized, 4 threads | vectorized, 8 threads | merge join (vectorized) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Q1 filter + aggregate (`status = 'approved' AND amount > 100`) | 18.0 | 18.8 | 19.2 | 4.2 | 4.1 | 2.0 | 1.2 | 4.2 |
| Q2 GROUP BY category, 5 aggregates | 158.3 | 159.3 | 151.5 | 20.8 | 20.1 | 9.3 | 5.4 | 19.9 |
| Q3 GROUP BY `bucket % 10` | 100.5 | 104.6 | 97.4 | 18.7 | 18.8 | 8.2 | 4.3 | 18.8 |
| Q4 top-N (`ORDER BY amount DESC, tx_id LIMIT 10`) | 41.0 | 15.9 | 41.3 | 3.7 | 12.6 | 2.5 | 1.7 | 3.8 |
| Q5 join 1M × 100k + GROUP BY | 141.0 | 148.0 | 139.9 | 35.6 | 35.1 | 20.8 | 11.1 | 88.9 |
| Q6 arithmetic filter, 3 conjuncts | 19.8 | 18.5 | 20.6 | 10.3 | 10.3 | 4.8 | 2.6 | 10.2 |
| Q7 GROUP BY customer_id (80k groups) + top-N | 116.0 | 114.6 | 111.3 | 17.5 | 20.4 | 14.4 | 8.5 | 16.6 |
| Q8 3-way join (items, orders, filtered customers) | 34.9 | 22.6 | 38.6 | 12.1 | 37.4 | 8.2 | 4.9 | 32.4 |
| Q9 sort 1M rows (`ORDER BY amount, tx_id`) | 153.7 | 153.3 | 154.8 | 57.6 | 61.8 | 53.6 | 55.1 | 54.0 |
| Q10 `SELECT DISTINCT customer_id, status` (1M rows) | 225.2 | 225.6 | 226.9 | 33.6 | 33.2 | 24.1 | 14.3 | 34.1 |

Single-thread columns use `threads: 1`; all use `join: "hash"` except the
last. Observations:

* The row-mode baseline (Volcano) performs like the Phase 4 executor; with
  `optimize` it gains from top-N (Q4) and join reordering (Q8: the filtered
  customers are joined first instead of joining all items with all orders).
* Vectorization alone gives 2–8× — most for grouping (hash aggregation
  instead of sorting key records: Q2, Q3, Q7), DISTINCT (hashing, Q10) and
  the dictionary-string predicate (Q1, one byte lookup per row); sorting
  (Q9) gains 2.7× from the normalized-key radix sort.
* Threads add up to another 3.5–4.5× on 8 cores for scans and grouping
  (Q1–Q3, Q6, Q10); joins (Q5, Q8) scale less because the hash-join build
  is single-threaded; Q9 stays on the (memory-bound) single-threaded radix
  sort.
* The optimizer matters most where it changes the work: top-N (Q4) and join
  order (Q8). Constant folding and predicate simplification remove per-row
  work only for queries that contain constant expressions.
* The merge join pays for sorting both inputs (Q5) and returns tuples in
  key order.

## Implementation-defined choices

* Phase 5: `mode: "auto"` is vectorized; `join: "auto"` is a hash join for
  equi-joins; default `threads` is `--threads N`, else the number of online
  CPUs capped at 8; a parallel task gets at least 16384 input rows. Without
  ORDER BY, the row order of a result may differ between option sets
  (e.g. sort-based vs hash-based grouping, merge-join key order).
* Phase 5: every mode evaluates exactly the operands the row evaluator
  evaluates (AND / OR short-circuit only on the deciding value), so the
  same rows raise the same errors. When a query would raise *different*
  errors on different rows or columns, which one is reported first may
  depend on the mode (batches evaluate column by column).

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
* Join reordering is greedy (no exhaustive / dynamic-programming search)
  and uses simple cardinality estimates. The hash-join build, sort-based
  grouping (row mode, DISTINCT aggregates) and the merge-join sort run on
  one thread; the final merge round of a parallel sort is a single merge.
* `native: true` is accepted but no native kernel library is supported.
* Streamed projections (`/v1/query/stream`) are evaluated row at a time.
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
