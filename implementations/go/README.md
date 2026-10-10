# PolyQuery — Go engine

An analytical database engine implementing the PolyQuery specification
(`spec/`), currently **Phase 5**: the complete SQL v1 query language over
row- or column-oriented in-memory tables, persistent PQCF v1 columnar files,
statistics, hash and ordered indexes and a planner with predicate pushdown,
row-group skipping, column pruning and index selection — served over
HTTP/1.1 with streamed results, admission control, timeouts, cancellation,
metrics, structured logs and graceful shutdown — executed either
row-at-a-time (the Volcano baseline) or vectorized over column batches, with
morsel-driven intra-query parallelism, hash / sort-merge / nested-loop joins,
a switchable logical optimizer and explicit SIMD kernels.

## Build prerequisites

* Go 1.27 (tested with `go1.27.1`), standard library only — `go.mod` has no
  requirements; builds work offline (`GOTOOLCHAIN=local`, `GOPROXY=off`).
  On amd64 the Makefile sets `GOEXPERIMENT=simd` to compile the explicit
  SIMD kernels, which use the standard library's experimental
  `simd/archsimd` package; without it (plain `go build`, other
  architectures) portable loops are used and results are identical.
* `make`.

```bash
make build      # → build/polyquery
make test       # unit tests (go test ./...)
make lint       # go vet + gofmt check
make fmt        # gofmt -w
make clean
bin/polyquery session --data-dir DIR    # launcher; builds on first use if needed
bin/polyquery serve --port 8080 --data-dir DIR --workers 8 --queue-depth 64
```

## Libraries

None. Only the Go standard library is used (`ENGINE.json` lists no libraries).

## Capabilities

`phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`, `sql.basic`,
`test.functions`, `phase2`, `sql.groupby`, `sql.join`, `sql.functions`,
`sql.subquery`, `sql.cte`, `sql.correlated_subquery`, `phase3`,
`storage.pqcf`, `storage.mmap`, `index.hash`, `index.btree`, `phase4`,
`http.streaming`, `phase5`, `exec.row`, `exec.vectorized`, `exec.parallel`,
`join.hash`, `join.merge`, `join.nested_loop`.

`native.kernels` is not claimed: native kernels are optional
(native-kernels.md) and this engine uses Go code only (cgo would be needed
to load `libpqkernels`). `--native-kernels PATH` is accepted and ignored,
and `native: true` is accepted and has no effect.

`storage.mmap` uses real memory mapping (`syscall.Mmap`, standard library)
on all Unix platforms; on other platforms `open` falls back to reading the
file into memory (chunks are still decoded lazily).

## Design overview

A statement flows through distinct, inspectable stages, one package each:

```
SQL text ─lexer→ tokens ─parser→ AST ─analyzer→ logical plan ─optimizer→ logical plan
        ─physical→ physical plan ─exec→ operator tree → rows
```

| Package | Responsibility |
|---|---|
| `cmd/polyquery` | CLI: modes `version`, `capabilities`, `session`, `exec`, `serve`; option parsing, JSON logs on stderr, SIGTERM/SIGINT handling |
| `internal/server` | HTTP API (protocol.md §7): router, admission control (workers + bounded FIFO queue), query registry (listing, cancellation, duplicate ids), timeouts, NDJSON streaming with backpressure, Prometheus metrics, completion logs, graceful shutdown |
| `internal/protocol` | JSON request decoding/validation, context-aware op dispatch (incl. `explain`, `save`, `open`, `stats`), single-line JSON response writer, NDJSON stream lines, session loop and exec mode |
| `internal/engine` | Facade owning config + catalog: path safety, file loading with limits, the query pipeline (statements run through a `Cursor` so results can be consumed incrementally), `EXPLAIN`, `CREATE/DROP INDEX`, `save`/`open`/`stats`, `max_rows`, timeouts |
| `internal/sql/lexer` | Tokens with 1-based line/column positions; comments, quoted identifiers, reserved keywords |
| `internal/sql/ast`, `internal/sql/parser` | Recursive-descent parser for the full v1 grammar producing an AST; `PARSE_ERROR` carries `line`/`column` |
| `internal/analyzer` | Semantic validation: scopes and range variables, CTE environments, name resolution (incl. outer scopes for correlation), typing with implicit promotions, function signatures, aggregate/grouping rules, ORDER BY resolution; produces the logical plan |
| `internal/plan` | Bound typed expressions and logical plan nodes (`Scan`, `Values`, `Filter`, `Project`, `Aggregate`, `Join`, `Sort`, `Limit`, `Distinct`); every produced column has a statement-unique `ColumnID` |
| `internal/optimizer` | Logical rewrites (all disabled by `optimize: false`): constant folding and boolean simplification; predicate pushdown through joins (WHERE/ON conjuncts on one input move below the join, spanning conjuncts become join conditions, so comma joins become inner joins) and through projections (derived tables, CTEs), sorts and DISTINCT, so that predicates end up directly above table scans; greedy reordering of inner-join chains |
| `internal/physical` | Physical planning: access paths (index selection from statistics, row-group skipping filters), join algorithm (hash join with the build side by estimated cardinality, sort-merge join, nested loop), hash aggregation, hash distinct, top-N sort; column pruning (scans read only referenced columns); correlated-subquery helpers; EXPLAIN JSON |
| `internal/exec` | Execution in two models over the same physical plan: Volcano row operators (`operators.go`, `join.go`, `merge.go`, `aggregate.go`; expressions compiled to closures against the input row layout) and vectorized batch operators (`vector.go`, `vexpr.go`, `vops.go`, `vagg.go`, `vjoin.go`, `vsort.go`, `simd_*.go`); morsel-driven parallelism (`parallel.go`); all scalar functions, LIKE, CASE, BETWEEN, IN; subquery evaluation; cancellation checks; approximate memory accounting; `--max-join-rows` |
| `internal/storage` | Immutable tables split into row groups, each either column-oriented (typed vectors with validity bitmaps, STRING columns optionally dictionary-encoded, chunks optionally decoded lazily) or row-oriented (tuples); per-group min/max/null statistics; lazily computed table statistics |
| `internal/index` | Single-column HASH (hash map value → row IDs) and BTREE (sorted permutation with binary search) indexes |
| `internal/catalog` | Copy-on-write catalog of tables and globally named indexes: every mutation publishes a new immutable snapshot atomically |
| `internal/pqcf` | PQCF v1 reader (full validation, PLAIN/DICT/RLE decoding, CRC-32, memory mapping with lazy chunk decoding) and atomic writer (encoding choice, statistics, temp file + fsync + rename + directory fsync) |
| `internal/ingest` | CSV (RFC 4180 + spec rules) and strict JSON/JSONL parsers, schema inference and explicit-schema conversion |
| `internal/types` | Type system: canonical names/aliases, values, exact DECIMAL arithmetic (int64 unscaled + 128-bit products, big-int sums), proleptic Gregorian DATE/TIMESTAMP, CAST matrix, text parsing/formatting, ordering |
| `internal/errs` | Structured errors with stable codes and optional details |

### Column IDs instead of positions

Expressions reference columns by `ColumnID`, not by row position. Plan
rewrites (pushdown, pruning, redirecting grouped columns) therefore never
renumber anything; the executor resolves IDs to row positions once, when it
compiles an expression against its input's layout. A column that is not in
the layout is an outer reference of a correlated subquery and reads the
current parameter value.

### Aggregation

Following semantics.md §5 literally, after binding the select list, HAVING
and ORDER BY of an aggregated query, every subexpression structurally equal
(canonical string incl. column IDs) to a GROUP BY key is replaced by a
reference to the key column and every aggregate call by a reference to its
aggregate column; any input column reference left over is a grouping
violation (`SEMANTIC_ERROR`). Correlated subqueries evaluated after grouping
get their references to grouped columns redirected to the key columns.

### Subqueries and CTEs

* Uncorrelated scalar/IN/EXISTS subqueries are evaluated once per statement
  (lazily) and cached; IN builds a hash set (NULL-aware three-valued logic).
* Correlated subqueries are evaluated per distinct combination of outer
  values (memoized). Inside their plans, a filter `inner = outer` over an
  uncorrelated input becomes a `ParamLookup` (input hashed once per query),
  and other uncorrelated subtrees are `Materialize`d once, so typical
  correlated EXISTS/COUNT/MAX patterns run in near-linear time.
* CTEs are inlined: each reference re-analyzes the definition in its
  definition environment (fresh column IDs, so a CTE can be self-joined).
  Every CTE is also validated once even when unreferenced.

### EXPLAIN

`EXPLAIN <query>` returns one STRING column `plan` with the JSON plan; the
`explain` op returns the same tree as an object. Nodes: `TableScan` (`table`,
`columns` actually read), `Values`, `Filter`, `Project`, `Aggregate`,
`HashJoin`/`MergeJoin`/`NestedLoopJoin` (`join_type`), `Sort` (`top_n` when combined with a
literal LIMIT), `Limit`, `Distinct`, `ParamLookup`, `Materialize`, and
`Subquery` (children of the operator that evaluates them).

### Value representation

A `types.Value` is `{Null, I int64, F float64, S string}`; the static type of
the producing expression decides which field is meaningful (INT64, BOOLEAN,
DECIMAL unscaled, DATE days and TIMESTAMP microseconds share `I`). Tables store
typed vectors per column. Hash keys (grouping, DISTINCT, joins, IN sets) use a
canonical byte encoding in which equal values per types.md §7 encode equally
(DECIMALs normalized by scale, `-0.0 = 0.0`, NULLs equal).

### Storage (Phase 3)

* **Layouts.** `load`/`open` accept `{"layout": "row"|"column"}` (default
  `column`) and `{"dictionary": true}`. Tables are split into row groups of
  65,536 rows (PQCF tables keep the file's row groups). In the column layout
  each group holds one vector per column (`[]int64` for BOOLEAN, INT64,
  DECIMAL unscaled, DATE, TIMESTAMP; `[]float64`; `[]string` or dictionary
  + `[]uint32` codes) plus an LSB-first validity bitmap (absent when the
  chunk has no NULLs). STRING chunks are dictionary-encoded automatically
  when they have fewer distinct values than half their rows, or always with
  `dictionary: true`. The row layout stores `[]types.Row` tuples. Scans,
  index scans, statistics and `save` work on both through one row-group
  reader, so results are identical by construction (and the conformance
  suite was also run with row layout, forced dictionaries and tiny row
  groups as defaults).
* **PQCF writing** follows the spec byte-exactly: chunks start at 8-byte
  aligned offsets with zero padding, NULL slots are zero / empty / code 0,
  validity bitmaps only when `null_count > 0`, `min`/`max` for every type
  except STRING (optional per spec, omitted to avoid cross-language string
  ordering issues). `encoding: auto` uses RLE when the run count is below
  n/4 (BOOLEAN, INT64, DECIMAL, DATE, TIMESTAMP) and DICT when the distinct
  count is below n/2 (STRING); forced encodings fall back to PLAIN for types
  they do not apply to. `row_group_size` defaults to 65,536.
* **Atomic saves**: the file is written to `.<target>.tmp-<random>` in the
  target directory, fsynced, renamed over the target and the directory is
  fsynced. Stale temporary files of earlier crashed saves to the same target
  are removed by the next save (never those of saves in progress).
* **PQCF reading** validates header (magic, version 0 ⇒ `STORAGE_CORRUPT`,
  version > 1 or flags ≠ 0 ⇒ `STORAGE_VERSION_UNSUPPORTED`), footer,
  metadata CRC, UTF-8 and every structural rule of §2; unknown encodings ⇒
  `STORAGE_VERSION_UNSUPPORTED`. Bytes between chunks must be zero (the spec
  only allows zero padding; this makes bit flips there detectable, too).
  Chunk decoding checks the CRC, bitmap NULL count, exact chunk size and all
  value rules of §3.4. Without `mmap` the whole file is verified and
  decoded at `open`; with `mmap: true` (column layout) the file is
  memory-mapped and each chunk is verified and decoded on first access (a
  query touching a damaged chunk fails with `STORAGE_CORRUPT`). Decoded data
  never aliases the mapping, which is unmapped once the table is no longer
  referenced. Malformed or missing `min`/`max` metadata is treated as
  unknown (it only enables skipping).
* **Statistics**: per row group (null count, min, max — computed for loaded
  data, taken from file metadata for lazily decoded PQCF chunks) and per
  table column (null count, min, max, distinct count), computed on first use
  and cached. Distinct counts are exact up to 131,072 distinct values and
  HyperLogLog estimates (≈0.8% error) beyond, bounding memory on big tables.

### Indexes and planning

* `CREATE INDEX` builds the index immediately; HASH maps values (DECIMAL
  unscaled at the column scale, `-0.0` normalized) to ascending row IDs;
  BTREE is a sorted permutation of the non-NULL rows (ties by row ID)
  answering equality and range lookups by binary search. NULLs are never
  indexed. Indexes are stored in the catalog with the exact table version
  they were built for; they are listed in PQCF metadata on `save` and rebuilt
  on `open`.
* **Search arguments**: WHERE conjuncts `col op const`, `const op col`,
  `col BETWEEN const AND const` and `col IN (consts)` (also through the
  implicit INT64→DECIMAL and DATE→TIMESTAMP promotions) are translated into
  the column's own domain (e.g. `int_col > 2.5` ⇒ `int_col > 2`,
  `int_col = 2.5` ⇒ no rows, `date_col < TIMESTAMP '… 12:00'` ⇒
  `date_col <= …`). Constants are evaluated at planning time; a constant
  that fails to evaluate just disables the optimization.
* **Row-group skipping**: a table scan below a filter skips row groups whose
  min/max (or all-NULL) statistics exclude any search argument.
* **Index selection** (indexes-and-planning.md §3): candidates are a single
  `=`/`IN` conjunct (HASH or BTREE) or all range conjuncts on one column
  combined into one interval (BTREE). Selectivity: points/distinct for
  equality, linear interpolation between min and max for numeric/temporal
  ranges, 1/3 otherwise. The most selective candidate is used if its
  selectivity is ≤ 10%, or — for point lookups — if it is expected to return
  at most 5 rows (only relevant for tables under 50 rows, where one key is
  already more than 10% of the table but a probe is still cheaper than a
  scan; the conformance suite expects an index scan for an equality on an
  8-row table). The conjuncts answered by the lookup are dropped, the rest
  stay in a filter above the `IndexScan`. `use_indexes: false` disables
  index selection.
* **Join build side**: estimated cardinalities use the same statistics
  (product of conjunct selectivities, 1/3 for non-sargable conjuncts).
* **EXPLAIN**: `TableScan` (`table`, `columns`, `layout`, `row_groups`,
  `row_group_filters`) and `IndexScan` (`table`, `index`, `kind`, `columns`
  = all columns the query reads from the table, including the indexed one,
  `condition`, `lookup`).

### HTTP server and concurrency (Phase 4)

* **Snapshot isolation** comes from the copy-on-write catalog: a query takes
  the current immutable catalog snapshot when it starts executing (after
  admission) and plans and runs against exactly those table and index
  versions; tables are immutable, so concurrent replaces/drops never affect
  running queries and readers never lock each other. Loads parse outside the
  mutation lock and publish with one atomic pointer swap.
* **Admission control**: `--workers` slots and a FIFO queue of
  `--queue-depth` waiters (`internal/server/admission.go`). A freed slot is
  handed directly to the oldest waiter; a query arriving with all slots busy
  and a full queue is rejected immediately with `OVERLOADED` (503).
  Non-query endpoints never wait for a worker.
* **Query lifecycle**: every query (`/v1/query`, `/v1/query/stream`, or
  `op: "query"` through `/v1/request`) is registered under its
  `options.query_id` (or a server-assigned `q-N`) before it queues; an id
  that is still queued/running is `409 ALREADY_EXISTS`. Its context is
  cancelled by `DELETE /v1/queries/{id}`, client disconnect, or shutdown
  after the grace period, and carries the effective timeout measured from
  arrival (queueing counts). Operators check the context every 4,096 rows
  (also every 4,096 comparisons inside sorts) and `PQ_SLEEP` waits on it, so
  `CANCELLED`/`TIMEOUT` are reported within milliseconds. A query is removed
  from the registry and its slot is released *before* its final response
  bytes are written, so a client that has its answer never sees the query
  in `/v1/queries` any more.
* **Streaming**: execution runs in its own goroutine and hands batches of up
  to 1,000 rows (or whatever accumulated within 100 ms) to the writer over a
  channel of capacity 4, so at most ~6 batches exist ahead of the client;
  each line is flushed as a chunk. The header is sent together with the
  first batch, so an error before any row exists (including runtime errors
  inside a sort) is a normal error response with its HTTP status; later
  errors end the stream with an `error` line and no `end` line. A failed
  write (client gone) cancels the query.
* **Metrics** (`/metrics`, text format 0.0.4): all required families plus
  HELP/TYPE lines. `polyquery_queries_total` counts every query request by
  final status (rejections included as `error`); the duration summary covers
  all of them except `OVERLOADED` rejections (time from arrival to end).
* **Logs** are JSON lines on stderr (`ts` RFC 3339 UTC, `level`, `msg`, …)
  via `log/slog`; each query emits `query finished` with `query_id`,
  `status`, `code` (on error), `duration_ms` and `rows`. SQL text and data
  are never logged at `info`. `net/http` internal errors are routed through
  the same JSON logger.
* **Shutdown** (SIGTERM/SIGINT): the listener is closed (new connections are
  refused), requests on existing keep-alive connections get `503
  SHUTTING_DOWN` (`/health` → `503 {"status":"shutting_down"}`; metrics,
  `/v1/queries` and cancellation keep working), and the server waits until
  no connection has a request in progress (tracked with `ConnState`, so
  streamed responses are completely written) or `--shutdown-grace-ms`
  passes. Then remaining queries are cancelled (`CANCELLED`), the handlers
  get up to 2 s to answer, all connections are closed and the process exits 0.
* **HTTP details**: unknown paths are `404 NOT_FOUND`, a known path with the
  wrong method `405 INVALID_REQUEST`; bodies above `--max-request-bytes` are
  `413 RESOURCE_LIMIT` (the rest of the body is drained, up to 256 MiB, so
  the client reliably receives the response). `PUT /v1/tables/{name}`
  accepts `format`, `replace`, `header` and, as extensions, `delimiter` and
  `schema` (a URL-encoded JSON schema array as in the `load` op, needed for
  `header=false`). Path segments are URL-decoded. Responses of the protocol
  endpoints are the protocol objects (with `"id": null` where no request id
  exists).

### Execution modes and optimization (Phase 5)

Both execution models run the same physical plan; the query options select
how (`mode`, `threads`, `join`, `optimize`, see *Decisions*).

**Row mode** (`mode: "row"`) is the original Volcano engine and the
permanent baseline: every operator returns one `types.Row` per `Next()`,
expressions are closures over rows.

**Vectorized mode** (`mode: "vectorized"`, also `auto`) exchanges
batches of up to 2,048 rows (`exec.Batch`): one typed vector per column
(`[]int64` for BOOLEAN/INT64/DECIMAL/DATE/TIMESTAMP, `[]float64`,
`[]string` or dictionary + codes) with a `[]bool` NULL array, plus an
optional selection vector of active rows.

* *Scans* slice the column chunks of a row group without copying (validity
  bitmaps are expanded per batch); dictionary-encoded STRING chunks stay
  encoded; row-layout groups are gathered into reusable vectors.
* *Expressions* compile to vector kernels (`vexpr.go`): comparisons and
  arithmetic over typed slices in dense, branch-free loops (computed for all
  physical rows; failures — overflow, division by zero — only count for
  needed, non-NULL rows), three-valued AND/OR evaluating the right operand
  only for rows the left one does not decide (like row-mode short-circuit
  evaluation), constants as pre-filled vectors, and dictionary-aware
  evaluation: `cat = 'x'`, `UPPER(cat)`, `cat LIKE 'a%'`, … are computed
  once per dictionary entry and mapped through the codes (string results
  stay dictionary-encoded). Every other node (functions, CAST, LIKE,
  BETWEEN, IN lists) is applied element-wise over vectorized operands; CASE,
  COALESCE, non-constant IN lists, subqueries and outer references are
  evaluated row by row.
* *Exact semantics*: a batch whose vectorized evaluation fails is
  re-evaluated row by row with the row-mode evaluator of the same
  expressions, which yields exactly the row-mode results and the error of
  the first failing row; filters and projections return the rows before
  that row and report the error on the next call, like row mode would.
* *Filters* produce selection vectors (branch-free); *projections* reuse
  input vectors for column references.
* *Hash aggregation* (`vagg.go`) resolves the group of every row of a batch
  first — specialized maps for a single INT-class or STRING key, a
  per-dictionary code→group cache, canonical byte keys otherwise — then
  updates struct-of-arrays aggregate states (exact 64-bit-with-overflow-
  spill sums, counts, min/max, …) in tight loops. DISTINCT is a grouping
  without aggregates. Groups keep their first-appearance order.
* *Hash join* (`vjoin.go`): see Joins.
* *Sort* (`vsort.go`): input materialized column-wise; a permutation of
  `(normalized first key, row)` pairs is sorted — INT-class, FLOAT64 and
  8-byte string prefixes map to order-preserving `uint64`s, so most
  comparisons touch no other memory — and ties fall back to a typed
  comparator over all keys and the input position (so the order equals
  the row-mode stable sort). `ORDER BY … LIMIT n` keeps a bounded heap and
  rejects most rows with one comparison against its root, without copying.
* Operators without a batch implementation (nested-loop and merge joins,
  index scans, VALUES, correlated-subquery helpers) run row-at-a-time over
  adapters; `result: "count"` counts whole batches.

**Parallelism** (`threads: N`, `parallel.go`) is morsel-driven: a
*pipeline* — a table scan with the filters, projections and hash-join
probes above it — is instantiated once per worker goroutine; workers take
morsels (ranges of 16,384 rows of non-skipped row groups) in table order
from a shared counter. Hash-join build sides are built once (lazily, by the
first worker that needs them) and probed read-only by all workers.

* Parallel *scans* return each morsel's output in morsel order (a bounded
  window of morsels in flight limits buffering), so rows — and errors —
  come out exactly as in a serial scan.
* Parallel *aggregation* folds morsels into per-worker partial tables that
  record each group's first position; partial tables are merged — in
  parallel, partitioned by key hash, for many groups — and output in
  first-appearance order. If several morsels fail, the error of the first
  failing morsel (table order) is reported.
* Parallel *top-N* keeps a heap per worker (ties broken by input
  position) and merges them; full *sorts* sort runs in parallel and merge
  them pairwise in parallel.
* Row mode parallelizes the same pipelines with row operators.

Results are identical for every option combination (FLOAT64 sums aside,
see *Known limitations*).

**Joins**: `join: "hash"` (and `auto` for equi-joins) builds on the smaller
estimated input for INNER joins (the right input for LEFT joins). The
vectorized build side is a column-wise copy of the build rows plus three
flat arrays — bucket heads, a `next` link per row and the keys (int64 for
INT-class keys of identical representation on both sides, canonical byte
strings otherwise) — instead of a map of slices: compact, cache-friendly and
shareable by parallel probes; chains keep insertion order. Probing gathers
(probe row, build row) pairs into output batches, evaluates residual
conditions vectorized, and emits NULL-extended rows for unmatched LEFT
rows. `join: "merge"` sorts both inputs by their keys (NULL keys never
match; unmatched LEFT rows are emitted) and merges equal-key runs; `join:
"nested_loop"` materializes the right input. EXPLAIN shows `HashJoin`,
`MergeJoin` or `NestedLoopJoin`.

**Logical optimizer** (`optimize: true`, default):

* *constant folding* — maximal constant subexpressions are evaluated once
  during planning (`100 * 5 + 0` ⇒ `500`); a constant whose evaluation fails
  stays unfolded, so `1/0` errors only if evaluated;
* *predicate simplification* — `TRUE AND x` ⇒ `x`, `FALSE AND x` ⇒ FALSE,
  `x OR FALSE` ⇒ `x`, …, filters reduced to TRUE disappear (`x AND FALSE` is
  kept: x is evaluated first and may fail);
* *predicate pushdown* (Phase 3) and *join reordering*: chains of inner
  joins are flattened and rebuilt left-deep, starting with the input of
  smallest estimated cardinality and repeatedly adding the smallest input
  connected by a join conjunct (cross products only for disconnected join
  graphs); a projection restores the column order.
* Physical planning adds *projection pushdown* (scans read only needed
  columns) and *top-N* for `ORDER BY … LIMIT`.

**SIMD**: Go's standard library has no stable SIMD API, so the loops are
written to be SIMD-friendly (dense, branch-free, over contiguous typed
slices) and, on amd64 with AVX2, the hottest kernels — comparisons of
INT-class/FLOAT64 vectors with constants or vectors, and FLOAT64
arithmetic — use explicit 256-bit SIMD from the experimental
`simd/archsimd` package (`simd_amd64.go`, 4 lanes, unrolled). They are
compiled with `GOEXPERIMENT=simd` (set by the Makefile) and selected at
start-up by CPU feature detection; `simd_other.go` provides the portable
fallback.

**Memory**: operators own their output vectors and reuse them for every
batch (no allocation per batch in steady state for scans, filters,
projections and aggregation updates); scans alias column chunks; row
copies of parallel gathers are carved from arena slabs; aggregation
results are allocated as one slab of cells; aggregate states are
struct-of-arrays slices indexed by group ID; the join table is three flat
arrays. Memory accounting (`--max-query-memory-mb`) is atomic so parallel
workers share one budget.

**Verification**: the conformance suite passes in both modes and under the
`--modes` matrix; `POLYQUERY_MORSEL_ROWS=N` (environment, testing aid)
shrinks morsels so that the small conformance tables exercise parallel
execution (the suite also passes with N = 3 … 7). `scripts/difftest.py`
generates random queries (expressions over all types with NULLs, errors,
joins incl. LEFT/non-equi/three-way, aggregates incl. DISTINCT, ORDER BY …
LIMIT, IN subqueries) over the generated fixtures in several layouts (row,
column, forced dictionaries, small PQCF row groups, mmap) and compares every
mode × join × threads × optimize combination with the row-mode baseline;
`internal/engine/modes_test.go` does the same for fixed queries; the race
detector runs over the unit tests and the conformance suite.

### Performance measurements

Measured on the generated `1m` datasets (`python3
datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata --jobs 1`:
1M transactions, sensor readings, order items and sort keys; 250k orders;
100k customers) on an AMD Ryzen 9 9950X3D (16 cores / 32 threads, AVX-512)
with `scripts/bench.py` (session protocol, column layout, `result:
"count"`, median of 5 runs, client-side milliseconds incl. the protocol
round trip; queries are listed in the script). *Before* is the Phase 4
engine (commit `606b0d1`, row-at-a-time, serial); `row1` is today's row mode
(the retained baseline), `vecN` vectorized execution with N threads.

| query | before | row1 | row8 | vec1 | vec4 | vec8 | before → vec8 |
|---|---:|---:|---:|---:|---:|---:|---:|
| filter_count (scan, 2 predicates) | 85 | 60 | 12 | 2 | 1 | <1 | >85× |
| agg_lowcard (GROUP BY category, 5 aggregates) | 111 | 108 | 22 | 7 | 2 | 1 | 111× |
| agg_highcard (GROUP BY customer_id, 100k groups) | 95 | 91 | 78 | 20 | 16 | 13 | 7× |
| agg_expr (GROUP BY bucket % 10, arithmetic) | 172 | 139 | 28 | 13 | 4 | 2 | 86× |
| sensor_agg (filter + GROUP BY, FLOAT64) | 144 | 119 | 22 | 8 | 3 | 2 | 72× |
| items_sum (SUM(quantity * unit_price)) | 109 | 95 | 16 | 26 | 7 | 4 | 27× |
| join_agg (1M ⋈ 100k, GROUP BY) | 159 | 120 | 49 | 26 | 9 | 6 | 26× |
| join_big (1M ⋈ 250k, GROUP BY) | 168 | 148 | 88 | 22 | 11 | 9 | 19× |
| join_filter (250k ⋈ 100k, filters) | 21 | 20 | 9 | 1 | 1 | 1 | 21× |
| topn (ORDER BY … LIMIT 10) | 38 | 40 | 20 | 11 | 3 | 2 | 19× |
| sort_full (1M rows by string, int) | 1077 | ~1000 | ~980 | 204 | 101 | 89 | 12× |
| distinct (DISTINCT merchant_id) | 43 | 44 | 30 | 6 | 3 | 3 | 14× |
| const_fold (constant expressions in WHERE) | 140 | 63 | 16 | 3 | 1 | 1 | 140× |
| join3_reorder (3-way comma join, bad FROM order) | RESOURCE_LIMIT¹ | 66 | 29 | 10 | 4 | 4 | — |

¹ The Phase 4 engine joins the first two FROM items (1M × 100k, no join
condition between them) as a cross product and exceeds `--max-join-rows`.

Where the gains come from:

* **Vectorization** (`row1` → `vec1`): 3.6–30× — typed column loops instead of
  per-row interface calls and `Value` boxing, zero-copy scans, dictionary
  codes for string predicates and grouping, batch-resolved group IDs. The
  smallest gains are top-N (3.6×, dominated by heap maintenance) and
  items_sum (3.7×: DECIMAL multiplication checks every product for 18-digit
  overflow).
* **Parallelism** (`vec1` → `vec8`): 4–7× for scans, filters,
  low-cardinality aggregation, join_agg and top-N; 2–2.5× for join_big,
  DISTINCT and the full sort (parallel runs + merge); 1.5× for 100k-group
  aggregation, where every worker sees most groups and the partial tables
  must be merged. Row mode profits from the same pipelines (`row1` → `row8`,
  up to 6×).
* **Logical optimizer** (`optimize: true` vs `false`, same engine):

  | query | row1 | row1, optimize off | vec1 | vec1, optimize off |
  |---|---:|---:|---:|---:|
  | join_filter (pushdown below the join) | 21 | 47 | 1 | 6 |
  | join_small (filter below the join: 2,000 instead of 250k probe rows) | 7 | 48 | 1 | 4 |
  | const_fold (folding, `1 = 1` removed) | 60 | 131 | 3 | 4 |
  | join3_reorder (pushdown + join reordering) | 82 | RESOURCE_LIMIT | 12 | RESOURCE_LIMIT |

  Folding matters most in row mode, where every constant subexpression was
  re-evaluated per row; vectorized execution already evaluates constant
  subtrees once per query.
* **Join algorithms** (`join` option, ms):

  | query | vec1 hash | vec1 merge | vec1 nested loop | row1 hash | row1 merge |
  |---|---:|---:|---:|---:|---:|
  | join_small (2,000 ⋈ 100k) | 1 | 6 | 9,960 | 7 | 10 |
  | join_filter (filtered 250k ⋈ 100k) | 1 | 8 | 30,477 | 21 | 24 |
  | join_agg (1M ⋈ 100k) | 28 | 374 | timeout (60 s) | 171 | 412 |
  | join_big (1M ⋈ 250k) | 22 | 122 | timeout (60 s) | 203 | 136 |

  The vectorized hash join (flat bucket arrays, batch probing) is 6–20×
  faster than the row-mode hash join; sort-merge pays for materializing and
  sorting both inputs; nested loops are quadratic.
* **Explicit SIMD** (`go test ./internal/exec -bench Kernel`, ns per
  2,048-value vector, portable loop → AVX2 kernel): INT64 compare with a
  constant 549 → 285 (1.9×), FLOAT64 compare 734 → 237 (3.1×), FLOAT64
  multiply incl. finiteness check 1,800 → 1,380 (1.3×). End to end the
  difference is within measurement noise (filter_count 1.9–2.1 ms either
  way): after vectorization these kernels are a small part of query time.
* **Memory**: reusing operator-owned vectors avoids per-batch allocation;
  slab allocation of group keys and materialized rows, batched memory
  reservations (one atomic update per 64 KiB instead of per group — the
  shared counter was 16% of the CPU profile of parallel 100k-group
  aggregation), and counting `result: "count"` results batch-wise (sort_full
  spent 48 ms per query converting 1M rows only to count them) are
  measurable in the profiles.

Reproduce with `python3 implementations/go/scripts/bench.py --data
/tmp/pqdata/1m --configs row1,row8,vec1,vec4,vec8` (`--engine` selects
another binary, e.g. a build of the baseline commit), or with Go benchmarks:
`POLYQUERY_BENCH_DATA=/tmp/pqdata/1m go test ./internal/engine -run - -bench
Queries`.

## Decisions on points the spec leaves open

* **INT64 ↔ DECIMAL comparison** follows types.md §2 literally: the INT64 side
  is promoted to `DECIMAL(18,s)` and a value that needs more than 18 digits
  raises `NUMERIC_OVERFLOW`. For arithmetic, INT64 operands keep scale 0
  (so `1.5 * 2` is `DECIMAL(18,1)`), `/` converts both sides directly to FLOAT64.
* **Null-typed expressions** (`NULL + NULL`, `SUM(NULL)`, `MIN(NULL)`) keep the
  null type and are reported as `STRING`; arithmetic with one NULL operand takes
  the other operand's type.
* **Explicit-schema errors**: an unknown type name or invalid DECIMAL parameters
  in a `load` schema, `header: false` without a schema, or an invalid delimiter
  are `INVALID_REQUEST` (malformed request fields).
* **Whitespace-only CSV fields** are treated as empty for non-STRING columns
  (NULL; not considered during inference); STRING columns keep the raw text.
* **Empty CSV input** with `header: true` is an `INGEST_ERROR` unless an
  explicit schema is given (then the table is empty).
* **JSON keys** differing only in case are duplicate column names
  (`INGEST_ERROR`); explicit schemas match keys case-insensitively.
* **CAST from STRING** trims ASCII whitespace; `CAST(... AS TIMESTAMP)` requires
  the full timestamp syntax of types.md §3 (a bare date is a `CONVERSION_ERROR`;
  ingestion does accept dates for TIMESTAMP columns as specified).
  `FLOAT64 → DECIMAL` rounds the shortest round-trip decimal representation.
* **FLOAT64 output** uses the shortest round-trip representation, `-0` as `0.0`,
  and integral values keep a `.0` suffix.
* **LIMIT/OFFSET** must be constant INT64 expressions: non-constant ⇒
  `SEMANTIC_ERROR`, non-INT64 ⇒ `TYPE_ERROR`, negative ⇒ `INVALID_ARGUMENT`,
  `NULL` ⇒ no limit.
* **Query options**: `mode` is `auto` (= vectorized), `row` or `vectorized`;
  `threads` (≥ 1, capped at 256) defaults to `--threads`, whose default is
  min(4, CPU count); `join` is `auto` (= hash for equi-joins), `hash`, `merge`
  or `nested_loop` (joins without an equality conjunct between the inputs
  always use a nested loop); `optimize: false` skips the logical optimizer
  (physical planning — column pruning, index selection, row-group skipping,
  build-side choice — stays on; `use_indexes: false` disables indexes);
  `native` is accepted and ignored. Other values of the enumerated options ⇒
  `UNSUPPORTED`; ill-typed values or `threads < 1` (the request schema's
  minimum) ⇒ `INVALID_REQUEST`.
* **PQ_SLEEP** queries (test-only function) always execute row-at-a-time
  and serially, whatever `mode`/`threads` say: its evaluation count is
  observable through timing, and batch execution would evaluate it for rows
  a `LIMIT` never needs.
* **Unknown ops** answer `INVALID_REQUEST`.
* **Storage options**: an invalid `layout`, non-boolean `dictionary`/`mmap`,
  non-positive `row_group_size` or unknown `encoding` value is
  `INVALID_REQUEST`. `open` answers like `load` (`table`, `row_count`,
  `columns`); `schema` additionally reports `layout`.
* **CREATE INDEX** checks table and column (`SEMANTIC_ERROR`) before the
  index name (`ALREADY_EXISTS`); `IF NOT EXISTS` with a taken name does
  nothing even if the existing index is on another table. Index names are
  case-insensitive like table names. `EXPLAIN` of `CREATE/DROP INDEX` is
  `INVALID_REQUEST`.
* **UPPER/LOWER**: functions.md says "ASCII letters only are case-mapped",
  while the conformance suite expects `UPPER('abc Ünï') = 'ABC Ünï'` (the
  ASCII `n` inside a non-ASCII word stays lowercase). The engine maps ASCII
  letters of words (maximal runs of non-whitespace) that consist only of
  ASCII characters and leaves words containing other characters unchanged;
  for ASCII text this is exactly the specified behaviour.
* **NULL-typed arguments**: functions whose result type is "same as the
  argument" (`ABS`, `ROUND`, `FLOOR`, `CEIL`, `NULLIF`) keep the null type for a
  NULL literal argument (reported as `STRING`); functions with a fixed result
  type (`LENGTH` → INT64, `YEAR` → INT64, `DATE_TRUNC` → TIMESTAMP, …) report it.
  `ROUND(x, NULL)` is NULL. Constant parameters (`ROUND` digits, units) are
  evaluated during analysis; units are case-insensitive.
* **CASE/COALESCE unification** follows semantics.md §13 strictly: numeric
  promotion only, so mixing DATE and TIMESTAMP results is a `TYPE_ERROR`.
  Branch values are converted to the result type (DECIMAL rescaled).
* **HAVING** cannot reference select-list aliases (only GROUP BY and ORDER BY
  can, as specified); such references are unknown columns (`SEMANTIC_ERROR`).
* **GROUP BY alias** matching uses explicit aliases only; ORDER BY name
  matching uses all output names (aliases, column names and `_colN`).
* A qualified reference `r.c` resolves against the innermost range variable
  named `r`; it does not fall through to outer scopes if `r` lacks `c`.
* **Hash joins** are used when the join condition has at least one
  `left_expr = right_expr` conjunct; other conjuncts are evaluated as a
  residual. For INNER joins the smaller (estimated) input is the build side.
* `--max-join-rows` limits the output of every individual join operator.
* Defaults: `--max-query-memory-mb 4096`, `--max-ingest-bytes 4 GiB`,
  `--max-table-rows 500000000`. Memory accounting covers retained rows (sort
  buffers, hash tables, materialized join inputs and results).

## Known limitations

* Native kernels (`native.kernels`) are not supported (no cgo).
* Parallelism covers pipelines of scans, filters, projections and hash join
  probes feeding a hash aggregation, DISTINCT, a sort, a top-N or the
  result; sort-merge and nested-loop joins, index scans and plans that
  evaluate subqueries or PQ_SLEEP run serially (their inputs may still be
  parallel scans). Correlated subquery plans never use parallel workers.
* FLOAT64 `SUM`/`AVG` computed by parallel workers add partial sums in a
  different order than serial execution, so results may differ in the last
  bits (summation order is implementation-defined; results stay within the
  conformance tolerance). INT64/DECIMAL aggregates are exact in every mode.
* With parallel hash join probes, `--max-join-rows` counts the rows of all
  workers; rows produced by workers ahead of a `LIMIT` count as well.
* Nested-loop, sort-merge and index-scan operators, VALUES and the
  correlated-subquery helpers run row-at-a-time inside vectorized plans
  (adapters convert between rows and batches).
* Streaming backpressure blocks query execution once the bounded batch
  buffer and the kernel socket buffers are full; on Linux loopback the
  kernel may accept a lot of data into a non-reading client's receive queue
  before that happens.
* Only `query` operations go through admission control; `load`, `open`,
  `explain` and the other catalog operations run directly (loads parse
  outside any lock and publish atomically, so they never block queries).
* Indexes are not used for `OR` predicates, `NOT IN`/`<>`, expressions over
  the column (e.g. `col + 1 = 5`) or INT64/DECIMAL columns compared with
  FLOAT64 values, and not to produce ordered output. Predicates are not
  pushed through GROUP BY or LIMIT.
* Correlated subqueries whose correlation is not an equality (e.g.
  `q.age < p.age`) rescan their input per distinct outer value.

