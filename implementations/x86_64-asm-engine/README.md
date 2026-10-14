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
[Phase 5](#phase-5-execution-modes-parallelism-and-optimizations)), plus the
architectural change CR-1 `UNION ALL` (capability `change.union_all`, see
[UNION ALL](#change-cr-1-union-all)), and the refactoring CR-3: an
explicit logical plan, a rule-based logical optimizer and a separate
physical planner (see
[plan separation](#change-cr-3-logical--physical-plan-separation)), and the
architectural change CR-2: `DECIMAL` precision up to 38 with PQCF v2
(capability `change.decimal38`, see
[DECIMAL precision 38](#change-cr-2-decimal-precision-38)), and the
requirement change CR-6: statement size limits (capability
`change.expression_limits`, see
[expression size limits](#change-cr-6-expression-size-limits)).

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
                  # storage, planner + optimizer, HTTP parser, parallel
                  # runner + vector scratch) + end-to-end session
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
| PQCF files | `pqcf.S` | PQCF v1 / v2 writer (PLAIN / DICT / RLE, chunk statistics), validating reader, CRC-32, UTF-8 validation, atomic replacement |
| wide decimals | `dec128.S` | DECIMAL(19..38): boxed i128 values, 256-bit exact arithmetic and comparison, rescaling and rounding, text and FLOAT64 conversions, 192-bit SUM / AVG accumulators |
| lexer | `lexer.S` | SQL text → tokens with line/column |
| parser / AST | `parser.S`, `ast.S` | recursive descent over the full grammar → statement, query, FROM-item and expression nodes (`include/sql.inc`); `ast.S` gives generic child access to every expression kind |
| semantic analysis | `binder.S` | scopes and range variables, CTE visibility, name resolution (incl. correlation), typing with implicit promotions, aggregate / GROUP BY validation by structural equality, output naming, ORDER BY resolution, constant LIMIT/OFFSET → bound query block (`QP_*`, `RV_*` range variables) with the FROM clause as a logical Scan / Join tree |
| scalar functions | `functions.S` | binding (typing) and evaluation of all scalar functions, CASE, LIKE, BETWEEN, IN lists |
| planning pipeline | `plan.S` | per query block: logical plan → optimizer → physical plan |
| logical plan | `lplan.S` | relational operators independent of execution strategy (`LP_*` / `LK_*`): Scan, SubqueryScan, Join, Filter, Project, Aggregate, Sort, Limit, Distinct, UnionAll, Values; builder and text printer |
| logical optimizer | `optimizer.S`, `rule_pushdown.S`, `rule_prune.S`, `rule_fold.S` | rule driver (option `optimize`) and one module per rule: predicate pushdown, column pruning, constant folding / predicate simplification |
| physical planning / EXPLAIN | `planner.S`, `explain.S` | scan predicates, access paths (index selection), row-group skipping, cardinality estimates, join keys, join algorithm (option `join`) and hash-join build side, execution mode (`mode`, `threads`) → executable plan (`QP_*`, `FP_*` FROM tree); JSON plan rendering |
| execution (row baseline) | `eval.S`, `exec.S`, `join.S`, `hash.S` | expression interpreter (exact DECIMAL with 128-bit intermediates, CAST matrix); materialising tuple-at-a-time operators: scan, hash / sort-merge / nested-loop join, filter, hash aggregation, projection, DISTINCT, sort, offset/limit; subquery evaluation; generic hash table on value cells |
| execution (batch / parallel) | `pexec.S`, `vec.S`, `par.S` | batch operator drivers split into parallel parts; vectorized expression evaluator and kernels (filter, projection, group keys, aggregation, join keys / ON re-check); worker threads with thread-local arenas and error handlers |
| protocol | `protocol.S`, `main.S` | CLI, JSON-lines session loop, `exec` mode, request validation, operations (`query`, `explain`, …), path safety, fault guard |
| HTTP | `http.S` | HTTP/1.1 message layer: incremental request parsing (Content-Length and chunked bodies, size limits, malformed framing), response / chunk writing, URL decoding, query parameters, error code → status mapping |
| server | `server.S` | `serve`: poll() event loop, connections and keep-alive, routing, admission control (workers, FIFO queue, `OVERLOADED`), fork-per-query execution, catalog worker thread, timeouts, cancellation, streaming, metrics, JSON logs, graceful shutdown |

The SQL pipeline is lex → parse (AST) → bind (semantic validation, typed
AST, bound query blocks) → logical plan → optimizer rules → physical plan →
execute. Errors detected before execution are reported without executing
anything.

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
  narrow DECIMAL (p ≤ 18) unscaled i64, wide DECIMAL (p > 18) a pointer to
  an immutable 16-byte i128 (see CR-2), STRING as a pointer to a
  length-prefixed string, DATE days and TIMESTAMP microseconds since the
  epoch.
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
* **Planning** (`plan.S` → `lplan.S`, `optimizer.S`, `planner.S`, run for
  every query block after binding; see
  [CR-3](#change-cr-3-logical--physical-plan-separation)):
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
  `use_indexes:false` disables index use. Pushdown is a logical rule; the
  physical planner applies the same placement to a WHERE that no rule has
  placed, so pushdown, index selection and row-group skipping stay on with
  `optimize:false` (which applies no optimizer rule, see Phase 5) as
  indexes-and-planning.md §3 requires. Pushed conjuncts are
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
* **Joins**: the physical planner extracts the first `left_expr = right_expr` conjunct
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
| `threads` | int ≥ 1 (default: `--threads N`, else the online CPUs up to 16 - in `serve` divided among the queries running; 1 with `mode: "row"`; capped at 64) | parallel parts for scans, filters, projections, hash-join probes and aggregation, in both modes |
| `join` | `"auto"` (default), `"hash"`, `"merge"`, `"nested_loop"` | algorithm of every equi-join (see below); joins without an equi-key conjunct and CROSS joins are always nested loops |
| `optimize` | `true` (default) / `false` | logical optimizer rules (`optimizer.S`, `rule_*.S`) on / off |
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
re-raise the error of the lowest failing part. Because column-at-a-time
evaluation could still meet a *later* row's error first when different
rows raise different errors, a batch / parallel execution that fails with a
data error (overflow, division by zero, conversion, invalid argument,
subquery cardinality) is replayed in the row baseline, which then reports
exactly the baseline's error (successful queries never pay for this).
ORDER BY is a stable sort everywhere (ties keep production order, which is
the same in every mode; top-N heaps use the same tie-break), so even tied
rows come out identically. `tests/modes_test.sh` (part
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
  the calling thread, the others on the persistent worker pool (see
  "Latency optimization" below). Workers allocate from
  their own arenas (thread-local `t_arena`, kept until the request ends) and
  raise errors through a thread-local `jmp_buf`; `tmp_alloc`, `pq_raise`
  and the CAST formatting buffer are thread-aware, so the evaluator runs
  unchanged in workers. Lazily decoded PQCF columns referenced by the block
  are decoded before workers start. Blocks containing subqueries run on one
  thread (subquery results are cached in the shared AST).
* Parallel operators: full scans with pushed-down filters (honouring
  row-group skipping), WHERE, projection (with per-part top-N), hash-join
  probe and build, nested-loop join, merge-join key evaluation,
  aggregation, ORDER BY (normalized-key sample sort, `keysort.S`; when
  the first key cannot be normalized, each part sorts its range of (row,
  sequence) pairs and the sorted runs are merged pairwise in parallel
  rounds). Aggregation without GROUP BY merges
  per-part partial states in part order (exact for INT64 / DECIMAL).
  GROUP BY is **hash-partitioned**: phase 1 computes key cells and hashes in
  parallel; in phase 2 part p owns the groups whose hash falls into
  partition p and aggregates their tuples in input order, so every group
  sees exactly the serial sequence of updates (identical FLOAT64 sums,
  DISTINCT aggregates work unchanged) and each part's hash table stays
  small and cache-resident. With one part, grouping is a single fused pass;
  with few groups and exactly mergeable states every part runs that fused
  pass on its own range and the local groups are merged in part order
  (see "Latency optimization").
* Timeouts and cancellation are checked by every part once per batch.

### Joins (`exec.S`, `join.S`, `pexec.S`)

* **Hash join**: chained hash table over the build input (inserted
  backwards so chains list build tuples in input order); the probe runs in
  parallel batches: key vector, candidate pairs, one vectorized ON re-check
  per batch (skipped when ON is just the key equality), emission in probe
  order with LEFT JOIN padding.
* **Sort-merge join**: both inputs reduced to (key, tuple) entries (keys
  evaluated as vectors, in parallel parts, in the batch modes), NULL keys
  dropped, sorted - stable LSD radix sort (8-bit digits, constant digits
  skipped) for integer-like keys, `qsort_r` otherwise - and merged into
  per-left-tuple ranges of equal right keys; emission in left input order
  (LEFT JOIN supported); the ON re-check is skipped when ON is just the key
  equality.
* **Nested loop**: every pair, full ON predicate; in the batch modes the
  left input is split into parallel parts and ON is evaluated as a vector
  over chunks of 1024 candidate pairs.

### Logical optimizer (`optimizer.S`, `rule_*.S`, `optimize: true`)

The rules (details in
[CR-3](#change-cr-3-logical--physical-plan-separation)) rewrite the logical
plan before physical planning; `optimize: false` applies none of them.

* **Predicate pushdown** (`rule_pushdown.S`): WHERE conjuncts that reference
  one range variable move into the join inputs, directly above that
  variable's scan.
* **Column pruning** (`rule_prune.S`): logical scans produce only the
  columns referenced above them.
* **Constant folding** (`rule_fold.S`) of subtrees without column / outer /
  aggregate references, subqueries or `PQ_SLEEP`, evaluated once at
  planning and replaced by a literal - unless the evaluation raises an
  error, in which case the subtree stays and fails at run time exactly when
  the baseline does - on filters, join conditions, outputs, keys and
  aggregate arguments. Rewritten nodes remember their form as written,
  which the physical planner analyses, so `optimize` never changes which
  rows are scanned (index selection and row-group skipping see the same
  predicates) - and thereby never which rows could raise errors.
* **Predicate simplification** (same rule): `TRUE AND x → x`, `x AND TRUE → x`,
  `FALSE OR x → x`, `x OR FALSE → x`, `TRUE OR x → TRUE`;
  `FALSE AND x → FALSE`, `x AND FALSE → FALSE` and `x OR TRUE → TRUE` only
  when `x` cannot raise errors (the baseline may evaluate `x` first:
  predicate pushdown reorders WHERE conjuncts). Filters folding to TRUE
  disappear.
* Physical optimizations that are always on (all modes): predicate
  placement at the scans, index selection, row-group skipping, column
  pruning, hash-join build side by estimated cardinality; **top-N** for
  `ORDER BY … LIMIT` (without DISTINCT, LIMIT + OFFSET ≤ 65536) in the batch
  modes: each part keeps a bounded max-heap of LIMIT + OFFSET rows instead
  of sorting all rows. Not implemented: join reordering.

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
| Q1 filter + COUNT | 22.4 ms | 22.7 ms | 17.8 ms | 4.3 ms | 1.2 ms | 0.7 ms |
| Q2 5 scalar aggregates | 20.0 ms | 19.8 ms | 19.8 ms | 8.7 ms | 3.0 ms | 1.2 ms |
| Q3 GROUP BY 2 strings | 39.4 ms | 38.6 ms | 38.8 ms | 27.8 ms | 13.4 ms | 8.8 ms |
| Q4 GROUP BY expression + filter | 25.5 ms | 25.1 ms | 24.9 ms | 11.7 ms | 9.7 ms | 7.0 ms |
| Q5 hash join + GROUP BY | 54.5 ms | 53.6 ms | 52.5 ms | 42.7 ms | 29.4 ms | 21.2 ms |
| Q6 filter + ORDER BY … LIMIT 10 | 48.8 ms | 58.9 ms | 62.2 ms | 11.4 ms | 3.3 ms | 1.7 ms |
| Q7 filter + projection | 9.0 ms | 8.6 ms | 9.1 ms | 1.3 ms | 0.6 ms | 0.4 ms |
| Q8 constant-foldable filter | 25.7 ms | 26.1 ms | 15.1 ms | 5.0 ms | 2.0 ms | 0.9 ms |
| Q9 full sort of 1M rows | 218.7 ms | 268.2 ms | 268.1 ms | 278.0 ms | 118.3 ms | 81.4 ms |
| Q10 2,000 × 2,000 join | 9.0 ms | 9.2 ms | 9.2 ms | 1.3 ms | 0.5 ms | 0.5 ms |

(The "Phase 4 engine" column is `bench/baseline-phase4.txt`: the
interpreter as it was before any Phase 5 change, built from commit c86cc2d,
which only added option parsing; the other columns are
`bench/results-phase5.txt`. The queries are in `bench/bench.sh`.) The row
baseline is the Phase 4 interpreter; it got slower on sorts (Q6, Q9: +20%)
because ORDER BY is now a *stable* sort over (row, sequence) pairs, the
price for returning tied rows in the same order in every mode.
Effects in short: vectorization 2–7× on scan / filter / aggregate /
projection queries (Q1, Q2, Q7, Q10), top-N 5× (Q6), constant folding 1.7×
in the row baseline (Q8: `amount > 10 * 10 + 0` folds, and the promoted
DECIMAL literal is no longer cast per row), parallelism a further 2–14×
with 16 threads. Join algorithms on Q5 (1M ⋈ 100k rows): hash join
51 ms (row, 1 thread) / 42 ms (vectorized) / 20 ms (16 threads); sort-merge
join 152 ms before its optimizations (comparison sort, per-pair ON
re-check) and 58 ms / 42 ms / 42 ms after them (radix sort of
integer-like keys, vectorized key evaluation, no ON re-check when ON is just
the key equality); joining 2,000 × 2,000 filtered rows (scans of both
tables included): hash 9.4 ms, merge 9.5 ms, nested loop 49 ms (row) /
21 ms (vectorized) / 6 ms (4 threads) / 2 ms (16 threads; parts sized by
the number of pairs).

## Change CR-1: `UNION ALL`

Implements `spec/changes/union-all.md` (capability `change.union_all`):
`select_core { UNION ALL select_core }` wherever a query is allowed (top
level, CTE bodies, derived tables, scalar / `IN` / `EXISTS` subqueries,
`EXPLAIN`), with `ORDER BY` / `LIMIT` / `OFFSET` after the last branch
applying to the whole result.

Modules touched:

| Module | Change |
|---|---|
| `include/sql.inc` | `SS_UNION` (compound statement: Vec of branch statements); plan fields `QP_NUNION` / `QP_UNION` (compound plan: branch plans) |
| `src/parser.S` | `parse_select` split into `parse_select_core` (SELECT … HAVING) and `parse_order_limit`; `parse_query` builds the compound; `p_error` reports a misplaced `UNION ALL` as `PARSE_ERROR`, `UNION` / `UNION DISTINCT` stay `UNSUPPORTED` |
| `src/binder.S` | `bind_query` dispatches compounds to `bind_compound`: the WITH list is bound once in a scope of its own, each branch is bound by `bind_query` in the compound's position (same enclosing scope, so correlated branches work), column count check (`SEMANTIC_ERROR`), output names from the first branch, output types by `common_type` (the CASE rule, `TYPE_ERROR` otherwise); `bind_order_by` rejects anything but output names / positions in a compound (`SEMANTIC_ERROR`) |
| `src/exec.S` | `exec_plan` runs compound plans through `exec_union`: branches execute in order (each as an ordinary block, so `mode` / `threads` / `join` / `optimize` apply inside every branch), rows are concatenated, converted to the output types with `cast_value` (`union_row`; `NUMERIC_OVERFLOW` when an INT64 does not fit the DECIMAL) and then sorted (stable `sort_rows`, parallel when enabled), offset and limited; uncorrelated compound results are cached like any plan |
| `src/explain.S` | `Limit > Sort > UnionAll` with the branch plans as children, in order |
| `src/server.S` | the streaming endpoint materializes compounds (no pipelining) |
| `src/protocol.S` | capability `change.union_all` |
| `tests/session_test.sh`, `tests/modes_test.sh` | end-to-end cases; compounds in the differential test across execution options |

Design decisions:

* The compound is a plan kind of its own (not a derived table wrapped in a
  projection), so EXPLAIN shows exactly `UnionAll` over the branch plans and
  the branches keep every per-block optimization (pushdown, index scans,
  join algorithms, parallel operators). Output row order without ORDER BY is
  branch order, then each branch's own order, which is identical in every
  execution mode (`modes_test.sh` checks byte-identical responses).
* Branch rows are shared with the branch results when no column needs a
  conversion and there is no ORDER BY; otherwise a row of output cells plus
  sort key cells is built (the same layout as an ordinary block's rows, so
  `sort_rows` / `pexec_sort` are reused unchanged).
* Values are converted after each branch has run, in row order, so a
  conversion error is the same error in every execution mode.
* An all-NULL column keeps the untyped NULL type, which the engine reports
  as `STRING` exactly like `SELECT NULL`.
* `ORDER BY x` where two output columns of the first branch are named `x`
  with different expressions is an ambiguous reference (`SEMANTIC_ERROR`),
  as for plain queries.
* `version` still reports `spec_version` `1.0.0`: the phase-1 conformance
  case `catalog.pqt` requires that value, and the engines must keep passing
  every earlier phase.

## Change CR-2: DECIMAL precision 38

Implements `spec/changes/decimal38.md` (capability `change.decimal38`, in
addition to `change.union_all`): `DECIMAL(p,s)` with `1 ≤ p ≤ 38`. Narrow
decimals (p ≤ 18) behave exactly as before; wide ones (p > 18) use result
precision W = 38; comparisons between INT64 / DECIMAL values of any precision
and scale are exact; CAST, ingestion and the protocol accept up to 38
digits; tables with a wide column are saved as PQCF v2.

### Representation of wide values

* A value slot stays 64 bits everywhere (columns, row tuples, vectors, value
  cells, hash keys, index keys, statistics). A **narrow** decimal keeps its
  unscaled value inline as an i64. A **wide** decimal stores a pointer to an
  immutable 16-byte box holding the unscaled value as a little-endian two's
  complement i128 - the same boxing STRING uses for `pstr*`. Boxes live in
  the arena of their owner: the table arena for ingested / decoded values
  (`dec_box_in`), the request or worker arena for computed ones
  (`dec_box`). They are never modified, so slots are copied freely and NULL
  slots hold 0.
* The packed type (`kind | p << 8 | s << 16`) tells the two apart:
  `dec_is_wide(type)` is `kind == DECIMAL && p > 18`. Every consumer of
  decimal payloads dispatches on it; the narrow code paths are unchanged.
* Intermediates are exact: operands are widened to 256 bits (|v| < 10³⁸ <
  2¹²⁷, so v · 10³⁸ and the product of two wide operands fit), and only the
  result is narrowed with the check |v| < 10^p (`NUMERIC_OVERFLOW`).
  SUM / AVG of wide values accumulate in 192 bits (the aggregate state's
  `AS_LO`, `AS_HI`, `AS_VAL` words), so 2⁶⁴ maximal values cannot overflow
  the accumulator; the final SUM is checked against 38 digits. AVG divides
  the exact sum by the count with a long division into decimal digits
  (≥ 40 significant) and converts that text with `strtod`.

### Dispatch (narrow vs wide)

| Operation | narrow (unchanged) | wide (`dec128.S`) |
|---|---|---|
| `+ - *` | `eval.S` 128-bit i64 path, result checked against 18 digits | `dec_arith`: 256-bit, result type DECIMAL(38, s); chosen when the *result* type is wide |
| unary `-`, `ABS` | `neg` | negated i128, new box (cannot overflow) |
| comparisons (`= <> < …`, `BETWEEN`, `IN`, simple `CASE`, `NULLIF`, joins) | `dec_cmp` (128-bit rescale) - now also for INT64 vs narrow DECIMAL, which the binder no longer casts | `dec_cmp_any` → `num_cmp`: both sides scaled to the larger scale in 256 bits |
| same-type ordering (`ORDER BY`, `MIN`/`MAX`, indexes, statistics, merge join) | `value_cmp` signed i64 | `value_cmp` compares the two i128 boxes |
| hashing (`GROUP BY`, `DISTINCT`, hash join, HASH index, IN sets) | the slot | the i128 (`hash.S`) |
| `SUM` / `AVG` | 128-bit sums | 192-bit sums (`sum192_*`, `avg192_to_double`) |
| `ROUND` / `FLOOR` / `CEIL` | `round_dec`, `idiv` | `round_dec128`, `floor_dec128` (result DECIMAL(38, …)) |
| CAST | `text_parse_decimal`, `dec_rescale`, … | `dec_parse`, `dec_rescale128`, `dec128_to_int`, `dec128_to_double`, `double_to_dec128` |
| text / JSON output | `fmt_decimal` | `fmt_dec128` |
| vectorized kernels | AVX2 / batch loops | binary operators with a wide operand or result and unary minus evaluate tuple at a time (`vbin_wide` → `eval`); wide SUM / AVG / MIN / MAX have their own batch loops |

DECIMAL → FLOAT64 is the nearest double for both widths (narrow values
above 2⁵³ also go through the exact digits), and FLOAT64 → DECIMAL rounds the
exact binary value of the double half away from zero for both widths
(`double_to_dec128`).

### Typing (binder / functions)

* Result precision W = 38 as soon as one DECIMAL operand is wide, else 18:
  `+ - *` (an INT64 operand becomes DECIMAL(19,0) when W = 38; `s1 + s2 > W`
  ⇒ `TYPE_ERROR`), `SUM`, `ROUND`, `FLOOR`, `CEIL`, the CASE / COALESCE /
  UNION ALL common type.
* Comparisons between INT64 and DECIMAL insert no cast any more; evaluation
  compares exact values. For `x IN (subquery)` the set is keyed in the common
  type DECIMAL(W', s) (W' = 18 when both sides' values fit 18 digits at the
  larger scale, else 38); a value without an exact representation in it
  cannot equal any value of the other side and simply matches nothing
  (`exec.S in_key`), so no comparison raises `NUMERIC_OVERFLOW`.
* Equi-join keys: INT64 = DECIMAL(p,s) (s ≤ 19) and narrow = wide DECIMAL of
  one scale are compared as DECIMAL(38,s) (exact casts added by the physical
  planner, `planner.S equi_key_type`), so these joins stay hash / merge
  joins. DECIMALs of different scales stay nested-loop joins as before.
* Literals with a decimal point and 19–38 significant digits are wide
  DECIMAL literals (boxed at parse time); more than 38 digits stay FLOAT64.

### Storage: PQCF v2

* Writer: a table with at least one wide column is written as version 2
  (header and metadata `format_version`), every other table as version 1.
  Wide chunks hold `PLAIN` n × i128 or `RLE` R × {i128, u32} runs (adjacent
  equal values merge into one run); narrow decimals keep the v1 i64 layout.
  Chunk `min` / `max` are canonical decimal strings.
* Reader: versions 1 and 2; header / metadata version mismatch and a wide
  column in a v1 file are `STORAGE_CORRUPT`; version > 2 or flags ≠ 0 are
  `STORAGE_VERSION_UNSUPPORTED`; wide values with |v| ≥ 10^p are
  `STORAGE_CORRUPT`. Decoded values are boxed in the table arena (one box per
  RLE run), eagerly or lazily (`mmap`).

### Modules touched

| Module | Change |
|---|---|
| `src/dec128.S` (new) | representation helpers, 256-bit arithmetic, exact comparison, rescale / round, parse / format, FLOAT64 conversions, SUM / AVG accumulators, ROUND / FLOOR / CEIL, planner constant conversion (`dec_conv_exact`) |
| `src/text.S` | `type_parse` accepts p ≤ 38; `fmt_value_text` formats wide values; `dec_to_float` / `float_to_dec` nearest / exact-binary |
| `src/parser.S` | wide decimal literals; `DECIMAL(p,s)` with p ≤ 38 in CAST; `AS full` / `AS right` aliases |
| `src/binder.S` | result precision W for arithmetic and SUM; no INT64 → DECIMAL cast in comparisons; IN (subquery) common type |
| `src/functions.S` | W in the CASE / COALESCE common type, ROUND / FLOOR / CEIL types and evaluation, ABS, exact mixed comparisons (`cmp_mixed`), `to_double` |
| `src/eval.S` | `value_cmp` on boxes, `cmp_values` (exact comparisons), wide arithmetic, unary minus and every CAST to / from wide |
| `src/exec.S`, `src/pexec.S`, `src/vec.S` | 192-bit SUM / AVG states (update, merge, finish); MIN / MAX through `value_cmp`; IN (subquery) keys; vectorized fallbacks for wide operands and a fast path for narrow DECIMAL vs INT64 comparisons |
| `src/hash.S` | wide values hash their i128 |
| `src/join.S`, `src/planner.S` | wide merge-join keys use `qsort_r` (no radix sort); equi-key typing; index / row-group constants converted exactly (`conv_exact`); selectivity estimates |
| `src/ingest.S` | CSV / JSON / JSONL values for wide columns (exact, literal text) |
| `src/pqcf.S` | PQCF v2 writer and reader |
| `src/protocol.S` | capability `change.decimal38` |
| `tests/test_dec128.S` (new), `tests/test_text.S`, `tests/modes_test.sh` | unit tests of the decimal core; wide-decimal queries in the cross-mode differential test |

### Verification

`changes/decimal38.pqt` passes in every mode, the whole suite passes with
`--modes` and `--transport http`, `http_suite` passes. Beyond that, a 3,000
row table of wide values (`modes_test.sh`, table `w`) is queried under every
execution option set (byte-identical responses), and its results (sums,
group sums, MIN / MAX, DISTINCT counts, products, AVG, ROUND / FLOOR / CEIL,
FLOAT64 conversions, filters) were checked against Python's `decimal`
module at 120-digit precision. A random-expression fuzzer (20,000 queries:
arithmetic with the W / scale / overflow rules, exact comparisons including
INT64, ROUND / FLOOR / CEIL, every CAST from wide values) agreed with a
Python `decimal` oracle, and PQCF v2 files written by the engine were decoded
independently. The Phase 5 benchmark (`bench/bench.sh`, 1m rows) shows the
narrow paths unchanged (a vectorized fast path keeps `decimal > integer`
filters on AVX2 now that the binder no longer casts the integer side).

Known limitations of CR-2: expressions with wide operands are evaluated tuple
at a time inside vectorized batches (correct and parallel, but without SIMD);
joins between DECIMALs of different scales stay nested-loop joins, as before.

## Change CR-6: expression size limits

Implements `spec/changes/expression-limits.md` (capability
`change.expression_limits`, in addition to the earlier changes).

### Limits of this engine

| measure | limit | beyond it |
|---|---|---|
| text length | none of its own: `--max-request-bytes` (default 1 GiB) and the query memory budget | as the protocol specifies (`RESOURCE_LIMIT`, HTTP 413) / `RESOURCE_LIMIT` "query memory budget exceeded" |
| nesting depth | 4,096 levels as counted by the parser (below) - at least 2,047 levels as CR-6 §1 counts them | `RESOURCE_LIMIT` "expression nesting depth exceeds 4096" |
| operand count | 1,000,000 primary expressions | `RESOURCE_LIMIT` "expression operand count exceeds 1000000" |
| memory | `--max-query-memory-mb` (default 4 GiB) per query, now shared by the query's parallel workers | `RESOURCE_LIMIT` "query memory budget exceeded" |
| stack | 1 GiB for the request thread, 256 MiB per parallel worker, checked at every recursive step | `RESOURCE_LIMIT` "statement too complex: stack exhausted (...)" |
| time | the query timeout, from receipt through parsing, binding, planning and execution | `TIMEOUT` |

*Nesting depth as counted by the parser*: each of these makes the
recursive-descent parser recurse and adds one level: an expression in
parentheses, a function argument, the operand of CAST, each part of a CASE,
an IN-list item, a unary `+`/`-`, `NOT`, a query (subquery, CTE body,
derived table) and a FROM item. A chain of one binary operator is parsed by
a loop and adds nothing, and so do comparisons, `BETWEEN`, `LIKE` and
`IS NULL`. A scalar / `EXISTS` / `IN` subquery or a derived table costs two
levels (its query and its expression or FROM item), every other CR-6
construct at most one, so every statement whose CR-6 nesting depth is at most
2,047 is accepted (4,094 nested parentheses, ABS calls, CASEs or NOTs;
2,047 nested scalar subqueries or derived tables).

*Operand count*: every primary expression parsed (literals, column
references, function calls, CAST, CASE, parenthesized expressions,
subqueries) counts one; this is at least the CR-6 operand count. 1,000,000
operands means e.g. a 500,000-term `OR` chain of comparisons, a
999,999-item `IN` list or a 999,999-term sum (all verified in every
execution mode, see below).

The limits are checked while parsing, so a statement beyond them fails
early with `RESOURCE_LIMIT` (CR-6 §3 lets that take precedence over a
syntax error further on). Valid SQL within the limits never fails with
`PARSE_ERROR` because of its size: the binder's old depth guard (a
`PARSE_ERROR` "expression too complex" at 400,000 nested binder calls) was
removed in favour of the stack checks.

### How large statements are processed

* **Long chains.** A chain `a OR b OR c …` is a left-deep tree, so every
  recursive tree walker (binder, optimizer rules, physical analysis,
  evaluators, EXPLAIN) recurses once per term. That is safe because each
  thread that processes queries has a large stack: the request thread runs
  on the 1 GiB lazily committed stack `main` maps (now with a 64 KiB
  `PROT_NONE` guard below it), the pool workers are created with 256 MiB
  stacks (`par.S`), and the server's catalog thread keeps its 1 GiB stack.
  The deepest walkers use about 230 bytes per level in a worker, so the
  operand limit keeps every accepted statement well inside every stack.
* **Stack checks.** Every recursive walker starts with `STACK_CHECK`
  (`pq.inc`): it compares `%rsp` with the thread's limit `t_stack_lo`
  (thread-local, `util.S`; 1 MiB above the stack bottom) and raises
  `RESOURCE_LIMIT` through the normal error path, which in a worker reports
  the error to `par_for` like any other part error. The limit comes from
  `stack_set_bottom` (the request thread) or `thread_stack_init`
  (`pthread_getattr_np`; pool workers and the catalog thread). As a last
  resort the fault handler, which now runs on an alternate signal stack in
  every thread (`thread_stack_init`), reports a fault whose stack pointer is
  below the limit as `RESOURCE_LIMIT` (other faults stay
  `INTERNAL_ERROR`).
* **Linear work.** The stages are linear in the statement size:
  * `expr_batch_const` (`vec.S`), asked at every node by constant folding
    and by the vectorized evaluator, walked the whole subtree each time
    (quadratic on long chains: a 100,000-term `OR` never finished); the
    answer is now cached in the node (`NF_BCDONE` / `NF_BCONST`, set with a
    locked `or` because workers may set it concurrently).
  * Constant folding (`rule_fold.S`) re-evaluated the whole subtree of
    every constant node whose child failed to fold (`1/0 + 1 + 1 …`); a
    node whose first operand failed is now marked `NF_FOLDERR` and its
    parent (binary / unary operator, CAST: `eval` computes that operand
    first, so it would fail the same way) is not re-evaluated.
  * The lexer (`lexer.S`) allocated "the rest of the statement" for every
    string literal or quoted identifier (quadratic memory with many
    literals); it now scans to the closing quote first.
  * `a || b || c …` copied the growing prefix at every step (quadratic time
    and arena memory per row: a 10,000-term chain over a 100-row column
    exceeded the 4 GiB budget); `eval` now evaluates a whole `||` tree left
    to right into one doubling buffer (`concat_chain`, `eval.S`), with the
    same NULL rule (the first NULL operand ends the evaluation, as the
    pairwise evaluation never computed the operands after it). The
    vectorized engine evaluates `||` through `eval` per row, so every mode
    shares it.
  * The vectorized evaluator (`veval`, `vec.S`) left every intermediate
    vector of a tree on the per-thread scratch stack until the batch ended
    (one 9 KiB vector per node, spilling into the request arena on long
    chains); `veval` now moves each node's result down to the scratch top it
    found on entry and releases the rest, so a chain needs scratch space for
    its nesting depth only.
* **Timeout in every stage.** The deadline is set when the request is
  received (as before) and checked by the executor's loops (as before) and
  now also by the walkers of parsing (`parse_primary`), binding
  (`bind_expr`), optimization (`fold_expr`, `prune_expr`) and physical
  planning (`conj_rv`, `push_conj`, `analyze_conj`, `find_equi`,
  `lp_print_expr`, `expr_equal`): `deadline_tick` (`util.S`) reads the clock every
  1,024 calls and preserves all registers, so it can be called at any
  function entry. Measured: `TIMEOUT` arrives 10-70 ms after expiry in every
  stage and mode (also for statements whose binding takes ~10 s, such as a
  100,000-CTE chain).
* **Memory of large parallel queries.** Two problems surfaced with
  statements that run many parallel operators (a 100,000-branch
  `UNION ALL`) and were fixed, since a session must stay usable after a
  failed statement: (1) `par_body` restored the worker's vector scratch
  pointer to its value at entry, which was 0 before the first use, so every
  later part allocated (and leaked) a fresh 8 MiB scratch stack; it now
  initialises the scratch first. (2) Arena chunks came from `malloc` and,
  once freed, stayed in fragmented per-thread malloc heaps (tens of GiB
  resident after such a query); chunks are now mapped directly (`mmap` /
  `munmap`, still pooled up to 1 GiB). Worker arenas (`AR_PAR`) count their
  chunks in the shared counter `g_par_mem`, so the memory budget limits the
  whole query instead of each thread separately.

Two robustness defects found by `tests/regression/robustness_probe.py`
along the way were fixed as well: a query that failed (e.g. over its memory
budget) left the budget set on the request arena, so the next `load` of the
session failed too (`protocol.S` / `server.S` now clear it at request start:
`limit_after_failed_query` passes), and `serve` kept CR/LF bytes sent before
a request line in the connection buffer (`server.S` `conn_process` drops
them: `http_crlf_flood` passes).

### Modules touched

| Module | Change |
|---|---|
| `include/pq.inc` | `STACK_CHECK` macro; `AR_PAR` arena field |
| `include/sql.inc` | parser operand counter `PS_NOPND`; node flags `NF_BCDONE`, `NF_BCONST`, `NF_FOLDERR` |
| `src/util.S` | `t_stack_lo`, `stack_set_bottom`, `thread_stack_init`, `stack_exhausted`; `deadline_tick`; `mmap`ed arena chunks; shared worker memory budget `g_par_mem` |
| `src/main.S` | guard pages and stack limit of the request stack; `SA_SIGINFO` fault handler reporting stack exhaustion as `RESOURCE_LIMIT` |
| `src/par.S` | 256 MiB worker stacks, `thread_stack_init` per worker; worker arenas marked `AR_PAR`, `g_par_mem` reset; scratch initialised before it is saved |
| `src/server.S` | the catalog thread uses `thread_stack_init`; budget cleared per catalog job; leading CR/LF bytes dropped |
| `src/lexer.S` | literal buffers sized to the literal |
| `src/parser.S` | `RESOURCE_LIMIT` for nesting depth (4,096) and operand count (1,000,000) |
| `src/binder.S` | depth guard replaced by `STACK_CHECK`; `deadline_tick` |
| `src/vec.S` | cached `expr_batch_const`; `veval` scratch compaction (`veval_node` holds the old body) |
| `src/rule_fold.S` | `NF_FOLDERR` |
| `src/eval.S` | `concat_chain` / `concat_append` / `concat_reserve` for `||` trees |
| `src/eval.S`, `src/functions.S`, `src/exec.S`, `src/pexec.S`, `src/lplan.S`, `src/planner.S`, `src/explain.S`, `src/json.S`, `src/rule_prune.S`, `src/rule_pushdown.S` | `STACK_CHECK` (and `deadline_tick` in planning walkers) at the entry of every recursive function |
| `src/protocol.S` | capability `change.expression_limits`; request arena budget cleared at request start |
| `tests/session_test.sh` | CR-6 cases in four execution modes: depth-998 / 2,000 nesting, 10,000-term `OR` / sum / IN / 50,000-term `||`, a 200,000-term `OR`, both `RESOURCE_LIMIT`s, `TIMEOUT` while binding |

### Verification

`robustness_probe.py --only expression_limits` passes (all minimum cases in
row, vectorized, parallel and auto mode in well under a second each;
100,000 nested parentheses give `RESOURCE_LIMIT` at once; the 100,000-term
`OR` chain and the 100,000-item `IN` list are computed in 0.01-0.2 s). The
whole conformance suite passes with `--modes` (also with `PQ_PAR_MIN=1`)
and `--transport http`, `http_suite` passes. Scripts kept outside the
repository ran, in the four probe modes on one session: depth-998
constructs of every CR-6 kind (CAST, nested CASE, COALESCE, scalar /
EXISTS / IN subqueries, derived tables, CTEs, comparisons in parentheses,
unary plus, mixed), 10,000-term `*` / `-` / `||` / `BETWEEN` / `LIKE` /
FLOAT64 / DECIMAL chains, 25,000-item IN lists, 10,000-argument functions,
25,000 select items, 10,000 ORDER BY / GROUP BY items, 5,000 UNION ALL
branches, 1,000 chained CTEs, 100 joins, EXPLAIN of large statements; and
beyond the minimums 500,000-term `+`, `-`, `AND` and `OR` chains over
INT64, FLOAT64, DECIMAL(18) and DECIMAL(38) values (also with `mode:"row"`
and 8 threads), 50,000-term `||` chains over a column, 1,000,000-operand statements, 100,000-deep
nesting of every construct, and 100,000-branch / -CTE / -WHEN / -item
statements: every answer was the correct result, `RESOURCE_LIMIT` or
`TIMEOUT`, never a crash, a hang or a size-caused `PARSE_ERROR`, and the
session stayed usable (resident memory back to ~0.5 GiB after each).

## Change CR-3: logical / physical plan separation

Implements `spec/changes/refactor-plan-separation.md`, a behaviour-preserving
refactoring: responses, errors, EXPLAIN output and the capability set are
unchanged (verified differentially against the previous engine, see below).

### Module map

**Before** (Phase 5 + CR-1):

| Concern | Module | Where it happened |
|---|---|---|
| semantic analysis | `binder.S` | bound query block `QP_*`; the FROM clause was built directly as the executor's `FP_*` nodes; equi-join keys (`find_equi`) extracted while binding |
| "logical plan" | — | no separate representation: `QP_*` / `FP_*` served as both |
| logical optimizer | `optimizer.S` | `optimize_block`: folding / simplification on `QP_*` / `FP_*`, called at the end of `plan_block` |
| physical planning | `planner.S` | `plan_block` (called by the binder): pushdown, index selection, row-group skipping, estimates, build side, join algorithm |
| execution mode | `exec.S`, `pexec.S` | read the request options `g_opt_mode` / `g_opt_threads` directly |
| EXPLAIN | `explain.S` | renders `QP_*` / `FP_*` |

**After**:

| Concern | Module | Entry points |
|---|---|---|
| semantic analysis | `binder.S` | `bind_statement`; the FROM clause becomes logical Scan / SubqueryScan / Join nodes (`lp_from_rv`, `lp_join`) in `QP_LFROM`; every bound block goes to `plan_block` |
| planning pipeline | `plan.S` | `plan_block`: `lp_build` → `optimize_logical` → `phys_plan` |
| **logical plan** | `lplan.S` (layout `LP_*` / `LK_*` / `LFF_*` in `include/sql.inc`) | `lp_build`, `lp_print`, `lp_print_expr`; shared predicate helpers `conj_rv`, `mk_and`, `lp_mark_nullable` |
| **optimizer** (rule driver) | `optimizer.S` | `optimize_logical`; rule table `opt_rules` / `opt_rule_names` |
| rule `pushdown` | `rule_pushdown.S` | `rule_pushdown` |
| rule `prune_columns` | `rule_prune.S` | `rule_prune_columns` |
| rule `fold_constants` | `rule_fold.S` | `rule_fold_constants` |
| **physical planner** | `planner.S` | `phys_plan` → `plan_from` / `build_fp` (scan predicates, physical FROM tree), `plan_scan` (access path: table / index scan, row-group skipping, estimate), `find_equi` (moved from the binder) / `choose_join` / build side, `phys_exec_settings` (execution mode, threads) |
| EXPLAIN | `explain.S` | unchanged: renders the physical plan |
| execution | `exec.S`, `pexec.S`, … | read only the physical plan and `g_exec_mode` / `g_exec_threads` |
| expression provenance | `ast.S` | `expr_written` (see below) |
| unit tests | `tests/test_optimizer.S` | logical plan builder and printer, each rule, the rule table, `optimize:false` |
| | `tests/test_planner.S`, `tests/test_lib.inc` | physical planner; shared test helpers |

### Logical plan

One tree per query block, built from the bound block in a canonical shape:
`[Limit] > [Sort] > [Distinct] > Project > [Filter (HAVING)] > [Aggregate] >
[Filter (WHERE)] >` FROM tree (`Scan` | `SubqueryScan` | `Join` with join
type and condition) or `Values`; a UNION ALL compound is
`[Limit] > [Sort] > UnionAll`. Expressions are the binder's typed nodes.
Nested blocks (derived tables, CTEs, UNION ALL branches, expression
subqueries) are separate plans referenced from `SubqueryScan` / `UnionAll`
/ the subquery node; rules never descend into them - each block is
optimized when it is planned, nested blocks first. `lp_print` renders a
plan for debugging and the unit tests, e.g. for
`SELECT t.a FROM t JOIN u ON t.a = u.a WHERE t.b = 1 + 1 AND u.a > 0`
after all rules:

```
Project t.a AS a
  Join INNER ON (t.a = u.a)
    Filter (t.b = 2)
      Scan t AS t [a, b]
    Filter (u.a > 0)
      Scan u AS u [a]
```

### Rules

`optimize_logical` applies the rules in order (each `rule(lp, block) → lp`,
individually callable and tested); with `optimize: false` it returns the
plan untouched.

1. **`pushdown`** - a Filter above a FROM tree is split into conjuncts; a
   conjunct that references exactly one range variable (not on the
   NULL-padded side of a LEFT JOIN, without aggregates or correlated
   subqueries) moves into the join inputs, into a Filter directly above that
   variable's scan (`LFF_PUSHED`); the rest stays above the FROM tree
   (`LFF_RESIDUAL`), and the Filter disappears when nothing remains.
2. **`prune_columns`** - each Scan / SubqueryScan produces only the columns
   referenced by the operators above it, including columns referenced by
   correlated subqueries (`EK_OUTER` nodes whose level count leads back to
   the block).
3. **`fold_constants`** - constant folding and predicate simplification as
   described in [Phase 5](#logical-optimizer-optimizers-rule_s-optimize-true);
   Filters folding to TRUE disappear.

### Physical planner

`phys_plan` derives the executable plan from the optimized logical plan:
LIMIT / ORDER BY / DISTINCT / outputs / HAVING / aggregation from the
corresponding operators; the FROM tree becomes `FP_*` nodes; a pushed Filter
becomes the predicate its scan evaluates; then, per scan, the access path
(TableScan vs IndexScan), row-group skipping and the estimate, per join the
equi-join key, the algorithm (`join` option or cost-based) and the build
side, and the execution mode (`mode` / `threads` → `g_exec_mode` /
`g_exec_threads`; `native` is accepted and ignored). No physical decision
is taken in the logical layer.

### Design decisions

* **Pushdown with `optimize: false`.** indexes-and-planning.md §3 requires
  scan-level pushdown, column pruning and index selection in every mode,
  and the conformance `--modes` matrix asserts IndexScans and exact scan
  column sets with `optimize: false`. A WHERE Filter that no rule has placed
  (no `LFF_*` flag) is therefore placed by the physical planner with the
  same criterion (the shared `conj_rv` / `lp_mark_nullable`); Filters the
  rule produced are mapped verbatim. The physical scan reads the columns the
  query references (`RV_USED`; scans produce row ids and columns are read
  lazily), which is what the logical `prune_columns` result describes when
  the rules run.
* **Rewrites before physical planning, same physical plan.** The previous
  engine folded constants *after* physical planning so that `optimize`
  never changed which rows are read. Now the rules run first, so a node the
  optimizer rewrites in place keeps a copy of itself as written
  (`N_WRITTEN`, expression nodes grew from 64 to 72 bytes), and the physical
  planner analyses predicates as written (`expr_written`): index selection,
  row-group skipping, estimates and equi-join keys are exactly those of the
  baseline, e.g. `WHERE id = 1234 OR FALSE` still does not use an index and
  `ON a.id = b.id OR FALSE` stays a nested loop, while execution evaluates
  the folded forms.
* **Rule order** pushdown → prune → fold places conjuncts by what the query
  says, exactly as the physical planner does when the rules are off, so
  EXPLAIN shows the same pushed filters in both settings (as before).
* Pushdown stops at SubqueryScans and Aggregates: pushing into a derived
  table's block or below grouping would change EXPLAIN and which rows are
  evaluated (errors). Within a block, WHERE is built below the Project, so
  there is nothing to push below a projection.
* The query block descriptor `QP_*` keeps the binder's semantic fields
  (range variables, output names and types, correlation, caching) and the
  physical planner (re)writes the executable ones from the logical plan,
  which keeps the executor and EXPLAIN untouched (small diff).

### Verification

* All suites as before (`runner.py` session / `--modes` / `--transport
  http`, `tests/concurrency/http_suite.py`, `make test`).
* A differential run against the engine before the refactoring replayed
  every public conformance file - each request plus an EXPLAIN of each
  query - under nine option sets (default, the six `--modes` combinations,
  `optimize:false`, `use_indexes:false`): 10,800 requests, identical
  responses (except `elapsed_us`); plus 1,107 requests of extra edge cases
  (foldable constants next to indexes, `OR FALSE` / `AND TRUE` in WHERE and
  ON, LEFT JOIN placement, correlated and uncorrelated subqueries, CTEs,
  UNION ALL, FROM-less queries, PQCF row-group skipping with and without
  `mmap`): identical.

## Latency optimization: the `analytics` workload

Goal: lower the latency of `benchmarks/workloads/analytics.json` at scale
1m without changing any result. Measured with `bench/workload.sh` (part of
the repository):

```
python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata --jobs 1
sh implementations/x86_64-asm-engine/bench/workload.sh /tmp/pqdata/1m 5
```

The script loads the nine workload tables (explicit schemas from the
generator), creates the two workload indexes, and sends every query once as
a warm-up and then 5 times through one `bin/polyquery session`, with the
engine's default options (rows requested as the workload says: `count` for
q14 / q15, full rows otherwise). The table shows the median of the
engine-reported `stats.elapsed_us` (parse → bind → plan → execute →
serialise; client wall-clock times measured separately with a driver
outside the repository differ by less than 0.3 ms). Machine: AMD Zen 5,
32 CPUs. "Before" is the engine at the start of this task (commit
`e912c3e`, kept in `bench/workload-before.txt`), "after" is this version
(`bench/workload-after.txt`).

| query | before (ms) | after (ms) | speed-up |
|---|---:|---:|---:|
| q01_filter_selective | 0.0 | 0.0 | - |
| q02_filter_low_selectivity | 15.0 | 1.6 | 9.4x |
| q03_range_filter_time | 0.6 | 0.7 | 0.9x |
| q04_arith_aggregate | 13.1 | 1.4 | 9.4x |
| q05_groupby_low_card | 10.7 | 1.2 | 8.9x |
| q06_groupby_high_card | 16.1 | 4.6 | 3.5x |
| q07_groupby_skewed | 33.5 | 5.9 | 5.7x |
| q08_groupby_uniform_multi | 25.5 | 3.1 | 8.2x |
| q09_distinct_count | 39.9 | 5.2 | 7.7x |
| q10_join_customers | 49.7 | 6.1 | 8.1x |
| q11_join_star | 25.6 | 4.4 | 5.8x |
| q12_left_join_anti | 14.9 | 5.6 | 2.7x |
| q13_sort_topn | 10.7 | 1.7 | 6.3x |
| q14_sort_full_string | 423.0 | 13.9 | 30.4x |
| q15_sort_multi_key | 354.4 | 16.8 | 21.1x |
| q16_timeseries_hourly | 1.8 | 0.3 | 6.0x |
| q17_wide_projection | 0.7 | 0.2 | 3.5x |
| q18_nulls | 23.4 | 1.9 | 12.3x |
| q19_cte_subquery | 23.3 | 7.0 | 3.3x |
| q20_string_functions | 38.3 | 3.5 | 10.9x |
| **total** | **1120.2** | **85.1** | **13.2x** |

The result rows of every query (warm-up runs, `PQ_BENCH_OUT=FILE`) are
byte-identical before and after.

### What changed

1. **Default parallelism** (`main.S` `resolve_threads`, `protocol.S`).
   A query without the `threads` option used one thread. The default
   (`--threads N`, implementation-defined per protocol.md) is now the number
   of online CPUs, capped at 16 (`DEFAULT_THREADS_MAX`); `--threads N` sets
   it explicitly. `mode: "row"` without `threads` keeps one thread, so the
   row baseline is still the unoptimized single-threaded interpreter. All
   modes return identical results (Phase 5 invariant), so this changes only
   speed. Largest effect on scans, filters and aggregations (q02, q04, q18,
   q20).
2. **ORDER BY with normalized keys** (new module `keysort.S`, used in the
   batch / parallel modes; the row baseline keeps the comparison sort).
   The leading ORDER BY keys of each row are encoded as up to 6 u64 words
   whose unsigned order is the ORDER BY order (sign-flipped integers, IEEE
   bits of FLOAT64 with -0.0 = 0.0, a NULL indicator word for keys that
   contain NULLs, STRING as 15 bytes + length in two words - exact while all
   strings are shorter than 16 bytes, DESC by complement). Rows are sorted
   by a parallel *sample sort*: per-part encoding, splitters from a sorted
   sample, classification by binary search, a stable scatter into one bucket
   per thread, and an MSD radix sort per bucket (constant bytes skipped,
   insertion sort with inlined word comparisons for small buckets; the
   NULL / long-string pre-scan is skipped for keys that are plain columns
   without NULLs; such STRING keys are assumed short and a long value seen
   while encoding just limits the key words trusted by the comparisons).
   Ties fall back to `row_cmp` only when
   the words are incomplete (wide DECIMAL, long strings, more than 6
   words), then to the production sequence, so the order is exactly the
   stable order of `sort_rows`. Parts accumulate their flags / masks /
   bucket counters on their own stacks (sharing written cache lines between
   threads made the first version 7x slower). q14 / q15: 423 / 354 ms →
   14 / 17 ms.
3. **GROUP BY with few groups** (`pexec.S` `lagg_ok`, `lagg_merge`). The
   parallel GROUP BY partitioned groups by hash, so with a handful of groups
   one thread did nearly all the work. When every aggregate state merges
   exactly (no DISTINCT, no FLOAT64 SUM / AVG), every part now aggregates its
   own range into a local table (`gfused_part`) and the local groups are
   merged in part order, which yields the serial first-seen group order and
   exactly the serial states. A part that sees more than 2048 groups stops
   all parts and the hash-partitioned aggregation runs instead. q05 10.7 →
   1.3 ms, q08 25.5 → 3.8 ms, q10 / q11 profit in their aggregation.
4. **Parallel DISTINCT aggregates without GROUP BY** (`pexec.S`
   `pexec_dsplit`). They used to force a single thread. Now the other
   aggregates run in parallel on a copy of the plan, and every DISTINCT
   aggregate is hash-partitioned: phase 1 evaluates and hashes its argument
   per tuple in parallel, phase 2 lets partition p keep the values whose
   hash falls into p (disjoint value sets) and aggregate each new value
   once; the partition states are merged. COUNT always; SUM / AVG / MIN /
   MAX unless the argument is FLOAT64 (summation order). The key phase also
   counts the values per (part, partition), so a scatter phase can list each
   partition's tuples (in tuple order) and a partition visits only its own
   tuples (radix partitioning, `aux_new` / `dscat_part`); integer-like
   values go into an open-addressing set instead of the generic chained
   table. q09 39.9 → 5.2 ms.
5. **Arena chunk pool** (`util.S` `chunk_get` / `chunk_put`). Released
   arena chunks (request, worker and table arenas) are kept, up to 1 GiB,
   and reused best-fit instead of being returned to malloc, which unmaps
   large blocks; first touches of fresh pages cost several ms on the larger
   queries. A reused chunk serves exactly the requested size, so memory
   accounting and `--max-query-memory-mb` behave as before. A forked
   `serve` child drops the inherited pool (`chunk_pool_forget`).
6. **Parallel hash-join build** (`pexec.S` `pexec_build`). Phase 1
   evaluates and hashes the build keys in parallel; phase 2 sizes the
   bucket array up-front and every part inserts only the keys whose bucket
   lies in its own bucket range (no locks, no shared chains), walking the
   build tuples backwards so that each key's tuple chain lists the tuples in
   input order, exactly like the serial build. Matters most for LEFT JOIN,
   which must build on its (larger) right input (q12). When both join keys
   have the same integer-like type (equality = bit equality), the build
   instead radix-partitions the build tuples by a multiplicative hash and
   every part fills an open-addressing sub-table (key → first tuple of the
   key's chain, `FastTable` in `HT_FAST`); the probe then needs one
   multiply and usually one slot instead of `hash_cells` / `cells_eq` /
   `value_cmp` calls per probe tuple.
7. **Hash-partitioned GROUP BY without sorting** (`pexec.S` `slot_order`,
   `pexec_emit`). The groups of all partitions used to be concatenated and
   sorted by their first tuple to restore the serial first-seen order; now
   every new group is recorded in a per-tuple slot array (cleared in
   parallel by the key phase) and a parallel compaction yields that order
   directly. The output rows of the groups (`agg_finish`, HAVING,
   projection) are then built in parallel parts and concatenated in order.
   Like the DISTINCT aggregates, the partitions get their tuples through
   radix partitioning instead of every partition scanning all hashes.
   q07 / q19: 33.5 / 23.3 ms → 5.9 / 7.0 ms.
8. **Persistent, pinned worker pool** (`par.S`). `par_run` used to create
   and join a pthread per part on every call (a sort makes seven calls).
   Workers now live as long as the process: a part is posted to its
   worker's slot under a mutex and both sides poll briefly (`POOL_SPIN`)
   before sleeping on condition variables. The calling thread and worker i
   are bound to the first and the i-th CPU of the process's affinity mask
   (on Linux all cores are numbered before their SMT siblings), which keeps
   every part on its own core; unbound, the long-lived threads were often
   scheduled onto shared cores and simple scans got slower. A thread's
   vector scratch stack top is restored after every part (an error inside a
   part could otherwise leak scratch space in a long-lived thread). A
   forked `serve` child starts without workers and does not pin (its
   queries run concurrently with other children).
9. Smaller: per-part results are appended with one copy (`vec_append`,
   `vec_reserve`) instead of element-wise pushes.

Verification after each step: the conformance suite (660/660), `--modes`
with `PQ_PAR_MIN=1` (3870/3870, forces parallel parts onto the tiny test
tables), `--transport http`, the concurrency suite, `make test` (whose
`modes_test.sh` now also covers full sorts on every key type, long and
short strings, NULL ordering, DISTINCT aggregates and the default thread
count), and full-result comparisons against the old engine on the 1m data
for many sort / group / DISTINCT queries beyond the workload.

## Scaling optimization: 1m -> 10m rows

Problem report: on `benchmarks/workloads/analytics.json` the engine grew
24.8x from 1m to 10m rows (geometric mean of the 20 query medians), with
large client-visible time outside `stats.elapsed_us`, latencies depending
on the previous query, about 2.1 million minor page faults and 4.6 s of
system CPU per round of the 20 queries, and HTTP throughput collapsing.
Goal: remove the causes of the super-linear growth without changing any
result.

### Measurements

`python3 benchmarks/harness/bench.py --engines x86_64-asm-engine --scale
<1m|10m> --no-sandbox --cpus '' --mem-limit-gb 0` (one session: all nine
tables, the two workload indexes, 3 warm-up and 7 measured rounds of the 20
queries in random order; medians of the client-side latency in ms; same
host - AMD Zen 5, 32 logical CPUs - and settings, "before" (the engine at
the start of this task, commit `7b2edaf`) and "after" run back to back at
each scale). Every query's result digest is identical before and after at
both scales (q14 / q15 return counts only; their full ordered results were
compared separately, see Verification).

| query | 1m before | 1m after | 10m before | 10m after | 10m/1m before | 10m/1m after |
|---|---:|---:|---:|---:|---:|---:|
| q01_filter_selective | 0.051 | 0.047 | 1.96 | 0.07 | 38.3x | 1.5x |
| q02_filter_low_selectivity | 2.033 | 1.777 | 35.17 | 20.06 | 17.3x | 11.3x |
| q03_range_filter_time | 1.645 | 1.620 | 33.54 | 16.85 | 20.4x | 10.4x |
| q04_arith_aggregate | 1.755 | 1.736 | 44.20 | 18.29 | 25.2x | 10.5x |
| q05_groupby_low_card | 1.357 | 1.354 | 49.28 | 14.46 | 36.3x | 10.7x |
| q06_groupby_high_card | 5.377 | 5.570 | 94.49 | 66.27 | 17.6x | 11.9x |
| q07_groupby_skewed | 7.060 | 6.504 | 147.25 | 125.47 | 20.9x | 19.3x |
| q08_groupby_uniform_multi | 3.297 | 3.237 | 55.93 | 24.48 | 17.0x | 7.6x |
| q09_distinct_count | 5.841 | 6.072 | 118.15 | 79.15 | 20.2x | 13.0x |
| q10_join_customers | 7.298 | 5.963 | 180.64 | 91.89 | 24.8x | 15.4x |
| q11_join_star | 5.614 | 5.025 | 133.55 | 60.33 | 23.8x | 12.0x |
| q12_left_join_anti | 6.755 | 5.189 | 171.61 | 89.96 | 25.4x | 17.3x |
| q13_sort_topn | 2.724 | 2.932 | 61.23 | 34.49 | 22.5x | 11.8x |
| q14_sort_full_string | 14.235 | 13.489 | 353.66 | 271.33 | 24.8x | 20.1x |
| q15_sort_multi_key | 16.513 | 15.510 | 375.23 | 296.57 | 22.7x | 19.1x |
| q16_timeseries_hourly | 0.827 | 0.703 | 21.75 | 2.96 | 26.3x | 4.2x |
| q17_wide_projection | 0.266 | 0.224 | 6.30 | 1.67 | 23.7x | 7.5x |
| q18_nulls | 2.175 | 1.923 | 59.26 | 21.65 | 27.2x | 11.3x |
| q19_cte_subquery | 9.018 | 8.011 | 170.57 | 128.86 | 18.9x | 16.1x |
| q20_string_functions | 3.151 | 3.246 | 57.37 | 32.24 | 18.2x | 9.9x |

Peak RSS (harness, whole session): 1m 1406 -> 1234 MiB; 10m 11326 -> 12702
MiB (+12 %, the chunk pool keeping up to half the peak chunk memory, see 1).
CPU time of the 10m query phase: 192.6 s -> 174.9 s, wall 22.6 s -> 14.4 s.
Repeated interleaved runs of the 1m queries that came out slightly slower
here (q06, q09, q13, q20) alternate between the two engines from run to
run (measurement noise, +-10 % on this shared host).

HTTP (`--http`, 10m, `transactions` and `customers` loaded, q01 / q03 /
q05 / q09 at random, 20 s per client count; same host, back to back):

| clients | before qps | after qps | before p50 (ms) | after p50 (ms) |
|---:|---:|---:|---:|---:|
| 1 | 5.4 | 30.7 | 137.1 | 11.1 |
| 4 | 15.3 | 34.7 | 192.5 | 60.1 |
| 16 | 17.7 | 26.0 | 813.9 | 119.7 |

With several clients the throughput is now bound by the CPU work of q09
(two COUNT(DISTINCT) over 10m rows: 1-2 CPU-seconds per query).

### Causes found and changes

Tools: `perf` is not permitted on the host, so `src/prof.S` adds an opt-in
sampling profiler (`PQ_PROF=FILE`: SIGPROF every millisecond of process
CPU time records the interrupted address, thread, time stamp counter and
the word at the stack pointer; `bench/prof.sh FILE` prints a flat profile).
Comparing per-function samples per query at 1m and 10m and per-phase
timelines located the growth; `strace` showed the memory behaviour.

1. **Arena chunk pool** (`util.S`; the main cause). Arena chunks are
   mmap'd; released chunks were kept in a pool of at most 1 GiB and reused
   only by requests that fit. At 10m a query's chunks run to gigabytes, so
   nearly every query mapped fresh memory (every first touch a page fault
   plus zeroing: the 2.1 million faults and 4.6 s system CPU per round) and
   unmapped it again (TLB shootdowns on all CPUs of the process). The
   unmapping happened when the next request reset the arenas, before its
   timer started: that is the time outside `stats.elapsed_us` and why a
   query's latency depended on the query before it. Now:
   * chunk sizes are rounded to size classes (four per power of two,
     multiples of 2 MiB from 2 MiB on), so released chunks fit later
     requests;
   * the pool keeps up to max(1 GiB, peak chunk bytes - chunk bytes in use,
     peak / 2), unmapping the least recently released chunks beyond that
     (with only the first two terms, differently sized queries kept
     evicting each other's chunks: about 1.5 GB of fresh mappings per round
     at 10m);
   * one free list per size class plus a release-order list, both doubly
     linked through the free chunks (a single list walked under the spin
     lock had become a hot spot with thousands of pooled chunks);
   * chunks of 2 MiB or more are 2 MiB aligned and use transparent huge
     pages (`madvise`): 512 times fewer faults for fresh memory, fewer TLB
     misses in hash / scatter phases, and a cheap `fork` of a `serve`
     process holding 10m-row tables.
   Steady state at 10m: about 20 faults and 0.05 s system CPU per round.
2. **Column statistics** (`table.S` `table_col_stats`). The planner's
   per-column statistics (NULLs, distinct values, min / max) were computed
   on first use by one row-at-a-time pass (about 260 ms per 10m-row column).
   They are now computed in parallel parts and merged with exactly the
   serial semantics (strict first-occurrence min / max, register-wise
   HyperLogLog maximum, exact distinct count up to 200,000 including the
   serial loop's rule for giving up the exact set); the `stats` op output
   is identical at 1m and 10m.
3. **Statistics in `serve`** (`server.S` `srv_prepare_table`). Every query
   runs in a forked child, which computed the statistics its plan
   consulted and lost them at exit - on every query (q01 over HTTP: 420
   ms at 10m). The server now computes all statistics when a table is
   loaded or opened (on the catalog worker, before publishing), so children
   inherit them.
4. **Serial merges of per-part tuple sets** (`pexec.S` `ts_concat`). Scans,
   hash-join probes and nested-loop joins appended the parts' outputs one
   by one on the calling thread, re-copying the growing set at every
   doubling. The result is now allocated once and every part copies its
   own output in parallel.
5. **Hash-join probe** (`pexec.S` `probe_part`). When ON is just the key
   equality, joined tuples go straight to the part's output instead of
   through a candidate set and a per-tuple copy (LEFT JOIN: the unmatched
   probe tuple's NULL-padded tuple follows in order). This matters most
   for skewed joins (q12: 80 % of the orders belong to the customers of
   the first probe part).
6. **Sort** (`keysort.S` `ks_msd`). The per-bucket MSD radix sort copied
   every level back from the scratch buffer; levels now alternate between
   the two buffers. Digits that are constant inside a bucket are skipped a
   key word at a time (one OR/AND pass instead of one histogram pass per
   byte: many equal short strings in q14), and a range already in key
   order (complete key words; ties are in sequence order because every
   scatter is stable) is left as it is.
7. **Concurrent queries in `serve`** (`server.S` `child_threads`,
   `par.S`). Unless `--threads` is given, a forked query process uses
   ceil(default threads / running queries) threads and polls only briefly
   before sleeping: 16 concurrent queries of 16 threads each took more
   than twice the CPU time per query.

### Verification

Conformance suite 660/660, `--modes` 3870/3870 (also with `PQ_PAR_MIN=1`),
`--transport http` 660/660, `tests/concurrency/http_suite.py` 19/19,
`robustness_probe.py --only expression_limits` pass, `make build test lint`.
Beyond the harness digests: full ordered results of q13-q15 and seven more
ORDER BY queries (three option sets) and of nine join queries (LEFT /
INNER, build on either side, multi-match and NULL keys; four option sets)
are byte-identical to the old engine at 1m, and the `stats` op output for
every column of the nine tables at 1m and 10m.

### What still grows faster than the data

Per-function samples (1m -> 10m, per query) still grow 25-40x in the
radix sort's scatter (q14 / q15: 25 MB of 40-byte entries per thread no
longer fit the caches), in chained hash tables of high-cardinality GROUP
BY (q07 / q19: one million groups) and in the probe of a one-million-key
join table (q10). These are cache effects of the operators' data
structures rather than overheads around them; candidates for a later
change are an open-addressing integer-key aggregation table, smaller sort
entries, and an anti-join for LEFT JOIN ... WHERE right.non_null_column
IS NULL.

## Implementation-defined choices

* `UNION` (without `ALL`, also `UNION DISTINCT`), `RIGHT` and `FULL` joins
  are `UNSUPPORTED`; a `UNION ALL` in a place the grammar does not allow it
  (after a branch's ORDER BY / LIMIT, after a parenthesised branch) is a
  `PARSE_ERROR`.
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
  its plan as child), `UnionAll` (the branch plans as children) and `Values`
  (SELECT without FROM). Subqueries inside
  expressions are not shown.
* Common type of CASE / COALESCE branches: identical types stay as they are;
  otherwise numeric promotion per types.md §2 (so two different DECIMAL types
  give `DECIMAL(W, max scale)`, W = 38 if one of them is wide, else 18);
  otherwise all must be equal.
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
  (e.g. `1.5 * 2` is `DECIMAL(18,1)`), or as `DECIMAL(19,0)` when the other
  operand is wide (W = 38, so every INT64 converts exactly). Comparisons of
  INT64 / DECIMAL values compare exact values without any promotion (CR-2).
* After an explicit `AS`, the words `FULL` and `RIGHT` (reserved for future
  join syntax, never valid there) are accepted as column aliases
  (`SELECT … AS full`, as `changes/decimal38.pqt` requires); everywhere else
  they stay `UNSUPPORTED`.
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
  both inputs (index order is not reused); the merge join's sort and merge,
  hash builds, DISTINCT aggregates over FLOAT64 without GROUP BY, DISTINCT and the
  materialisation of derived tables / CTEs run single-threaded.
* Blocks whose expressions contain subqueries run their operators on one
  thread (subquery results are cached in the shared plan). The `native`
  option is accepted and ignored (`native.kernels` is not claimed).
* Statement size limits (CR-6): nesting depth 4,096 parser levels (at
  least 2,047 CR-6 levels), 1,000,000 operands; a 100,000-branch
  `UNION ALL` exceeds the default memory budget in parallel modes (each
  branch's scan allocates per worker), and binding a chain of CTEs is
  quadratic in its length (a 100,000-CTE chain runs into the timeout).
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
