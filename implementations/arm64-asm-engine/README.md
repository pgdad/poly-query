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

It also implements the architectural change **CR-1 `UNION ALL`**
(`spec/changes/union-all.md`, capability `change.union_all`); see
[Change CR-1: UNION ALL](#change-cr-1-union-all), and the behaviour-preserving
refactoring **CR-3 logical / physical plan separation**
(`spec/changes/refactor-plan-separation.md`); see
[Change CR-3](#change-cr-3-logical--physical-plan-separation).

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
| values | `values.S`, `decimal.S`, `wdec.S`, `datetime.S`, `types.S` | text parsing/formatting of every type, CAST matrix, comparisons, type names; `wdec.S`: wide DECIMAL (p ≤ 38) arithmetic on 256-bit intermediates |
| storage | `catalog.S`, `ingest.S`, `storage.S`, `pqcf.S`, `index.S` | catalog of immutable tables; CSV/JSON/JSONL ingestion; row / column layouts, dictionary encoding, statistics; PQCF v1 / v2 reader/writer; HASH / BTREE indexes |
| lexer / parser | `lexer.S`, `parser.S` | tokenizer and recursive-descent parser for the full v1 grammar into an AST |
| semantic analysis | `binder.S`, `functions.S`, `strfuncs.S` | scopes (range variables, outer scopes, CTEs), name resolution, typing with implicit casts, aggregate / GROUP BY validation, subquery binding; scalar functions, CASE, LIKE, BETWEEN, IN lists |
| logical plan | `logical.S` | LogicalNode trees (Scan, SubqueryScan, Values, Filter, Join, Aggregate, Project, Distinct, Sort, Limit, UnionAll) built from a bound query level, expression visitor, debug printer |
| optimizer | `optimize.S`, `rule_prune.S`, `rule_fold.S`, `rule_simplify.S`, `rule_pushdown.S`, `rule_joinorder.S` | rule driver (option `optimize`) and one module per rule: column pruning, constant folding, predicate simplification, predicate pushdown (filters, join conditions), join reordering — all on the logical plan |
| physical planning | `physical.S`, `access.S` | logical → physical plan: predicate placement, join keys and algorithm, access paths (simple predicates, selectivity estimates, index selection, row-group skipping), columns read, build side, top-N, execution mode / threads |
| planning driver | `plan.S` | `plan_statement` / `plan_query` (build → optimize → physical), EXPLAIN JSON of the physical plan, conjunct / range-variable helpers |
| execution | `exec.S`, `eval.S`, `ops.S`, `join.S`, `volcano.S`, `sort.S` | plan operators (scan tasks, filter, project, hash / merge / nested-loop joins, sort-based aggregation, distinct, sort, top-N, limit), subquery evaluation, batched projection for streaming; expression evaluator and aggregate accumulators |
| vectorized execution | `vexec.S`, `vagg.S` | batch expression evaluation over column vectors with selection vectors (`veval`, `vfilter`, join key vectors), hash aggregation with partial tables |
| parallelism | `parallel.S` | worker threads for query tasks (`par_run`), parallel-safety check |
| server | `http.S`, `server.S`, `log.S` | HTTP/1.1 listener and connection threads, routing, request framing, streaming, shutdown; query registry, admission control, cancellation, disconnect watchdog, metrics; structured logs |

Query processing: `parse_sql` → `bind_query` (BoundQuery per query level,
SubPlans for every subquery / derived table / CTE) → `plan_statement`
(per query level: `lp_build` LogicalNode tree → `optimize` → `phys_plan`
PlanNode tree) → `exec_plan` (ResultSet).

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
  `x0`/`x1`; the type is static (from the AST). A narrow DECIMAL (precision
  ≤ 18) is a scaled `i64` with exact 128-bit intermediates; a wide DECIMAL
  (19–38) is a pointer to a boxed `i128` (see "Change CR-2"); DATE is days and
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
request into thread-local planner inputs (`g_opt_mode`, `g_opt_join`,
`g_opt_threads`, `g_opt_optimize` in `plan.S`, `g_use_indexes` in
`access.S`). The physical planner turns them into plan properties (join
operators, top-N, `PN_XMODE` / `PN_XTHREADS` on the plan root); the
executor runs a plan with its mode and thread count (`g_x_mode`,
`g_x_threads`, inherited by worker threads). Unsupported values
(`"mode":"quantum"`) are `UNSUPPORTED`.

| option | effect |
|---|---|
| `mode: "row"` | the unoptimized baseline, kept permanently: a Volcano iterator pipeline (`volcano.S`). Scans, filters and join probes return one tuple per `next()` call, expressions go through the tree-walking evaluator `eval` one row at a time; grouping is sort-based (`qsort_r` on key records). Single-threaded. |
| `mode: "vectorized"` (also `auto`) | batch execution: scans, filters, projections, join keys and aggregates evaluate expressions over batches of 1024 tuples as column vectors (`vexec.S`), grouping is hash-based (`vagg.S`). |
| `threads: N` | in vectorized mode, scans, filters, projections, hash-join probes and aggregations run as up to N parallel tasks (default: `--threads`, else the online CPUs, at most 8; capped at 64; values < 1 are `UNSUPPORTED`). The row-mode baseline ignores it. |
| `join: "hash"` / `"merge"` / `"nested_loop"` | forces the algorithm of every equi-join; joins without an equality between the two sides are always nested loops. `auto` = hash join for equi-joins. |
| `optimize: false` | the optimizer applies no rule to the logical plan (column pruning, constant folding, predicate simplification, predicate pushdown, join reordering); the physical planner uses neither top-N nor the cost-based hash-join build side. The Phase 3 planner guarantees still hold (indexes-and-planning.md §3: single-table conjuncts evaluated at the scan, scans reading only referenced columns, index selection — controlled by `use_indexes`), because the physical planner provides them for any logical plan; the Phase 3 suite checks them under every option combination. |
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
  skipped); only rows with equal codes go through the comparator (a NULL
  in a radix key falls back to `qsort_r`). A STRING first key is radix
  sorted on its 8-byte prefix; with threads such sorts are chunk-sorted in
  parallel and merged pairwise in parallel rounds. The key list ends with every visible
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

### Optimizer (`optimize.S`, `rule_*.S`, `physical.S`)

With `optimize` (default) the optimizer rewrites the logical plan of every
query level (see [Change CR-3](#change-cr-3-logical--physical-plan-separation)
for the rule modules):

* **constant folding**: constant subtrees (no columns, aggregates,
  subqueries, `PQ_SLEEP`) are evaluated at planning time under a nested
  error handler and replaced by literals. A constant that raises (`1/0`) is
  left in place, so the error appears at run time exactly as without
  optimization (e.g. not at all if no row is evaluated);
* **predicate simplification** (three-valued logic): `x AND TRUE`,
  `TRUE AND x` → `x`; `FALSE AND x` → `FALSE`; `x OR FALSE`, `FALSE OR x`
  → `x`; `TRUE OR x` → `TRUE`; `NOT NOT x` → `x`. A WHERE / HAVING / ON
  condition that becomes TRUE disappears from the plan;
* **join reordering** (`rule_reorder_joins`): a region of three or more inputs
  connected by INNER / CROSS joins (a LEFT JOIN is one input of its region;
  regions inside its inputs are reordered separately) is rebuilt as a
  left-deep tree in greedy order — the input with the smallest estimated
  cardinality (statistics estimate after predicate pushdown) first, then
  always the smallest input connected to the joined set by a condition.
  Every condition of the region (ON conditions and pushed-down WHERE
  conjuncts) is attached to the lowest join covering its range variables.
  Tuples keep one slot per range variable and joins merge them slot-wise,
  so the order never changes results (two-input joins only choose the
  hash-join build side);
* **predicate pushdown** and **column pruning** on the logical plan;
* physical choices that also depend on `optimize`: **top-N** (`ORDER BY …
  LIMIT n [OFFSET m]` keeps a bounded max-heap of `n + m` rows, O(N log k),
  instead of sorting all rows) and **build side** selection for hash joins
  (Phase 3).

Index selection and PQCF row-group skipping are physical access-path
decisions (`physical.S` → `access.S`).

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

## Change CR-1: UNION ALL

`query = [with_clause] compound [order_by] [limit_clause]`,
`compound = select_core { UNION ALL select_core }` — at the top level, in
CTE bodies, derived tables, scalar / IN / EXISTS subqueries and EXPLAIN, in
every execution mode. A compound is one more *query level* of the existing
pipeline; nothing else had to learn about it:

| layer | module | change |
|---|---|---|
| AST | `include/pq.inc` | `Q_UNION` / `Q_NUNION`: a compound Query keeps WITH / ORDER BY / LIMIT / OFFSET and points to its branch Queries (plain select cores) |
| parser | `parser.S` | `p_union` after the first select core; `p_error`: `UNION` without `ALL` stays `UNSUPPORTED`, a misplaced `UNION ALL` (after ORDER BY / LIMIT, parenthesised branch) is `PARSE_ERROR` |
| binder | `binder.S` | `bq_bind_union`: the compound is a binder level without range variables that owns the WITH clause; every branch is bound as a nested level below it (so correlation depths and CTE levels stay uniform); column count check (`SEMANTIC_ERROR`), common type per column with `common_type` (the CASE rule; `TYPE_ERROR`), branch expressions of another type wrapped in an implicit CAST (so INT64 → DECIMAL(18,s) overflow is `NUMERIC_OVERFLOW` at run time); names from the first branch; `bind_order` accepts only output column names / positions for a compound |
| bound query | `include/pq.inc` | `BQ_UNION` / `BQ_NUNION` (branch BoundQueries) |
| planner | `plan.S` | `plan_union`: `Limit? <- Sort? <- UnionAll(branch plans)`, each branch planned and optimised on its own (`lp_upper` shared with `lp_build`); EXPLAIN `{"op":"UnionAll","children":[branch plans in order]}` |
| executor | `exec.S` | `ex_union` (`PO_UNION` in `ex_rows`): runs each branch plan as a nested level and concatenates the row pointers; Sort / top-N / Limit / caching of subqueries / materialisation of derived tables and CTEs work on the compound's result unchanged |
| protocol | `protocol.S` | capability `change.union_all` |

Execution options: the branches are ordinary query plans, so `mode`,
`threads`, `join` and `optimize` apply inside every branch; the
concatenation itself is O(rows) pointer copying. Results are identical
across option sets (checked by `tests/sh/run_mode_tests.sh`).

Choices: the compound output column has the branch-0 name; a duplicated
output name used in the compound's ORDER BY is ambiguous (`SEMANTIC_ERROR`);
a qualified name (`t.c`) is not an output column name (`SEMANTIC_ERROR`);
two DECIMAL branches unify to DECIMAL(W, max scale) like CASE; DATE and
TIMESTAMP branches do not unify (`TYPE_ERROR`), as for CASE. `spec_version`
stays `1.0.0` (the Phase 1 conformance case requires it).

## Change CR-2: DECIMAL precision 38 (PQCF v2)

`DECIMAL(p,s)` accepts `1 ≤ p ≤ 38` (`spec/changes/decimal38.md`, capability
`change.decimal38`). Narrow decimals (p ≤ 18) keep their representation and
code paths; only expressions with a wide operand (p > 18) take the new ones.

### Representation

* **Narrow** (p ≤ 18): the payload is the unscaled `i64` (unchanged).
* **Wide** (19 ≤ p ≤ 38): the payload is a pointer to a 16-byte box holding
  the unscaled value as a two's-complement little-endian `i128`
  (|v| < 10^p). Boxing keeps every value a 64-bit payload, so tuples, cells,
  vectors, column vectors, the row store, sort / hash / join key cells and
  aggregate states did not change shape — exactly like `Str*` for STRING.
  Boxes live in the request arena (computed values, literals), in a worker's
  arena (adopted by the request), or in the table arena (ingestion, PQCF,
  `rebuild_table` / `build_rows` deep-copy them with `val_copy_in` like
  strings).
* Exact intermediates use a **256-bit** two's-complement integer in memory
  (`wdec.S` "I256": add/sub/neg, ×10^k, ÷10^k with truncate / half-away /
  floor / ceiling rounding, i128×i128, digits, compare, fit check against
  10^p). 76-digit products, 38-digit values rescaled by 10^38 and sums of 2^64
  values all fit. Wide `SUM`/`AVG` accumulate 192 bits (`AS_LO/AS_HI/AS_TOP`
  of the aggregate state); AVG converts the exact sum to the nearest double
  (decimal text → `strtod`) before dividing by the count.
* The check "is this type wide" is the macro `BR_WIDE` (`pq.inc`): kind
  DECIMAL and precision > 18. There is no separate type kind, so type names,
  CAST targets, schemas and PQCF metadata are unchanged in form.

### Dispatch narrow / wide

* **Typing** (`binder.S`, `functions.S`): `dec_wtype` computes the result
  precision W (38 if any DECIMAL operand is wide, INT64 does not count) for
  `+ - *` (scale check `s1+s2 > W` ⇒ TYPE_ERROR), INT64 promotion, `SUM`,
  `ROUND`, `FLOOR`/`CEIL`, and `common_type` (CASE, COALESCE, UNION ALL).
* **Evaluation**: `eval.S` dispatches on the *result* type — narrow results
  keep `arith_dec` (128-bit), wide results call `dec_arith` (256-bit);
  `ev_unary` / ABS / ROUND / FLOOR / CEIL / CAST call the `wdec.S` routines
  when a wide type is involved; the vectorized kernels (`vexec.S`, `vagg.S`)
  use the same routines per value (`arith_dec_any`, `dec_neg`, comparison
  class "exact via cmp_typed", wide SUM through `agg_accum`).
* **Comparisons are exact** (§4): `cmp_typed` compares narrow decimals of
  different scales in 128 bits as before and every other INT64 / DECIMAL
  combination (wide, mixed width, INT64 vs DECIMAL) with `dec_cmp`
  (256-bit alignment). The binder keeps both comparison operands in one
  payload encoding so hash keys, indexes and row-group statistics keep
  working: a narrow operand compared with a wide one is widened to
  DECIMAL(38, s) (never overflows); an INT64 operand compared with a
  DECIMAL(p,s) is cast to DECIMAL(W,s) with the flag `T_SATF` — a
  *saturating* cast: a value that does not fit becomes ±INT64_MAX (narrow)
  or ±10^38 (wide), which lies beyond every value of the other operand, so
  `9223372036854775807 > 1.5` is TRUE instead of NUMERIC_OVERFLOW. `x IN
  (subquery)` compares INT64 / DECIMAL values without casts (`cmp_typed`).
  DECIMAL vs FLOAT64 still converts the decimal to the nearest double.
* **Hashing / sorting**: `hash_cell` hashes the 16 bytes of a wide value
  (`dec_hash`); `keys_equal`, `gt_keys_eq` compare wide keys by value; the
  radix paths (merge-join key sort, normalized sort keys) treat a wide key
  like a STRING (prefix code = high word, comparator for ties); hash-join
  keys require the same scale *and* width (`try_hash_key`); index lookups
  convert the key exactly into the column's encoding (`dec_convert`, exact
  mode).
* **Text / CAST / ingestion**: `parse_dec128` (the `parse_decimal` rules for
  p ≤ 38: exact for ingestion, half-away rounding for CAST), `fmt_dec128`
  (canonical text), `dec_from_f64` (exact binary value of the double, printed
  with s+40 digits and rounded), `dec_to_double` (exact text → `strtod`),
  `dec_to_int` (truncation, INT64 range check). Literals with 19–38
  significant digits are wide DECIMAL literals; with more than 38 they stay
  FLOAT64. Schema / CAST types accept p ≤ 38 (`type_from_name`).

### PQCF v2 (`pqcf.S`)

A table with at least one wide column is written as format version 2 (header
and metadata `format_version`), every other table as version 1. Wide chunks:
PLAIN n × i128, RLE `u32 R` + R × `{i128, u32}` (20 bytes, packed; NULL rows
hold 0 and join runs), min/max statistics as canonical decimal strings;
narrow columns keep the v1 layout. The reader accepts versions 1 and 2
(> 2 or flags ≠ 0 ⇒ STORAGE_VERSION_UNSUPPORTED), rejects a wide column type
in a v1 file and a header / metadata version mismatch (STORAGE_CORRUPT),
checks |v| < 10^p for every non-null wide value (STORAGE_CORRUPT), and boxes
the values in the table arena (one box per RLE run, also with `mmap`).

### Modules touched

| module | change |
|---|---|
| `include/pq.inc` | wide-decimal representation notes, `DEC_NARROW_MAX`, `DEC_MAX_PREC`, `T_SATF`, `BR_WIDE` |
| `wdec.S` (new) | 256-bit integer toolkit and every wide-decimal operation (box, compare, + - *, convert/CAST, to INT64 / FLOAT64, from FLOAT64, ROUND, FLOOR/CEIL, ABS, negation, hash, parse, format) |
| `types.S` | precision limit 38 |
| `parser.S` | wide literals (19–38 digits); `AS FULL` / `AS RIGHT` accepted as an explicit alias (the public decimal38 case uses `AS full`) |
| `binder.S` | `dec_wtype`, `dec_widen`; W for arithmetic / SUM; exact comparison casts (`T_SATF`); IN-subquery without INT64 → DECIMAL casts; `expr_equal` compares wide literals by value |
| `functions.S` | `common_type` W; ABS / ROUND / FLOOR / CEIL typing and wide evaluation |
| `values.S` | text output, `value_cmp`, CAST matrix for wide / saturating targets |
| `eval.S` | `cmp_typed` exact for any INT64 / DECIMAL mix, `arith_dec_any`, unary minus, saturating / wide INT64 casts, 192-bit wide SUM / AVG |
| `vexec.S`, `vagg.S` | wide arithmetic / comparison / negation per value; wide SUM via `agg_accum`; 192-bit partial-state merge |
| `join.S`, `sort.S`, `physical.S` | hashing, key equality, radix exclusion, hash-key width check |
| `index.S`, `access.S` | exact key conversion for lookups; constant folding of wide / saturating casts; selectivity of wide constants |
| `storage.S` | `val_copy_in` (deep copy of boxed values when a table is rebuilt) |
| `ingest.S` | wide values parsed exactly and boxed in the table arena (CSV, JSON, JSONL) |
| `pqcf.S` | PQCF v2 writer / reader |
| `protocol.S` | capability `change.decimal38` |

`spec_version` stays `1.0.0` (the Phase 1 conformance case requires it).

## Change CR-3: logical / physical plan separation

A behaviour-preserving refactoring (`spec/changes/refactor-plan-separation.md`):
same responses, errors, EXPLAIN output and capabilities. Planning of a query
level is now three separate steps with their own data structures:

```
BoundQuery --lp_build--> LogicalNode tree --optimize (rules)--> LogicalNode tree
           --phys_plan--> PlanNode tree --exec_plan / plan_explain
```

### Module map

| concern | before | after |
|---|---|---|
| plan data structures | `PlanNode` (`pq.inc`) for both: the logical plan was rewritten in place into the physical one | **logical plan** `LogicalNode` (`pq.inc` `LN_*`, ops `LO_*`: Scan, SubqueryScan (derived table / CTE), Values, Filter, Join (type + condition), Aggregate (keys + aggregate calls + HAVING), Project, Distinct, Sort, Limit, UnionAll; expression subqueries keep their own logical plan in `SP_LPLAN`); **physical plan** `PlanNode` (`PN_*`, ops `PO_*`) |
| building the logical plan | `plan.S` `lp_build` / `lp_from` / `lp_upper` / `plan_union` (PlanNodes) | `logical.S` `lp_build` (no decisions: WHERE is one Filter above the FROM tree, ON conditions stay on their joins, scans read every column) |
| printing it | — (only EXPLAIN of the physical plan) | `logical.S` `lp_print` / `lp_print_expr` (debug text; `PQ_TRACE_PLAN=1` prints the plan before and after every rule to stderr) |
| optimizer driver | `plan.S` `plan_query` calling `optimize.S` `opt_query` (rewrote the *bound query's* expressions before planning) and `pp_rewrite` calling `opt_join_order` | `optimize.S` `optimize`: rule table, applied in order to the logical plan only; nothing when `optimize` is false |
| rule: projection / column pruning | binder flags (`RV_USED`) printed by EXPLAIN | `rule_prune.S` `rule_prune_columns` (columns referenced by the plan's expressions + correlated references flagged `RVU_OUTER` by the binder) |
| rule: constant folding | `optimize.S` `opt_expr` (folding part), `opt_foldable`, `try_eval` | `rule_fold.S` `rule_fold_constants` |
| rule: predicate simplification | `optimize.S` `opt_expr` (simplification part), `opt_cond_slot` | `rule_simplify.S` `rule_simplify_predicates` |
| rule: predicate pushdown | `plan.S` `pp_rewrite` + `push_conj` (WHERE), `pp_joins` (ON conjuncts), physical | `rule_pushdown.S` `rule_push_filters` (Filter conjuncts into scans / onto joins), `rule_push_join_conditions` (single-input join conjuncts into the inputs) |
| rule: join reordering | `optimize.S` `opt_join_order` / `jo_*` on PlanNodes, estimates via `ap_scan` | `rule_joinorder.S` `rule_reorder_joins` on LogicalNodes, estimates via `access.S` `scan_estimate` (statistics only) |
| physical planner | `plan.S` `pp_rewrite`, `pp_joins`, `try_hash_key`, `pp_access` (mixed with the logical steps above); top-N decided in `exec.S` from `g_x_optimize` | `physical.S` `phys_plan`: lowering (`pp_lower`), predicate placement, join keys and algorithm (option `join`), access paths (`access.S` `ap_scan`: index / table scan, row groups), columns read, hash-join build side, top-N (`PN_TOPN`), execution mode and threads (`PN_XMODE` / `PN_XTHREADS`, installed by `exec_plan`) |
| EXPLAIN | `plan.S` `plan_explain` (physical plan) | unchanged, from the physical plan; the scan column list now comes from the physical scan (`PN_COLS`) |
| planner driver | `plan.S` `plan_statement` / `plan_query` | `plan.S` `plan_statement` / `plan_query`: `lp_build` → `optimize` → `phys_plan` per query level (SubPlans: `SP_LPLAN`, `SP_PLAN`) |
| options | `exec.S` `g_x_mode` / `g_x_join` / `g_x_threads` / `g_x_optimize`, read by planner and executor alike | planner inputs `plan.S` `g_opt_*` (protocol.S); the executor only sees the plan's settings (`exec.S` `g_x_mode` / `g_x_threads`) |

### Rules

`optimize.S` applies, in this order: `prune_columns`, `fold_constants`,
`simplify_predicates`, `push_filters`, `reorder_joins`,
`push_join_conditions`. Each is a function `LogicalNode* → LogicalNode*`
that only reads statistics and rewrites the logical plan. The order is the
order the decisions were taken before the refactoring, which keeps every
plan identical: join reordering estimates its inputs with the WHERE
conjuncts already on the scans (not yet the single-input ON conjuncts) and
attaches each condition to the lowest join covering it, which
`push_join_conditions` then splits; column pruning runs on the expressions
as written, so a column referenced only inside an operand that
simplification removes (`FALSE AND c > 5`) stays in the column list, as it
always did.

`tests/unit/test_optimizer.S` (42 cases) checks the logical plan builder and
every rule on its own: SQL → bind → `lp_build` → one or two rules →
`lp_print` compared with the expected plan text, plus the whole optimizer
with `optimize` on and off.

### `optimize: false` and the Phase 3 planner guarantees

With `optimize: false` no rule runs. The Phase 3 requirements
(indexes-and-planning.md §3) — single-table WHERE conjuncts evaluated at the
scan, scans reading only referenced columns, index selection — hold for
every plan, and the conformance `--modes` suite checks them with
`optimize: false`. The physical planner therefore guarantees them itself:
it places every conjunct at the lowest operator that can evaluate it (the
same placement the pushdown rules perform on the logical plan, so after the
optimizer it finds nothing left to move), and a scan the optimizer did not
prune reads the columns the query references (the binder's `RV_USED`). This
is exactly what the engine did before with `optimize: false`.

### Verification

Besides the conformance suites (session, `--modes`, HTTP, HTTP suite) a
throw-away differential script compared the responses of the engine before
and after the refactoring for every SQL statement of the conformance cases
plus extra planner-heavy queries (multi-way joins with ON / WHERE
conjuncts, LEFT joins, correlated subqueries, derived tables, CTEs,
UNION ALL, constant folding that raises, simplification), each as `explain`
and `query` under ten option sets: 9059 requests, no difference.

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
* DECIMAL ± DECIMAL with different scales is aligned exactly (128-bit for
  narrow, 256-bit for wide operands: no spurious overflow); INT64 operands
  of arithmetic are promoted to DECIMAL(W,s) as the spec requires.
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
  DECIMAL(W, max scale) (W = 38 if one of them is wide, else 18); a single
  DECIMAL branch keeps its type. DATE and
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
* Wide DECIMAL values are boxed (16 bytes + an 8-byte pointer per value) and
  their arithmetic / comparisons go through 256-bit routines; the vectorized
  evaluator handles wide arithmetic and comparisons per value (no SIMD), and
  wide casts fall back to the row evaluator.
* Ingestion builds a plain columnar table first; converting it (row layout,
  dictionary encoding) rebuilds it into a fresh arena, so loading needs
  transient memory for both representations.
