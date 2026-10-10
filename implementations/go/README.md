# PolyQuery — Go engine

An analytical in-memory database engine implementing the PolyQuery
specification (`spec/`), currently **Phase 1** (in-memory data engine).

## Build prerequisites

* Go 1.27 (tested with `go1.27.1`), standard library only — `go.mod` has no
  requirements; builds work offline (`GOTOOLCHAIN=local`, `GOPROXY=off`).
* `make`.

```bash
make build      # → build/polyquery
make test       # unit tests (go test ./...)
make lint       # go vet + gofmt check
make fmt        # gofmt -w
make clean
bin/polyquery session --data-dir DIR    # launcher; builds on first use if needed
```

## Libraries

None. Only the Go standard library is used (`ENGINE.json` lists no libraries).

## Capabilities

`phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`, `sql.basic`,
`test.functions`.

## Design overview

Processing follows the spec pipeline with one package per stage:

| Package | Responsibility |
|---|---|
| `cmd/polyquery` | CLI: modes `version`, `capabilities`, `session`, `exec` (`serve` is reserved for Phase 4), option parsing, JSON logs on stderr |
| `internal/protocol` | JSON request decoding/validation, op dispatch, single-line JSON response writer, session loop and exec mode |
| `internal/engine` | Facade owning config + catalog: path safety, file loading with limits, query pipeline (parse → analyze → build → execute), `max_rows`, timeouts |
| `internal/sql/lexer` | Tokens with 1-based line/column positions; comments, quoted identifiers, reserved keywords |
| `internal/sql/ast`, `internal/sql/parser` | Recursive-descent parser for the **full** v1 grammar (joins, GROUP BY, CTEs, subqueries, CASE, BETWEEN/IN/LIKE, EXPLAIN, CREATE/DROP INDEX) producing an AST; `PARSE_ERROR` carries positions |
| `internal/analyzer` | Semantic analysis: name resolution (case-insensitive), typing with implicit numeric/temporal promotion casts, aggregate validation, ORDER BY resolution (ordinals, output aliases, hidden sort columns), LIMIT/OFFSET constant checks; builds the logical plan. Phase-2 constructs are rejected with `UNSUPPORTED` |
| `internal/plan` | Bound typed expressions and logical plan nodes (`Scan`, `Values`, `Filter`, `Aggregate`, `Project`, `Sort`, `Limit`) |
| `internal/exec` | Physical execution: expressions compiled to closures; pull-based (Volcano) operators; top-N heap for `ORDER BY … LIMIT`; aggregate accumulators; cancellation checks; approximate memory accounting |
| `internal/storage` | Immutable column-oriented tables (typed vectors + null flags) and a thread-safe catalog with atomic publish/replace |
| `internal/ingest` | CSV (RFC 4180 + spec rules) and strict JSON/JSONL parsers, schema inference and explicit-schema conversion |
| `internal/types` | Type system: canonical names/aliases, values, exact DECIMAL arithmetic (int64 unscaled + 128-bit products, big-int sums), proleptic Gregorian DATE/TIMESTAMP, CAST matrix, text parsing/formatting, ordering |
| `internal/errs` | Structured errors with stable codes and optional details |

Extension points for later phases: the parser already produces ASTs for the
full grammar; the logical plan's `Aggregate` node carries (currently empty)
grouping keys; `Scan` carries the needed column set (column pruning);
operators are behind a small `Operator` interface so join, hash-aggregate,
index-scan and vectorized operators can be added; the catalog is guarded by a
RW lock and tables are immutable snapshots (ready for concurrent readers).

### Value representation

A `types.Value` is `{Null, I int64, F float64, S string}`; the static type of
the producing expression decides which field is meaningful (INT64, BOOLEAN,
DECIMAL unscaled, DATE days and TIMESTAMP microseconds share `I`). Tables store
typed vectors per column.

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
* **Query options**: `mode` accepts `auto`/`row` (`vectorized` ⇒ `UNSUPPORTED`);
  `threads`, `join`, `optimize`, `use_indexes`, `native`, `query_id` are
  validated and accepted (single-threaded execution, no joins yet). Ill-typed
  option values ⇒ `INVALID_REQUEST`.
* **Ops of later phases** (`explain`, `save`, `open`, `stats`) answer
  `UNSUPPORTED`; unknown ops answer `INVALID_REQUEST`. `serve` exits with status 1.
* Aggregates with `DISTINCT` (`COUNT(DISTINCT x)` etc.) are implemented even
  though they belong to `sql.groupby`; other Phase-2 SQL (GROUP BY, HAVING,
  SELECT DISTINCT, joins, subqueries, CTEs, CASE, BETWEEN, IN, LIKE, scalar
  functions, EXPLAIN, index DDL) is parsed and answered with `UNSUPPORTED`.
* Defaults: `--max-query-memory-mb 4096`, `--max-ingest-bytes 4 GiB`,
  `--max-table-rows 500000000`. Memory accounting covers retained rows (sort
  buffers and materialized results).

## Known limitations

* Phase 2+ features (see above) are not implemented yet; no HTTP server.
* Execution is single-threaded and row-at-a-time.
* Sorting is not interruptible by a timeout while the in-memory sort itself
  runs (input consumption is).
* Two public conformance cases (`limits_and_output.pqt` lines 34 and 39) cannot
  pass with the provided runner: it replaces every request's `id` with the step
  index before sending (`runner.py`, `req["id"] = k`) and then also expects the
  test's original `id` (`{"nested":[1,"x"]}` / `"abc"`) in the response. The
  engine echoes ids verbatim (covered by unit tests).
