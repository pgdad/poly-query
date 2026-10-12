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
[DECIMAL precision 38](#change-cr-2-decimal-precision-38)).

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
| `threads` | int ≥ 1 (default 1, capped at 64) | parallel parts for scans, filters, projections, hash-join probes and aggregation, in both modes |
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
  the calling thread, the others on fresh pthreads. Workers allocate from
  their own arenas (thread-local `t_arena`, kept until the request ends) and
  raise errors through a thread-local `jmp_buf`; `tmp_alloc`, `pq_raise`
  and the CAST formatting buffer are thread-aware, so the evaluator runs
  unchanged in workers. Lazily decoded PQCF columns referenced by the block
  are decoded before workers start. Blocks containing subqueries run on one
  thread (subquery results are cached in the shared AST).
* Parallel operators: full scans with pushed-down filters (honouring
  row-group skipping), WHERE, projection (with per-part top-N), hash-join
  probe (build is serial), nested-loop join, merge-join key evaluation,
  aggregation, ORDER BY (each part sorts its range of (row, sequence)
  pairs, then the sorted runs are merged pairwise in parallel rounds). Aggregation without GROUP BY merges
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
  hash builds, DISTINCT aggregates without GROUP BY, DISTINCT and the
  materialisation of derived tables / CTEs run single-threaded.
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
