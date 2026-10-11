# PolyQuery — x86-64 assembly engine

An in-memory analytical database engine implementing the PolyQuery
specification (`spec/`), written entirely in hand-written x86-64 assembly
(GNU as, AT&T syntax). Status: **Phase 5** (protocol, catalog, CSV/JSON/JSONL
ingestion, all data types, the complete SQL grammar: GROUP BY/HAVING,
DISTINCT, INNER/LEFT/CROSS joins, all scalar functions, CASE/LIKE/BETWEEN/IN,
uncorrelated and correlated subqueries, derived tables, CTEs, EXPLAIN,
structured errors, resource limits, test functions; row and column
in-memory layouts with NULL bitmaps and dictionary encoding, table
statistics, HASH and ordered (BTREE) indexes, predicate pushdown, index
selection, row-group skipping, column pruning, join build-side selection,
and the PQCF v1 columnar file format with PLAIN/DICT/RLE encodings, CRC-32
checksums, atomic crash-safe saves and memory-mapped reads; the `serve`
HTTP/1.1 server with all endpoints, pipelined NDJSON streaming, Prometheus
metrics, structured JSON logs, snapshot-isolated concurrent queries, worker
limits with FIFO queueing and `OVERLOADED` rejection, timeouts, cancellation
and graceful shutdown; Phase 5: the row-at-a-time baseline next to
vectorized batch execution with AVX2 kernels, intra-query parallelism for
scans, filters, projections, hash-join probes and (hash-partitioned)
aggregation, hash / sort-merge / nested-loop joins selectable per query, a
switchable logical optimizer and top-N sorting - see
[Phase 5](#phase-5-execution-modes-parallelism-and-optimizations)).

## Build prerequisites

| Tool | Version | Use |
|---|---|---|
| GNU binutils (`as`, `ld`) | 2.42 | assembler / linker |
| gcc | 13.3 | **driver only**: runs cpp on `.S` files, the assembler and the linker. No C source exists anywhere in the build. |
| glibc (libc, libm, libpthread) | system | dynamically linked runtime (malloc, read/write, strtod, snprintf, qsort_r, setjmp/longjmp, …) |
| GNU make, POSIX sh | any | build and tests |

```
make build        # -> out/polyquery
make test         # assembly unit tests (text, JSON, ingest, hash, SQL,
                  # storage, planner, HTTP parser) + end-to-end session
                  # tests + end-to-end serve tests (curl) + the Phase 5
                  # differential test of all execution options
make lint         # verifies every object carries a non-executable .note.GNU-stack
make fmt          # whitespace normalisation
make clean
bin/polyquery session --data-dir DIR
bin/polyquery serve --port 0 --data-dir DIR [--workers N] [--queue-depth Q] ...
```

`bin/polyquery` is a small shell launcher that builds on first use and execs
`out/polyquery`; it works from any directory.

## Libraries

None besides glibc (`ENGINE.json`: `"libraries": []`).

## Design overview

The code is organised in layers, one module (`src/*.S`) per layer, with shared
structure layouts and macros in `include/`:

| Layer | Module | Responsibility |
|---|---|---|
| runtime | `util.S` | globals, error raising (`pq_raise` → `longjmp`), arenas, byte buffers, vectors, length-prefixed strings |
| text | `text.S` | number/date/timestamp/decimal parsing and canonical formatting, type names |
| JSON | `json.S` | strict RFC 8259 parser to a DOM, serializer |
| storage | `catalog.S`, `ingest.S`, `table.S` | catalog of immutable tables; CSV / JSON / JSONL ingestion with inference and explicit schemas; physical row / column layouts, NULL bitmaps, dictionary encoding, lazily computed statistics |
| indexes | `index.S` | HASH (chained over row ids) and BTREE (sorted permutation + keys, binary search) indexes; CREATE / DROP INDEX |
| PQCF files | `pqcf.S` | PQCF v1 writer (PLAIN / DICT / RLE, chunk statistics), validating reader, CRC-32, UTF-8 validation, atomic replacement |
| lexer | `lexer.S` | SQL text → tokens with line/column |
| parser / AST | `parser.S`, `ast.S` | recursive descent over the full grammar → statement, query, FROM-item and expression nodes (`include/sql.inc`); `ast.S` gives generic child access to every expression kind |
| semantic analysis + logical plan | `binder.S` | scopes and range variables, CTE visibility, name resolution (incl. correlation), typing with implicit promotions, aggregate / GROUP BY validation by structural equality, output naming, ORDER BY resolution, constant LIMIT/OFFSET → plan tree (`QP_*` per query block, `FP_*` FROM tree, `RV_*` range variables) |
| scalar functions | `functions.S` | binding (typing) and evaluation of all scalar functions, CASE, LIKE, BETWEEN, IN lists |
| logical optimizer | `optimizer.S` | error-preserving constant folding, AND/OR simplification (option `optimize`) |
| physical planning / EXPLAIN | `binder.S` (`find_equi`), `planner.S`, `explain.S` | join key extraction and algorithm choice (hash / merge / nested loop, option `join`); predicate pushdown, index selection, row-group skipping, cardinality estimates and hash-join build side; JSON plan rendering |
| execution (row baseline) | `eval.S`, `exec.S`, `join.S`, `hash.S` | expression interpreter (exact DECIMAL with 128-bit intermediates, CAST matrix); materialising tuple-at-a-time operators: scan, hash / sort-merge / nested-loop join, filter, hash aggregation, projection, DISTINCT, sort, offset/limit; subquery evaluation; generic hash table on value cells |
| execution (batch / parallel) | `pexec.S`, `vec.S`, `par.S` | batch operator drivers split into parallel parts; vectorized expression evaluator and kernels (filter, projection, group keys, aggregation, join keys / ON re-check); worker threads with thread-local arenas and error handlers |
| protocol | `protocol.S`, `main.S` | CLI, JSON-lines session loop, `exec` mode, request validation, operations (`query`, `explain`, …), path safety, fault guard |
| HTTP | `http.S` | HTTP/1.1 message layer: incremental request parsing (Content-Length and chunked bodies, size limits, malformed framing), response / chunk writing, URL decoding, query parameters, error code → status mapping |
| server | `server.S` | `serve`: poll() event loop, connections and keep-alive, routing, admission control (workers, FIFO queue, `OVERLOADED`), fork-per-query execution, catalog worker thread, timeouts, cancellation, streaming, metrics, JSON logs, graceful shutdown |

The SQL pipeline is lex → parse (AST) → bind (semantic validation, typed
AST) → plan (logical plan tree with the physical join choice) → execute.
Errors detected before execution are reported without executing anything.

Key decisions:

* **Error handling** uses glibc `_setjmp`/`longjmp`: any layer raises an error
  with a code and message; the request dispatcher reports it. Since all
  per-request memory comes from a request arena (reset per request) and tables
  under construction live in their own arena (destroyed on failure), no cleanup
  code is needed on error paths, and failed operations never modify the catalog.
* **Memory**: arenas (bump allocation in malloc'd chunks). The request arena
  carries the `--max-query-memory-mb` budget (exceeding it ⇒ `RESOURCE_LIMIT`).
  Each table owns an arena, freed on `drop`/`replace`/`reset`.
* **Values** are one `u64` slot each: BOOLEAN 0/1, INT64, FLOAT64 bits,
  DECIMAL unscaled i64, STRING as a pointer to a length-prefixed string, DATE
  days and TIMESTAMP microseconds since the epoch.
* **Physical layouts** (`table.S`, option `layout` of `load`/`open`, default
  `column`): ingestion fills a staging form (slots + NULL bytes) which
  `table_finalize` turns into either
  * the *column* layout — one dense vector per column plus a NULL bitmap
    (omitted when the column has no NULLs); STRING columns are dictionary
    encoded (u32 codes + dictionary of shared strings) when the distinct
    count is at most half the rows, or always with `"dictionary":true`; or
  * the *row* layout — one row-major block of tuples (the slots followed by
    the tuple's NULL bitmap words).
  Each Column carries accessor fields (data base, stride, NULL bitmap base,
  bit stride and bit offset, dictionary), so one accessor (`col_get`) serves
  both layouts and the rest of the engine is layout-agnostic: results are
  identical by construction. `schema` reports the layout.
* **Statistics** (`stats` op, planner): per column NULL count, distinct
  count (exact with a hash set up to 200,000 values, then a HyperLogLog
  sketch, so memory stays bounded), min and max; computed on first use per
  column and cached in the (immutable) table.
* **Indexes** (`index.S`) are single-column and belong to their table (dropped
  with it, or when it is replaced); names are global. `HASH`: bucket heads and
  a per-row `next` array over row ids. `BTREE`: an ordered structure realised
  as the non-NULL row ids sorted by (value, row id) plus the sorted keys;
  equality and range lookups by binary search. NULLs are never indexed.
  `CREATE INDEX` defaults to `BTREE`; each index owns an arena freed by
  `DROP INDEX`.
* **Planning** (`planner.S`, run for every query block after binding):
  WHERE conjuncts referencing exactly one range variable (that is not on the
  NULL-padded side of a LEFT JOIN, and without correlated subqueries) are
  pushed into that variable's scan; `col = c`, `col IN (c, ...)` and range
  conjuncts (`<`, `<=`, `>`, `>=`, `BETWEEN`, intersected per column) with
  literal constants that convert exactly to the column type are analysed with
  the statistics (equality 1/distinct per value; ranges by linear
  interpolation between min and max for numeric/temporal types, 1/3
  otherwise). An index is used when its estimated selectivity is ≤ 10%
  (and, for tiny tables, for equality lookups estimated at ≤ 16 rows). For
  PQCF-backed tables, row groups whose chunk min/max (or all-NULL chunk)
  exclude a constraint are skipped. Inner hash joins build on the input with
  the smaller estimated cardinality; LEFT joins build on the right input.
  `use_indexes:false` disables index use. Pushdown, index selection and
  row-group skipping are physical planning and stay on with
  `optimize:false` (which only disables the logical rewrites of
  `optimizer.S`, see Phase 5). Pushed conjuncts are
  always re-evaluated on every candidate row, so index lookups and skipping
  only need to be conservative.
* **Column pruning** is inherent: scans produce row ids, and only the columns
  the query references (shown as `columns` of `TableScan`/`IndexScan`) are
  ever read.
* **PQCF** (`pqcf.S`): `save` assembles the file in memory (8-byte aligned
  chunks, row groups of `row_group_size` rows, default 65536; encodings
  `auto` = RLE when runs < n/4 for BOOLEAN/INT64/DECIMAL/DATE/TIMESTAMP, DICT
  when distinct < n/2 for STRING, else PLAIN; `plain`/`dict`/`rle` force the
  encoding where the type allows it, PLAIN otherwise; min/max written for
  every type), writes it to `.<name>.tmp-<pid>-<seq>` in the target's
  directory, `fsync`s it, `rename`s it over the target and `fsync`s the
  directory. `open` validates header, footer, metadata CRC and structure,
  every chunk's CRC and every value (UTF-8, offsets, decimal precision,
  date/timestamp range, finite floats, RLE booleans and run lengths,
  dictionary codes, bitmap NULL counts, exact chunk sizes) before the table
  is published, then recreates the file's indexes. With `"mmap":true` (and
  the default column layout) the file is memory-mapped (`mmap(2)`) and
  decoded lazily: `open` validates header, footer, metadata checksum and the
  complete metadata structure, and every column is decoded — its chunk CRCs
  verified and every value validated — on its first access (`col_get` tests
  one flag), so queries only decode the columns they reference; a corrupt
  chunk then fails the query that touches it with `STORAGE_CORRUPT` and the
  column stays undecoded. The table owns the mapping until it is dropped or
  replaced; `save` always writes a new file and renames it, so saving over an
  open file never disturbs the mapping. Without `mmap` (or with the row
  layout) the file is read and decoded completely at `open`. Row-group
  min/max statistics are kept for skipping.
* **Types** are packed into one word (`kind | precision<<8 | scale<<16`). The
  binder inserts explicit promotion casts (INT→DECIMAL/FLOAT, DATE→TIMESTAMP),
  so the evaluator only sees same-kind operands (DECIMAL scales are aligned
  exactly with 128-bit arithmetic).
* **Evaluation** is a tree-walking interpreter returning `(payload, null)` in
  `rax:rdx`. The evaluation context holds one row index per range variable
  (a *tuple*), the range variables' tables, the current group's aggregate
  values and a link to the enclosing query's context (correlation).
* **Query blocks** execute as materialising operators. The FROM clause
  produces a tuple set (row indices only: base tables are never copied;
  `-1` marks a NULL-padded LEFT JOIN side). Derived tables and CTEs are
  executed once (results of uncorrelated plans are cached in the plan) and
  converted into columnar tables, so every range variable is a table.
* **Joins**: the binder extracts the first `left_expr = right_expr` conjunct
  of `ON` whose sides reference only the left resp. right input; such
  equi-joins run as hash joins (build on the right input, which is also the
  correct side for LEFT JOIN, or on the smaller input of an inner join),
  sort-merge joins or nested loops (option `join`, see Phase 5); joins
  without such a key (and CROSS joins) always run as nested loops. The full
  `ON` predicate is always re-checked. `--max-join-rows` bounds every join
  output.
* **Grouping** hashes the GROUP BY key cells (NULLs group together); each
  group keeps a representative tuple and aggregate states. Because every
  column reference outside aggregates must be (structurally) a GROUP BY
  expression, outputs, HAVING and ORDER BY are evaluated on the
  representative tuple. DISTINCT aggregates keep a per-group hash set.
* **Subqueries**: scalar, `IN` and `EXISTS` subqueries are bound in a child
  scope; an uncorrelated one is executed once and its value / hash set is
  cached in the expression node. A correlated one (a column resolves to an
  enclosing scope, bound as `EK_OUTER` with a level count) is re-executed for
  each evaluation with the outer context chain.
* **Sorting** uses `qsort_r` over row pointers with a multi-key comparator
  (NULLS FIRST/LAST, ASC/DESC).
* **Robustness**: SIGSEGV/SIGBUS/SIGFPE handlers on an alternate stack turn an
  unexpected fault inside a request into an `INTERNAL_ERROR` response instead
  of a crash; parser recursion depth is bounded.
* **Timeouts**: `timeout_ms` sets a monotonic deadline checked every 1024 scanned
  rows and inside `PQ_SLEEP` (10 ms slices).

## HTTP server (`serve`, Phase 4)

**Process model.** The server process has two threads:

* the *network thread* runs a `poll(2)` event loop over the listening
  socket, all client connections, a `signalfd` (SIGCHLD, SIGTERM, SIGINT)
  and a completion pipe. It parses HTTP, answers `/health`, `/metrics`,
  `/v1/version`, `/v1/capabilities` and `/v1/queries` itself, performs
  admission control and starts queries. It never touches the catalog, so it
  stays responsive whatever else is happening;
* the *catalog worker thread* executes all catalog operations (`load`/`PUT`,
  `drop`/`DELETE`, `open`, `save`, `reset`, `tables`, `schema`, `stats`,
  `explain`, `CREATE/DROP INDEX`, and invalid requests) one at a time, so
  mutations are serialized and atomic.

**Queries run in forked processes.** An admitted query is executed by a
child process created with `fork(2)`. The child's copy-on-write address
space *is* the query's snapshot of the catalog (concurrency.md §1): a
concurrent replace, drop or reset in the server never affects it, readers
never block each other, and a crash or runaway query cannot corrupt the
server. A `pthread` mutex (`cat_lock`) held by the catalog worker while it
changes the catalog is taken with `trylock` around `fork()`, so a snapshot is
never torn; `load` and `open` release it while they read and parse their
input (the new table is published only afterwards), so a long load does not
delay queries.
The child writes the HTTP response straight to the client socket (blocking
writes, so a slow streaming client applies backpressure to execution),
publishes its status and row count in a small `MAP_SHARED` record, and
exits; the server reaps it via SIGCHLD and resumes reading the keep-alive
connection. Lazily decoded (mmap) PQCF columns are therefore decoded per
query in the child.

**Admission** (`--workers N`, default CPU count; `--queue-depth Q`,
default 64): a query starts if fewer than N run and nobody waits, else waits
in a FIFO queue if fewer than Q wait, else is rejected at once with
`OVERLOADED` (503, `polyquery_queries_rejected_total`). Queries are
`POST /v1/query`, `/v1/query/stream` and `/v1/request` with op `query`
(except `CREATE`/`DROP INDEX`, which are catalog jobs) or `sleep`.

**Timeouts**: the deadline is arrival time + (`timeout_ms` if > 0, else
`--query-timeout-ms`); the server fails queued queries at their deadline
(`TIMEOUT`, 504) and the child passes the same absolute deadline to the
engine's checks (every 1024 rows, `PQ_SLEEP` every 10 ms). As a safety net a
child still running 300 ms after its deadline is killed.

**Cancellation**: `DELETE /v1/queries/{id}` removes a queued query (it is
answered `CANCELLED`, 409) or sends SIGUSR1 to the running child, whose
handler sets a flag tested by the same checks, so the query ends with
`CANCELLED` within ~10 ms (SIGKILL after 300 ms). A client disconnect
(`POLLRDHUP` on the connection) kills the query's child. Finished or unknown
ids are `NOT_FOUND`.

**Streaming** (`/v1/query/stream`, chunked `application/x-ndjson`): for
queries without ORDER BY, aggregation or DISTINCT the projection loop hands
each row to a sink (`g_row_sink`) that applies OFFSET/LIMIT and `max_rows`
and sends batches of 1,000 rows as they are produced; other queries are
materialized, then sent in batches. The header line goes out with the
first batch (or with the end line), so errors raised before that produce an
ordinary error response with its HTTP status; later errors end the body with
an `{"type":"error",...}` line and no end line. At most one batch is
buffered in the process; beyond that the socket buffer bounds what is ahead
of the client.

**HTTP details**: HTTP/1.1 keep-alive (and HTTP/1.0), pipelining,
`Expect: 100-continue`, chunked request bodies (a malformed chunk size is
answered `400` immediately and the connection is closed), bodies above
`--max-request-bytes` get `413 RESOURCE_LIMIT` (a Content-Length body is
skipped and the connection kept; a chunked one closes it). Connections that
must be closed are half-closed and drained briefly (lingering close) so the
client receives the response. Table names and query ids in paths are
percent-decoded. `PUT /v1/tables/{name}` accepts `format`, `replace` and
`header` query parameters.

**Metrics** (`GET /metrics`, text format 0.0.4): the required families plus
`polyquery_workers`. `in_flight` counts started, unfinished queries.
Queries are counted when they finish (`status="ok"`/`"error"`; timeouts and
cancellations are errors and also increment their own counters); rejected
queries only increment `polyquery_queries_rejected_total`.

**Logs**: JSON lines on stderr with `ts` (RFC 3339 UTC, ms), `level`, `msg`;
`listening`, `query finished` (`query_id`, `status`, `error_code`,
`duration_ms`, `rows`), rejections, cancellations, shutdown. Error messages,
SQL text and data are never logged. `--log-level` filters (`off` disables).

**Shutdown** (SIGTERM / SIGINT): the listening socket is closed, `/health`
answers 503 and new queries / mutations get `SHUTTING_DOWN`; queued and
running queries continue for `--shutdown-grace-ms`, then queued ones are
answered `CANCELLED` and running ones are cancelled (SIGUSR1, SIGKILL 300 ms
later); the process exits 0 once nothing is left.

## Phase 5: execution modes, parallelism and optimizations

### Query options

| option | values | effect |
|---|---|---|
| `mode` | `"row"` | the unoptimized baseline: the original tuple-at-a-time interpreter of `exec.S` (every operator evaluates `eval()` once per tuple and materialises its output tuple set) |
| | `"vectorized"`, `"auto"` (default) | batch execution: operators run over batches of 1024 tuples and evaluate expressions as column vectors (`vec.S`) |
| `threads` | int ≥ 1 (default 1, capped at 64) | parallel parts for scans, filters, projections, hash-join probes and aggregation, in both modes |
| `join` | `"auto"` (default), `"hash"`, `"merge"`, `"nested_loop"` | algorithm of every equi-join (see below); joins without an equi-key conjunct and CROSS joins are always nested loops |
| `optimize` | `true` (default) / `false` | logical rewrites (`optimizer.S`) on / off |
| `native` | bool | accepted and ignored (`native.kernels` is not claimed) |

Unsupported values of known options are `UNSUPPORTED`. `explain` honours
the options: join nodes are `HashJoin`, `MergeJoin` or `NestedLoopJoin`.
With `join: "auto"` an equi-join is a hash join unless both inputs are
estimated tiny (≤ 64 pairs), where a nested loop avoids building anything.

**Identical results.** Every combination of options produces the same
rows, and in the same order wherever the row baseline's order is defined by
its operators: parallel parts cover contiguous ranges of their input and are
concatenated in order, groups are emitted in order of their first tuple, and
all three join algorithms emit left-input order with the matching right
tuples in right-input order (only a hash join that builds on its smaller
*left* input emits right-input order). Errors are identical too: the
vectorized evaluator computes anything that can fail (overflow, division by
zero, casts, functions) only on the rows the row engine evaluates - the
right operand of AND / OR only where the left one did not decide, the right
operand of other binary operators only where the left one is not NULL,
CASE branches and other complex nodes tuple by tuple - and parallel parts
re-raise the error of the lowest failing part. `tests/modes_test.sh` (part
of `make test`) checks byte-identical responses, including error cases,
across modes, thread counts (forced onto tiny inputs with `PQ_PAR_MIN=1`),
join algorithms and `optimize`; the conformance runner's `--modes` matrix
also passes with `PQ_PAR_MIN=1`.

### Vectorized execution (`vec.S`, `pexec.S`)

* A vector is 1024 `u64` values followed by 1024 NULL bytes; vectors live
  on a per-thread scratch stack (8 MiB, mark / release per batch kernel, so
  steady-state execution allocates nothing).
* `veval(node, batch, active-mask)` fast paths: column gathers from both
  physical layouts (inline NULL-bitmap tests, dictionary decoding),
  literals, constant subtrees (evaluated once per batch; never `PQ_SLEEP`),
  comparisons (AVX2 `vpcmpeqq` / `vpcmpgtq` for all 64-bit integer-like
  types and same-scale DECIMALs; FLOAT64, STRING and mixed-scale DECIMAL
  per row), INT64 / FLOAT64 / DECIMAL arithmetic with the exact overflow /
  division checks of the row engine, AND / OR (Kleene logic) / NOT / IS
  [NOT] NULL (AVX2 mask arithmetic), CAST. Functions, CASE, LIKE, IN,
  BETWEEN and subqueries fall back to `eval()` on the active rows.
* Kernels: filter (selection + tuple compaction), projection (one vector per
  output column, then row assembly), group keys, aggregation (dispatch per
  batch into specialised update loops: COUNT, 128-bit SUM / AVG with the
  accumulators in registers, FLOAT64 sums in row order so results equal the
  baseline bit for bit, integer MIN / MAX), join key evaluation and batched
  ON re-checks.

### Parallel execution (`par.S`, `pexec.S`)

* `par_for(n, fn, arg)` splits `[0, n)` into P = min(threads, ⌈n / 4096⌉)
  contiguous parts (environment variable `PQ_PAR_MIN` overrides the 4096 -
  used by the tests to force parallelism on tiny inputs); part 0 runs on
  the calling thread, the others on fresh pthreads. Workers allocate from
  their own arenas (thread-local `t_arena`, kept until the request ends) and
  raise errors through a thread-local `jmp_buf`; `tmp_alloc`, `pq_raise`
  and the CAST formatting buffer are thread-aware, so the evaluator runs
  unchanged in workers. Lazily decoded PQCF columns referenced by the block
  are decoded before workers start. Blocks containing subqueries run on one
  thread (subquery results are cached in the shared AST).
* Parallel operators: full scans with pushed-down filters (honouring
  row-group skipping), WHERE, projection (with per-part top-N), hash-join
  probe (build is serial), aggregation. Aggregation without GROUP BY merges
  per-part partial states in part order (exact for INT64 / DECIMAL).
  GROUP BY is **hash-partitioned**: phase 1 computes key cells and hashes in
  parallel; in phase 2 part p owns the groups whose hash falls into
  partition p and aggregates their tuples in input order, so every group
  sees exactly the serial sequence of updates (identical FLOAT64 sums,
  DISTINCT aggregates work unchanged) and each part's hash table stays
  small and cache-resident. With one part, grouping is a single fused pass.
* Timeouts and cancellation are checked by every part once per batch.

### Joins (`exec.S`, `join.S`, `pexec.S`)

* **Hash join**: chained hash table over the build input (inserted
  backwards so chains list build tuples in input order); the probe runs in
  parallel batches: key vector, candidate pairs, one vectorized ON re-check
  per batch (skipped when ON is just the key equality), emission in probe
  order with LEFT JOIN padding.
* **Sort-merge join**: both inputs reduced to (key, tuple) entries, NULL
  keys dropped, sorted with `qsort_r`, merged into per-left-tuple ranges of
  equal right keys; emission in left input order (LEFT JOIN supported).
* **Nested loop**: every pair, full ON predicate.

### Logical optimizer (`optimizer.S`, `optimize: true`)

* **Constant folding** of subtrees without column / outer / aggregate
  references, subqueries or `PQ_SLEEP`, evaluated once at planning and
  replaced by a literal - unless the evaluation raises an error, in which
  case the subtree stays and fails at run time exactly when the baseline
  does. The rewrites run after the physical planning (on the residual WHERE,
  the pushed-down scan filters, join conditions, HAVING, outputs, keys and
  aggregate arguments), so `optimize` never changes which rows are scanned
  (index selection and row-group skipping see the same predicates) - and
  thereby never which rows could raise errors.
* **Predicate simplification**: `TRUE AND x → x`, `x AND TRUE → x`,
  `FALSE OR x → x`, `x OR FALSE → x`, `TRUE OR x → TRUE`;
  `FALSE AND x → FALSE`, `x AND FALSE → FALSE` and `x OR TRUE → TRUE` only
  when `x` cannot raise errors (the baseline may evaluate `x` first:
  predicate pushdown reorders WHERE conjuncts). WHERE / HAVING folding to
  TRUE disappear.
* Physical optimizations that are always on (all modes): predicate
  pushdown, index selection, row-group skipping, column pruning, hash-join
  build side by estimated cardinality; **top-N** for `ORDER BY … LIMIT`
  (without DISTINCT, LIMIT + OFFSET ≤ 65536) in the batch modes: each part
  keeps a bounded max-heap of LIMIT + OFFSET rows instead of sorting all
  rows. Not implemented: join reordering.

### Memory and cache-aware layout

* Arena (bump) allocation everywhere, per request and per worker; vector
  scratch stacks per thread; tuple sets of row indices (base data is never
  copied); 1024-tuple batches keep the working vectors of a kernel in L1/L2.
* Hash-partitioned aggregation keeps one small hash table per partition;
  string hashing processes 8 bytes per step.

### Measurements

`bench/bench.sh DATASET_DIR [REPS]` loads `transactions` (1,000,000 rows)
and `customers` (100,000 rows) of `pqgen.py generate --scale 1m` into one
session and reports the best of REPS server-side `stats.elapsed_us` (results
not serialised: `"result":"count"`). AMD Ryzen 9 9950X3D (16 cores / 32
threads), best of 5:

| query | Phase 4 engine | row, 1 thread, `optimize:false` | row, 1 thread | vectorized, 1 thread | vectorized, 4 threads | vectorized, 16 threads |
|---|---:|---:|---:|---:|---:|---:|
| Q1 filter + COUNT | 22.6 ms | 22.9 ms | 18.3 ms | 4.5 ms | 1.5 ms | 0.7 ms |
| Q2 5 scalar aggregates | 20.3 ms | 19.9 ms | 20.3 ms | 8.5 ms | 2.6 ms | 1.2 ms |
| Q3 GROUP BY 2 strings | 39.7 ms | 38.8 ms | 38.9 ms | 27.7 ms | 13.1 ms | 8.7 ms |
| Q4 GROUP BY expression + filter | 27.2 ms | 24.7 ms | 24.7 ms | 11.8 ms | 9.6 ms | 6.9 ms |
| Q5 hash join + GROUP BY | 58.7 ms | 51.6 ms | 51.4 ms | 42.1 ms | 28.5 ms | 20.1 ms |
| Q6 filter + ORDER BY … LIMIT 10 | 49.9 ms | 47.6 ms | 48.4 ms | 11.0 ms | 4.2 ms | 2.2 ms |
| Q7 filter + projection | 9.5 ms | 8.7 ms | 8.6 ms | 1.4 ms | 0.7 ms | 0.4 ms |
| Q8 constant-foldable filter | 26.0 ms | 25.9 ms | 14.5 ms | 5.0 ms | 1.6 ms | 0.8 ms |

(The "Phase 4 engine" column is `bench/baseline-phase4.txt`, measured
before any Phase 5 change; the row baseline is the same interpreter, so the
first two columns agree within noise. The queries are in `bench/bench.sh`.)
Effects in short: vectorization 2–7× on scan / filter / aggregate /
projection queries (Q1, Q2, Q6, Q7), top-N 4× (Q6), constant folding 1.8×
in the row baseline (Q8: `amount > 10 * 10 + 0` folds, and the promoted
DECIMAL literal is no longer cast per row), parallelism a further 3–13×
with 16 threads. Join algorithms on Q5 (1 thread): hash 64 ms (row) /
42 ms (vectorized), sort-merge 152 ms / 145 ms; joining 2,000 × 2,000 filtered rows
(both 1M- and 100k-row scans included):
hash 9.4 ms, merge 9.5 ms, nested loop 50 ms.

## Implementation-defined choices

* `UNION`, `RIGHT` and `FULL` joins are `UNSUPPORTED`.
* EXPLAIN shows pushed-down conjuncts as a `Filter` node (`"predicate":"WHERE
  (pushed down)"`) directly above the scan; `IndexScan` nodes carry `index`,
  `kind` and `lookup` (`equality`/`range`); scans carry `estimated_rows` and,
  for PQCF-backed tables with skipped groups, `row_groups_skipped`;
  `HashJoin` carries `build` (`left`/`right`).
* PQCF: an unknown `encoding` save option is `INVALID_REQUEST`;
  `row_group_size` 0 means the default. Index names duplicated inside a file
  are `STORAGE_CORRUPT`. A metadata `row_count` above `--max-table-rows` is
  `RESOURCE_LIMIT`. Temporary files of a crashed save are not removed
  automatically (readers ignore them).
* `load`/`open` option `layout` other than `"row"`/`"column"` is
  `INVALID_REQUEST`.
* `PARSE_ERROR` responses carry `details.line`/`details.column` of the
  offending token (lexical errors: of the current scan position).
* EXPLAIN plan nodes: `Limit`, `Sort`, `Distinct`, `Project`, `Filter`
  (`predicate` is `"WHERE"` or `"HAVING"`), `Aggregate`, `HashJoin` /
  `MergeJoin` / `NestedLoopJoin` (with `join_type`), `TableScan` (catalog `table`, `alias`,
  `columns` actually referenced), `SubqueryScan` (derived table / CTE, with
  its plan as child) and `Values` (SELECT without FROM). Subqueries inside
  expressions are not shown.
* Common type of CASE / COALESCE branches: identical types stay as they are;
  otherwise numeric promotion per types.md §2 (so two different DECIMAL types
  give `DECIMAL(18, max scale)`); otherwise all must be equal.
* `HAVING` and `WHERE` cannot reference SELECT aliases (only GROUP BY and
  ORDER BY can, as the spec defines).
* `UPPER`/`LOWER` map ASCII letters only, and leave a whole word (maximal run
  of ASCII letters/digits and non-ASCII characters) unchanged when it contains
  a non-ASCII character: `UPPER('abc Ünï')` is `'ABC Ünï'` (as the conformance
  suite expects).
* `ROUND(x, n)` with a NULL `n` is NULL; `DATE_TRUNC`/`DATE_DIFF` with a NULL
  unit are NULL. Constant arguments (`ROUND`'s `n`, units) are evaluated at
  validation time.
* Comparisons inside `IN` lists, `BETWEEN`, simple `CASE` and `NULLIF` promote
  per pair at run time (INT64 vs DECIMAL compares exactly; DATE vs TIMESTAMP
  uses midnight).
* In DECIMAL arithmetic an INT64 operand takes part as `DECIMAL(18,0)`
  (e.g. `1.5 * 2` is `DECIMAL(18,1)`); in comparisons the INT64 side is
  promoted to the other operand's scale.
* FLOAT64 output uses the shortest of `%.15g`/`%.16g`/`%.17g` that round-trips.
* `TIMESTAMP` literals and `CAST(string AS TIMESTAMP)` also accept a bare date
  (midnight).
* `LIMIT NULL` means no limit; a non-INT64 `LIMIT`/`OFFSET` is a `TYPE_ERROR`.
* An invalid type name in a load schema is `INVALID_REQUEST`; `header:false`
  without a schema is `INVALID_REQUEST`.
* JSON input must be valid UTF-8; lone surrogate escapes are rejected.

## Known limitations

* Without `mmap`, PQCF files are decoded completely at `open`.
* A lazily opened file must not be modified in place by other processes while
  it is open (PQCF files are immutable; the engine itself only replaces files
  by rename).
* Distinct counts are exact up to 200,000 distinct values per column and
  HyperLogLog estimates (2^14 registers, ~1% error) beyond.
* Index contents are rebuilt whenever a table is loaded or opened (PQCF
  persists only index definitions); statistics are recomputed per table on
  first use.
* Join reordering is not implemented: joins run in the order written (the
  hash join picks its build side by estimated cardinality). Merge joins sort
  both inputs (index order is not reused); nested-loop and merge joins, hash
  builds, DISTINCT aggregates without GROUP BY, DISTINCT, derived tables /
  CTEs and the final sort run single-threaded (top-N heaps are per part).
* Blocks whose expressions contain subqueries run their operators on one
  thread (subquery results are cached in the shared plan). The `native`
  option is accepted and ignored (`native.kernels` is not claimed).
* `serve` binds IPv4 addresses only (`--host` must be an IPv4 address or
  `localhost`); at most 1000 simultaneous connections.
* A client that half-closes its socket (`shutdown(SHUT_WR)`) while its query
  runs is treated as disconnected and its query is cancelled.
* Queries with ORDER BY / GROUP BY / DISTINCT are materialized before
  streaming starts; pipelined streaming still keeps the projected rows of the
  query in the query's arena (memory grows with the result, the output
  buffer does not).
* Catalog operations are serialized in one worker thread: a long `save`,
  `stats` or `CREATE INDEX` delays other catalog operations (not queries
  already admitted, `/health`, `/metrics` or cancellation); new queries wait
  for the catalog lock while such an operation changes the catalog.
