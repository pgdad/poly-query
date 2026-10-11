# PolyQuery — Common Lisp implementation

An in-memory analytical SQL engine implementing the PolyQuery specification
(`spec/`) in ANSI Common Lisp on SBCL. Current scope: **Phases 1–5**
(protocol, catalog, CSV/JSON/JSONL ingestion, all data types, the complete
SQL grammar and semantics — joins, grouping, DISTINCT, all scalar functions,
CASE/LIKE/BETWEEN/IN, uncorrelated *and correlated* subqueries, derived
tables, CTEs, EXPLAIN — resource limits, test functions; row and column
layouts, dictionary encoding, null bitmaps, the PQCF v1 file format with
memory-mapped reads, statistics, hash and ordered indexes, index selection,
predicate pushdown with row-group skipping, column pruning and cost-based
join build sides), and the Phase 4 HTTP/1.1 server (`serve`): every
endpoint of protocol.md §7, NDJSON streaming with backpressure, Prometheus
metrics, structured JSON logs, snapshot-isolated concurrent readers, worker
limits with a bounded FIFO queue and `OVERLOADED` rejection, timeouts,
cancellation (explicit and on client disconnect) and graceful shutdown, and
the Phase 5 execution engine: the row-at-a-time (Volcano) baseline, a
vectorized batch executor over typed column vectors, morsel-driven parallel
scans, aggregation, DISTINCT and sorting, hash / sort-merge / nested-loop
joins selectable per query, and a switchable rule-based logical optimizer
(constant folding, predicate simplification, predicate pushdown, join
reordering, column pruning) followed by a separate physical planner (access
paths, join algorithms, top-N, execution mode, threads, native kernels);
and the M9 native kernel integration: the
`libpqkernels` library (`native-kernels/`) is loaded through SBCL's FFI
(`sb-alien`) with `--native-kernels PATH` and used for filtering,
aggregation, bitmap and hashing work of queries run with `native: true`
(see *Native kernels*). On top of that, change request CR-1 adds
`UNION ALL` (`spec/changes/union-all.md`, capability `change.union_all`;
see *Change request CR-1: UNION ALL*), the refactoring CR-3 separates
logical and physical planning (`spec/changes/refactor-plan-separation.md`;
see *Change request CR-3: logical/physical plan separation*), and change
request CR-2 raises the maximum DECIMAL precision from 18 to 38 digits with
exact INT64/DECIMAL comparisons and the PQCF v2 file format
(`spec/changes/decimal38.md`, capability `change.decimal38`; see *Change
request CR-2: DECIMAL precision 38*).

## Build prerequisites

* SBCL 2.6.9 (`sbcl` on `PATH`), with its bundled ASDF and `sb-rt` contrib.
* GNU make, a POSIX shell.
* No network access and no third-party libraries are needed.

```sh
make build      # compiles with ASDF and saves build/polyquery (standalone executable)
make test       # runs the unit tests (sb-rt)
make lint       # clean recompile; fails on any compiler WARNING
make fmt        # whitespace normalisation (there is no standard CL formatter)
make clean
bin/polyquery version
```

`bin/polyquery` is a small shell launcher that execs `build/polyquery` and works
from any directory. The executable is saved with `:save-runtime-options`, so
SBCL's runtime does not interpret any command-line arguments; the heap
(8 GiB dynamic space) and control stack (64 MiB) sizes are fixed at build time.

## Libraries

None. Only ANSI Common Lisp, SBCL extensions (`sb-ext`, `sb-sys`, `sb-alien`,
`sb-int`, `sb-impl`, `sb-kernel`, `sb-thread`, `sb-unix`) and the bundled
`asdf`/`uiop`/`sb-posix`/`sb-bsd-sockets`/`sb-rt` contribs are used (`ENGINE.json` lists
no libraries). `sb-posix` provides `mmap`, `fsync`, `rename` and `fstat`;
`sb-bsd-sockets` provides TCP sockets; threads, mutexes and condition
variables come from `sb-thread`; `sb-alien` is the FFI to the workspace's
own optional kernel library `libpqkernels` (built separately with
`make -C native-kernels`, loaded at run time, never linked into the build).

## Capabilities

`phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`, `sql.basic`,
`test.functions`, `phase2`, `sql.groupby`, `sql.join`, `sql.functions`,
`sql.subquery`, `sql.cte`, `sql.correlated_subquery`, `phase3`,
`storage.pqcf`, `storage.mmap`, `index.hash`, `index.btree`, `phase4`,
`http.streaming`, `phase5`, `exec.row`, `exec.vectorized`, `exec.parallel`,
`join.hash`, `join.merge`, `join.nested_loop`, `native.kernels`,
`change.union_all`, `change.decimal38`.

## Architecture

A statement goes through the stages required by the spec, each with its own
data structures and module (`src/`, loaded in this order by `polyquery.asd`):

```
SQL text --lexer--> tokens --parser--> AST --binder--> BOUND-QUERY
  --plan builder--> logical plan (LP-*) --optimizer rules--> logical plan
  --physical planner--> physical plan (PP-*) + execution settings
  --compiler--> row iterators (mode: row)
             or batch iterators over column vectors (mode: vectorized/auto,
                parallel pipelines with threads > 1) --> rows
```

| Layer | Files | Responsibility |
|---|---|---|
| util | `errors`, `numbers`, `json` | `pq-error` condition with stable codes; exact numeric text parsing, correctly rounded float parsing, shortest round-trip float printing; strict RFC 8259 JSON reader/writer |
| types | `types`, `temporal`, `values`, `compare` | type representation, aliases, promotion lattice and result-type unification; DATE/TIMESTAMP calendar math; text conversion, `CAST`, canonical serialization; total ordering |
| storage | `columns`, `table`, `stats`, `index`, `catalog`, `binary`, `files`, `pqcf-write`, `pqcf-read` | typed column vectors with validity bitmaps and dictionary encoding; immutable tables in row or column layout split into segments; lazily computed column statistics; hash and sorted-permutation (B-tree equivalent) indexes; catalog of tables and global index names with atomic publish (mutex-protected); little-endian codec, CRC-32, strict UTF-8; crash-safe file replacement and mmap/buffered file sources; PQCF v1/v2 writer and validating reader |
| ingest | `common`, `csv`, `json` | CSV parsing on raw UTF-8 octets, JSON/JSONL; type inference and explicit-schema conversion |
| sql | `lexer`, `ast`, `parser` | tokenizer with line/column positions; AST structures; recursive-descent parser for the full grammar of `grammar.md` (`PARSE_ERROR` carries `details.line`/`column`) |
| analyzer | `bound`, `functions`, `binder`, `query` | semantic validation. `bound`: bound expression nodes and the analysed-query representation; `functions`: the scalar function registry (typing + implementation per function); `binder`: expressions — name resolution through nested scopes, typing, implicit promotions, CASE/LIKE/BETWEEN/IN, subqueries; `query`: CTEs, FROM/joins/derived tables, `*` expansion, output naming, GROUP BY alias/ordinal resolution, the structural grouping rewrite, HAVING, DISTINCT, ORDER BY resolution, constant LIMIT/OFFSET |
| plan | `logical`, `estimates`, `rules/*`, `builder`, `optimizer`, `access`, `physical` | the logical plan representation (`Scan`, `Values`, `Filter`, `Project`, `Join`, `Aggregate`, `Distinct`, `Sort`, `Limit`, `UnionAll`, `SubqueryAlias`; subquery plans on the subquery descriptors) and its printer; predicate analysis, selectivity and cardinality estimates; one file per optimizer rule; plan construction from analysed queries; the optimizer (rule registry and driver); access paths (index choice, segment skipping); physical planning (operators, join algorithms, top-N, execution settings) and EXPLAIN JSON rendering. See *Change request CR-3* |
| native | `kernels` | FFI bindings to `libpqkernels` (`sb-alien`): run-time loading, ABI check, entry points, array-level wrappers |
| exec | `context`, `expressions`, `aggregates`, `operators`, `vectors`, `vexpressions`, `keytable`, `vaggregates`, `vnative`, `voperators`, `parallel` | query context (deadline, cancellation flag, memory budget, join row limit, cleanups) and execution options; expression compiler to closures (incl. subquery evaluation); aggregate accumulators; Volcano-style row operators. Vectorized executor: typed column vectors and batches; vector kernels; hash table of key tuples; columnar mergeable aggregate states; native-kernel predicates, filters and lazy scan batches; batch operators; morsel-driven parallelism |
| protocol | `requests`, `cli` | JSON-lines request dispatch (`query`, `explain`, catalog ops), validation and responses, structured logging; CLI modes `version`, `capabilities`, `session`, `exec`, `serve` |
| server | `http`, `scheduler`, `metrics`, `server` | HTTP/1.1 message parsing and response writing; admission control (worker pool, bounded queue, query registry, timeouts, cancellation, bounded streaming channel); Prometheus counters; routing, endpoint handlers, connection threads, listener and graceful shutdown |

### Values and expressions

Values are untyped at runtime; the static type in the plan decides their
meaning: NULL is `:null`, BOOLEAN is `t`/`nil`, INT64 an integer, FLOAT64 a
`double-float`, DECIMAL(p,s) its unscaled integer, STRING a Lisp string,
DATE days and TIMESTAMP microseconds since the epoch. Exactness comes from
Lisp's unbounded integers: INT64 and DECIMAL arithmetic is computed exactly
and range-checked afterwards; SUM/AVG accumulate exactly. This holds for
narrow (p ≤ 18) and wide (p 19–38) decimals alike: a wide value is the same
kind of unscaled integer, merely one that may be a bignum (see *Change
request CR-2*).

Bound expressions (`B-LITERAL`, `B-COLUMN`, `B-PARAM`, `B-OP`, `B-AGG`) are
typed trees; every column reference is a position in the row of the operator
that evaluates it. Expressions are compiled once per statement into closures
with all type dispatch (promotions, comparators, hash-key normalization) done
at compile time.

### Planning

* **Logical plan.** The FROM row is the concatenation of all range
  variables' columns; joins associate left to right; derived tables and CTE
  references are planned as nested sub-plans under a `SubqueryAlias` node;
  expression subqueries carry their own logical plans. Aggregated queries
  project from an aggregation row `[group keys..., aggregates...]` produced
  by the structural GROUP BY rewrite of semantics.md §5. The plan builder
  prunes columns as it builds (scans read only referenced columns, also with
  `optimize: false`).
* **Optimizer.** A sequence of named rules (no rule runs with `optimize:
  false`; see Phase 5 for constant folding, predicate simplification and
  join reordering). *Predicate pushdown* splits WHERE and ON conditions into
  conjuncts and moves each one to the lowest valid place: the preserved side
  of a LEFT JOIN, either side of an inner join, or an inner join's condition
  (so comma joins with a WHERE equality become hash joins), and below the
  Project of a derived table or CTE whose expressions cannot fail;
  conjuncts on the NULL-supplying side of a LEFT JOIN stay above it.
  *Column pruning* propagates the set of required columns top-down and
  renumbers column positions, so every `TableScan` reads only referenced
  columns.
* **Access paths.** A filter directly above a scan (where pushdown puts
  every single-table conjunct) is analysed into `column op constant`,
  `column IN (constants)` and `column BETWEEN constant AND constant`
  predicates. Every index of the table proposes an access (HASH: `=`/`IN`;
  BTREE: `=`/`IN` and all range predicates on its column combined); the
  estimated selectivity is 1/distinct per value for equality and linear
  interpolation between the index's min and max for ranges on
  numeric/temporal columns (1/3 per bound otherwise). The most selective
  access becomes an `IndexScan` when it selects ≤ 10% of the rows; the
  conjuncts it answers exactly are removed and the rest stay in a `Filter`
  above it. Otherwise the `TableScan` receives the predicates for segment
  skipping (see Storage).
* **Physical plan.** Joins with equality conjuncts between the two sides
  become `HashJoin` (remaining conjuncts form a residual; inner joins build
  on the input with the smaller estimated cardinality, LEFT joins on the
  right input), or `MergeJoin` / `NestedLoopJoin` when the `join` option
  forces them; joins without equality conjuncts are `NestedLoopJoin`
  (`join_type` INNER/LEFT/CROSS);
  aggregation and DISTINCT are hash based; `ORDER BY … LIMIT n` with a
  literal limit becomes a bounded `TopN`; inside correlated subqueries a
  filter `column = outer value` over a scan becomes a `HashLookupScan` (the
  table is hashed once and probed per evaluation).
* **EXPLAIN** (statement and `explain` op) renders the physical plan as JSON
  (indexes-and-planning.md §4). The plan of a subquery appears after the
  input children of the node that evaluates it, wrapped in a `Subquery`
  node (`kind`, `correlated`), so plan walkers see every scan.

### Execution

`COMPILE-OPERATOR` turns each physical node into an *opener* (a function
returning a fresh iterator): expressions are compiled once, openers may run
many times. Join hash tables and materialized nested-loop inputs whose
subtree does not depend on correlation parameters are built once and reused
across re-executions of a correlated subquery. Timeouts/cancellation are
checked every few thousand rows in every loop; materialized state is charged
against the memory budget.

### Storage (Phase 3)

* **Layouts.** A table is immutable and split into *segments* (one for
  loaded tables, one per row group for tables opened from PQCF). In the
  *column* layout (default) a segment holds one typed vector per column —
  `(signed-byte 64)` for INT64/narrow DECIMAL/DATE/TIMESTAMP, a simple
  vector of integers for wide DECIMAL (p > 18), `double-float` for
  FLOAT64, a bit vector for BOOLEAN, strings or dictionary codes for STRING —
  plus a validity bitmap (absent when the column has no NULLs). In the *row*
  layout a segment holds row tuples. Scans, statistics, indexes and the PQCF
  writer read both through the same per-column reader functions, so results
  are identical.
* **Dictionary encoding** is used for STRING columns in the column layout
  when the input has at least 16 rows and fewer than n/2 distinct values, or
  always with `{"dictionary": true}` (`false` disables it).
* **Statistics** (`stats`): null count, exact distinct count, min and max
  per column, computed from the data on first use and cached per column.
* **Indexes.** `HASH`: hash table from value to the ascending row ids;
  `BTREE`: a sorted permutation (non-NULL values in order with their row
  ids) searched by binary search with the SQL comparator between the column
  type and the constant's type, so cross-type predicates (`int_col > 2.5`,
  `date_col < TIMESTAMP '…'`) are exact. Hash lookups convert the constant to
  the column's representation exactly; when that is impossible (e.g. a FLOAT64
  constant beyond 2^53 against INT64) the hash index is not used. Index
  scans return rows in table order. Index names are global; indexes belong
  to the table object they were built on and disappear when it is dropped or
  replaced.
* **PQCF writing** (`save`): a table with a wide DECIMAL column is written
  as PQCF v2 (128-bit values for those columns), every other table as v1
  (decimal38.md §7). Row-group-major chunks at 8-byte aligned
  offsets (zero padding), metadata with min/max for every type except
  STRING, indexes of the table. Encodings with `auto`: RLE when the run count
  is below n/4 (BOOLEAN, INT64, DECIMAL, DATE, TIMESTAMP), DICT when the
  distinct count is below n/2 (STRING), else PLAIN; forced `dict`/`rle` fall
  back to PLAIN for types they do not apply to. Default row group size 65536.
  The file is written to `.<name>.tmp-<pid>-<n>` in the target directory,
  fsynced, renamed over the target and the directory is fsynced; temporaries
  of crashed processes (dead pid) are removed by the next save of the target.
* **PQCF reading** (`open`): header, footer, metadata CRC, metadata structure
  and value rules are validated; every column chunk is CRC-checked and
  validated before use. With `mmap: true` the file is mapped read-only
  (`sb-posix:mmap`) and each chunk is verified and decoded on first access
  (a corrupt chunk fails the query that touches it with `STORAGE_CORRUPT`);
  otherwise the file is read and every chunk is verified and decoded during
  `open`. Bytes of the data area not covered by any chunk must be zero
  padding (so bit flips in padding are detected). With `layout: "row"`
  everything is decoded into row tuples. Chunk min/max statistics are used
  only to skip row groups: a `TableScan` skips a segment when its
  statistics prove a pushed `column op constant` / `IN` / `BETWEEN`
  predicate false for every row (or the column is entirely NULL there).

### Subqueries and correlation

A subquery used as an expression is a `:SUBQUERY` op whose descriptor holds
its analysed query, logical and physical plans and a *parameter
environment*. While a
subquery is analysed, column references it cannot resolve itself are looked
up in the enclosing scopes; each such outer reference becomes a correlation
parameter: a `B-PARAM` inside the subquery and a parameter expression (an
argument of the `:SUBQUERY` op) in the enclosing query. Because parameters
are ordinary arguments, the grouping rewrite, column pruning and pushdown
treat them like any other expression (an outer column used in a subquery of
an aggregated query must be grouped). At runtime the parameter values are
computed from the current outer row, stored in the environment and the
subquery plan is re-opened; results are memoized per distinct parameter
tuple. Uncorrelated subqueries are evaluated once, lazily, so nothing runs
before the whole statement has been analysed.

### HTTP server and concurrency (Phase 4)

* **Threads.** The main thread accepts connections (non-blocking listener
  polled every 50 ms, so a shutdown request is noticed promptly) and starts
  one thread per connection. A connection thread parses requests (keep-alive,
  pipelining, `Content-Length` and chunked bodies, `Expect: 100-continue`)
  and answers every non-query endpoint itself, so `/health`, `/metrics`,
  `/v1/queries` and cancellation stay responsive when all workers are busy.
* **Admission control** (`scheduler.lisp`). `--workers N` persistent worker
  threads take query jobs from a FIFO queue. A query is admitted while
  running + queued < N + `--queue-depth`, otherwise it is rejected at once
  with `OVERLOADED` (503). Every admitted job is registered under its query
  id (client-chosen `options.query_id` or a server-assigned `q<n>`); a
  duplicate active id is `ALREADY_EXISTS` (409). Queries come from
  `/v1/query`, `/v1/query/stream` and `query` ops sent to `/v1/request`;
  all other operations (including `explain` and loads) run on the
  connection thread.
* **Completion protocol.** A job completes exactly once (first writer wins
  under the scheduler mutex): normally by its worker; or by the waiting
  connection thread when it is cancelled or its deadline passes while still
  queued, or when a running job has not stopped by itself 50 ms after its
  cancellation/deadline (the worker then finishes in the background and its
  result is discarded). Completion updates the metrics and writes the
  `query finished` log event.
* **Timeouts.** The query context (deadline, cancellation flag, memory
  budget) is created at admission, so queued time counts; the effective
  timeout is `options.timeout_ms` if > 0, else `--query-timeout-ms`.
  Operators check the context every 4096 rows and `PQ_SLEEP` every 5 ms.
* **Cancellation.** `DELETE /v1/queries/{id}` sets the cancellation flag
  (a queued job completes immediately). While a connection thread waits for
  its query it polls the socket every 10 ms; end of input (`recv` with
  `MSG_PEEK` returning 0) or a failed write means the client disconnected
  and the query is cancelled.
* **Streaming.** The worker plans the query (errors so far become a normal
  error response with its HTTP status), then pushes the header, batches of
  up to 1000 rows (a partial batch is flushed after 50 ms) and the end or
  error item into a channel bounded to 8 batches; the connection thread
  serializes items as NDJSON chunks. A full channel blocks the worker
  (checking for cancellation/timeout every 5 ms), and responses are written
  with blocking `write(2)` calls rather than SBCL fd-streams (which queue
  unwritten output without bound), so a client that stops reading stalls
  the query. The socket send buffer of a streaming connection is limited
  to 256 KiB. A runtime error after the header is reported as a final
  `{"type":"error",…}` line without an `end` line.
* **Snapshot isolation.** A query analyses and plans against a private copy
  of the catalog's name → table/index maps taken when it starts executing;
  tables are immutable, so the query sees exactly those versions even if
  they are replaced or dropped meanwhile. Catalog mutations are atomic under
  the catalog mutex; loads parse outside the lock and publish at the end.
* **Graceful shutdown.** SIGTERM/SIGINT set a flag; the main thread then
  closes the listener (new connections are refused), marks the server as
  draining (`/health` answers 503, requests on existing connections get
  `SHUTTING_DOWN`), waits until no query is queued or running and no
  request is in progress, up to `--shutdown-grace-ms`, then cancels the
  remaining queries (their clients receive `CANCELLED`), waits up to 2 s for
  those responses to be written and exits with status 0.
* **Logs** are JSON lines on stderr (`ts` in RFC 3339 UTC with
  milliseconds, `level`, `msg`, plus event fields), serialized by a mutex.
  At `info`: startup, query completion (`query_id`, `status`,
  `duration_ms`, `rows`, `error_code`), rejections, cancellation requests
  and shutdown; SQL text and data never appear. `debug` adds one line per
  HTTP request (method and path).

### Phase 5: execution engine and optimizations

**Options** (protocol.md §5.2, for `query`, `explain` and the HTTP
endpoints). Every combination produces the same results (FLOAT64 sums up to
summation order, which functions.md leaves implementation-defined):

| option | effect |
|---|---|
| `mode: "row"` | the row-at-a-time Volcano executor (`operators.lisp`), kept unchanged as the unoptimized baseline; single-threaded |
| `mode: "vectorized"` / `"auto"` (default) | the batch executor (`v*.lisp`) |
| `threads: N` | morsel-driven parallelism of the vectorized executor (scans, filters, projections, hash-join probes, aggregation, DISTINCT, sorting, top-N); default: the `--threads` command line option of `session`/`exec`/`serve`, else (or with `--threads 0`) one per usable CPU, at most 16 (see *Latency optimization*) |
| `join: "hash"` / `"merge"` / `"nested_loop"` | forces the algorithm of every equi-join (`HashJoin`, `MergeJoin`, `NestedLoopJoin` in EXPLAIN); joins without an equality conjunct are always nested loops. `auto` = hash join (linear in both inputs; no operator produces sorted output a merge join could exploit) |
| `optimize: false` | applies no optimizer rule (no constant folding, predicate simplification, predicate pushdown, join reordering or re-pruning). Scans still read only referenced columns: Phase 3 requires pruned scans, so the plan builder prunes every new plan, which also guarantees that unreferenced expressions are not evaluated |
| `native: true` | the vectorized executor uses the native kernels of `libpqkernels` when the library was loaded with `--native-kernels` (see *Native kernels*); otherwise, and in `mode: "row"`, the Lisp code runs |

**Vectorized executor.** Operators exchange *batches* of up to 2048 rows
(small enough to stay in L1/L2) holding one *vector* per column. Vectors are
typed by the column's static type: INT64/DECIMAL/DATE/TIMESTAMP as
`(signed-byte 64)` arrays and FLOAT64 as `double-float` arrays, each with a
validity bitmap — the same layout as the column store, so a scan copies
slices instead of boxing values — and BOOLEAN/STRING as simple vectors.
Expressions compile to *kernels* (batch → vector):

* typed loops for comparisons (column/column and column/constant, with the
  constant converted once to the column's representation), INT64/DECIMAL/
  FLOAT64 arithmetic with the same overflow checks as the row evaluator,
  negation, numeric promotions, AND/OR/NOT, IS [NOT] NULL, CASE;
* every other operator (string functions, casts, LIKE, IN lists, date
  functions, subqueries, ...) is *lifted*: its arguments are evaluated as
  vectors and the row implementation is applied per element, so both
  executors share one definition of every function;
* evaluation is never less lazy than the row evaluator where it could make a
  difference: an operand that may raise an error is evaluated only on the
  rows where the row evaluator would evaluate it (after a non-NULL left
  operand, a non-FALSE left side of AND, the rows reaching a CASE branch);
  operands that cannot fail are evaluated eagerly over the whole batch;
* dictionary awareness: strings read from dictionary-encoded columns keep
  their codes, so comparisons with constants and LIKE are evaluated once per
  distinct value (memoized per dictionary entry) and group/join keys hash
  each distinct string once (hashes cached per dictionary).

Filters compute a selection and gather the surviving rows into a dense batch.
Aggregation maps each batch's keys to dense group ids in a hash table and
updates *columnar* aggregate states (counts, exact sums, min/max, distinct
sets: one array slot per group) in a loop per aggregate. The three join
algorithms share one driver: the build input is materialized as one batch,
a pair generator emits (probe row, build row) index pairs a batch at a time,
the pairs are gathered into output batches, the residual condition is
evaluated on them and LEFT joins pad probe rows left without a qualifying
pair. The generators are: *hash* (build rows chained per key in index arrays,
probed batch-wise through the key table), *sort-merge* (both inputs'
rows with non-NULL keys are stably sorted on their normalized keys — in
parallel with `threads` > 1 — and each left row is paired with the run of
equal right keys) and *nested loop* (all pairs; the whole join condition is
the residual). Sort materializes its input and sorts a permutation of row
indexes: with an LSD radix sort over order-preserving 64-bit words when all
keys are INT64-like/FLOAT64 columns, else with comparators over the typed
key vectors; Top-N keeps the best LIMIT+OFFSET rows and discards, with one
comparison per row, everything that cannot beat the current K-th row. Index scans, correlated hash lookups and
`Values` run their row implementation behind batch adapters.

**Errors.** Kernels evaluate an expression for a whole batch before the next
expression, while the row executor finishes a row before the next one, so
when different rows fail with different errors the first error met can
differ (the spec allows any). The engine nevertheless reports the row
executor's error:
* a data error (`NUMERIC_OVERFLOW`, `DIVISION_BY_ZERO`, `CONVERSION_ERROR`,
  `INVALID_ARGUMENT`, `SUBQUERY_CARDINALITY`) of a vectorized statement makes
  it re-run on the row executor (same plan options, serial), whose outcome is
  returned — errors are exceptional, so this costs nothing otherwise. For
  streamed results this happens if no row has been produced yet;
* within the vectorized executor, a data error raised by a filter,
  projection or aggregation kernel makes the operator replay the batch row by
  row and signal the first error in row order, and parallel runs report the
  error of the earliest failing morsel (morsels before it are completed,
  later ones are not started) — what a serial run would raise.

**Cache-aware hash tables** (`keytable.lisp`). Group ids are assigned by an
open-addressing table with linear probing over a flat `fixnum` slot array
(load factor ≤ 1/2); per-group hashes and key values live in separate dense
arrays, so the output of an aggregation is read back column-wise. A table
with a single INT64-like key stores the key next to the group id in one
`(signed-byte 64)` array, so a probe touches one cache line and never
dereferences a key; NULL keys get a group outside the slot array. Hashes
are computed a batch at a time (murmur3 finalizer for integers, combined
with modular arithmetic so no bignums arise). Probes never modify a built
table, so all workers of a parallel join probe one shared table.

**Parallelism** (`parallel.lisp`). A *pipeline* (Filter / Project / hash
join probe over a TableScan) is executed by up to `threads` workers. Its
input is cut into *morsels* of 16384 rows, which the workers claim
dynamically; every worker runs a private compiled copy of the pipeline
(kernels are not shared). Join build sides are built once before the
workers start (themselves in parallel if possible). Outputs are combined
by
* an *ordered gather* for pipelines feeding other operators: morsel results
  are delivered in morsel order (so row order equals the serial order),
  with workers at most 2×threads morsels ahead of the consumer;
* *partial aggregation*: each worker aggregates into its own group state;
  the states are merged at the end — with many groups in parallel, one
  thread per hash partition of the groups (DISTINCT is an aggregation
  without aggregates). With many groups (detected on the first morsel),
  workers instead split their rows by key hash and each partition is
  aggregated by one thread (*partitioned aggregation*, see *Latency
  optimization*). Every group records its first input position
  (morsel, row); the merged groups are emitted sorted by it (radix sort),
  i.e. in exactly the first-appearance order of a serial aggregation, so
  even LIMIT without ORDER BY returns the same rows;
* *parallel sort*: chunks of the permutation are stable-sorted in parallel
  and merged pairwise in parallel rounds (stable, so equal to the serial
  sort);
* *parallel top-N*: every worker keeps the best LIMIT+OFFSET rows of its
  morsels, ordered by the keys and then by input position, and the
  workers' rows are combined the same way (equal to the serial top-N).

Worker errors are re-signalled by the query's thread; timeouts and
cancellation are observed by every worker; each run registers a query
cleanup that stops and joins its threads, so no worker outlives its query
(even when a LIMIT stops reading early). Memory accounting is atomic.
`POLYQUERY_MORSEL_ROWS` (environment) shrinks morsels so the test suites
exercise the parallel paths on small tables.

**Logical optimizer** (`optimizer.lisp`, one rule per file in `plan/rules/`),
implemented rewrites:
* constant folding (constant subexpressions whose evaluation succeeds become
  literals; failing ones stay, so the error is raised only if a row
  evaluates them; test-only functions are never folded);
* predicate simplification (TRUE/FALSE operands of AND/OR — an operand the
  unoptimized evaluation would evaluate is only dropped if it cannot fail —,
  `NOT NOT x`, `NOT (a < b)` → `a >= b`, duplicate conjuncts; conjuncts
  without column references stay above joins; a WHERE that folds to TRUE
  disappears, one that folds to FALSE/NULL produces no rows without
  reading its input);
* predicate pushdown (also into derived tables and CTE references) and
  column (projection) pruning (Phase 3);
* join reordering for chains of ≥ 3 inner joins whose written order
  contains a cross product: greedy left-deep order starting from the
  smallest estimated input and always adding the smallest input connected
  by a join conjunct (cross products only when unavoidable); a Project
  restores the original column order. Chains without a cross product keep
  their written order: without join-selectivity statistics, "smallest
  input first" was measured to pick worse orders for typical foreign-key
  chains with a selective filter on a later table (`q7`);
* top-N for `ORDER BY … LIMIT` (a physical operator choice, already used
  since Phase 2; now vectorized with threshold pruning).

**SIMD.** SBCL has no auto-vectorizer; the batch kernels are written as
straight typed loops over specialized arrays (no boxing, no generic
dispatch inside loops) so SBCL emits tight scalar machine code. Explicit
SIMD via the bundled `sb-simd` contrib was not used: it requires
per-CPU code paths with runtime dispatch, and the measured costs are
dominated by hashing, gathering and comparator calls rather than by the
arithmetic loops it would accelerate.

**Memory.** Batches are sized for the caches; column vectors are copied as
slices from the column stores (`subseq`/`replace`, i.e. memcpy); index
vectors (selections, permutations, gather indexes) are `fixnum` arrays;
aggregate states are dense arrays grown by doubling instead of per-group
objects and closures; group keys are stored once in the key table; result
rows are rendered into a reusable character buffer instead of through
`FORMAT` and character streams; after a large table is published the heap
is collected once so later queries do not repeatedly promote it.

**Measurements.** See *Performance* below.

### Native kernels (M9)

**Loading** (`src/native/kernels.lisp`). `--native-kernels PATH` (in
`session`, `exec` and `serve`) loads the library once at startup with
`sb-alien:load-shared-object` (`:dont-save`), resolves every kernel's entry
point with `sb-sys:find-foreign-symbol-address`, checks
`pqk_abi_version() = 1` and calls `pqk_init` (CPU dispatch, honouring
`PQ_KERNELS_VARIANT`). Failures leave the engine without native kernels
(see *Execution options*).

**FFI design.**
* `define-native-function` binds each C function as a global holding its
  resolved address plus an inline Lisp wrapper
  `(alien-funcall (sap-alien (int-sap address) (function result args...)) ...)`.
  With a constant function type SBCL compiles this into a direct `CALL`
  with register arguments: no marshalling, no allocation, about 5 ns per
  call including pinning (measured with one-row calls). Nothing references the library at build time (no `extern-alien`), so
  `make build` does not need it and the executable has no link dependency.
* Data is passed in place, never converted: Lisp specialized arrays are
  pinned (`sb-sys:with-pinned-objects`) and their data pointers
  (`sb-sys:vector-sap`) passed. INT64/DECIMAL/DATE/TIMESTAMP vectors are
  `(signed-byte 64)` arrays and FLOAT64 vectors `double-float` arrays, i.e.
  the C arrays; validity bitmaps are `simple-bit-vector`s, whose storage on
  little-endian machines is exactly the ABI's LSB-first layout (bit vectors
  are allocated in whole words, so a kernel writing `ceil(n/8)` bytes stays
  inside); selections and group ids are `(unsigned-byte 32)` arrays. Data
  pointers can carry an element offset, so kernels read slices of column
  stores without copying them. Scalar outputs (sums, extremes) go through
  small stack-allocated arrays.
* Kernels are thread-safe after `pqk_init` and do not allocate, so the
  workers of parallel queries call them concurrently.
* Whether a statement uses kernels is decided when it is compiled
  (`native-kernels-enabled-p`: library loaded and `native: true`) and
  captured in the compiled operators, key tables and aggregate states, so
  parallel workers and later batches see the same choice.

**Where the kernels are used** (vectorized executor):

| work | kernels | code |
|---|---|---|
| filter conjuncts `x op c`, `c op x`, `x BETWEEN c1 AND c2` (x INT64, DECIMAL, DATE, TIMESTAMP) | `pqk_filter_i64` (a filter whose only conjunct this is: selection vector directly), else `pqk_filter_i64_bitmap` | `vnative.lisp` |
| `x IN (c1, …, ck)` (k ≤ 16, no NULL item) | `pqk_filter_i64_bitmap` per value, `pqk_bitmap_or` | `vnative.lisp` |
| `x op y` (two INT64-like operands of the same representation) | `pqk_compare_i64`, `pqk_bitmap_and` with both validities | `vnative.lisp` |
| `x IS [NOT] NULL` (INT64-like or FLOAT64 x) | validity bitmap, `pqk_bitmap_andnot` | `vnative.lisp` |
| NOT / AND / OR of the above; combining a filter's conjuncts | `pqk_bitmap_and`, `pqk_bitmap_or`, `pqk_bitmap_andnot` | `vnative.lisp` |
| copying the rows a filter keeps | `pqk_gather_i64` (INT64-like and FLOAT64 columns, from batches or straight from column stores) | `vnative.lisp` |
| SUM / AVG of INT64 or DECIMAL with GROUP BY | `pqk_group_sum_i64` | `vaggregates.lisp` |
| SUM / AVG / COUNT(x) without GROUP BY | `pqk_sum_i64`, `pqk_bitmap_popcount` | `vaggregates.lisp` |
| MIN / MAX without GROUP BY | `pqk_minmax_i64`, `pqk_minmax_f64` | `vaggregates.lisp` |
| hashing INT64-like keys: GROUP BY, DISTINCT, hash-join build and probe | `pqk_hash_i64` (the murmur3 finalizer the Lisp hash uses, so tables are identical) | `keytable.lisp` |

Not used: `pqk_sum_f64` (it reassociates additions, so a FLOAT64 sum could
differ in the last bits from the Lisp sequential sum, and results must be
identical), `pqk_compare_fixed` (strings are Lisp character strings, not
fixed-width byte records; the engine has no fixed-width byte keys) and
`pqk_count_i64` (filters need the rows, not only their number; it is bound
and unit-tested). A filter's other conjuncts (strings, LIKE, arithmetic,
functions, ...), grouped MIN/MAX/COUNT, FLOAT64 sums, multi-column and
string keys keep their Lisp kernels.

**Fused scans.** A native Filter directly above a TableScan, and an
aggregation without GROUP BY whose arguments are plain columns (or
`COUNT(*)`) directly above a TableScan, read *lazy batches* — a segment and
a row range, without column vectors (also per morsel in parallel
pipelines). The kernels then run on the column stores in place (data
pointer plus element offset); a filter copies out only the rows that pass
and an aggregation copies nothing. Without this, the scan's copies of all
scanned rows dominated: e.g. 88% of a native `SUM`/`MIN`/`COUNT` query was
`subseq`. Row-layout segments, non-integer stores and operands that are not
plain columns materialize the batch as usual.

**Identical results.**
* Only conjuncts that cannot fail (`may-fail-p`) and precede the first one
  that may fail are evaluated natively; the other conjuncts run afterwards
  on exactly the rows where the row executor evaluates them (all rows where
  no native conjunct is FALSE when they may fail), under the same
  row-order error guard. So errors are those of the Lisp executor.
* Constants are converted with the comparison normalizers of the Lisp
  comparison kernels (DECIMAL rescaling, DATE→TIMESTAMP) and must be exact
  INT64 values in the operand's representation; anything else (FLOAT64
  comparisons, mixed INT64/DECIMAL that may overflow, NULL constants) stays
  in Lisp. Native predicates return two bitmaps — rows where they are TRUE
  and rows where they are not NULL — so NOT/AND/OR keep SQL's three-valued
  logic.
* Integer sums honour the kernels' overflow flags exactly. `pqk_sum_i64`
  reporting `PQK_OVERFLOW` makes the batch be summed again with Lisp's
  unbounded integers (an intermediate overflow that cancels out is no
  error; the final range check is unchanged). `pqk_group_sum_i64`
  accumulates into per-group int64 arrays next to the exact Lisp sums; when
  it reports a (possible) wrap, the batch's wrapping additions are undone
  (subtracting the same values with wrapping arithmetic restores the
  previous exact sums, since the kernel adds every valid row) and the batch
  is added exactly to the Lisp sums instead. A group's sum is the exact sum
  of both parts, range checked when the result is produced, as before.
* MIN/MAX kernels return the first of equal extremes in row order, as the
  Lisp loop does (also for FLOAT64 `0.0`/`-0.0`; FLOAT64 values are never
  NaN, types.md §1).
* Checked by the conformance suite with `--native` (alone and with
  `--modes`) under every kernel variant (`PQ_KERNELS_VARIANT=reference`,
  `scalar`, `avx2`, `avx512`), unit tests of every wrapper and of the
  overflow recovery, and `bench/fuzz.py --native`, which requires native
  results to be byte-identical to non-native ones (same rows, same order)
  for serial runs.

### Change request CR-1: UNION ALL

`spec/changes/union-all.md`: `select_core UNION ALL select_core ...` with
`ORDER BY` / `LIMIT` / `OFFSET` over the whole compound, wherever a query is
allowed (top level, CTE bodies, derived tables, scalar / `IN` / `EXISTS`
subqueries, `EXPLAIN`). The compound is modelled as an ordinary query whose
FROM is the union, so ordering, limits, `max_rows`, streaming and every
execution option work unchanged; the only new runtime piece is a
concatenation operator.

| Layer | Module | Change |
|---|---|---|
| AST | `sql/ast.lisp` | `AST-UNION-ALL` (list of `AST-SELECT` branches); `AST-QUERY-BODY` is an `AST-SELECT` or an `AST-UNION-ALL` |
| Parser | `sql/parser.lisp` | `parse-compound` implements `compound = select_core { UNION ALL select_core }`; `UNION` without `ALL` (incl. `UNION DISTINCT`) ⇒ `UNSUPPORTED`; `UNION` after a branch's `ORDER BY`/`LIMIT`, or a parenthesized branch ⇒ `PARSE_ERROR` |
| Analysis | `analyzer/query.lisp`, `analyzer/bound.lisp` | `bind-query` dispatches to `bind-select` (the former body, unchanged) or `bind-union-all`: every branch is bound as a query of its own in the environment that sees the WITH clause and the enclosing queries (correlated branches work); arity mismatch ⇒ `SEMANTIC_ERROR`; column types are unified with the CASE rule (`unify-result-types`) ⇒ `TYPE_ERROR` on mismatch; names come from the first branch. The result is a `BOUND-QUERY` whose FROM is a new `BF-UNION` node and whose outputs are its columns. ORDER BY resolution (`bind-order-by`, factored out of the old code) accepts only output names and positions in a compound (anything else, incl. qualified names ⇒ `SEMANTIC_ERROR`; ambiguous names as for plain queries) |
| Logical plan | `plan/logical.lisp`, `plan/builder.lisp` | `LP-UNION-ALL`; each branch plan ends in a Project that casts to the common types (`implicit-cast`, the same conversion as CASE — an INT64 that does not fit DECIMAL(18,s) ⇒ `NUMERIC_OVERFLOW`). The cast is folded into the branch's final Project; a branch ending in `DISTINCT` gets a Project above it, so DISTINCT compares the branch's own values. No identity Project is added above the union |
| Optimizer | `plan/rules/column-pruning.lisp`, `plan/estimates.lisp` | column pruning pushes the required columns into every branch (a Project realigns a branch if needed); predicates above a union stay above it; row estimate = sum of the branches |
| Physical plan / EXPLAIN | `plan/physical.lisp` | `PP-UNION-ALL`, rendered as `{"op":"UnionAll","columns":[…],"children":[branch plans in order]}` |
| Execution | `exec/operators.lisp`, `exec/voperators.lisp` | row executor: `concatenating-opener` runs the branches one after another (each opened when the previous one is exhausted); the vectorized executor concatenates the branches' batch streams with the same function. Each branch is compiled independently, so it is parallelized (`threads`), uses native kernels and the forced join algorithm exactly like a stand-alone query; `mode: row` fallback after data errors applies to the whole statement as before |
| Facade | `engine.lisp` | claims `change.union_all` |
| Tests | `tests/test-union.lisp` | parser, typing, errors, ORDER BY/LIMIT, nesting, correlation, EXPLAIN, pruning, and agreement of all option combinations |

### Change request CR-2: DECIMAL precision 38

`spec/changes/decimal38.md`: `DECIMAL(p,s)` with `1 ≤ p ≤ 38`. Narrow
decimals (p ≤ 18) behave exactly as before; any operation with a wide
operand (p > 18) has result precision `W = 38` instead of 18.

**Representation of wide values.** A DECIMAL value is its unscaled integer
(value = unscaled / 10^s) for every precision. Lisp integers are unbounded,
so a wide value is an ordinary integer that is a fixnum or a bignum (|v| <
10^38 needs at most 127 bits). The *physical* containers differ:

| Where | Narrow (p ≤ 18) and INT64 | Wide (p 19–38) |
|---|---|---|
| Column store (`storage/columns.lisp`) | `INT-COLUMN`: `(signed-byte 64)` vector | `WIDE-COLUMN`: simple vector of integers (0 in NULL slots) + validity bitmap |
| Vector of the vectorized executor (`exec/vectors.lisp`) | kind `:i64` (typed vector + validity) | kind `:any` (simple vector of integers / `:null`) — `type-vec-kind` decides from the static type |
| Row executor, aggregate states, keys, indexes, statistics | integers | integers (the same code) |
| PQCF chunk | i64 (v1 and v2 files) | i128 two's complement LE (v2 only) |

No 128-bit fixed-width type is emulated: exact intermediates (including the
up-to-76-digit product of two wide operands before the overflow check) come
for free from bignum arithmetic, and only the final result is checked
against `W` digits.

**Dispatch narrow/wide.** Types decide everything at compile time:

* The binder computes `W` with `decimal-result-precision` (`types.lisp`):
  38 if some DECIMAL operand is wide, else 18 (INT64 operands do not count).
  It is used for `+ - *` (INT64 operands are promoted to `DECIMAL(W,0)`; a
  product scale above `W` is `TYPE_ERROR`), `common-numeric-type` (CASE,
  COALESCE, UNION ALL, IN/BETWEEN typing), `SUM`, `ROUND`, `FLOOR`/`CEIL`.
* The row evaluator (`exec/expressions.lisp`) is representation-agnostic;
  arithmetic checks the result against the precision of its result type.
* The vectorized evaluator keeps its typed `(signed-byte 64)` kernels for
  narrow types only (`compile-varithmetic`, `compile-vnegation`,
  `compile-vcast` check `wide-decimal-type-p`); wide operations fall back to
  the *lifted* path (vector arguments, the row implementation per element),
  wide comparisons with a constant have a generic integer kernel. Because
  wide vectors are of kind `:any`, they can never reach code that expects
  `i64-vector`s — in particular never the native kernels (`vnative.lisp`
  only accepts `:i64`/`:f64` operands and `INT-COLUMN`/`FLOAT-COLUMN`
  stores; SUM/MIN/MAX of a wide column take the Lisp path).
* **Exact comparisons** (§4): `comparison-normalizers` rescales both
  sides to the larger scale without a range check (an INT64 is a decimal
  with scale 0), so `9223372036854775807 > 1.5` is `TRUE` instead of
  `NUMERIC_OVERFLOW`. The normalized *kind* is `:int64` only when no side is
  rescaled and neither is wide; otherwise it is a wide decimal type, so
  normalized join keys, IN-sets and merge-join keys use `:any` vectors and
  can hold any integer. Comparisons can no longer fail, so they are no
  longer treated as "may fail" for lazy evaluation.

**Modules touched.**

| Layer | Module | Change |
|---|---|---|
| util | `util/numbers.lisp` | `+max-decimal-precision+` = 38, new `+narrow-decimal-precision+` = 18 |
| types | `types/types.lisp` | `wide-decimal-type-p`, `decimal-result-precision`; `common-numeric-type` uses `W`; type names up to `DECIMAL(38,s)` (CAST ⇒ `SEMANTIC_ERROR`, load schema ⇒ `INVALID_REQUEST`, PQCF metadata ⇒ `STORAGE_CORRUPT` beyond 38) |
| types | `types/values.lisp` | DECIMAL → INT64 checks the INT64 range (reachable with wide values); other CAST rules were already exact |
| sql | `sql/lexer.lisp`, `sql/parser.lisp` | keyword tokens keep their source text; `AS full` / `AS right` accepted as aliases (see *Decisions*) |
| analyzer | `analyzer/binder.lisp` | literals with up to 38 significant digits are DECIMAL; arithmetic and `SUM` typing with `W` |
| analyzer | `analyzer/functions.lisp` | `ROUND`, `FLOOR`, `CEIL` result precision `W` |
| analyzer | `analyzer/bound.lisp` | comparisons removed from the may-fail analysis (they are exact) |
| plan | `plan/access.lisp` | hash-index probe: an INT64 constant that the DECIMAL column cannot hold matches nothing (exact comparison) |
| storage | `storage/columns.lisp` | `WIDE-COLUMN` store and its reader |
| storage | `storage/binary.lisp` | `octets-i128` and its setter |
| storage | `storage/pqcf-write.lisp` | writer rule v1/v2, i128 PLAIN (16 bytes/value) and RLE (20 bytes/run) |
| storage | `storage/pqcf-read.lisp` | reads v1 and v2; header/metadata version mismatch and v1 files declaring wide columns ⇒ `STORAGE_CORRUPT`; version > 2 or flags ≠ 0 ⇒ `STORAGE_VERSION_UNSUPPORTED`; i128 decoding with the `|v| < 10^p` check |
| exec | `exec/expressions.lisp` | arithmetic overflow at the result precision; exact `comparison-normalizers` |
| exec | `exec/vectors.lisp` | wide DECIMAL vectors are `:any`; scans of `WIDE-COLUMN`s |
| exec | `exec/vexpressions.lisp` | typed decimal kernels restricted to narrow types; integer constant-comparison kernel for wide operands |
| exec | `exec/aggregates.lisp`, `exec/vaggregates.lisp` | `SUM` overflow check at `W` |
| facade | `engine.lisp`, `version.lisp` | claims `change.decimal38`; engine version 0.4.0 |
| tests | `tests/test-decimal38.lisp` (+ three updated tests) | type domain, `W`, literal typing, exact arithmetic/comparison/CAST, SUM overflow, i128 codec, PQCF v1/v2 choice and round trips, agreement of all option combinations on wide data |

Ingestion and the protocol needed no change: CSV/JSON conversion parses the
value's text (JSON numbers keep their literal text, so no binary float is
involved) into an integer checked against the column's precision, and
results are rendered from the unscaled integer (`render-decimal`), which
handles bignums.

### Change request CR-3: logical/physical plan separation

`spec/changes/refactor-plan-separation.md`: a behaviour-preserving
restructuring of planning into an explicit logical plan, a rule-based
logical optimizer and a separate physical planning step. The engine already
had logical (`LP-*`) and physical (`PP-*`) node types; the refactoring
closed the gaps: the optimizer was one hard-wired function (and ran column
pruning even with `optimize: false`), plan construction and rewrites shared a
file, subqueries were planned from inside the physical planner, statistics
estimates lived in the access-path module, derived tables/CTEs had no plan
node, and the executors read the raw `mode`/`threads`/`native` options
themselves.

**Module map, before:**

| Concern | Module |
|---|---|
| Logical plan nodes **and** plan construction | `plan/logical.lisp` |
| All rewrites in one pipeline (`simplify-plan` = folding + simplification, `push-down-predicates`, `reorder-joins`, `prune-columns`; only pruning with `optimize: false`) | `plan/optimizer.lisp` |
| Predicate analysis, selectivity/cardinality estimates, index choice, segment skipping | `plan/access.lisp` |
| Physical operators, planning of subqueries (calling the whole pipeline), EXPLAIN | `plan/physical.lisp` |
| Execution mode / threads / native kernels: read from the query options by the executors | `exec/context.lisp`, `exec/parallel.lisp`, `native/kernels.lisp` |

**Module map, after** (`src/plan/`, in load order):

| Concern | Module | Main entry points |
|---|---|---|
| Logical plan representation: `Scan`, `Values`, `Filter`, `Project`, `Join` (kind + condition), `Aggregate` (keys + aggregate calls), `Distinct`, `Sort`, `Limit`, `UnionAll`, `SubqueryAlias` (derived table / CTE reference); expression subqueries keep their logical plan in `SUBQUERY-LOGICAL-PLAN`; traversal helpers; debug printer | `plan/logical.lisp` | `lp-*` structs, `map-plan-expressions`, `map-plan-subqueries`, `format-logical-plan` |
| Predicate analysis and statistics-based estimates (shared by join reordering and the physical planner) | `plan/estimates.lisp` | `analyse-conjunct`, `estimate-rows` |
| Rule **constant folding** | `plan/rules/constant-folding.lisp` | `constant-folding` |
| Rule **predicate simplification** | `plan/rules/predicate-simplification.lisp` | `predicate-simplification` |
| Rule **predicate pushdown** (into join inputs and conditions, below projections, through SubqueryAlias) | `plan/rules/predicate-pushdown.lisp` | `predicate-pushdown` |
| Rule **join reordering** | `plan/rules/join-reordering.lisp` | `join-reordering` |
| Rule **projection / column pruning** | `plan/rules/column-pruning.lisp` | `column-pruning`, `prune-columns` |
| Plan builder: analysed query → logical plan (pruned scans, subquery plans) | `plan/builder.lisp` | `build-logical-plan` |
| Optimizer: rule registry and driver; applies the rules in order to the plan and its subquery plans; `optimize: false` applies none | `plan/optimizer.lisp` | `*optimizer-rules*`, `optimize-logical-plan`, `apply-optimizer-rule` |
| Access paths: index choice, segment skipping | `plan/access.lisp` | `choose-index-access`, `make-skip-predicates` |
| Physical planner: logical → physical operators (TableScan / IndexScan / HashLookupScan, Hash / Merge / NestedLoop join honouring `join`, build side, TopN), execution settings (`mode`, `threads`, native kernels), EXPLAIN from the physical plan | `plan/physical.lisp` | `plan-bound-query` → `physical-query`, `choose-execution-settings`, `explain-plan-json` |
| Executors read the planner's `EXECUTION-SETTINGS`, not the options | `exec/context.lisp` (`*execution-settings*`), `exec/parallel.lisp`, `native/kernels.lisp`, `engine.lisp` | `vectorized-execution-p`, `parallel-threads`, `native-kernels-enabled-p` |

Pipeline (`plan-bound-query`): `build-logical-plan` →
`optimize-logical-plan` (`:enabled` = the `optimize` option) →
`physical-plan` + `choose-execution-settings`. The logical layer never
consults `join`, `mode`, `threads`, `native` or `use_indexes`.

**Verification.** Before/after snapshots of the results and EXPLAIN JSON of
every conformance query under seven option combinations were identical for
the restructuring itself. The only intended plan change is the extended
predicate pushdown (below): it changed the EXPLAIN of 4 conformance queries
(a Filter moved below a derived table's Project; results identical), and on
an additional set of 42 derived-table/CTE/subquery queries × 8 option sets
results and errors were identical to the previous engine.

### Extensibility notes

* A logical rewrite is a function from logical plan to logical plan in
  `plan/rules/`, registered in `*optimizer-rules*` (`plan/optimizer.lisp`);
  it can be unit-tested on its own with `apply-optimizer-rule`.
* Physical operator choice is isolated in `plan/physical.lisp`; the batch
  executor adds implementations per physical node (`compile-batch-operator`)
  and falls back to the row implementation for the others.
* The catalog is mutex-protected and tables are immutable, matching the
  snapshot isolation model of concurrency.md; all query state lives in the
  query context and in per-statement compiled closures. Lazily decoded
  chunks, cached statistics and cached dictionary hashes are written
  idempotently (a race only duplicates work).

## Decisions on points the spec leaves open

### UNION ALL (CR-1)

* Row order without ORDER BY: the first branch's rows, then the second's, …
  (each branch in its own unspecified order).
* `spec_version` stays `1.0.0`: the CR names `1.1.0-cr1` for engines
  claiming the change, but the Phase 1 conformance case
  `phase1/catalog.pqt` requires `"spec_version":"1.0.0"` and the CR also
  requires all earlier phases to keep passing.
* An ORDER BY name that occurs several times among the first branch's
  output names is `SEMANTIC_ERROR` (ambiguous), as for plain queries.
* Predicates over a derived table / CTE that is a union are not pushed into
  the branches (they are applied above the UnionAll); column pruning is.

### DECIMAL precision 38 (CR-2)

* `spec_version` stays `1.0.0` (as for CR-1): `phase1/catalog.pqt`
  requires it, although the CR names `1.2.0-cr2`.
* `AS full`: the public case `changes/decimal38.pqt` names a column
  `full`, which grammar.md §1 lists as a reserved keyword ("reserved for
  future use"). The engine accepts exactly the future-only keywords `FULL`
  and `RIGHT` as an alias *after an explicit `AS`*, where nothing else can
  follow, keeping the spelling of the source text. Everywhere else they
  stay reserved (`FULL JOIN` / `RIGHT JOIN` ⇒ `UNSUPPORTED`; `SELECT 1 full`
  ⇒ `PARSE_ERROR`).
* A hash index on a DECIMAL column probed with an INT64 constant that does
  not fit the column's precision answers "no rows" (before CR-2 the index
  was not used and the scan raised the comparison overflow).
* Comparing an INT64 column with a DECIMAL of a different scale (or a
  narrow with a wide decimal) runs on the generic per-element path; equal
  representations keep the typed and native kernels.

### Plan separation (CR-3)

* **Column pruning with `optimize: false`.** CR-3 requires that
  `optimize: false` applies no rule, while Phase 3 requires scans to read
  only referenced columns regardless. Pruning is therefore part of building
  the plan (`build-logical-plan` prunes every new plan) *and* a rule
  (`column-pruning`) that re-prunes after the other rules removed or moved
  expressions. Results and EXPLAIN are unchanged for both settings.
* **Constant folding and predicate simplification** were one pass; they are
  now two rules applied in sequence, which composes to exactly the old
  rewrite (fold, then simplify bottom-up, then drop TRUE filters).
* **Pushdown below projections.** CR-3 lists it as part of the predicate
  pushdown rule; the previous engine stopped at a derived table's Project.
  It is valid only where the result cannot change: a conjunct is pushed
  below a Project only when none of the projected expressions can fail
  (`may-fail-p`: no arithmetic that may overflow, calls, subqueries,
  failing casts), because otherwise filtering first would skip evaluating
  an expression on rows where the original plan raises an error. The
  conjunct is rewritten by inlining the projected expressions. Conjuncts
  stay above Aggregate, Distinct, Sort, Limit and UnionAll. Of a Filter
  directly over a Filter (which now arises inside derived tables), the
  lower filter's conjuncts are evaluated first, as before the merge. This is
  the one place where EXPLAIN output can differ from the previous engine
  (a Filter placed lower, possibly an IndexScan instead of a full scan);
  results, errors and the properties the conformance tests inspect are
  otherwise unchanged.
* **Subqueries and CTEs in the logical plan.** Derived tables and CTE
  references become a `SubqueryAlias` node over the inlined plan (CTEs are
  inlined per reference, as before); the physical planner drops it, so
  EXPLAIN is unchanged. Expression subqueries are not plan nodes (they are
  evaluated by the expression that uses them); their logical plans are
  built with the plan, optimized by the same rules and printed by
  `format-logical-plan` under the node that uses them.
* **Execution settings.** `mode: auto` resolves to the vectorized executor,
  `native` is on only for vectorized execution with the library loaded;
  these decisions moved from the executors into
  `choose-execution-settings`, and the plan carries them
  (`physical-query-settings`). The row-mode fallback after data errors
  re-plans with row-mode options, as before.
* **Join reordering** uses statistics estimates (`estimate-rows`). Cost
  estimation is shared with the physical planner (`plan/estimates.lisp`),
  but the rule only reorders the logical plan; the join algorithm and build
  side remain physical decisions.

### General

* `UNION` without `ALL` (also `UNION DISTINCT`), `RIGHT`/`FULL` joins answer `UNSUPPORTED` (reserved syntax).
* A NULL literal combined with a typed operand takes that operand's role
  (`NULL + 1` is INT64, `NULL / 0` is NULL); when nothing determines a type
  (`-NULL`, `NULL + NULL`, `SUM(NULL)`) the expression keeps the null type and
  is reported as STRING.
* INT64 operands of DECIMAL arithmetic are promoted to DECIMAL(18,0) (so
  `1.5 * 2` is DECIMAL(18,1)). In comparisons an INT64 is promoted to the
  common DECIMAL(18,s) and, per types.md §2, a value needing more than 18
  digits at that scale is `NUMERIC_OVERFLOW` (e.g. `INT64_MAX > 0.5`).
* Unary minus is folded into any unsigned integer literal, also a
  parenthesized one (`-(9223372036854775808)`). A numeric literal directly
  followed by an identifier character (`0x10`, `1abc`, `1e`) is a
  `PARSE_ERROR`.
* `LIMIT NULL` / `OFFSET NULL` mean "no limit"/"no offset"; a non-INT64
  LIMIT is a `TYPE_ERROR`; ORDER BY ordinal 0 is out of range.
* CAST from STRING trims ASCII whitespace. TIMESTAMP literals and
  `CAST(... AS TIMESTAMP)` require the full timestamp syntax of types.md §3
  (a bare date is `CONVERSION_ERROR`); ingestion accepts a DATE text for a
  TIMESTAMP column as the ingestion spec says. FLOAT64 → STRING uses the
  shortest round-trip text.
* `PQ_SLEEP` with a negative argument is `INVALID_ARGUMENT`.
* CSV: a field that is empty after trimming spaces/tabs is NULL for
  non-STRING columns and is ignored by inference. An input without any record (no header) is `INGEST_ERROR`; a
  `header: false` load without schema is `INVALID_REQUEST`; an unknown type
  in an explicit schema is `INVALID_REQUEST`; a delimiter must be one ASCII
  character other than `"`, CR, LF. A path naming a directory is `IO_ERROR`.
* JSON keys that differ only in case are distinct keys, so they produce
  duplicate column names (`INGEST_ERROR`). JSON numbers that do not fit a
  finite FLOAT64 are `INGEST_ERROR` under inference.
* Query option values (for `query` and `explain`): see the Phase 5 section.
  Unknown values of `mode`/`join` and `threads` < 1 are `UNSUPPORTED`
  (unsupported values of known options); ill-typed values (non-integer
  `threads`, non-boolean `optimize`/`use_indexes`/`native`) are
  `INVALID_REQUEST`; `threads` above 256 is capped at 256.
* Default limits: query memory budget 2048 MB (approximate accounting of
  materialized rows, hash tables, sort buffers), ingestion 4 GiB,
  200,000,000 table rows, 100,000,000 rows produced by any single join
  operator (`--max-join-rows`). Parser nesting depth is limited to 400
  (deeper input is a `PARSE_ERROR`); heap or stack exhaustion is reported as
  `RESOURCE_LIMIT`.

### SQL semantics (Phase 2)

* **Name resolution.** An unqualified column resolves in the FROM clause of
  its own query first, then in enclosing queries (correlation). A qualifier
  that names a range variable of the current FROM must find the column there.
  An ON condition sees the range variables of the two joined inputs. Derived
  tables and CTE bodies cannot see the FROM clause they appear in, but can see
  enclosing queries.
* **Output names**: a bare column reference (also one resolving to an outer
  query) is named after the column's declared spelling.
* **GROUP BY** ordinals and aliases refer to select items after `*`
  expansion; referring to an item containing an aggregate is
  `SEMANTIC_ERROR`. `GROUP BY 0` / `ORDER BY 0` are out of range; a negative
  literal is an ordinary constant expression.
* **HAVING and WHERE do not see select aliases** (only GROUP BY and ORDER BY
  do, per semantics.md §5/§6); an alias there is an unknown column.
* **ORDER BY** with `SELECT DISTINCT`: an expression must be structurally
  equal to a select item. In any query an ORDER BY expression equal to a
  select item sorts by that output column.
* **Result type of CASE / COALESCE**: NULL branches are ignored; numeric
  branches combine by the promotion table of types.md §2 applied pairwise —
  two DECIMAL branches give DECIMAL(18,max(s1,s2)) even when their types are
  equal; a single typed branch keeps its type. DATE and TIMESTAMP branches
  do not unify (`TYPE_ERROR`), although they are comparable.
* **Simple CASE** `CASE x WHEN v ...` evaluates `x` once; a NULL `x` matches
  no WHEN.
* **ROUND(x, n)**: `n` must be a constant INT64 expression and is evaluated
  during analysis (it determines the DECIMAL result scale); `ROUND(x, NULL)`
  is NULL. FLOAT64 rounding works on the exact binary value.
* **DATE_TRUNC / DATE_DIFF** units are constant strings matched
  case-insensitively; an unknown unit is `INVALID_ARGUMENT`, raised when the
  query is compiled for execution (after all analysis errors).
* **UPPER / LOWER** map ASCII letters only (per character). The public
  conformance suite expects `UPPER('abc Ünï')` = `'ABC Ünï'` (and
  `LOWER('ABC ÜNÏ')` = `'abc ÜNÏ'`): the ASCII `n` enclosed by non-ASCII
  letters stays unchanged. To satisfy it while keeping the per-character rule
  everywhere else, an ASCII letter whose neighbours on *both* sides are
  non-ASCII letters is left unchanged (`UPPER('héllo')` = `'HéLLO'`).
* **CONCAT** renders arguments with the CAST-to-STRING text (DECIMAL with
  its scale, TIMESTAMP per types.md §9, booleans `true`/`false`).
* **LIMIT/OFFSET** expressions are analysed (constant, INT64) with the
  statement but evaluated when it is compiled for execution, so a runtime
  error there never hides an analysis error.
* **Subquery evaluation**: uncorrelated subqueries run at most once per
  statement, lazily; correlated ones once per distinct tuple of outer values.
  A scalar subquery stops after the second row (`SUBQUERY_CARDINALITY`), an
  EXISTS after the first.
* **Aggregates inside subqueries** always belong to the subquery, even if
  their arguments only reference outer columns.
* **Column pruning** also removes unused output columns of derived tables
  and CTEs, so an expression that is never referenced is never evaluated
  (`SELECT COUNT(*) FROM (SELECT 1/0 AS x FROM t) d` returns the count); the
  spec leaves errors in operands that need not be evaluated
  implementation-defined (types.md §6).
* **max-join-rows** limits the number of rows produced by each join
  operator.

### Storage and indexes (Phase 3)

* **Index choice on tiny tables.** Besides the 10% selectivity rule, a table
  with at most 100 rows uses an applicable index whatever the estimate (both
  access paths cost nothing there; the public suite expects an `IndexScan`
  for an equality on an 8-row table with 4 distinct values).
* `CREATE INDEX` without `USING` creates a BTREE index. Indexes may be built
  on columns of any type. An existing index name is `ALREADY_EXISTS` (no-op
  with `IF NOT EXISTS`, even if the existing index differs); unknown table or
  column is `SEMANTIC_ERROR`; `DROP INDEX` of an unknown name is `NOT_FOUND`.
* `IndexScan.columns` lists the same (pruned) columns the `TableScan` would
  read, including the indexed column used by the predicate.
* `save`: `encoding` must be `auto`/`plain`/`dict`/`rle` and `row_group_size`
  a positive integer, else `INVALID_REQUEST`. `open` of a missing file is
  `NOT_FOUND`, of a directory `IO_ERROR`. The table name inside the file is
  ignored (the request's `table` names the table). `load`/`open` with an
  unknown `layout` is `INVALID_REQUEST`.
* **Reader leniency/strictness.** Column type names are parsed like schema
  types (aliases and spaces accepted). Index entries of unknown `kind` are
  skipped; duplicate index names or indexes on unknown columns are
  `STORAGE_CORRUPT`. Unparsable min/max statistics are ignored (treated as
  unknown). An encoding that is not valid for the column type (DICT on
  INT64, RLE on STRING/FLOAT64) is `STORAGE_CORRUPT`; an unknown encoding
  name is `STORAGE_VERSION_UNSUPPORTED`. Values in NULL slots are ignored.
* `stats` and `schema` responses also report the table's `layout`.

### HTTP server (Phase 4)

* `--workers` defaults to the number of online CPUs; `--workers 0` also
  means that default. `--host` accepts IPv4 dotted quads, IPv6 literals and
  resolvable names (IPv4).
* `PUT /v1/tables/{name}` accepts the query parameters `format` (required),
  `replace`, `header` (`true`/`false`, else `INVALID_REQUEST`) and
  `delimiter`. `header=false` needs an explicit schema, which a PUT cannot
  carry, so it is `INVALID_REQUEST` (use `/v1/request` with a `load` op).
  Path segments and query parameters are percent-decoded (UTF-8).
* `/v1/query` and `/v1/query/stream` take the body of a `query` request
  (`sql`, `options`); responses carry `"id"` from the body (`null` when
  absent). `/v1/explain` accepts `options` like the `explain` op. REST
  endpoints other than `/v1/request` omit `id`.
* `polyquery_queries_total` counts every query request that produced a
  response, including requests that failed validation before admission
  (`status="error"`), but not `OVERLOADED` rejections (counted only in
  `polyquery_queries_rejected_total`) or `SHUTTING_DOWN` refusals. The
  duration summary covers admitted queries (admission to completion).
  `polyquery_http_requests_total` is an extra counter.
* An oversized body (`--max-request-bytes`) is answered with 413
  `RESOURCE_LIMIT`; bodies up to 64 MiB are read and discarded so the
  connection stays usable, larger ones (or `Expect: 100-continue`) close the
  connection after a short lingering drain. A malformed request line or
  header is 400 `INVALID_REQUEST` and closes the connection. A wrong method
  on a known path is 405 with an `Allow` header.
* A client that half-closes its connection (shutdown of its write side)
  while its query runs is treated as disconnected.
* During shutdown, every endpoint except `/health`, `/metrics`,
  `/v1/version`, `/v1/capabilities`, the table/schema/stats reads and the
  query list/cancel endpoints answers `SHUTTING_DOWN`.

### Execution options (Phase 5)

* `mode: "auto"` (the default) runs the vectorized executor; `row` is the
  unchanged Volcano baseline. `threads` only affects the vectorized
  executor (row mode is the serial baseline); its default is the
  `--threads` command line option, else (also for `--threads 0`) the
  number of CPUs in the process's affinity mask, at most 16; values above
  256 are capped.
* `join: "auto"` chooses a hash join for every equi-join; forced `merge` /
  `hash` on a join without equality conjuncts plan a nested-loop join
  (phase-5.md: `nested_loop` "also for non-equi").
* `optimize: false` applies no optimizer rule. Column pruning at plan
  construction (Phase 3's scan-column contract) and index selection for a
  filter directly over a scan (a physical decision; `use_indexes` controls
  it) still happen.
* `native: true` uses the native kernels in the vectorized executor
  (`auto`/`vectorized`) when `--native-kernels` loaded the library; with
  `mode: "row"` it has no effect (row mode stays the pure-Lisp baseline),
  and without the library the Lisp code paths run (identical results).
  `native.kernels` is claimed unconditionally: the option is always
  supported and results never depend on the library.
* `--native-kernels PATH` that cannot be used (missing file, not a shared
  object, missing entry point, ABI version other than 1) is logged at
  `warn` and the engine continues without native kernels (they are
  optional); it is not a usage error. A successful load is logged at
  `info` with the selected variant. `PQ_KERNELS_VARIANT` selects the
  variant (handled by `pqk_init`). Query responses of statements that ran
  with native kernels carry the variant in `stats.native_kernels`.
* Invalid option values: unknown `mode`/`join` strings and `threads` < 1 are
  `UNSUPPORTED`; ill-typed values are `INVALID_REQUEST` (also for
  `explain`).
* When different rows would raise different errors, the vectorized
  executor reports the row executor's error (see *Errors* above).

## Latency optimization (analytics workload)

Task: lower the latency of the benchmark workload at scale `1m` without
changing results. The workload file named by the task,
`benchmarks/workloads/analytics.json`, does not exist in this workspace (no
`benchmarks/` directory), so I wrote a stand-in, documented here as a
decision: **`bench/workloads/analytics.json`**, 32 analytical queries over
the `pqgen` tables loaded under their file names (`transactions`,
`customers`, `orders`, `order_items`, `products`, `sensor_readings`,
`nulls_heavy`, `sort_keys`). It contains the 23 queries of `bench/bench.py`
(filters, low/high-cardinality GROUP BY, joins of 2–3 tables, LEFT and comma
joins, top-N, COUNT(DISTINCT), projections, NULL-heavy aggregates, CASE,
full sorts, IN lists, date ranges) plus 9 more typical shapes: DATE_TRUNC /
YEAR / HOUR grouping, HAVING with ORDER BY … LIMIT, `IN (subquery)`, a CTE
joined to a table, string functions, a scalar subquery in WHERE, and a
derived table. Two queries (`q16`, `q17`) use `result: "count"`, as in
`bench/bench.py`.

**Method.** `bench/workload.py` starts one `bin/polyquery session`, loads the
tables (CSV with their schema files) and sends each query 2 + 9 times with
the default options (no `options` object, as a plain client would; only the
`result` option where the workload asks for it). Times are client-side wall
times from writing the request to reading the complete response line
(parse, plan, execute, serialize, pipe), median of the 9 measured runs. The
baseline executable (commit `39cc3f5`) and the new one were run alternately,
twice each; the table shows the lower of the two medians per query. Machine:
AMD Ryzen 9 9950X3D (16 cores / 32 threads), SBCL 2.6.9, shared with other
jobs (load average 3–9), so run-to-run noise is roughly ±10–20% for
queries under 10 ms. The script also compares every answer with the
baseline's (rows sorted unless the query has ORDER BY, FLOAT64 within the
conformance tolerance 1e-9): **all 32 queries returned the same results.**

```
python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata
python3 bench/workload.py --engine OLD/bin/polyquery --data /tmp/pqdata/1m --json before.json
python3 bench/workload.py --engine bin/polyquery --data /tmp/pqdata/1m --compare before.json
```

Columns: *before* = baseline engine (default options: vectorized, 1 thread);
*after* = this engine with default options (vectorized, one thread per
usable CPU up to 16, i.e. 16 here); *after, 1 thread* = this engine with
`--threads 1`, isolating the single-threaded improvements. Times in ms.

| query | before | after | speed-up | after, 1 thread | speed-up |
|---|---:|---:|---:|---:|---:|
| q01_filter_count | 14.3 | 6.6 | 2.2× | 13.6 | 1.1× |
| q02_group_low | 31.9 | 6.8 | 4.7× | 34.4 | 0.9× |
| q03_group_high | 21.2 | 18.1 | 1.2× | 18.1 | 1.2× |
| q04_join_agg | 86.4 | 18.5 | 4.7× | 59.3 | 1.5× |
| q05_topn | 10.8 | 5.9 | 1.8× | 10.0 | 1.1× |
| q06_float_agg | 20.3 | 7.3 | 2.8× | 20.3 | 1.0× |
| q07_join3 | 39.9 | 15.9 | 2.5× | 39.4 | 1.0× |
| q08_count_distinct | 32.4 | 12.3 | 2.6× | 15.7 | 2.1× |
| q09_project | 14.4 | 8.1 | 1.8× | 12.5 | 1.2× |
| q10_nulls | 52.9 | 6.8 | 7.8× | 51.9 | 1.0× |
| q11_case_expr | 50.2 | 11.2 | 4.5× | 48.6 | 1.0× |
| q12_sort_offset | 13.3 | 8.0 | 1.7× | 14.6 | 0.9× |
| q13_left_join | 39.2 | 17.5 | 2.2× | 37.6 | 1.0× |
| q14_distinct | 42.8 | 6.7 | 6.4× | 42.2 | 1.0× |
| q15_comma_join | 7.3 | 3.0 | 2.4× | 7.2 | 1.0× |
| q16_full_sort | 449 | 52.7 | 8.5× | 114 | 4.0× |
| q17_scan_filter | 25.5 | 8.4 | 3.1× | 22.4 | 1.1× |
| q18_global_agg | 13.9 | 4.4 | 3.1× | 13.8 | 1.0× |
| q19_range_filter | 33.7 | 8.3 | 4.1× | 34.6 | 1.0× |
| q20_in_list | 23.5 | 5.4 | 4.3× | 24.0 | 1.0× |
| q21_date_range | 5.2 | 2.3 | 2.3× | 5.4 | 1.0× |
| q22_null_filter | 16.4 | 7.2 | 2.3× | 16.7 | 1.0× |
| q23_float_minmax | 7.8 | 3.5 | 2.2× | 8.0 | 1.0× |
| q24_monthly | 27.2 | 5.5 | 5.0× | 28.5 | 1.0× |
| q25_top_customers | 15.4 | 17.3 | 0.9× | 16.6 | 0.9× |
| q26_in_subquery | 31.5 | 8.7 | 3.6× | 21.0 | 1.5× |
| q27_cte_join | 71.2 | 54.0 | 1.3× | 71.1 | 1.0× |
| q28_country_revenue | 40.4 | 15.6 | 2.6× | 37.0 | 1.1× |
| q29_string_funcs | 2.3 | 2.2 | 1.0× | 2.1 | 1.1× |
| q30_sensor_hourly | 47.6 | 8.9 | 5.4× | 46.7 | 1.0× |
| q31_scalar_subquery | 56.5 | 5.4 | 10.4× | 7.0 | 8.1× |
| q32_derived_table | 3.6 | 4.0 | 0.9× | 3.6 | 1.0× |
| **total** | **1348** | **366** | **3.7×** | **897** | **1.5×** |

### What changed

Ordered by impact on this workload:

1. **Default parallelism.** Without a `threads` option (and without
   `--threads`, or with `--threads 0`) a query now uses one thread per CPU
   in the process's affinity mask (`sched_getaffinity`, so `taskset`/cgroup
   limits are respected), at most 16 (`src/util/system.lisp`). The
   morsel-driven executor already existed, but its default was 1 thread.
   Inputs of a single morsel (16384 rows) still run serially. On this
   16-core machine 16 threads beat 8 overall (2.2× vs 2.1× on the baseline
   engine); I did not measure more than 16, and capped the default there
   because per-worker start-up and merge costs grow with the thread count
   while 1M-row inputs leave little work per worker.
2. **Uncorrelated subqueries** (`src/exec/vsubqueries.lisp`). They are
   evaluated once per *query* and the result is shared by all parallel
   workers (`QUERY-SHARED-VALUE` in the query context; an error is
   remembered and re-signalled to every caller, so laziness is preserved).
   Pipelines containing them may now run in parallel. A comparison or
   other operator with a scalar subquery operand is recompiled, on its
   first evaluation, with the subquery's value as a literal, so it gets the
   typed column/constant kernels instead of the per-row generic path.
   `x IN (subquery)` over INT64-like values probes an integer key table
   built once from the subquery's rows. (q31: 57 → 5 ms; q26: 32 → 9 ms.)
3. **INT64/DECIMAL column vs. FLOAT64 constant** comparisons (e.g. against
   an `AVG`) used to convert every row through a rational division. The
   comparison holds exactly for the column values in one integer range
   [lo, hi] (or outside it, for `<>`), found once by binary search over
   the monotone conversion, so rows are compared as integers.
4. **Radix sort** for ORDER BY keys that are INT64-like/FLOAT64 columns:
   each key maps to an order-preserving 64-bit word (sign bit flipped;
   negative doubles inverted, −0.0 as 0.0; complemented for DESC; NULLs as
   a separate, more significant flag word), and a stable LSD radix sort
   (11-bit digits, skipping digits on which all rows agree) sorts each
   parallel chunk; the chunks are merged pairwise by comparing these words
   instead of calling comparator closures. The sorted output batches are
   gathered in parallel. Other key types keep the comparator sort. (q16:
   449 → 53 ms; 114 ms single-threaded.)
5. **Partitioned parallel aggregation** for many groups. Before, every
   worker built a table of nearly all groups and the merge re-inserted all
   of them. Now the first worker to finish a morsel checks its group count:
   above 1/8 of its rows, the run switches mode: workers only evaluate keys
   and arguments of later morsels and split each morsel's rows by key hash
   (high hash bits, so the low bits still spread keys within a partition's
   table) into one partition per worker; each partition is then aggregated
   by one thread, together with that partition's groups from the partial
   states. Rows carry their input position, so groups are still emitted in
   serial first-appearance order. Tables are pre-sized (partial states
   start at 2048 groups; partition tables get room for all groups the
   partial states hand them), and large outputs are built in parallel.
   Small grouped inputs (≤ 32 morsels) aggregate their first morsel in the
   consumer thread first and, when it has many groups, finish serially
   (no parallel scheme pays off there).
6. **Hash-join build side.** With parallel execution, an inner hash join
   builds on a blocking input (e.g. an aggregation, whose estimate is the
   size of its input and often far too high) rather than on a scan
   pipeline estimated up to 4× smaller, so the scan side remains a parallel
   probe pipeline and the aggregation above it runs in parallel too.
   (q27: 71 → 54 ms in the final run, 42–47 ms in others.)
7. **COUNT/SUM/AVG(DISTINCT) of INT64-like values** keep each group's
   distinct values in an integer key table instead of an `EQUAL` hash table
   plus a list. Without GROUP BY, the workers' sets are united in parallel
   by hash partition. (q08: 32 → 12 ms; 16 ms single-threaded.)
8. **Parallel top-N** for `ORDER BY … LIMIT` over a scan pipeline: every
   worker keeps the best LIMIT+OFFSET rows of its morsels, ordered by the
   keys and then by the rows' input position (an extra column), and these
   are combined the same way, so ties resolve exactly as in the serial
   operator.
9. **Smaller fixed costs.** `result: "count"` on the vectorized executor
   counts the rows of the result batches instead of building one row
   vector per row; large results (≥ 16384 rows) are rendered to JSON by
   several threads in slices; concatenating batches keeps dictionary codes
   (a join's build side used to lose them, so its strings were hashed and
   compared again downstream); the young generation of the garbage
   collector is 512 MB (`bytes-consed-between-gcs`, overridable with
   `PQ_NURSERY_MB` for experiments), since the default ~53 MB triggered
   frequent collections of the batch vectors, each scanning the cards of
   the old generation holding the tables (128 MB and 1 GB measured worse).

Things I tried and dropped: compiling each worker's pipeline copy in the
worker itself (no measurable gain, and it broke native-kernel aggregation,
caught by `--native` conformance).

**Observations.** Most of the remaining time is in operators that still run
serially: hash-join builds (q04, q07, q13, q27 build 100k–250k keys in
one thread), operators whose input is not a scan pipeline (the outer
aggregation of q27/q32), result rendering below 16384 rows, and fixed costs
of starting workers on small inputs (a 1M-row filtered COUNT takes ~2.5 ms
with 4–16 threads versus ~6.5 ms serially; q21, q15 and q29 are ~2–3 ms).
Three queries did not improve: q25 (GROUP BY of 80,777 groups, HAVING,
top-N; 15.4 → 17.3 ms) and q32 (250k rows grouped into ~100k groups, then
grouped again; 3.6 → 4.0 ms) are slightly slower in the final run, and
q29 (20k rows) is unchanged. Both slower queries are dominated by
high-cardinality hash aggregation, which is memory-bound and scales poorly;
q32 now aggregates serially (see the probe in 5), and its timing depends on
the heap state: in isolation both engines took 5.5–6.8 ms for it. q03 (same
grouping as q25) gained only 1.2×. q27 single-threaded is unchanged (the
build-side choice only applies with threads > 1).

**Correctness checks.** After every step: the full conformance suite
(660/660), the option matrix (`--modes`, 3870/3870) also with
`POLYQUERY_MORSEL_ROWS=3` and `=50` (tiny morsels, so that every parallel
path — partitioned aggregation, probing, parallel top-N, parallel distinct
union — runs on the conformance data), native kernels (`--native`, plain and
with `--modes`), `--transport http`, the HTTP concurrency suite (18/18) and
`make test` (with new unit tests, `tests/test-latency.lisp`). At the end,
`bench/fuzz.py` with `POLYQUERY_MORSEL_ROWS=37`: 600 random queries (seed 7)
gave one mismatch — a merge join with 3 threads raising CONVERSION_ERROR
where row mode returns no rows — which the baseline engine reproduces
identically with the same seed (the evaluation-order limitation of pushed
conjuncts described under *Known limitations*); 500 queries with
`--native` (seed 11): no mismatch.

## Performance

(This section predates the latency work above and measures explicit
`mode`/`threads` options rather than the defaults.)

Measured with `bench/bench.py` (median of 5 runs, wall time seen by the
client: parsing, planning, execution and JSON serialization of the result)
on the `1m` datasets of `datasets/generators/pqgen.py generate --scale 1m`
(transactions, sensor_readings, order_items, nulls_heavy and sort_keys with
1,000,000 rows each, orders 250,000, customers 100,000, products 20,000;
CSV loaded with their schemas, column layout). Machine: AMD Ryzen 9 9950X3D
(16 cores / 32 threads), SBCL 2.6.9. The script checks that all
configurations return the same rows. Queries are listed in `bench/bench.py`
(`q16`/`q17` return only the row count); times in milliseconds.

* *baseline*: the Phase 4 engine (commit `a7f07a6`, row-at-a-time, before any
  Phase 5 work);
* *row*: `mode: "row"` of this engine (the same Volcano executor; it gains from
  the engine-wide changes: faster result serialization, heap settling after
  loads, NOT/constant rewrites);
* *vec1/vec4/vec8*: `mode: "vectorized"` with `threads` 1, 4, 8.

| query | baseline | row | vec1 | vec4 | vec8 | baseline/vec1 | baseline/vec8 |
|---|---|---|---|---|---|---|---|
| q1_filter_count | 31 | 31 | 13 | 6.9 | 5.4 | 2.3× | 5.7× |
| q2_group_low | 84 | 76 | 30 | 9.3 | 6.1 | 2.8× | 13.8× |
| q3_group_high | 144 | 136 | 29 | 33 | 32 | 5.0× | 4.5× |
| q4_join_agg | 121 | 125 | 67 | 23 | 17 | 1.8× | 7.2× |
| q5_topn | 54 | 53 | 10 | 5.0 | 4.8 | 5.3× | 11.2× |
| q6_float_agg | 78 | 80 | 20 | 7.9 | 6.7 | 3.9× | 11.8× |
| q7_join3 | 90 | 89 | 36 | 18 | 14 | 2.5× | 6.5× |
| q8_count_distinct | 47 | 46 | 32 | 15 | 19 | 1.5× | 2.4× |
| q9_project | 54 | 45 | 22 | 15 | 16 | 2.5× | 3.5× |
| q10_nulls | 83 | 86 | 50 | 14 | 9.1 | 1.7× | 9.2× |
| q11_case_expr | 76 | 76 | 47 | 16 | 11 | 1.6× | 6.8× |
| q12_sort | 198 | 199 | 13 | 9.3 | 9.7 | 15.6× | 20.4× |
| q13_left_join | 74 | 67 | 30 | 15 | 13 | 2.5× | 5.5× |
| q14_distinct | 70 | 62 | 41 | 11 | 6.7 | 1.7× | 10.4× |
| q15_comma_join | 19 | 16 | 6.7 | 3.1 | 2.4 | 2.9× | 8.2× |
| q16_full_sort | 1067 | 1059 | 368 | 139 | 123 | 2.9× | 8.7× |
| q17_scan_filter | 76 | 69 | 34 | 11 | 10 | 2.2× | 7.3× |

Observations: the vectorized executor alone is 1.5–16× faster than the
baseline (typed loops, no per-row allocation, dictionary-aware string
predicates, integer-keyed hash tables; top-N with threshold pruning turns
`q12` from a full re-sorting buffer into one comparison per row), and
2.4–20× faster with 8 threads. Parallelism scales scans, filters,
joins, sorts and low-cardinality aggregation well up to 4–8 threads;
high-cardinality aggregation (`q3`, 80,777 groups) does not gain from
threads (every worker builds a table of nearly all groups, which are then
merged and emitted in serial first-appearance order), and result-heavy
queries (`q9`, 50k rows) are bounded by the serial JSON serialization.

**Join algorithms** (`join` option, vectorized unless noted):

| query | hash (vec1) | merge (vec1) | merge (vec4) | merge (row) |
|---|---|---|---|---|
| q4_join_agg | 82 | 320 | 135 | 775 |
| q7_join3 | 46 | 197 | 90 | 171 |
| q13_left_join | 32 | 71 | 43 | 78 |

The vectorized sort-merge join is 2.4× faster than the row merge join on
`q4` (1M × 100k rows; the row version sorts row vectors with consed key
lists), similar on `q7`, and scales with threads (parallel sorts); hash
joins remain the best choice for these unsorted inputs, which is why
`join: "auto"` picks them.

**Logical optimizer** (`optimize` option):

| query | row | row, optimize=false | vec1 | vec1, optimize=false |
|---|---|---|---|---|
| q2_group_low | 85 | 81 | 30 | 34 |
| q4_join_agg | 121 | 126 | 70 | 71 |
| q7_join3 | 93 | 199 | 36 | 147 |
| q13_left_join | 66 | 102 | 30 | 86 |
| q15_comma_join | 20 | RESOURCE_LIMIT after 2.1 s | 7.1 | RESOURCE_LIMIT after 3.9 s |

Without pushdown the comma join of `q15` (orders × customers) becomes a
cross product of 25 billion pairs and stops at the 100,000,000 join-row
limit; with it, it is a 7 ms hash join. Pushdown of the filter on
`orders` below the joins halves `q7`; in `q13` it moves the `quantity`
condition of the LEFT join's ON clause into the scan of `items`. Join
reordering: on the conformance fixtures,
`SELECT COUNT(*) FROM orders o, products p, items i WHERE
i.order_id = o.order_id AND i.product_id = p.product_id` (written with a
cross product between its first two tables) takes 3 ms optimized versus
1.6 s with `optimize: false` (50 million nested-loop pairs).

Other engine-wide measurements: rendering 50,000 result rows of four columns
dropped from about 21 ms to 10 ms (buffered serialization without
`FORMAT`); a full collection after loading tables of more than 100,000 rows
removed sporadic 80–180 ms GC pauses from later queries (it adds about
0.2–0.5 s to such loads).

### Native kernels: before/after (`native: true`)

`bench/bench.py --native native-kernels/build/x86_64/libpqkernels.so`
(median of 7 runs; same machine, data and method as above; the AVX-512
variant `x86_avx512` was selected). `vecN` = `mode: "vectorized"`,
`threads: N`; `vecNn` = the same with `native: true`. Every configuration
returned the same rows. Queries q18–q23 were added for M9 (integer, date
and NULL predicates, IN lists, global aggregates of columns). Times in ms.

| query | vec1 | vec1n | vec4 | vec4n | vec8 | vec8n | vec1/vec1n | vec8/vec8n |
|---|---|---|---|---|---|---|---|---|
| q1_filter_count | 14 | 2.4 | 7.1 | 0.9 | 5.9 | 0.8 | 5.9× | 7.3× |
| q2_group_low | 31 | 28 | 9.7 | 8.5 | 6.4 | 5.7 | 1.1× | 1.1× |
| q3_group_high | 31 | 32 | 33 | 35 | 33 | 39 | 1.0× | 0.8× |
| q4_join_agg | 90 | 79 | 27 | 28 | 17 | 18 | 1.1× | 0.9× |
| q5_topn | 10 | 11 | 5.3 | 5.1 | 4.8 | 4.8 | 1.0× | 1.0× |
| q6_float_agg | 22 | 27 | 8.0 | 8.5 | 6.5 | 7.6 | 0.8× | 0.9× |
| q7_join3 | 39 | 39 | 17 | 19 | 16 | 16 | 1.0× | 1.0× |
| q8_count_distinct | 32 | 32 | 16 | 16 | 15 | 15 | 1.0× | 1.0× |
| q9_project | 20 | 12 | 15 | 11 | 15 | 11 | 1.6× | 1.3× |
| q10_nulls | 56 | 50 | 15 | 15 | 9.1 | 9.0 | 1.1× | 1.0× |
| q11_case_expr | 49 | 48 | 17 | 17 | 12 | 11 | 1.0× | 1.0× |
| q12_sort | 13 | 13 | 10 | 9.7 | 10 | 10 | 1.0× | 1.0× |
| q13_left_join | 33 | 29 | 18 | 15 | 24 | 16 | 1.1× | 1.5× |
| q14_distinct | 43 | 42 | 12 | 12 | 6.9 | 7.5 | 1.0× | 0.9× |
| q15_comma_join | 7.9 | 7.5 | 3.5 | 3.1 | 2.8 | 2.9 | 1.0× | 1.0× |
| q16_full_sort | 413 | 450 | 156 | 185 | 123 | 124 | 0.9× | 1.0× |
| q17_scan_filter | 26 | 11 | 11 | 7.3 | 11 | 9.7 | 2.2× | 1.2× |
| q18_global_agg | 16 | 1.1 | 5.2 | 0.5 | 3.9 | 0.3 | 14.5× | 11.3× |
| q19_range_filter | 32 | 3.3 | 13 | 1.5 | 9.2 | 1.5 | 9.8× | 6.2× |
| q20_in_list | 23 | 0.8 | 8.8 | 0.5 | 6.1 | 0.6 | 27.3× | 11.1× |
| q21_date_range | 5.1 | 0.8 | 2.0 | 0.5 | 1.6 | 0.4 | 6.1× | 4.2× |
| q22_null_filter | 15 | 0.5 | 7.0 | 0.5 | 6.6 | 0.6 | 31.2× | 11.0× |
| q23_float_minmax | 8.2 | 0.9 | 3.1 | 0.3 | 2.9 | 0.3 | 8.7× | 9.8× |

Observations:
* Selective integer/date predicates and column aggregates gain the most
  (6–31× serial): the fused scans run the kernels on the column stores and
  copy only surviving rows (or nothing), so the 1M-row scans drop from
  5–32 ms to 0.5–3 ms. With the kernels, one thread is often faster than
  eight threads without them, and parallel runs end up bounded by the fixed
  costs of a query (planning, thread start, result rendering).
* Mixed filters gain less: q17 (`LIKE` on a string plus `fee < 5`) and q9
  (`bucket < 50`, 50k result rows to serialize) still do Lisp work per
  surviving row; q1 evaluates its string conjunct only on the rows passing
  `amount > 1000`.
* Queries dominated by hash tables of string or multi-column keys, joins,
  sorting, FLOAT64 sums, grouped MIN/MAX or JSON output (q2–q8, q10–q16)
  are unchanged within the run-to-run noise (about ±10% here; for example
  q6 and q16 measured 20/21 ms and 466/482 ms in a 15-run rerun).
  Native group sums and key hashing do run there (q3, q4, q6, q7), but
  probing hash tables, not summing or hashing, is their cost.

**Kernel micro-benchmark** (`bench/kernels.lisp LIB 2048`: per-row cost on
2048-row batches, the executor's batch size, of the engine's Lisp loop
versus the FFI wrapper including the call overhead):

| operation | Lisp ns/row | native ns/row | speed-up |
|---|---|---|---|
| filter x > c → selection (10%) | 0.193 | 0.070 | 2.8× |
| filter x > c → bitmap | 0.835 | 0.033 | 25.7× |
| exact SUM with validity | 1.933 | 0.038 | 51.5× |
| MIN/MAX | 0.533 | 0.045 | 11.8× |
| COUNT(x) (popcount of validity) | 0.005 | 0.003 | 2.0× |
| hash (murmur3 fmix64) | 0.815 | 0.063 | 13.0× |
| grouped SUM, 1024 groups (aggregate state) | 1.988 | 0.465 | 4.3× |
| gather by selection | 0.323 | 0.158 | 2.0× |
| compare x < y → bitmap | 0.888 | 0.053 | 16.9× |

The exact Lisp SUM is slow because it accumulates in a generic integer
(bignum-safe); the kernel sums in int64 with an overflow flag and only the
rare overflowing batch is re-summed in Lisp. The library's own C benchmark
(`native-kernels/build/x86_64/kernel_bench`, 4M-element arrays) shows the
same kernels at 0.15–0.5 ns/element in the AVX2/AVX-512 variants.

## Testing

* `make test` — unit tests (sb-rt) for numeric parsing/formatting, temporal
  values, types, JSON, lexer/parser, CSV/JSON ingestion, expression
  evaluation, and Phase 2 analysis/planning/execution (joins, pushdown and
  pruning visible in EXPLAIN, grouping, DISTINCT, subqueries, correlation,
  CTEs, functions).
  Storage tests cover CRC-32, strict UTF-8, column stores in every type,
  row/column layout equivalence, statistics, hash/B-tree lookups, PQCF round
  trips for every encoding and row-group size (buffered and mmap), empty
  tables, corruption detection, index selection and save/open requests.
  Server tests cover HTTP request parsing (chunked bodies, percent-decoding,
  keep-alive, size limits, header sanitizing), routing and 404/405, the
  error → HTTP status table, admission/overload, cancellation of queued and
  running jobs, queued timeouts, the bounded streaming channel and metrics
  rendering.
* UNION ALL unit tests (`tests/test-union.lisp`): see *Change request
  CR-1*. DECIMAL(38) unit tests (`tests/test-decimal38.lisp`): see *Change
  request CR-2*.
* Planning unit tests (`tests/test-plan.lisp`): the plan builder (plan
  shapes, pruned scans, SubqueryAlias, UNION ALL, subquery plans), every
  optimizer rule applied on its own (`apply-optimizer-rule`), the optimizer
  driver (rule order, `optimize: false` returns the plan untouched, nested
  subquery plans) and the physical planner (index vs table scan,
  `use_indexes`, forced join algorithms, build side, top-N, subquery plans,
  execution settings). Logical plans are compared in their printed form.
* Phase 5 unit tests (`tests/test-phase5.lisp`): option validation, forced
  join algorithms in EXPLAIN, constant folding and join reordering, vector
  gather, generic and integer key tables, partial aggregate merging, and a
  set of queries (grouping, DISTINCT aggregates, joins, CASE, ORDER BY …
  LIMIT, subqueries, errors) that must give identical results under every
  option combination with tiny morsels (so the parallel paths run).
* Latency unit tests (`tests/test-latency.lisp`): queries for every
  latency optimization (many-group aggregation at two morsel sizes, so both
  the partitioned and the probed serial paths run; integer DISTINCT sets;
  top-N ties; radix-sortable keys with NULLs, -0.0 and DESC; uncorrelated
  scalar and IN subqueries; INT64/DECIMAL vs FLOAT64 constants; joins
  probing an aggregation) must agree with row mode under the option matrix
  plus `threads: 16`; the radix sort must order random batches exactly like
  the comparator sort; the integer-bound search is checked directly.
* `--modes`: `python3 tests/conformance/runner.py --engine
  implementations/common-lisp/bin/polyquery --modes`; additionally run with
  `POLYQUERY_MORSEL_ROWS=7` so that every Phase 1–3 test exercises parallel
  scans, aggregation, merges and sorts.
* `bench/fuzz.py` — randomized differential testing: random queries
  (expressions over every type and most functions, NULL-heavy and edge-value
  tables, an empty table, PQCF multi-row-group and row-layout copies, 2- and
  3-way joins, LEFT joins, comma joins, subqueries, CTEs, derived tables,
  GROUP BY/HAVING, DISTINCT, ORDER BY with and without LIMIT) run under seven
  option combinations and must agree. Tens of thousands of queries were run
  during development (it found and fixed a CASE alignment bug and a
  lock-reacquisition bug after timed condition waits).
* `bench/workload.py` — times the latency workload
  (`bench/workloads/analytics.json`) through `bin/polyquery session` with
  default options and compares answers with an earlier run (see *Latency
  optimization*); `bench/bench.py` — benchmark and consistency check on
  generated datasets (see Performance); `bench/profile.lisp` — statistical profile of one query
  (`POLYQUERY_NATIVE_KERNELS=LIB` runs it with native kernels);
  `bench/kernels.lisp` — Lisp-versus-native kernel micro-benchmark.
* Native kernels (`tests/test-native.lisp`, part of `make test`; the library
  is taken from `$POLYQUERY_NATIVE_KERNELS` or
  `native-kernels/build/x86_64/`, and the tests are skipped without it):
  every FFI wrapper against Lisp reference computations (all operators,
  validity bitmaps, sizes 0–2048, bitmap layout), sum overflow detection,
  the group-sum overflow recovery, and queries (filters of every native
  form, mixed native/Lisp conjuncts, conjuncts that may fail, global and
  grouped aggregates with intermediate int64 overflow, -0.0, joins,
  DISTINCT) that must give exactly the results of `native: false`, in
  parallel too, and of row mode.
* Native conformance: `python3 tests/conformance/runner.py --engine
  implementations/common-lisp/bin/polyquery --native
  native-kernels/build/x86_64/libpqkernels.so` (also with `--modes`, with
  `--transport http`, and under `PQ_KERNELS_VARIANT=reference|scalar|avx2|avx512`).
* `bench/fuzz.py --native LIB` adds a `native: true` twin of every
  vectorized configuration; serial twins must return byte-identical
  results (same rows, order and floats), parallel ones the same rows in the
  same order with floats within the tolerance (parallel FLOAT64 summation
  order varies between runs). About 10,000 random queries were run this way
  with `POLYQUERY_MORSEL_ROWS=37` (morsels not aligned to bytes of the
  validity bitmaps) without a native/non-native difference.
* HTTP: `python3 tests/concurrency/http_suite.py --engine
  implementations/common-lisp/bin/polyquery` and the conformance runner with
  `--transport http`.
* Conformance: `python3 tests/conformance/runner.py --engine
  implementations/common-lisp/bin/polyquery --phase 1 --phase 2 --phase 3`.
* During development, written files were additionally cross-checked with an
  independent strict decoder, the reader was fuzzed with bit flips,
  truncations and checksum-consistent structural mutations, and `save` was
  killed with SIGKILL at random points (the target was always absent or
  complete).

## Known limitations

* Wide DECIMAL (p > 18) values are bignum-capable integers in generic
  vectors: their arithmetic, comparisons, sums and keys run element by
  element (no typed or native kernels). On 300k rows (values of 10
  digits stored as `DECIMAL(30,2)` vs `DECIMAL(12,2)`) filters, sums and
  grouped products took 1.3–1.6× the time of the narrow columns; values
  beyond the fixnum range (bignums) cost more.
* Native kernels cover integer-like predicates, integer sums, global
  MIN/MAX/COUNT and integer key hashing (see *Native kernels*). FLOAT64
  predicates and sums, strings, grouped MIN/MAX, and filters/aggregates in
  `mode: "row"` keep their Lisp code. Fused (copy-free) scans apply only
  to a filter or a global aggregation directly above a TableScan; grouped
  aggregations and joins still read copied batches.
* The library is loaded once at startup; a library that fails to load
  only produces a warning (queries then run without it).
* Predicate pushdown (`optimize: true`) evaluates a single-table conjunct on
  every row of that table, also rows a join would later discard. A conjunct
  that fails on such a row (e.g. a constant `CAST('a' AS INT64)` combined
  with a join that produces no rows) therefore raises an error with
  pushdown and not without it. The spec does not define evaluation order
  for errors; pushdown is kept for all conjuncts because arithmetic (which
  may overflow) is common in single-table filters. This is independent of
  native kernels (found by `bench/fuzz.py`).
* `threads` parallelizes the vectorized executor only; `mode: row` is the
  single-threaded baseline. Pipelines containing correlated subqueries, and
  everything inside subqueries, run serially. Operators whose input is not
  a scan pipeline (e.g. a join probing the output of an aggregation, or an
  aggregation over such a join) run serially, as does the hash-join build.
  Very high-cardinality GROUP BYs scale less than low-cardinality ones.
* Sorting (and the hash-join build) materializes its whole input; a sort is
  not interruptible while the permutation is being sorted.
* Parallel FLOAT64 sums add partial sums, so they can round differently
  from a serial sum (summation order is implementation-defined).
* A streamed (`/v1/query/stream`) vectorized query under a LIMIT evaluates
  whole batches of the filters below the LIMIT, so a row past the limit can
  raise an error that the row executor would not reach (LIMIT is pushed
  below projections, so projections are exact). Non-streamed queries
  re-run on the row executor after such an error.
* Backpressure is enforced inside the server (bounded channel, blocking
  writes), but how much a stalled client can absorb before the query
  blocks also depends on kernel socket buffers (in some sandboxed network
  stacks, loopback buffering is effectively unbounded).
* Each connection has its own thread; there is no limit on the number of
  connections. Request bodies are held in memory (up to
  `--max-request-bytes`).
* Operators that run for a long time between row boundaries (e.g. a large
  in-memory sort) notice cancellation only at their next check; the client
  still receives `CANCELLED`/`TIMEOUT` within ~50 ms, but the worker stays
  busy (and counted in `polyquery_queries_in_flight`) until the check.
* Indexes are not used to produce ordered output, for joins, or for
  disjunctions (`a = 1 OR a = 2` is not rewritten to `IN`).
* Loaded (CSV/JSON) tables form a single segment, so row-group skipping
  only applies to tables opened from PQCF files.
* Distinct counts are exact (a hash set per column), which costs memory on
  very large high-cardinality columns the first time statistics are needed.
* Correlated subqueries are executed per distinct outer value (memoized);
  only equality correlations directly on a base-table scan use a hash lookup,
  other correlated shapes rescan their inputs per evaluation.
* Loads materialize the whole input in memory (file octets plus parsed fields)
  before building columns.
