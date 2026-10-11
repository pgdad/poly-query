# PolyQuery — Rust engine (Track A)

An analytical database engine implementing the PolyQuery specification
(`spec/`) in Rust, using **only the standard library** (no crates).

Status: **Phase 5** (optimization) plus **M9** (native kernel
integration). Capabilities claimed:
`phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`, `sql.basic`,
`test.functions`, `phase2`, `sql.groupby`, `sql.join`, `sql.functions`,
`sql.subquery`, `sql.cte`, `sql.correlated_subquery`, `phase3`,
`storage.pqcf`, `storage.mmap`, `index.hash`, `index.btree`, `phase4`,
`http.streaming`, `phase5`, `exec.row`, `exec.vectorized`, `exec.parallel`,
`join.hash`, `join.merge`, `join.nested_loop`, `native.kernels`.

## Build and run

Prerequisites: Rust 1.96.0 stable with Cargo (edition 2024). No network
access is needed; there are no dependencies.

```bash
make build          # cargo build --release --offline
make test           # unit tests (cargo test)
make lint           # cargo clippy -D warnings
make fmt            # cargo fmt
make clean

bin/polyquery version
bin/polyquery capabilities
bin/polyquery session --data-dir DIR [--enable-test-functions] …
bin/polyquery exec --data-dir DIR --request FILE|-
bin/polyquery serve --port N [--host H] [--workers N] [--queue-depth Q]
                    [--query-timeout-ms T] [--shutdown-grace-ms G]
                    [--max-request-bytes B] [common options]
```

`bin/polyquery` is a POSIX shell launcher that resolves its own location and
runs `target/release/polyquery`, so it works from any directory.

## Libraries

None. `ENGINE.json` lists `"libraries": []`. The optional native kernel
library `libpqkernels` (built from `native-kernels/`, not part of this
crate) is loaded at run time with `--native-kernels PATH`; see
[Native kernels](#native-kernels-m9).

## Architecture

The crate is a library (`src/lib.rs`) plus a thin binary (`src/main.rs`).
Layers, bottom-up:

| Module | Responsibility |
|---|---|
| `json` | strict RFC 8259 parser (keeps number literal text and member order) and single-line serializer |
| `error` | stable error codes (errors.md), error object with optional `details` (`line`/`column`, `record`, …) |
| `types` | `DataType`, runtime `Value`, exact DECIMAL helpers (i128 intermediates), DATE/TIMESTAMP calendar code, FLOAT64 text, CAST matrix |
| `storage` | immutable tables in row layout, column layout (typed vectors + validity bitmap, dictionary-encoded STRING) or PQCF-file-backed (lazily decoded row groups); `stats` (per-column statistics), `index` (hash and ordered indexes), `pqcf` (CRC-32, mmap, reader, writer) |
| `catalog` | case-insensitive table map of `Arc<Table>` (queries hold snapshots) |
| `ingest` | CSV (RFC 4180 + spec rules), JSON array and JSON Lines readers, type inference, explicit schemas |
| `sql` | lexer (positions for `PARSE_ERROR` details), AST, recursive-descent parser for the **full** v1 grammar |
| `planner::binder` | semantic analysis: name resolution (`scope`: range variables, CTE environments, correlation), expression typing (`exprs`), function signatures (`functions`), the grouping rule, ORDER BY/GROUP BY ordinal and alias resolution; produces a `LogicalPlan` of bound, typed `Expr`s |
| `planner::typing` | numeric promotion, comparability, common types (CASE/COALESCE) |
| `planner::logical` | logical algebra: Scan, Filter, Project, Aggregate, Join (INNER/LEFT/CROSS), Distinct, Sort, Limit |
| `planner::optimizer` | logical optimization driver: `rewrite` (constant folding, predicate simplification), predicate pushdown (WHERE/ON conjuncts to the scans, also through pass-through projections of derived tables/CTEs; cross joins with equality predicates become inner joins), `reorder` (join reordering of inner-join chains) and column pruning |
| `planner::access` | access paths: recognizes `col <op> const` / `BETWEEN` / `IN` / `IS NULL` conjuncts, estimates selectivity from statistics, chooses index scans, selects PQCF row groups by min/max |
| `planner::physical` | physical plan: hash / merge / nested-loop join (equi-keys, build side by estimated cardinality; LEFT builds right), hash aggregate, top-N sort, `ParamLookup` for correlated subqueries; EXPLAIN JSON |
| `exec` | row-at-a-time (Volcano) operators (`operators`); row expression evaluator; scalar functions; aggregate accumulators; subquery evaluation with memoization; per-query context (timeout, cancellation flag, shared memory budget, join-row limit, execution options) |
| `exec::vector` | vectorized engine: column vectors and batches (`batch`), vectorized expression kernels (`eval`), key interning (`keys`), aggregation (`agg`), joins (`join`), sorting (`sort`), batch operators (`ops`) and the plan builder (`build`) |
| `exec::parallel` | morsel-driven parallel scan pipelines: ordered gather and parallel (partitioned) aggregation |
| `exec::hash` | fast non-cryptographic hasher for execution hash tables |
| `exec::native_filter` | filters above column-table scans evaluated with the native kernels (vectorized and row operators) |
| `native` | `libpqkernels` integration: `dlopen`/`dlsym` FFI (`native::ffi`), typed function-pointer table with safe slice wrappers (`Kernels`), bitmap helpers |
| `engine` | transport-independent facade: load/drop/reset/query/explain, path safety, limits |
| `protocol` | request validation, response building, `session` (JSON lines) and `exec` modes |
| `server` | `serve`: HTTP/1.1 (`http`), routing (`conn`), admission control (`admission`), query registry (`registry`), query threads and NDJSON streaming (`query`), Prometheus metrics (`metrics`), SIGTERM/SIGINT (`signal`) |
| `cli` | argument parsing (unknown options ⇒ exit 2) |

Processing of a statement: `lex → parse (AST) → bind/type (LogicalPlan) →
optimize → lower (PhysicalPlan) → build operators → execute`. Errors found
before execution (parse, semantic, type) are reported without executing
anything; `EXPLAIN` / the `explain` op render the physical plan.

### Subqueries and correlation

A subquery inside an expression is bound with a *correlation* link to the
scope it appears in. A column that does not resolve locally is resolved in
the enclosing scopes and becomes a parameter of the subquery
(`Expr::Param`); the outer expressions for those parameters are children of
the subquery expression, so they take part in grouping checks, column
pruning and remapping like any other expression (references several levels
up are passed through intermediate subqueries). At run time the parameter
values are pushed on the execution context while the subquery's plan runs;
results are memoized per (subquery, parameter values), so an uncorrelated
subquery runs at most once per query. Inside a subquery, a filter
`inner_expr = <outer value>` over a parameter-independent input is planned
as a `ParamLookup`: the input is hashed once per query and probed per outer
row. Derived tables and CTEs share the correlation of the query they appear
in (no LATERAL).

## Design decisions (where the spec leaves room)

* **Numbers in JSON** keep their literal text, so request ids are echoed
  verbatim and JSON ingestion can apply literal-based typing exactly.
* **FLOAT64 output** uses Rust's shortest round-trip formatting; magnitudes
  outside [1e-5, 1e16) use exponent form (`1.5e300`); `-0.0` prints as `0.0`.
  `CAST(float AS STRING)` uses the same text.
* **FLOAT64 → DECIMAL** rounds half away from zero based on the shortest
  round-trip decimal representation of the float (so `1.005e0` → `1.01`).
* **Numeric comparisons** are exact by mathematical value (types.md §5); INT64
  vs DECIMAL is compared in i128, so `0.000000000000000001 < 1` is TRUE rather
  than a promotion overflow. Arithmetic still applies the promotion rule
  (an INT64 operand of DECIMAL arithmetic must fit 18 digits).
* **Null type**: in arithmetic a `NULL` operand takes the other operand's type
  (`NULL / 0` is INT64); `SUM(NULL)` is INT64, `AVG(NULL)` FLOAT64, `MIN/MAX(NULL)`
  are reported as STRING.
* **LIMIT/OFFSET** must be constant INT64 expressions; `LIMIT NULL` means no
  limit; non-INT64 types are `TYPE_ERROR`.
* **CSV**: a whitespace-only field is empty (NULL) for non-STRING columns
  (types are trimmed of spaces/tabs before conversion and inference); STRING
  fields are kept raw. A file with no header record is `INGEST_ERROR`.
  Header names are used verbatim; with an explicit schema the schema's
  spelling is reported. A lone `"` inside an unquoted field is literal text;
  characters after a closing quote are `INGEST_ERROR`.
* **JSON**: without a schema, columns are the union of the exact keys, so
  keys differing only in case (in the same or different objects) are
  duplicate column names ⇒ `INGEST_ERROR`; with a schema, keys match column
  names case-insensitively. An integer literal outside INT64 makes the column
  FLOAT64. With an explicit schema, JSON numbers/booleans into STRING columns
  are `CONVERSION_ERROR` (ingestion.md §2.2 "any other combination").
* **Load requests**: `format` is required; unknown schema type names are
  `INVALID_REQUEST`; a missing file is `NOT_FOUND`, a directory `IO_ERROR`,
  an OS permission failure `ACCESS_DENIED`.
* **Query options**: unknown options are ignored; ill-typed known options are
  `INVALID_REQUEST`; unsupported values (unknown `mode`/`result`/`join`
  values) are `UNSUPPORTED`; `threads: 0` is `INVALID_REQUEST` (values above
  256 are capped). `use_indexes: false` disables index scans. Phase 5
  options are described below.
* **Common type** (CASE, COALESCE): if all non-NULL branch types are equal
  that type is kept (e.g. `DECIMAL(10,2)`); otherwise numeric promotion
  (`INT64`+`DECIMAL(p,s)` ⇒ `DECIMAL(18,s)`, decimals ⇒ `DECIMAL(18,max s)`,
  any `FLOAT64` ⇒ `FLOAT64`); DATE and TIMESTAMP have no common type.
  Branch values are converted to the common type.
* **UPPER/LOWER** map ASCII letters only. A word (maximal run of
  alphanumeric characters) containing a non-ASCII character is left
  unchanged, which is what the public conformance suite expects
  (`UPPER('abc Ünï')` = `'ABC Ünï'`); for ASCII text this is exactly ASCII
  case mapping.
* **Units** of `DATE_TRUNC`/`DATE_DIFF` are matched case-insensitively and
  validated at bind time (`INVALID_ARGUMENT`); a NULL unit or a NULL `ROUND`
  digit count yields NULL.
* **GROUP BY alias** lookup only considers explicit `AS` aliases (bare
  column items already resolve as input columns). HAVING cannot reference
  select aliases (not in the spec).
* **Correlated CTE**: a CTE whose body references an outer query's column
  may only be used at the level where it is defined; using it from a nested
  subquery answers `UNSUPPORTED` (never a wrong result).
* **Hash keys** of joins and IN-subquery sets are normalized to the
  comparison domain (INT64 vs DECIMAL ⇒ decimal, any FLOAT64 ⇒ float, DATE
  vs TIMESTAMP ⇒ timestamp) so hashing agrees with SQL comparison.
* **Robustness**: requests are processed on a thread with a 256 MiB stack;
  the parser limits nesting depth and operator-chain length (10,000) and the
  JSON parser depth (512);
  panics are caught and reported as `INTERNAL_ERROR` (logged to stderr).
* **Defaults**: `--max-query-memory-mb 4096`, `--max-ingest-bytes 4 GiB`,
  `--max-table-rows 500,000,000`; memory accounting is approximate and covers
  materializing operators (sort, aggregation state, result rows).

## Phase 3: storage and indexing

### In-memory layouts

`load`/`open` accept `options.layout` (`"column"`, the default, or `"row"`;
anything else is `INVALID_REQUEST`). The **column layout** stores one typed
vector per column plus a validity bitmap; STRING columns are dictionary
encoded when that pays off (≥ 64 rows and at most half as many distinct
values as rows) or always with `options.dictionary: true` (`false` disables
it). The **row layout** stores a vector of row tuples. Scans are written
against a row-group interface (`Table::read_group`, `Table::read_rows`), so
every operator works unchanged on all representations; `schema` reports the
`layout`.

### PQCF files

* `save` streams the file to `.<name>.tmp-<pid>-<n>` in the target directory,
  `fsync`s it, renames it over the target and `fsync`s the directory; a failed
  save removes its temporary file, and temporaries of other (crashed)
  processes for the same target are removed by the next save. A missing
  directory or any write failure is `IO_ERROR`.
* Options: `row_group_size` (default 65,536; 0 is `INVALID_REQUEST`) and
  `encoding` (`auto` default, `plain`, `dict`, `rle`; unknown values are
  `INVALID_REQUEST`). Forced `dict` applies to STRING chunks and forced `rle`
  to BOOLEAN/INT64/DECIMAL/DATE/TIMESTAMP chunks; other chunks are PLAIN.
  `auto` picks RLE when runs < n/4 (NULL slots extend the current run), DICT
  when distinct < n/2, else PLAIN; FLOAT64 is always PLAIN.
* Chunks start 8-byte aligned; NULL slots are written as zero / empty;
  every chunk carries `null_count` and exact `min`/`max` of its non-null values
  (STRING bounds are omitted when longer than 1 KiB). Index definitions of the
  table are written to `indexes`. Writer string: `polyquery-rust <version>`.
* `open` validates header, footer, metadata checksum, JSON structure and all
  consistency rules of pqcf-v1.md §2 up front. Without `mmap` the file is read
  and **every chunk is checksummed, decoded and validated at open**. With
  `options.mmap: true` the file is memory-mapped (`mmap(2)` declared via
  `extern "C"`, no crates) and each column chunk is checksummed and decoded on
  first access (failures surface as `STORAGE_CORRUPT` from the query and are
  cached). The file's row-group structure and chunk statistics are kept, so
  scans of PQCF-backed tables skip row groups whose `min`/`max`/`null_count`
  exclude a `col <op> constant`, `BETWEEN`, `IN` or `IS [NOT] NULL` conjunct
  (EXPLAIN shows `row_groups` and `row_groups_read`). `options.layout` on open
  converts to that in-memory layout; without it the columnar file
  representation is used directly.
* Chunk `min`/`max` that do not parse for the column type are treated as
  unknown (they only ever enable skipping). Metadata type names are accepted
  with the same aliases as explicit load schemas. An unknown encoding name is
  `STORAGE_VERSION_UNSUPPORTED`; a known encoding that is not valid for the
  column type is `STORAGE_CORRUPT`. Files with more rows than
  `--max-table-rows` are `RESOURCE_LIMIT`.

### Statistics

Per-column statistics (null count, min, max, distinct count) are computed on
first use and cached with the immutable table. The distinct count is exact up
to 65,536 distinct values, then a HyperLogLog estimate (2^14 registers,
≈1% error).

### Indexes

* `HASH`: a hash map from value to row ids. `BTREE`: an ordered structure — the
  non-null values sorted with their row ids (a sorted permutation), searched
  by binary search for equality and ranges. NULLs are never indexed. Lookups
  return row ids in ascending order, so index scans produce rows in table
  order, exactly like full scans.
* Index names are global and case-insensitive. Indexes reference the exact
  table version they were built on; `drop`, `reset` and replacing a table
  (`load`/`open` with `replace`) drop its indexes. `CREATE INDEX` validates the
  table and column (`SEMANTIC_ERROR`) before the name (`ALREADY_EXISTS`, or a
  no-op with `IF NOT EXISTS`). `open` recreates the indexes listed in the file,
  atomically with the table (`ALREADY_EXISTS` if a name is taken by another
  table).

### Planning

* Predicate pushdown places single-table conjuncts directly above the scan;
  physical planning then picks the access path for that scan.
* **Index selection**: for the conjuncts on an indexed column — `col = c`,
  `col IN (c, …)` (any index; hash indexes only when the constant has the
  column's own type family, so hashing agrees with SQL equality), and ranges
  (`<, <=, >, >=, BETWEEN`, all range conjuncts on the column intersected;
  BTREE only) — the selectivity is estimated from statistics (equality
  1/distinct, IN k/distinct, ranges by linear interpolation between min and
  max for numeric/temporal types, 1/3 otherwise). The most selective
  candidate is used when its selectivity is ≤ 10 % **or it is expected to
  return at most 10 rows** (on tiny tables an index lookup is never worse than
  a scan; this matches the public suite, which expects index scans on the
  8-row `people` table). Conjuncts answered by the lookup are removed; the
  rest stay in a `Filter` above the `IndexScan`. Constant expressions are
  folded at planning time; a comparison with NULL selects nothing.
* Join build side: hash joins build on the input with the smaller estimated
  cardinality (filtered scans are estimated with the same selectivity model,
  other filters with 1/3); LEFT joins build on the right.

## Phase 4: HTTP server and concurrency

### Catalog snapshots

The engine (`Engine`) is shared by all connections (`Sync`). The catalog is
an immutable value behind an `RwLock<Arc<Catalog>>` whose lock is only held
to clone or swap the `Arc`. Every statement plans against a snapshot taken
when it starts executing, and the physical plan holds `Arc`s of the table
versions and indexes it uses, so a query sees exactly those versions even
if the tables are replaced or dropped meanwhile (concurrency.md §1).
Mutations (`load`, `open`, `drop`, `reset`, `CREATE/DROP INDEX`) are
serialized by a writer mutex, copy the catalog, change the copy and publish
it atomically (a failed mutation publishes nothing). Expensive work — reading
and parsing input, opening PQCF files — happens before the writer lock is
taken; `CREATE INDEX` builds the index while holding only the writer lock.
Readers never wait for writers.

### Threads, admission and the query lifecycle

* One thread per connection (keep-alive, `Expect: 100-continue`, chunked
  request bodies). Non-query endpoints run on the connection thread, so
  `/health`, `/metrics`, `/v1/queries` and cancellation stay responsive while
  all workers are busy.
* A query (`/v1/query`, `/v1/query/stream`, or `op: "query"` through
  `/v1/request`) is registered by `query_id` (client-supplied or `q-<n>`;
  a duplicate of a queued/running id is `409 ALREADY_EXISTS`), then admitted:
  it takes a free worker slot if nobody is queued, else a FIFO queue slot,
  else it is rejected immediately with `503 OVERLOADED`. It then runs on its
  own thread; the connection thread waits for its result on a bounded
  channel and polls the socket every 20 ms (non-consuming `peek`) to detect a
  client disconnect, which cancels the query.
* The effective deadline is `arrival + (options.timeout_ms || --query-timeout-ms)`,
  so queue time counts. Queued queries re-check deadline and cancellation
  every 5 ms; running operators check every 1,024 rows; `PQ_SLEEP` sleeps in
  5 ms slices.
* Before the response is sent the query is unregistered and metrics are
  updated, so a client that has its response sees consistent
  `/v1/queries` and `/metrics`.

### Streaming

`/v1/query/stream` sends NDJSON over chunked transfer encoding. The execution
thread serializes rows and pushes lines into a channel of 8 lines; when it is
full the producer waits (re-checking timeout/cancellation), so a client that
stops reading stops the query (backpressure) and at most 8 batches are
buffered ahead of the socket. The header line is sent together with the
first row (or the end), so errors found before any row exists (parse,
semantic, or during a blocking sort) get a normal error response with its
HTTP status; later errors end the stream with an `error` line and no `end`
line. The first row is flushed immediately; later `rows` lines hold up to
4,096 rows, 1 MiB, or the rows produced within 100 ms.

### HTTP details

* The `serve` options are accepted (and validated) in every mode so that one
  set of engine arguments works for both transports; outside `serve` they
  are ignored, except `--query-timeout-ms`, which is the default query
  timeout in `session`/`exec` too. `serve` still requires `--port`.

* `PUT /v1/tables/{name}` accepts `format`, `replace`, `header`, `delimiter`,
  `layout` and (extension) `schema` — a URL-encoded JSON schema array as in
  the `load` op. As in `load`, CSV with `header=false` requires a schema
  (`400 INVALID_REQUEST` otherwise). The body must be UTF-8. Success is `201`.
* Error responses are the protocol error objects (with `"id"`), status per
  protocol.md §7.1; unknown paths `404 NOT_FOUND`; a wrong method
  `405 INVALID_REQUEST` with an `Allow` header; malformed HTTP `400`.
* A body over `--max-request-bytes` is `413 RESOURCE_LIMIT` (rejected from
  `Content-Length` before reading; the body is drained briefly so the client
  sees the response, then the connection is closed).
* `polyquery_queries_total` counts every query request that ended (including
  `OVERLOADED` rejections and duplicate ids, as `error`); the duration summary
  covers admitted queries, measured from arrival. An extra counter
  `polyquery_http_requests_total` is exported.
* Logs are JSON lines on stderr. At `info`: startup, table loads, query
  completion (`query_id`, `status`, `error_code`, `duration_ms`, `rows`),
  cancellations, shutdown. SQL text and per-request lines only at `debug`.

### Graceful shutdown

SIGTERM/SIGINT set a flag (handler installed with libc `signal`, declared via
`extern "C"`). The server then answers every new request — on existing and
on new connections — with `503 SHUTTING_DOWN` (`/health`: `503
{"status":"shutting_down"}`; `/metrics` and `/v1/queries` stay available)
and closes connections after the response. It waits up to
`--shutdown-grace-ms` for in-progress requests (running and queued queries,
loads, streams); then cancels all queries (`409 CANCELLED`), gives them up to
1 s to answer, and exits with status 0. New connections are still accepted
during shutdown so that clients get a definite 503 instead of a refused
connection.

## Phase 5: optimization

### Execution options

| Option | Implementation |
|---|---|
| `mode: "row"` | the row-at-a-time Volcano engine (`exec::operators`), kept unchanged as the **baseline**; always single-threaded |
| `mode: "vectorized"` / `"auto"` (default) | batch execution over column vectors (`exec::vector`), batches of 2,048 rows |
| `threads: N` | parallel scans, filters, projections, join probes, aggregation, DISTINCT and sorting in vectorized mode; default `--threads` (the CPU count, at most 16). `threads: 1` is fully serial |
| `join: "hash"` | hash join for equi-joins (other joins: nested loop) |
| `join: "merge"` | sort-merge join for equi-joins (INNER and LEFT) |
| `join: "nested_loop"` | nested-loop join for every join, including equi-joins |
| `join: "auto"` (default) | cost-based: hash join for equi-joins, building on the input with the smaller estimated cardinality (statistics-based estimates); nested loop for non-equi joins |
| `optimize: false` | disables the logical rewrites (see below) |
| `native: true` | use the native kernels of the library loaded with `--native-kernels` (see [Native kernels](#native-kernels-m9)); without a loaded library the option has no effect |

EXPLAIN shows `HashJoin`, `MergeJoin` or `NestedLoopJoin` accordingly
(`MergeJoin` has `keys` and `residual` like `HashJoin`); the root node
carries `"execution": {"mode": …, "threads": …}`.

### Vectorized engine

* **Column vectors** (`batch.rs`): typed contiguous arrays (`Vec<i64>`,
  `Vec<f64>`, unscaled DECIMAL with one scale per vector, `Vec<i32>` dates,
  `Arc<str>` strings, BOOLEAN) plus an optional validity array.
  **Dictionary-encoded columns stay encoded** (codes + the shared dictionary
  `Arc`), so string predicates, grouping, joins and sorting on them work on
  integer codes. A generic `Value` representation covers non-uniform data
  (e.g. DECIMALs of mixed scales). Scans copy typed slices straight out of
  the column chunks (row-layout tables are transposed per batch).
* **Expression kernels** (`eval.rs`): comparisons, arithmetic (with the
  exact overflow / division-by-zero semantics), `AND`/`OR`/`NOT`,
  `IS NULL`, `BETWEEN`, constant `IN` lists (hash set), `LIKE`, numeric and
  temporal `CAST`s, unary minus, `ABS`, `YEAR`…`SECOND` and `DATE_TRUNC`
  (sharing helpers with the row evaluator) run as
  monomorphized loops over slices (one closure type per operator, so the
  compiler emits branch-free, auto-vectorized SIMD code; overflow checks
  accumulate flags instead of branching). Comparisons and `LIKE`/`IN` on a
  dictionary column are evaluated once per dictionary entry; scalar
  functions whose only non-constant input is a dictionary column (e.g.
  `UPPER(category)`) once per distinct code occurring in the batch, with
  string results kept dictionary-encoded. `AND`, `OR`
  and `CASE` evaluate lazily-evaluated operands only on the rows that need
  them (like row mode). Everything else (other functions and casts,
  subqueries) is evaluated element-wise by the row evaluator on the
  vectorized child results, so semantics are shared, not duplicated.
* **Hash aggregation** (`keys.rs`, `agg.rs`): each key column is interned to
  dense ids (specialized maps for `i64`-representable values, strings and
  dictionary codes resolved once per code); multi-column keys combine the
  ids (two columns: one packed `u64`). Aggregates are struct-of-arrays
  accumulators (`Vec<i64>` counts, `Vec<i128>` exact sums, typed MIN/MAX),
  updated by per-batch loops with dedicated loops for global aggregates.
  String MIN/MAX keep indices into a per-accumulator string table and
  return a dictionary-encoded vector (no per-group reference counting).
  DISTINCT aggregates use the row-mode accumulators.
* **Joins** (`join.rs`): the hash join materializes the build side as one
  batch and indexes it with a key table and **CSR row lists** (offsets +
  one row array, no per-key allocation); probe batches stream. The merge
  join sorts both sides on the keys (typed comparisons over the
  concatenated key columns) and merges equal-key groups. The nested-loop
  join pairs each left row with the materialized right side and filters the
  pairs vectorized. All three share one pair-emission routine (residual
  predicate, NULL padding for LEFT joins), which produces rows in the same
  order as the row engine.
* **Sorting** (`sort.rs`): a single numeric/temporal/boolean/dictionary key
  is encoded as an order-preserving `u64` and sorted as `(key, row)` pairs
  with an LSD **radix sort** (constant digits skipped); a single string key
  sorts `(8-byte prefix, row)` pairs and compares full strings only on
  prefix ties; other key lists use a comparator over typed key columns.
  Large comparator-sorted inputs are sorted in chunks on several threads
  and merged (a radix sort is a single linear pass and stays serial). Top-N
  (`ORDER BY … LIMIT`) keeps only the best rows (periodic compaction, then
  selection). Ties are broken by input position, so results are exactly
  the stable order of the row engine (whose top-N now uses the same
  tie-breaker).
* Subqueries: uncorrelated ones run vectorized; correlated ones (one
  small execution per distinct outer value) use the row engine, whose
  setup cost is lower.
* Results are serialized to JSON straight from the column vectors
  (allocation-free number/date formatting, no per-row value tuples);
  `result: "count"` counts whole batches without touching the values.

### Parallel execution (`exec/parallel.rs`)

Morsel-driven: a scan pipeline (scan → filters / projections / probe side
of hash or nested-loop joins) is cut into morsels of 16,384 rows (within
row groups); worker threads claim morsels from an atomic counter and run
the pipeline on them with their own execution context (sharing the
query's deadline, cancellation flag and memory budget). Join build sides
are built once, before the workers start, and shared read-only (`Arc`).

* **Ordered gather**: morsel outputs are returned in scan order, so a
  parallel scan yields exactly the serial row order; at most 2×threads
  morsels are in flight ahead of the consumer, so `LIMIT` stops the
  workers early.
* **Parallel aggregation**: every worker aggregates its morsels into a
  private partial aggregator. Partials are merged serially when small; for
  many groups the groups of each partial are **partitioned by key hash**
  and partition *p* of all partials is merged and finished by thread *p*
  (cache-friendly, no shared hash table, no locks).
* **Parallel DISTINCT**: executed as a parallel aggregation grouping by
  every column (no aggregates).
* **Parallel sort**: see above.
* Tables smaller than two morsels, subqueries, and scan pipelines under a
  `LIMIT` of at most one morsel (which a serial scan answers from its
  first batches) run serially.
  `POLYQUERY_MORSEL_ROWS` overrides the morsel size (used by the test
  scripts to force parallel execution on small tables).

### Logical optimizer (`optimize`)

With `optimize: true` (default) the optimizer runs **constant folding**
(constant subexpressions are evaluated at planning time — only if that
succeeds, so `1/0` still fails only when evaluated), **predicate
simplification** (`TRUE AND x` → `x`, `FALSE AND x` → `FALSE`,
`NOT NOT x` → `x`, `NOT (a < b)` → `a >= b`, filters on `TRUE` removed;
operands are only dropped where the row engine would not evaluate them or
where they cannot fail), **predicate pushdown** (as in Phase 3) and **join
reordering**: a maximal tree of inner/cross joins is flattened into its
inputs and conjuncts and rebuilt left-deep, greedily: first the connected
pair with the smallest estimated result, then the input keeping the
estimated intermediate result smallest (never a cross product while a
connected input remains), estimating `|A ⋈ B| = |A|·|B| / max(ndv(a),
ndv(b))` from the column statistics; each conjunct is attached to the first
join where its columns are available and a projection restores the column
order. With `optimize: false` none of these run. Always applied (they are
part of physical planning or required by the scan contract): column
pruning (projection pushdown), access-path selection for filters directly
above a scan (index / row-group skipping) and top-N for `ORDER BY …
LIMIT`.

### Identical results in every mode

* **Error replay**: vectorized and parallel execution evaluate eagerly over
  batches and in a different order than the row engine. When such an
  execution fails with a data error before any row was delivered, the
  statement is re-executed by the row-mode engine and its result or error
  is reported (also used if the vectorized engine fails internally). So
  `SELECT 10/x FROM t LIMIT 1` succeeds in every mode if the first row is
  fine, and with several failing rows every mode reports the same code.
* **Commutative AND/OR errors**: if one operand of `AND` fails with a data
  error, the error is only raised if the other operand is not `FALSE`
  (dually for `OR` and `TRUE`). Together with lazy evaluation this makes
  query failure independent of conjunct order, hence of predicate pushdown
  and of `optimize` (types.md §6 leaves errors in operands that need not
  be evaluated implementation-defined).
* Row order: ordered gather, stable sorts with deterministic top-N, and
  join output in the row engine's order (hash joins: probe order).
* `SUM`/`AVG` over FLOAT64 may differ in the last bits with `threads > 1`
  (summation order is implementation-defined, functions.md §2); INT64 and
  DECIMAL sums are exact (`i128`) in every mode.

Verification beyond the conformance suite: `bench/difftest.py` generates
random typed queries (joins, LEFT joins, 3-way joins, grouping, DISTINCT,
ORDER BY/LIMIT, subqueries, overflow and division-by-zero prone
expressions) over the generated fixture tables, including PQCF copies
with many small row groups (lazily decoded) and row-layout copies, and
compares every option combination — once with default morsels and once
with 37-row morsels — against the row-mode execution of the same plan
(thousands of queries, no differences; different plans agree whenever
both succeed). `bench/bigdiff.py` compares row mode with the vectorized,
parallel and merge-join configurations on the 1M-row datasets (including
a memory-mapped PQCF copy with 16 row groups), where the real morsel sizes,
partitioned merges and radix sorts are active.

### Memory and cache-oriented techniques

* typed, contiguous vectors; dictionary codes instead of strings; dense
  integer ids for keys, so hash tables are small flat maps of integers;
* CSR row lists for join tables and a packed `u64` for two-column keys
  (no per-entry heap allocation);
* scratch buffers (group ids, dictionary-code caches) reused across batches;
* partitioned (radix-style) merging of parallel aggregation partials;
* a fast multiply-rotate hasher instead of SipHash for all execution hash
  tables;
* shared string tables for string MIN/MAX results, shared dictionaries for
  dictionary-encoded vectors.

Explicit SIMD (`std::arch`) was evaluated: building the whole engine with
`-C target-cpu=native` (AVX2) gained only 0–15 % on the scan benchmarks,
because the kernels are already auto-vectorized and execution is bound by
memory traffic; the build therefore stays portable (no target-specific
code, no runtime dispatch). Hand-written SIMD with runtime CPU dispatch is
available through the native kernels (`native: true`, see
[Native kernels](#native-kernels-m9)).

### Measurements

Data: `pqgen.py generate --scale 1m` (transactions, order_items, sensor
readings and sort keys: 1M rows each; orders 250k; customers 100k;
products 20k), loaded as CSV with the generated schemas (column layout).
Tool: `bench/bench.py` (session protocol, `result: "count"`, wall-clock
per query as seen by the client, best of 7, milliseconds). Machine:
32 hardware threads on a shared host (run-to-run noise up to ±25 %; the
Phase 4 column comes from an earlier, quieter run). "Phase 4 engine" is the
accepted engine before this phase (commit `978d364`).

| Query | Phase 4 engine | `mode: row` | vectorized, 1 thread | vectorized, 8 threads | vectorized, 32 threads |
|---|---:|---:|---:|---:|---:|
| Q1 filter + COUNT (1M) | 86 | 85 | 3 | 1 | 1 |
| Q2 GROUP BY 20 groups, 5 aggregates | 120 | 120 | 9 | 1 | 1 |
| Q3 GROUP BY 80k groups | 107 | 124 | 7 | 4 | 5 |
| Q4 1M ⋈ 100k + GROUP BY | 212 | 277 | 15 | 4 | 3 |
| Q5 1M ⋈ 250k + GROUP BY | 326 | 371 | 41 | 12 | 13 |
| Q6 filter + top-10 | 107 | 112 | 5 | 2 | 2 |
| Q7 full sort of 1M rows | 523 | 430 | 39 | 18 | 23 |
| Q8 FLOAT64 arithmetic + filter | 128 | 137 | 7 | 1 | 1 |
| Q9 3-way join + GROUP BY | 160 | 179 | 13 | 4 | 3 |
| Q10 DISTINCT (10k values) | 61 | 62 | 3 | 1 | 3 |
| Q11 4-way join, badly ordered | 252 | 140 | 10 | 3 | 2 |
| Q12 GROUP BY 500k groups, MIN(string) | 513 | 600 | 44 | 27 | 26 |

Vectorized execution alone is 10–30× faster than the row baseline; with 8
threads, scan/aggregation/join queries gain another 2–9× (Q7: the scan and
materialization run in parallel, the radix sort itself is one serial
linear pass). With 32 threads the per-query thread start-up and merging
of 32 partial results cost about as much as they gain on 1M-row tables
(hence the default of at most 16 threads).
`mode: row` is the unchanged Phase 4 operator code; it benefits from the
logical optimizer like every mode (Q11: join reordering).

Logical optimizer and join algorithms (vectorized, 8 threads):

| Query | `optimize: true`, hash joins | `optimize: false` | `join: "merge"` |
|---|---:|---:|---:|
| Q4 1M ⋈ 100k + GROUP BY | 4 | 5 | 74 |
| Q5 1M ⋈ 250k + GROUP BY | 12 | 18 | 29 |
| Q9 3-way join + GROUP BY | 4 | 9 | 32 |
| Q11 4-way join, badly ordered | 3 | 13 | 16 |

Without the rewrites, filters stay above the joins and the written join
order is kept (Q9, Q11). The merge join pays for sorting both inputs.

Other measurements (single queries, engine-side time):

* Full results without `result: "count"`: `SELECT * FROM transactions`
  (1M rows, 100 MB of JSON) went from ≈490 ms to ≈270 ms, a 3-column
  integer result from ≈100 ms to ≈20 ms, by serializing straight from the
  column vectors with allocation-free number/date formatting.
* Sorting 1M rows by an INT64 key (`ORDER BY uniq_key`): row engine
  612 ms, first vectorized version (comparator sort) 120 ms, radix sort
  28 ms.
* First 4-way join on fresh tables (statistics computed for the cost
  model): 66 ms → 17 ms after replacing SipHash / per-value `Value`
  construction in the statistics code with typed loops.

Reproduce:

```bash
python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata --jobs 1
python3 implementations/rust/bench/bench.py --engine implementations/rust/bin/polyquery \
    --data /tmp/pqdata/1m --variant '{"mode":"row","threads":1}' \
    --variant '{"mode":"vectorized","threads":1}' --variant '{"mode":"vectorized","threads":8}'
python3 implementations/rust/bench/difftest.py --engine implementations/rust/bin/polyquery --queries 500
```

## Native kernels (M9)

`--native-kernels PATH` loads `libpqkernels` (C ABI v1,
`native-kernels/include/pq_kernels.h`); queries run with the option
`native: true` then use its kernels for filtering, aggregation, bitmap and
hashing work. The capability `native.kernels` is claimed. Without the
option, or when no library is loaded, execution is exactly the engine's
own code (the option is accepted and ignored).

### FFI design (`src/native/`)

* **Loading** (`native::ffi`): the dynamic loader is declared directly
  against the system C library with `unsafe extern "C"` (`dlopen` with
  `RTLD_NOW | RTLD_LOCAL`, `dlsym`, `dlerror`) — no crates. The library is
  loaded once per process when the engine starts (`native::init`, a
  `OnceLock`), `pqk_abi_version()` must return 1, `pqk_init()` runs the
  CPU-feature dispatch (which honours `PQ_KERNELS_VARIANT`), and the handle
  is never closed, so kernels are `&'static`. Startup logs the path, the
  active variant and the available ones (`info`). A library that cannot be
  loaded (missing file, wrong ABI, missing symbol) is logged as a warning
  and the engine runs without it — native kernels are optional
  (native-kernels.md); the conformance results do not depend on them.
* **Function table** (`native::Kernels`): every exported kernel is resolved
  once with `dlsym` into a typed `unsafe extern "C" fn` pointer mirroring
  the header. All calls go through safe wrappers taking slices, which check
  every length the C side relies on (validity bitmaps of `ceil(n/8)` bytes,
  output capacities, group ids, in-bounds gather indices, `n < 2^32`) and
  translate status codes: `pqk_sum_i64` → `Option<i64>` (`None` =
  `PQK_OVERFLOW`), `pqk_group_sum_i64` → `GroupSum::{Exact, Wrapped}`;
  `(size_t)-1`/`PQK_EINVAL` are impossible by construction and assert.
  Outputs are written into spare `Vec` capacity and committed with
  `set_len` only after the kernel returned its count.
* **Per query**: the engine resolves `native: true` to
  `ExecOptions::native: Option<&'static Kernels>`, which is `Copy`, travels
  with the execution context into parallel workers, and is `None` for the
  row-mode reference re-execution used by error replay.
* **Bitmaps**: column chunks store validity as `u64` words, LSB-first,
  which on little-endian is exactly the ABI's byte bitmap;
  `Bitmap::copy_lsb_bytes` extracts the bits of any (unaligned) row window
  word-at-a-time. Engine vectors keep validity as `bool` arrays, which are
  packed (`native::pack_bools`) where a kernel needs a bitmap.

### Which kernels are used where

| Work | Where | Kernels |
|---|---|---|
| **Filters directly above a scan** of a column-oriented table (in-memory column layout or PQCF, lazily decoded chunks included) — vectorized, parallel (each morsel) and row mode | `exec::native_filter` (`NativeFilterScanOp`, `NativeFilterRowOp`) | `pqk_filter_i64` (single conjunct → selection vector), `pqk_filter_i64_bitmap` (several conjuncts), `pqk_compare_i64` (`col <op> col`), `pqk_bitmap_and` / `pqk_bitmap_or` / `pqk_bitmap_andnot` (combining conjuncts, NULL handling, `IS [NOT] NULL`), `pqk_bitmap_popcount` (selection size), `pqk_gather_i64` (copying the selected rows of 64-bit columns out of the chunks) |
| Global `SUM` / `AVG` of INT64 and DECIMAL | `exec::vector::agg` | `pqk_sum_i64` (on `PQK_OVERFLOW` the batch is summed exactly in `i128` by the engine) |
| Grouped `SUM` / `AVG` of INT64 and DECIMAL (and their counts) | `exec::vector::agg` | `pqk_group_sum_i64` into per-group `i64` sums kept beside the exact `i128` accumulators (see below) |
| Global `MIN` / `MAX` of INT64, DECIMAL, TIMESTAMP | `exec::vector::agg` | `pqk_minmax_i64` |
| Global `MIN` / `MAX` of FLOAT64 | `exec::vector::agg` | `pqk_minmax_f64` (a zero result is recomputed by the engine, see below) |
| Global `COUNT(col)` over vectors with NULLs | `exec::vector::agg` | `pqk_bitmap_popcount` |
| Hashing of fixed-width keys (INT64, DECIMAL, DATE, TIMESTAMP, BOOLEAN) for GROUP BY, DISTINCT, hash-join build and probe | `exec::vector::keys`, `exec::vector::hashtab` | `pqk_hash_i64` per batch (single keys: the identical `native::fmix64`), feeding std's SwissTable through a pass-through hasher |

The filter path splits the predicate into conjuncts. *Native conjuncts*
are `col <op> constant` (either side), `col BETWEEN c1 AND c2`, `col1 <op>
col2` over INT64, DECIMAL, DATE (widened to `i64` per window) and
TIMESTAMP columns of the same type, and `col IS [NOT] NULL` on any column;
everything else is the *residual*, kept in its original order. Per window
of 2,048 rows the native conjuncts run on the stored slices; only selected
rows are copied into the output batch, so rejected rows are never
materialized. EXPLAIN shows `"native": <number of kernel conjuncts>` on such
`Filter` nodes and the active variant in the root's `execution` object.
`pqk_compare_fixed` and `pqk_sum_f64` are not used (see below);
`pqk_count_i64` is only exercised by the unit tests, because every scan
below a filter also outputs the filtered column, so a count-only scan never
occurs.

### Identical results with and without kernels

* **Exact constants**: a constant is converted into the column's stored
  integer domain as an exact rational, and comparisons become integer
  ranges: `int_col < 2.5` ⇒ `int_col <= 2`, `int_col = 2.5` ⇒ no row,
  `int_col <> 2.5` ⇒ every non-NULL row, `dec(·,2)_col >= 3` ⇒ unscaled
  `>= 300`, a DATE column against a TIMESTAMP constant compares days
  (`date < TIMESTAMP '…00:00:01'` ⇒ `day <= …`), out-of-range constants
  become constant predicates. A unit test checks the conversion against
  the comparison semantics by brute force. FLOAT64 and string comparisons
  stay in the residual; so do predicates whose column references do not
  carry the stored column types.
* **Three-valued logic and errors**: with a residual, the candidates are
  the rows on which *no* native conjunct is FALSE (rows where one is NULL
  included), the residual is evaluated on them, and a row qualifies if the
  residual and every native conjunct are TRUE. A row with a FALSE native
  conjunct cannot raise an error in the reference engine either (an error
  in an `AND` operand is raised only if no other operand is FALSE). The row
  operator evaluates the residual row by row with the row evaluator and
  returns all qualifying rows before a failing row's error, exactly like
  the row engine (also under `LIMIT`). Predicates with `PQ_SLEEP`,
  subqueries or correlation parameters are not split (their evaluation
  cost/timing must stay as in the reference engine). A window whose chunk
  is not in the expected representation is filtered by the engine's own
  code.
* **Overflow flags**: `pqk_sum_i64` reporting `PQK_OVERFLOW` makes the engine
  sum that batch exactly (`i128`), so a final `SUM` outside INT64 still
  fails with `NUMERIC_OVERFLOW` exactly as before, and intermediate overflow
  that cancels out is not an error. For grouped sums the exact value of a
  group is `i128 sum + i64 kernel sum`; while the kernel answers `PQK_OK`
  every kernel sum is exact. When it answers `PQK_OVERFLOW` ("may have
  wrapped") the batch is undone on the kernel sums (two's-complement
  addition is invertible) and on the counts, all kernel sums are folded into
  the exact accumulators, the batch is added exactly, and the accumulator
  stops using the kernel. Merging partial aggregators and finishing use the
  exact sums.
* **Floats**: `pqk_minmax_f64` is only used for global MIN/MAX; when the
  extreme is zero the engine's loop recomputes it (it keeps the first
  zero's sign; the kernel's lane order could pick `-0.0` instead). Inputs
  are finite (types.md §1), as the kernel requires. `pqk_sum_f64`
  reassociates additions, so FLOAT64 `SUM`/`AVG` keep the engine's
  sequential summation (bit-identical results with and without `native`).
* **Hashing** only changes where keys are stored, not group ids (assigned
  in first-seen order) or any output order; partitioning of parallel
  aggregation keeps its own key hash.

Verification: the conformance suite passes with `--native` (also with
`--modes`, and with each variant forced through `PQ_KERNELS_VARIANT`:
`reference`, `x86_scalar`, `x86_avx2`, `x86_avx512`); unit tests check
every wrapper against reference semantics (when the library is built) and
the constant conversion; `bench/difftest.py --native LIB --simple 0.6`
runs random queries — biased towards the predicate shapes the kernels
evaluate, against PQCF copies with small row groups and row-layout copies,
with default and 37-row morsels — under every option combination with and
without `native: true` and compares them with the row-mode reference (no
differences in 1,250 queries across seeds).

### Measurements

Machine: 32 hardware threads, x86-64 with AVX-512 (variant `x86_avx512`
selected by the dispatcher), shared with other jobs (load ≈ 10; run-to-run
noise ≈ ±15 %, more on the join queries). Data: `pqgen.py generate --scale
1m` (1M rows in `tx`, `items`, `sensor`, `sortk`; 250k `orders`; 100k
customers), CSV-loaded, column layout. Tool: `bench/bench.py --native LIB`
(session protocol, `result: "count"`, client wall-clock, best of 11 runs
taken round-robin over the variants, milliseconds). Q1–Q12 are the Phase 5
queries; N1–N10 were added for the kernels (see `bench.py`).

| Query | 1 thread | 1 thread, `native` | 8 threads | 8 threads, `native` | `mode: row` | row, `native` |
|---|---:|---:|---:|---:|---:|---:|
| Q1 filter + COUNT (decimal + string conjuncts) | 3.4 | 2.5 | 0.8 | 0.6 | 86 | 20 |
| Q2 GROUP BY 20 groups, 5 aggregates | 11.2 | 8.3 | 2.3 | 1.7 | 147 | 142 |
| Q3 GROUP BY 80k int groups | 10.8 | 9.6 | 9.7 | 9.3 | 211 | 194 |
| Q4 1M ⋈ 100k + GROUP BY | 16.7 | 18.7 | 4.6 | 5.3 | 263 | 280 |
| Q5 1M ⋈ 250k + GROUP BY | 26.5 | 29.0 | 9.4 | 10.4 | 333 | 339 |
| Q6 filter + top-10 | 4.8 | 4.6 | 2.0 | 1.9 | 111 | 112 |
| Q7 full sort | 22.8 | 22.0 | 21.4 | 21.3 | 557 | 592 |
| Q8 FLOAT64 arithmetic + filter | 7.4 | 7.3 | 1.3 | 1.2 | 133 | 133 |
| Q9 3-way join + GROUP BY | 12.1 | 12.4 | 3.5 | 3.8 | 171 | 165 |
| Q10 DISTINCT int (10k values) | 2.8 | 3.0 | 1.5 | 1.4 | 62 | 62 |
| Q11 4-way join | 9.4 | 9.3 | 2.9 | 2.9 | 139 | 137 |
| Q12 GROUP BY 500k groups | 42.3 | 42.3 | 25.4 | 29.7 | 575 | 555 |
| N1 `BETWEEN` on int, 0.1 % of 8 wide columns | 5.0 | 3.2 | 1.7 | 1.0 | 125 | 14 |
| N2 int + decimal conjuncts, COUNT | 3.3 | 1.1 | 0.8 | 0.4 | 76 | 4.5 |
| N3 filter + `IS NOT NULL` + global SUM/MIN/MAX | 3.6 | 2.0 | 0.9 | 0.5 | 90 | 9.9 |
| N4 global SUM/MIN/MAX/COUNT, no filter | 6.9 | 2.5 | 1.3 | 0.6 | 96 | 96 |
| N5 DATE + int conjuncts | 0.8 | 0.4 | 0.3 | 0.2 | 22 | 2.1 |
| N6 `col < col` + int conjunct | 2.3 | 1.1 | 0.6 | 0.4 | 99 | 39 |
| N7 GROUP BY int key, SUM | 4.6 | 4.1 | 2.2 | 1.9 | 83 | 84 |
| N8 int-key join, filtered build side | 19.8 | 21.0 | 9.1 | 8.4 | 244 | 230 |
| N9 FLOAT64 global MIN/MAX | 5.0 | 2.3 | 1.0 | 0.7 | 76 | 77 |
| N10 int conjunct + arithmetic residual | 11.6 | 10.8 | 2.0 | 1.6 | 128 | 80 |

* **Filters over scans** gain most: 1.5–3× vectorized (N1, N2, N5, N6),
  because only selected rows are copied out of the column chunks
  (previously every projected column of every row was copied, then
  filtered), and 4–20× in row mode (Q1, N1–N5), where rejected rows are no
  longer materialized as row tuples at all.
* **Global aggregates** (N4, N9, the SUM/MIN/MAX part of N3, Q2): 2–2.8×
  — the kernels replace `i128` accumulation and branchy MIN/MAX loops.
* **Grouping, DISTINCT and joins** (Q3–Q5, Q10, Q12, N7, N8) are within
  noise (±10 %): batch hashing is cheap (≈0.1 ms per 1M keys), but the hash
  table dominates. A hand-written open-addressing table fed with the
  kernel's hashes was 1.5–2× slower than std's SwissTable, so the kernel's
  hashes are fed into std's table instead (keys carry their hash, so the
  table is somewhat larger). Sorting (Q7), top-N and float arithmetic
  (Q6, Q8) use no kernels.
* Variant matters: with `PQ_KERNELS_VARIANT=reference` (portable C) the
  filter queries become 10–50 % *slower* with `native` than without (the
  engine's auto-vectorized Rust beats scalar C), `x86_avx2` and
  `x86_avx512` give the gains above (N6/N9 are faster with AVX-512, the
  others alike).

Kernel micro-benchmarks (`native-kernels/build/x86_64/kernel_bench`,
4M elements, median ns per element, same shared machine):

| Kernel | reference | x86_scalar | x86_avx2 | x86_avx512 |
|---|---:|---:|---:|---:|
| filter_i64 (10 % selected) | 0.81 | 0.69 | 0.44 | 1.25 |
| filter_i64_bitmap | 2.91 | 0.68 | 0.35 | 0.49 |
| count_i64 (BETWEEN) | 0.66 | 0.52 | 0.33 | 0.44 |
| sum_i64 (with validity) | 0.65 | 0.52 | 0.25 | 0.37 |
| minmax_i64 | 0.72 | 0.69 | 0.25 | 0.31 |
| bitmap_popcount | 0.115 | 0.014 | 0.002 | 0.001 |
| hash_i64 | 1.92 | 1.07 | 0.74 | 2.14 |
| compare_i64 | 3.16 | 0.92 | 0.50 | 1.18 |
| group_sum_i64 (1,024 groups) | 1.52 | 0.97 | 0.66 | 0.98 |
| gather_i64 (random) | 9.79 | 6.56 | 4.48 | 6.08 |

At 4M elements these are mostly memory-bound; inside the engine the
kernels run on 2,048-row windows that are in cache.

Reproduce:

```bash
make -C native-kernels
python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata --jobs 1
python3 implementations/rust/bench/bench.py --engine implementations/rust/bin/polyquery \
    --data /tmp/pqdata/1m --native native-kernels/build/x86_64/libpqkernels.so --repeat 11 \
    --variant '{"threads":1}' --variant '{"threads":1,"native":true}' \
    --variant '{"threads":8}' --variant '{"threads":8,"native":true}' \
    --variant '{"mode":"row"}' --variant '{"mode":"row","native":true}'
python3 implementations/rust/bench/difftest.py --engine implementations/rust/bin/polyquery \
    --queries 300 --simple 0.6 --native native-kernels/build/x86_64/libpqkernels.so
```

### Limitations of the native integration

* Filters use the kernels only directly above a table scan of a
  column-oriented table (the planner pushes WHERE/ON conjuncts there);
  filters above joins, index scans and row-layout tables use the engine's
  code. Conjuncts on FLOAT64, BOOLEAN and STRING columns, `NOT BETWEEN`,
  `IN` lists and OR-trees are not native.
* Aggregation kernels apply to global SUM/MIN/MAX/COUNT and grouped
  SUM/AVG/COUNT of 64-bit integer representations; grouped MIN/MAX, DATE
  MIN/MAX and DISTINCT aggregates use the engine's loops. FLOAT64 sums never
  use `pqk_sum_f64` (results would not be bit-identical).
* `pqk_compare_fixed` is unused: string comparisons stay on dictionary
  codes / Rust slices, which the fixed-width byte comparison does not fit.
* The library is located only through `--native-kernels` (no search path);
  a library that fails to load is not fatal, so a typo leaves `native: true`
  without effect (a warning is logged).

## Known limitations

* The HTTP server uses a thread per connection and per running query
  (no event loop); idle keep-alive connections each hold a thread.
* `mode: "row"` is single-threaded by design (it is the baseline).
* Parallelism covers scan pipelines (filters, projections, join probes),
  aggregation, DISTINCT and comparator sorts; merge joins, hash-table
  building and operators above pipeline breakers run serially. Subqueries
  run serially.
* Native kernels: see [Native kernels → Limitations](#limitations-of-the-native-integration).
* Join reordering only considers inner/cross joins; LEFT joins are fixed
  points of the order.
* Indexes are not used for joins (index nested-loop join), for OR
  predicates, or to produce ordered output.
* Correlated subqueries whose correlation is not an equality on a
  parameter-independent input are re-executed per distinct outer value
  (memoized), i.e. nested-loop cost.
* Filters are pushed through projections only for conjuncts over
  pass-through columns (not through aggregations, DISTINCT or LIMIT).
