# PolyQuery — Rust engine (Track A)

An analytical database engine implementing the PolyQuery specification
(`spec/`) in Rust, using **only the standard library** (no crates).

Status: **Phase 1** (in-memory data engine). Capabilities claimed:
`phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`, `sql.basic`,
`test.functions`.

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
| `storage` | immutable column-oriented tables: one typed vector per column plus a validity bitmap |
| `catalog` | case-insensitive table map of `Arc<Table>` (queries hold snapshots) |
| `ingest` | CSV (RFC 4180 + spec rules), JSON array and JSON Lines readers, type inference, explicit schemas |
| `sql` | lexer (positions for `PARSE_ERROR` details), AST, recursive-descent parser for the **full** v1 grammar |
| `planner` | semantic analysis (`binder`: name resolution, typing, aggregate validation, ORDER BY resolution, column pruning) producing a `LogicalPlan` of bound, typed `Expr`s |
| `exec` | pull-based (Volcano) operators: scan, filter, project, hash aggregate, sort (with top-N), limit; expression evaluator; per-query context (timeout, cancellation flag, memory budget) |
| `engine` | transport-independent facade: load/drop/reset/query, path safety, limits |
| `protocol` | request validation, response building, `session` (JSON lines) and `exec` modes |
| `cli` | argument parsing (unknown options ⇒ exit 2) |

Processing of a query: `lex → parse (AST) → bind/type (logical plan) →
build operators → execute`. Errors found before execution (parse, semantic,
type) are reported without executing anything.

### Extension points for later phases

* The parser already accepts the complete grammar (joins, GROUP BY/HAVING,
  DISTINCT, CTEs, subqueries, CASE/LIKE/BETWEEN/IN, CREATE/DROP INDEX,
  EXPLAIN); the binder rejects what Phase 1 does not implement with
  `UNSUPPORTED`, so later phases only extend the binder/executor.
* Scopes support multiple range variables (joins); the aggregate operator
  already supports grouping keys; `LogicalPlan::to_json` renders the EXPLAIN
  node format of indexes-and-planning.md §4.
* Storage is columnar with typed vectors and validity bitmaps (PQCF and
  vectorized execution can build on it); tables are shared immutably via
  `Arc`, as required for snapshot isolation in the server phase.
* `ExecContext` carries the deadline, a cancellation flag and the memory
  budget, checked by operators every 1024 rows and by `PQ_SLEEP` every 5 ms.

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
  `INVALID_REQUEST`; unsupported values (`mode: "vectorized"`, unknown
  `result`/`join` values) are `UNSUPPORTED`. `threads`, `join`, `optimize`,
  `use_indexes` and `native` are accepted and have no effect in Phase 1.
* **Ops of later phases** (`explain`, `save`, `open`, `stats`) answer
  `UNSUPPORTED`; `serve` exits with status 1.
* **Robustness**: requests are processed on a thread with a 256 MiB stack;
  the parser limits nesting depth and operator-chain length (10,000) and the
  JSON parser depth (512);
  panics are caught and reported as `INTERNAL_ERROR` (logged to stderr).
* **Defaults**: `--max-query-memory-mb 4096`, `--max-ingest-bytes 4 GiB`,
  `--max-table-rows 500,000,000`; memory accounting is approximate and covers
  materializing operators (sort, aggregation state, result rows).

## Known limitations

* Phase 2+ features (joins, GROUP BY/HAVING, DISTINCT, subqueries, CTEs,
  scalar functions other than `PQ_SLEEP`, CASE/LIKE/BETWEEN/IN, indexes,
  EXPLAIN, PQCF storage, HTTP server) are not implemented and are reported as
  `UNSUPPORTED`. (`COUNT(DISTINCT x)` and other `DISTINCT` aggregates already
  work.)
* Execution is single-threaded and row-at-a-time.
* Two public conformance cases (`limits_and_output.pqt` lines 34 and 39)
  cannot pass with the provided runner: it replaces every request's `id` with
  its step number and then requires both that the response id equals the step
  number and that it equals the id written in the test. The engine echoes ids
  verbatim (verified manually with nested-object and string ids).
