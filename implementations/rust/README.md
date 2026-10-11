# PolyQuery — Rust engine (Track A)

An analytical database engine implementing the PolyQuery specification
(`spec/`) in Rust, using **only the standard library** (no crates).

Status: **Phase 5** (optimization). Capabilities claimed:
`phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`, `sql.basic`,
`test.functions`, `phase2`, `sql.groupby`, `sql.join`, `sql.functions`,
`sql.subquery`, `sql.cte`, `sql.correlated_subquery`, `phase3`,
`storage.pqcf`, `storage.mmap`, `index.hash`, `index.btree`, `phase4`,
`http.streaming`, `phase5`, `exec.row`, `exec.vectorized`, `exec.parallel`,
`join.hash`, `join.merge`, `join.nested_loop`.

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

None. `ENGINE.json` lists `"libraries": []`.

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
| `threads: N` | parallel scans, filters, projections, join probes, aggregation and sorting in vectorized mode; default `--threads` (CPU count). `threads: 1` is fully serial |
| `join: "hash"` | hash join for equi-joins (other joins: nested loop) |
| `join: "merge"` | sort-merge join for equi-joins (INNER and LEFT) |
| `join: "nested_loop"` | nested-loop join for every join, including equi-joins |
| `join: "auto"` (default) | cost-based: hash join for equi-joins, building on the input with the smaller estimated cardinality (statistics-based estimates); nested loop for non-equi joins |
| `optimize: false` | disables the logical rewrites (see below) |
| `native: true` | accepted; native kernels are optional (native-kernels.md) and none are loaded, so execution is the same as without it. `--native-kernels PATH` is accepted and ignored |

EXPLAIN shows `HashJoin`, `MergeJoin` or `NestedLoopJoin` accordingly
(`MergeJoin` has `keys` and `residual` like `HashJoin`).

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
  `IS NULL`, `BETWEEN`, constant `IN` lists (hash set) and `LIKE` run as
  monomorphized loops over slices (one closure type per operator, so the
  compiler emits branch-free, auto-vectorized SIMD code; overflow checks
  accumulate flags instead of branching). Comparisons and `LIKE`/`IN` on a
  dictionary column are evaluated once per dictionary entry. `AND`, `OR`
  and `CASE` evaluate lazily-evaluated operands only on the rows that need
  them (like row mode). Everything else (functions, casts, subqueries) is
  evaluated element-wise by the row evaluator on the vectorized child
  results, so semantics are shared, not duplicated.
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
* `result: "count"` counts whole batches without converting them to rows.

### Parallel execution (`exec/parallel.rs`)

Morsel-driven: a scan pipeline (scan → filters / projections / probe side
of hash or nested-loop joins) is cut into morsels of 32,768 rows (within
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
* Tables smaller than two morsels, and subqueries, run serially.
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
both succeed).

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
code, no runtime dispatch).

### Measurements

Data: `pqgen.py generate --scale 1m` (transactions, order_items, sensor
readings and sort keys: 1M rows each; orders 250k; customers 100k;
products 20k), loaded as CSV with the generated schemas (column layout).
Tool: `bench/bench.py` (session protocol, `result: "count"`, wall-clock
per query as seen by the client, best of 5, milliseconds). Machine:
32 hardware threads (shared host, so ±10 % noise). "Phase 4 engine" is the
accepted engine before this phase (commit `978d364`).

| Query | Phase 4 engine | `mode: row` | vectorized, 1 thread | vectorized, 8 threads | default (vectorized, 32 threads) |
|---|---:|---:|---:|---:|---:|
| Q1 filter + COUNT (1M) | 86 | 83 | 3 | 1 | 1 |
| Q2 GROUP BY 20 groups, 5 aggregates | 120 | 118 | 8 | 1 | 1 |
| Q3 GROUP BY 80k groups | 107 | 115 | 7 | 4 | 5 |
| Q4 1M ⋈ 100k + GROUP BY | 212 | 228 | 16 | 4 | 3 |
| Q5 1M ⋈ 250k + GROUP BY | 326 | 354 | 36 | 13 | 10 |
| Q6 filter + top-10 | 107 | 111 | 5 | 2 | 2 |
| Q7 full sort of 1M rows | 523 | 469 | 25 | 25 | 25 |
| Q8 FLOAT64 arithmetic + filter | 128 | 131 | 7 | 1 | 1 |
| Q9 3-way join + GROUP BY | 160 | 171 | 12 | 4 | 3 |
| Q10 DISTINCT (10k values) | 61 | 64 | 3 | 3 | 3 |
| Q11 4-way join, badly ordered | 252 | 121 | 9 | 2 | 2 |
| Q12 GROUP BY 500k groups, MIN(string) | 513 | 555 | 47 | 29 | 28 |

Vectorized execution alone is 9–30× faster than the row baseline; with 8
threads scan/aggregation queries gain another 3–8× (the radix sort of
Q7 is a serial linear pass and does not scale). `mode: row`
is the unchanged Phase 4 operator code; it benefits from the logical
optimizer like every mode (Q11: join reordering).

Logical optimizer and join algorithms (vectorized, 8 threads):

| Query | `optimize: true`, hash joins | `optimize: false` | `join: "merge"` |
|---|---:|---:|---:|
| Q4 1M ⋈ 100k + GROUP BY | 4 | 4 | 72 |
| Q5 1M ⋈ 250k + GROUP BY | 13 | 11 | 27 |
| Q9 3-way join + GROUP BY | 4 | 9 | 31 |
| Q11 4-way join, badly ordered | 2 | 17 | 16 |

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

## Known limitations

* The HTTP server uses a thread per connection and per running query
  (no event loop); idle keep-alive connections each hold a thread.
* `mode: "row"` is single-threaded by design (it is the baseline).
* Parallelism covers scan pipelines (filters, projections, join probes),
  aggregation, DISTINCT and comparator sorts; merge joins, hash-table
  building and operators above pipeline breakers run serially. Subqueries
  run serially.
* Native kernels are not loaded (`native` has no effect).
* Join reordering only considers inner/cross joins; LEFT joins are fixed
  points of the order.
* Indexes are not used for joins (index nested-loop join), for OR
  predicates, or to produce ordered output.
* Correlated subqueries whose correlation is not an equality on a
  parameter-independent input are re-executed per distinct outer value
  (memoized), i.e. nested-loop cost.
* Filters are pushed through projections only for conjuncts over
  pass-through columns (not through aggregations, DISTINCT or LIMIT).
