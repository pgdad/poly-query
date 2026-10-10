# PolyQuery — Clojure engine

An analytical in-memory database engine implementing the PolyQuery
specification (`spec/`) in Clojure. Status: **Phase 1** (protocol, catalog,
CSV/JSON/JSONL ingestion, all data types, the `sql.basic` SQL subset, resource
limits, test functions).

Reported capabilities: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic test.functions`.

## Prerequisites and build

* OpenJDK (tested with 27) — `JAVA_HOME` or `java` on `PATH`
* Clojure CLI (tools.deps) with Clojure 1.12.3 in the local Maven cache
* GNU make

```sh
make build    # AOT-compiles src/ into target/classes, writes target/classpath
make test     # clojure.test unit tests (test/)
make lint     # compiles with *warn-on-reflection*; fails on reflection warnings
make fmt      # whitespace normalisation (no third-party formatter is allowed)
make clean
bin/polyquery session --data-dir DIR    # JSON-lines protocol on stdin/stdout
```

`bin/polyquery` works from any directory; extra JVM flags can be passed via
`POLYQUERY_JAVA_OPTS` (e.g. `-Xmx16g` for very large tables).

## Libraries

None besides Clojure itself (`org.clojure/clojure 1.12.3`, which pulls in its
own `spec.alpha`/`core.specs.alpha`). Everything else — JSON, CSV, the SQL
front end, decimal and calendar arithmetic — is implemented here on top of
`clojure.core` and the JDK. See `ENGINE.json`.

## Architecture

The code is layered so that later phases plug in without a rewrite:

| Layer | Namespaces | Responsibility |
|---|---|---|
| CLI / protocol | `polyquery.main`, `polyquery.protocol` | argument parsing, session/exec loops, request validation, op dispatch (`handle-op` multimethod), response objects |
| Engine pipeline | `polyquery.engine` | parse → analyze → plan → execute → serialize, per-query context |
| Lexer | `polyquery.sql.lexer` | tokens with line/column positions, comments, quoted identifiers, reserved words |
| Parser / AST | `polyquery.sql.parser`, `polyquery.sql.ast` | recursive descent over the **full** v1 grammar (joins, GROUP BY, CTEs, subqueries, CASE, statements) producing a plain-map AST |
| Semantic analysis | `polyquery.sql.analyzer`, `polyquery.sql.functions` | scopes / name resolution, typing and coercion rules, aggregate validation, ORDER BY resolution, constant LIMIT/OFFSET; produces bound expressions |
| Planning | `polyquery.sql.planner` | logical operator tree: values/scan → filter → aggregate → filter (HAVING) → project → sort → limit → project |
| Execution | `polyquery.exec.*` | expression compiler (bound expr → specialised closure), aggregate accumulators, operators as reducibles + transducers, query context (timeout, cancellation, memory budget) |
| Storage / catalog | `polyquery.storage.table`, `polyquery.catalog` | immutable column-wise tables, immutable catalog value held in an atom (snapshot per query, atomic publication of loads) |
| Ingestion | `polyquery.ingest`, `polyquery.ingest.{csv,json,common}` | streaming RFC 4180 reader, strict JSON reader, inference, explicit-schema conversion |
| Values / types | `polyquery.types`, `polyquery.values` | type model, exact DECIMAL arithmetic, proleptic Gregorian calendar, CAST matrix, canonical serialization, total order |
| Utilities | `polyquery.util.{json,text,log}` | JSON reader/writer, ASCII case folding, code-point string order, stderr JSON logs |

### Value representation

Rows are `Object[]`; NULL is `nil` for every type. `BOOLEAN` → `Boolean`,
`INT64` → `Long`, `FLOAT64` → `Double`, `STRING` → `String`, `DATE` → `Long` days
since 1970-01-01, `TIMESTAMP` → `Long` microseconds, `DECIMAL(p,s)` → `Long`
unscaled value (the scale is static, carried by the type). Decimal arithmetic
is exact: long fast paths with `BigInteger` fallbacks wherever an
intermediate (rescaling, sums) may exceed 64 bits; only final results are
range-checked, as the spec requires.

Because all types are static after analysis, the expression compiler emits
type-specialised closures (e.g. INT64 `+` uses `Math/addExact`, DECIMAL
comparison rescales by the static scale difference), so there is no dynamic
type dispatch per row.

## Design decisions (where the spec is silent or open)

* **Unsupported features.** The parser accepts the whole v1 grammar. Valid
  syntax outside `sql.basic` (joins, derived tables, CTEs, GROUP BY, DISTINCT,
  subqueries, CASE/LIKE/BETWEEN/IN, the Phase-2 scalar functions, EXPLAIN,
  CREATE/DROP INDEX) is answered with `UNSUPPORTED`; unknown function names
  are `SEMANTIC_ERROR`. `HAVING` and `COUNT/SUM/AVG(DISTINCT …)` over the
  single whole-table group are supported. Protocol ops of later phases
  (`explain`, `save`, `open`, `stats`) answer `UNSUPPORTED`; `serve` exits 1.
* **CSV whitespace.** For non-STRING columns a field that is empty after
  trimming spaces/tabs is treated like an empty field: it is not considered
  during inference and loads as NULL.
* **CSV structure.** A lone `\r` (not followed by `\n`) is data. Text after a
  closing quote other than a delimiter/record end is an `INGEST_ERROR`; a quote
  inside an unquoted field is literal. A completely empty input with
  `header: true` is an `INGEST_ERROR` (no header).
* **Schemas.** With `header: true` and an explicit schema the reported column
  names are the schema's spellings. An unknown type name in an explicit schema
  is `INVALID_REQUEST`; `header: false` without a schema is `INVALID_REQUEST`.
* **JSON.** A key that collides case-insensitively with another key is an
  `INGEST_ERROR` (duplicate column). A JSON number that is not a finite
  FLOAT64 (e.g. `1e400`) fails conversion (`CONVERSION_ERROR`).
* **CAST from STRING.** All targets trim ASCII spaces/tabs. `TIMESTAMP`
  literals and casts require the time part (date-only text is accepted only by
  ingestion, as the spec says). FLOAT64 → STRING uses Java's shortest
  round-trip text (`1.0`, `1.5E300`).
* **LIMIT/OFFSET.** Must be constant INT64 expressions (`TYPE_ERROR` for other
  types, `SEMANTIC_ERROR` for column references); `NULL` means "no limit".
* **Null type.** Arithmetic on two NULL literals keeps the null type (reported
  as `STRING`); `SUM(NULL)` likewise; `AVG(NULL)` is FLOAT64.
* **Query options.** `mode` accepts `auto`/`row`, `join` any of its documented
  values (no joins exist yet), `threads` ≥ 1 is accepted and ignored
  (execution is single-threaded); other values of known options are
  `UNSUPPORTED`, ill-typed values `INVALID_REQUEST`.
* **Limits.** Defaults: `--max-ingest-bytes` 4 GiB, `--max-table-rows`
  200,000,000, `--max-query-memory-mb` 4096 (approximate accounting of
  materialised rows in sort/aggregation/result), `--max-join-rows`
  100,000,000 (no joins yet). `OutOfMemoryError` and stack overflow are
  reported as `RESOURCE_LIMIT`, any other unexpected exception as
  `INTERNAL_ERROR`; the session never dies on a request.
* **Path safety** is lexical (absolute, empty, NUL or `..` component ⇒
  `ACCESS_DENIED`), so symbolic links inside the data directory work.

## Testing

* `make test` — unit tests for the JSON codec, values/casts/calendar, lexer,
  parser, analyzer, CSV/JSON ingestion, the engine pipeline and the protocol.
* Conformance: `python3 tests/conformance/runner.py --engine
  implementations/clojure/bin/polyquery --phase 1`.

## Known limitations

* Only Phase 1 is implemented (see "Unsupported features").
* Tables are held as boxed values in `Object[]` columns; very large inputs
  need a correspondingly large heap (`POLYQUERY_JAVA_OPTS=-Xmx…`). JSON (array)
  inputs are parsed from a single in-memory string.
* Sorting is not interruptible once the in-memory sort has started (rows are
  checked for timeout/cancellation while being collected).
* Two public conformance cases (`limits_and_output.pqt` lines 34 and 39)
  expect the request's own `id` to be echoed, but the runner replaces every
  request's `id` with its step number before sending it, so no engine can
  satisfy both checks. The engine echoes `id` verbatim as the protocol
  requires.
