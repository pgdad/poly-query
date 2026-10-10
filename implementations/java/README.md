# PolyQuery — Java engine

An in-memory analytical database engine implementing the PolyQuery specification
(`spec/`), currently at **Phase 1** (protocol, catalog, CSV/JSON/JSONL ingestion,
all data types, the `sql.basic` SQL subset, resource limits, test functions).

## Prerequisites and build

* OpenJDK 27 (`java`, `javac`, `jar` on `PATH`, or `JAVA_HOME` set). No other tools,
  no network, no third-party libraries (Track A: standard library only).
* `make build` — compiles with `javac --release 27` into `build/polyquery.jar`.
* `make test` — builds and runs the unit tests (`src/test/java`, plain Java with a small
  runner in `polyquery.TestMain`; JUnit is not used).
* `make lint` — compiles with `-Xlint:all -Werror`.
* `make fmt` — no-op (the JDK has no formatter); code follows standard Java style,
  4-space indentation, 120 columns.
* `make clean`.

`bin/polyquery` is a POSIX shell launcher that works from any directory (it resolves its
own location). Extra JVM flags can be passed with `POLYQUERY_JAVA_OPTS`.

```
bin/polyquery version | capabilities
bin/polyquery session [--data-dir DIR] [--enable-test-functions] [--log-level LEVEL] ...
bin/polyquery exec --request FILE|- [options]
```

## Libraries

None. `ENGINE.json`: `{"language": "java", "track": "A", "libraries": []}`.

## Architecture

Source lives in `src/main/java/polyquery/`, one package per layer:

| Package | Responsibility |
|---|---|
| `common` | `ErrorCode`, `PolyQueryException` (code + message + details), ASCII name folding |
| `types` | `DataType`, value representation, exact DECIMAL arithmetic (`Decimals`), DATE/TIMESTAMP (`DateTimes`), strict text parsers, `Casts`, ordering/text (`Values`) |
| `json` | Strict RFC 8259 parser (keeps number literal text, optional duplicate-key rejection) and writer |
| `sql.lexer` | Tokenizer with line/column positions, reserved keywords, comments |
| `sql.ast` | Immutable AST (sealed interfaces + records) for the **full** v1 grammar |
| `sql.parser` | Recursive-descent parser for the full grammar (WITH, joins, subqueries, CASE, IN, LIKE, BETWEEN, EXPLAIN, CREATE/DROP INDEX) |
| `sql.analyzer` | Semantic analysis: scopes/range variables, name resolution, typing and implicit coercions, aggregate validation, ORDER BY resolution → `BoundQuery`; `LogicalPlanner` → logical plan |
| `plan` | Bound (typed) expressions, aggregate calls, logical plan nodes |
| `exec` | Physical planning, expression compiler (bound expression → closures), Volcano operators (scan, filter, project, hash aggregate, sort, limit), `ExecContext` (timeout, memory budget, row limit) |
| `storage` | Immutable columnar tables (`ColumnVector`: primitive arrays + null bitmaps), thread-safe `Catalog` |
| `ingest` | CSV parser + type inference, JSON / JSON Lines ingestion |
| `engine` | `Engine` façade used by every front-end; config; path safety |
| `protocol` | JSON request handling/validation, result serialization, structured logger |
| `Main` | CLI (`version`, `capabilities`, `session`, `exec`) |

Query pipeline: **lex → parse (AST) → analyze (bind & type) → logical plan → physical
plan → execute**. Every stage is a separate class so later phases can slot in: the
parser already accepts the full grammar; the analyzer currently rejects Phase-2
constructs with `UNSUPPORTED`; the aggregate operator is already a hash aggregate with
group keys; storage is columnar so column pruning, statistics, PQCF and vectorized
execution can be added without changing the table model; the catalog stores immutable
tables in a concurrent map so snapshot isolation for the HTTP server falls out naturally.

### Runtime value representation

BOOLEAN → `Boolean`, INT64 → `Long`, DECIMAL(p,s) → `Long` unscaled value (scale from
the static type), FLOAT64 → `Double`, STRING → `String`, DATE → `Integer` days since
1970-01-01, TIMESTAMP → `Long` microseconds since epoch, NULL → `null`. Types are always
known statically, so values carry no tags.

DECIMAL arithmetic is exact: 64-bit fast paths with `Math.*Exact`, falling back to
`BigInteger` for intermediates; any result beyond 18 digits is `NUMERIC_OVERFLOW`.
SUM/AVG over INT64/DECIMAL accumulate exactly (widening to `BigInteger`); only the final
INT64/DECIMAL result is range-checked.

## Design decisions / interpretations

Where the spec leaves room, these choices were made:

* **Phase-2 syntax** (DISTINCT, GROUP BY/HAVING, joins, derived tables, CTEs,
  subqueries, CASE/IN/LIKE/BETWEEN, Phase-2 scalar functions, COUNT(DISTINCT),
  EXPLAIN, CREATE/DROP INDEX, UNION, RIGHT/FULL JOIN) is parsed and answered with
  `UNSUPPORTED`. Unknown function names are `SEMANTIC_ERROR`.
* `PQ_SLEEP` exists only with `--enable-test-functions` (otherwise it is an unknown
  function). It sleeps in ≤5 ms slices and checks the query deadline, so `timeout_ms`
  is honoured within a few ms. Operators check the deadline every 1024 rows.
* Comparing INT64 with DECIMAL(p,s) promotes the integer to DECIMAL(18,s) as types.md
  §2 says, so an integer that needs more than 18 digits at that scale is
  `NUMERIC_OVERFLOW`. In arithmetic, INT64 becomes DECIMAL(18,0) (so `1.5 * 2` is
  DECIMAL(18,1)).
* A NULL literal in arithmetic takes the type family of the other operand (`1 + NULL` is
  INT64); `NULL + NULL`, `-NULL` and `MIN(NULL)` keep the null type (reported as STRING).
  `SUM(NULL)` is INT64 and `AVG(NULL)` is FLOAT64.
* `LIMIT NULL` / `OFFSET NULL` mean "no limit" / 0. Non-INT64 constants are
  `TYPE_ERROR`, non-constant expressions `SEMANTIC_ERROR`, negative values
  `INVALID_ARGUMENT`. `ORDER BY 0` is out of range (`SEMANTIC_ERROR`).
* `TIMESTAMP '…'` literals need a time part. `CAST('YYYY-MM-DD' AS TIMESTAMP)` is
  accepted (midnight), as in ingestion. CAST from STRING trims all whitespace.
* FLOAT64 → DECIMAL rounding uses the shortest decimal representation of the double
  (`2.675e0` → `2.68`). FLOAT64 → STRING uses Java's shortest round-trip text
  (`1.0E20`); FLOAT64 JSON output uses the same (valid JSON), with `-0.0` as `0.0`.
* CSV: a quote inside an unquoted field, or text after a closing quote, is
  `INGEST_ERROR` (strict RFC 4180). A whitespace-only field is ignored for type inference
  and becomes NULL in non-STRING columns (kept verbatim in STRING columns). An empty
  input with `header: true` yields an empty table with no columns (or with the explicit
  schema's columns). `header: false` without a schema is `INVALID_REQUEST`.
* JSON: keys that differ only in case are duplicate column names → `INGEST_ERROR`.
  Inferred FLOAT64 numbers that overflow are `INGEST_ERROR`.
* An invalid type name in a `load` schema is `INVALID_REQUEST`; duplicate or empty
  schema column names are `INGEST_ERROR`.
* Query options: `mode` accepts `auto`/`row` (this engine is row-at-a-time);
  `vectorized` is `UNSUPPORTED`. `threads`, `join`, `optimize`, `use_indexes`, `native`
  and `query_id` are validated and otherwise ignored. Ill-typed option values are
  `INVALID_REQUEST`; unknown values of known enum options are `UNSUPPORTED`.
* The per-query memory budget (`--max-query-memory-mb`, default 4096, capped at 70% of
  the JVM heap) is enforced approximately for sort buffers, aggregation groups and
  result materialization. `OutOfMemoryError` and `StackOverflowError` are reported as
  `RESOURCE_LIMIT`. Requests run on a thread with a 512 MiB stack, and parser nesting is
  limited to depth 1000 (`PARSE_ERROR` beyond).
* Names (tables, columns, aliases) are matched with ASCII-only case folding.

## Testing

```
make -C implementations/java build test
python3 tests/conformance/runner.py --engine implementations/java/bin/polyquery --phase 1
```

Two public cases cannot pass with the current runner, whatever the engine does:
`limits_and_output.pqt` lines 34 and 39 check that a request's `id` is echoed back
verbatim, but `runner.py` replaces every request's `id` with its step index (`req["id"] = k`)
and separately requires the response id to equal that index. The engine echoes ids
verbatim, including nested objects and number literals in their original spelling (see
`ProtocolTest.testRequests`). Running these requests directly through
`bin/polyquery session` shows the correct behaviour.

## Known limitations

* Phase 1 only: no joins, grouping, subqueries, CTEs, Phase-2 functions, EXPLAIN,
  indexes, PQCF storage, HTTP server (`serve` exits with status 1) or vectorized/parallel
  execution yet.
* Execution is single-threaded and row-at-a-time.
* Each ingestion reads the whole input into memory before parsing.
