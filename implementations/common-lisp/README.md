# PolyQuery — Common Lisp implementation

An in-memory analytical SQL engine implementing the PolyQuery specification
(`spec/`) in ANSI Common Lisp on SBCL. Current scope: **Phases 1–4**
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
cancellation (explicit and on client disconnect) and graceful shutdown.

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

None. Only ANSI Common Lisp, SBCL extensions (`sb-ext`, `sb-sys`, `sb-int`,
`sb-impl`, `sb-kernel`, `sb-thread`, `sb-unix`) and the bundled
`asdf`/`uiop`/`sb-posix`/`sb-bsd-sockets`/`sb-rt` contribs are used (`ENGINE.json` lists
no libraries). `sb-posix` provides `mmap`, `fsync`, `rename` and `fstat`;
`sb-bsd-sockets` provides TCP sockets; threads, mutexes and condition
variables come from `sb-thread`.

## Capabilities

`phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`, `sql.basic`,
`test.functions`, `phase2`, `sql.groupby`, `sql.join`, `sql.functions`,
`sql.subquery`, `sql.cte`, `sql.correlated_subquery`, `phase3`,
`storage.pqcf`, `storage.mmap`, `index.hash`, `index.btree`, `phase4`,
`http.streaming`.

## Architecture

A statement goes through the stages required by the spec, each with its own
data structures and module (`src/`, loaded in this order by `polyquery.asd`):

```
SQL text --lexer--> tokens --parser--> AST --binder--> BOUND-QUERY
  --planner--> logical plan (LP-*) --optimizer--> logical plan
  --physical planner--> physical plan (PP-*) --compiler--> iterators --> rows
```

| Layer | Files | Responsibility |
|---|---|---|
| util | `errors`, `numbers`, `json` | `pq-error` condition with stable codes; exact numeric text parsing, correctly rounded float parsing, shortest round-trip float printing; strict RFC 8259 JSON reader/writer |
| types | `types`, `temporal`, `values`, `compare` | type representation, aliases, promotion lattice and result-type unification; DATE/TIMESTAMP calendar math; text conversion, `CAST`, canonical serialization; total ordering |
| storage | `columns`, `table`, `stats`, `index`, `catalog`, `binary`, `files`, `pqcf-write`, `pqcf-read` | typed column vectors with validity bitmaps and dictionary encoding; immutable tables in row or column layout split into segments; lazily computed column statistics; hash and sorted-permutation (B-tree equivalent) indexes; catalog of tables and global index names with atomic publish (mutex-protected); little-endian codec, CRC-32, strict UTF-8; crash-safe file replacement and mmap/buffered file sources; PQCF v1 writer and validating reader |
| ingest | `common`, `csv`, `json` | CSV parsing on raw UTF-8 octets, JSON/JSONL; type inference and explicit-schema conversion |
| sql | `lexer`, `ast`, `parser` | tokenizer with line/column positions; AST structures; recursive-descent parser for the full grammar of `grammar.md` (`PARSE_ERROR` carries `details.line`/`column`) |
| analyzer | `bound`, `functions`, `binder`, `query` | semantic validation. `bound`: bound expression nodes and the analysed-query representation; `functions`: the scalar function registry (typing + implementation per function); `binder`: expressions — name resolution through nested scopes, typing, implicit promotions, CASE/LIKE/BETWEEN/IN, subqueries; `query`: CTEs, FROM/joins/derived tables, `*` expansion, output naming, GROUP BY alias/ordinal resolution, the structural grouping rewrite, HAVING, DISTINCT, ORDER BY resolution, constant LIMIT/OFFSET |
| plan | `logical`, `optimizer`, `access`, `physical` | logical plan construction (`Scan`, `Values`, `Filter`, `Join`, `Aggregate`, `Project`, `Distinct`, `Sort`, `Limit`); logical rewrites (predicate pushdown, column pruning); access paths (predicate analysis, selectivity and cardinality estimates, index choice, segment skipping); physical operator selection and EXPLAIN JSON rendering |
| exec | `context`, `expressions`, `aggregates`, `operators` | query context (deadline, cancellation flag, memory budget, join row limit); expression compiler to closures (incl. subquery evaluation); aggregate accumulators; Volcano-style operators |
| protocol | `requests`, `cli` | JSON-lines request dispatch (`query`, `explain`, catalog ops), validation and responses, structured logging; CLI modes `version`, `capabilities`, `session`, `exec`, `serve` |
| server | `http`, `scheduler`, `metrics`, `server` | HTTP/1.1 message parsing and response writing; admission control (worker pool, bounded queue, query registry, timeouts, cancellation, bounded streaming channel); Prometheus counters; routing, endpoint handlers, connection threads, listener and graceful shutdown |

### Values and expressions

Values are untyped at runtime; the static type in the plan decides their
meaning: NULL is `:null`, BOOLEAN is `t`/`nil`, INT64 an integer, FLOAT64 a
`double-float`, DECIMAL(p,s) its unscaled integer, STRING a Lisp string,
DATE days and TIMESTAMP microseconds since the epoch. Exactness comes from
Lisp's unbounded integers: INT64 and DECIMAL arithmetic is computed exactly
and range-checked afterwards; SUM/AVG accumulate exactly.

Bound expressions (`B-LITERAL`, `B-COLUMN`, `B-PARAM`, `B-OP`, `B-AGG`) are
typed trees; every column reference is a position in the row of the operator
that evaluates it. Expressions are compiled once per statement into closures
with all type dispatch (promotions, comparators, hash-key normalization) done
at compile time.

### Planning

* **Logical plan.** The FROM row is the concatenation of all range
  variables' columns; joins associate left to right; derived tables and CTE
  references are planned as nested sub-plans. Aggregated queries project from
  an aggregation row `[group keys..., aggregates...]` produced by the
  structural GROUP BY rewrite of semantics.md §5.
* **Optimizer.** *Predicate pushdown* splits WHERE and ON conditions into
  conjuncts and moves each one to the lowest valid place: the preserved side
  of a LEFT JOIN, either side of an inner join, or an inner join's condition
  (so comma joins with a WHERE equality become hash joins); conjuncts on the
  NULL-supplying side of a LEFT JOIN stay above it. *Column pruning*
  propagates the set of required columns top-down and renumbers column
  positions, so every `TableScan` reads only referenced columns.
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
  right input), others `NestedLoopJoin` (`join_type` INNER/LEFT/CROSS);
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
  `(signed-byte 64)` for INT64/DECIMAL/DATE/TIMESTAMP, `double-float` for
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
* **PQCF writing** (`save`): row-group-major chunks at 8-byte aligned
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
its analysed query, physical plan and a *parameter environment*. While a
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

### Extensibility notes (later phases)

* Physical operator choice is isolated in `plan/physical.lisp`; forced join
  algorithms (Phase 5) and index scans (Phase 3) are additional physical
  operators. Column pruning already yields exact `TableScan` column sets and
  pushdown places single-table conjuncts directly above the scans, where an
  index scan can absorb them.
* The catalog is mutex-protected and tables are immutable, matching the
  snapshot isolation model of concurrency.md; all query state lives in the
  query context and in per-statement compiled closures. Lazily decoded
  chunks and cached statistics are written idempotently (a race only
  duplicates work).

## Decisions on points the spec leaves open

### General

* `UNION`, `RIGHT`/`FULL` joins answer `UNSUPPORTED` (reserved syntax).
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
* Query option values (for `query` and `explain`): `mode` accepts
  `auto`/`row` (`vectorized` is `UNSUPPORTED`), `threads` ≥ 1 is accepted
  (execution is single-threaded, results are identical),
  `use_indexes: false` disables index scans; `join`/`optimize`/`native` are
  validated and otherwise have no effect yet.
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

* The Phase 5 execution options are not implemented yet.
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
* Execution is single-threaded and row-at-a-time.
* Correlated subqueries are executed per distinct outer value (memoized);
  only equality correlations directly on a base-table scan use a hash lookup,
  other correlated shapes rescan their inputs per evaluation.
* Loads materialize the whole input in memory (file octets plus parsed fields)
  before building columns.
