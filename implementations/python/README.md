# PolyQuery — Python engine

An analytical database engine implementing the PolyQuery specification
(`spec/`) in pure Python. Current status: **Phase 1** (in-memory data engine).

Capabilities reported: `phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`,
`sql.basic`, `test.functions`.

## Build prerequisites

* CPython 3.14 (`python3` on `PATH`). No other dependencies.
* **Libraries:** none. Only the Python standard library is used
  (`json`, `csv`, `decimal`-free integer arithmetic, `datetime`, `argparse`,
  `unittest`, …). `sqlite3` is not used.

```sh
make build    # byte-compiles the package and smoke-tests the launcher
make test     # unit tests (unittest)
make lint     # compile with -W error + small stdlib-only lint (tools/lint.py)
make fmt      # whitespace normalisation (tools/fmt.py); no third-party formatter
make clean
bin/polyquery session --data-dir DIR     # JSON-lines protocol on stdin/stdout
bin/polyquery exec --request FILE|-      # one request or an array of requests
bin/polyquery version | capabilities
```

`bin/polyquery` is a POSIX shell launcher that resolves its own location and
runs `entry.py` with `python3 -I` (isolated mode: neither the current directory
nor `PYTHON*` environment variables can influence module loading).

## Architecture

Strictly layered; each layer only depends on the ones above it in this list.

| Package | Responsibility |
|---|---|
| `polyquery/datatypes.py`, `values.py`, `names.py` | SQL types, runtime value representation, exact decimal / date / timestamp helpers, ASCII identifier folding |
| `polyquery/storage/` | `Catalog` and immutable column-oriented `Table`s (one Python list per column) |
| `polyquery/ingest/` | CSV (stdlib `csv` reader in `QUOTE_NOTNULL` mode to distinguish `""` from empty) and JSON/JSONL ingestion, type inference, explicit-schema conversion, ingestion limits |
| `polyquery/sql/` | Lexer (tokens with line/column), full SQL v1 recursive-descent parser, AST |
| `polyquery/analysis/` | Binder: name resolution, typing rules (promotion lattice, CAST matrix), aggregate extraction, ORDER BY resolution → `BoundQuery` of immutable, structurally comparable bound expressions |
| `polyquery/planner/` | Logical plan nodes (`TableScan`, `SingleRow`, `Filter`, `Aggregate`, `Project`, `Distinct`, `Sort`, `Limit`), JSON-describable for a future `EXPLAIN` |
| `polyquery/execution/` | Expression compiler (bound expression → Python closure), batch-at-a-time operators (generators of row-tuple batches), aggregate accumulators, CAST kernels, execution context (timeout / cancellation / memory budget) |
| `polyquery/service.py` | `Engine` facade: owns the catalog, runs `load` and SQL (`parse → bind → plan → execute`) |
| `polyquery/protocol/` | Transport-independent request handler (validation, path safety, responses), JSON-lines session loop, exec mode, canonical value serialization |
| `polyquery/cli.py` | Command line (`version`, `capabilities`, `session`, `exec`) |

### Runtime value representation

`BOOLEAN` → `bool`, `INT64` → `int` (range-checked after every operation),
`FLOAT64` → `float` (non-finite results raise `NUMERIC_OVERFLOW`),
`DECIMAL(p,s)` → `int` holding the unscaled value (exact arbitrary-precision
intermediates; results checked against 18 digits), `STRING` → `str`,
`DATE` → `int` days since 1970-01-01, `TIMESTAMP` → `int` microseconds since
the epoch, `NULL` → `None`. Values are converted to their canonical JSON form
only at the protocol boundary.

### Execution model

Operators exchange batches of up to 2048 row tuples. Scans zip only the
referenced columns (column pruning happens during binding: every referenced
column gets an input *slot*). Expressions are compiled once per query into
closures that implement NULL propagation and the runtime error rules; projection
lists are compiled into a single generated tuple-building function. Timeouts,
cancellation and memory accounting are checked per batch; `PQ_SLEEP` sleeps in
≤ 10 ms slices so it observes timeouts promptly.

### Extensibility towards later phases

* The parser already accepts the complete v1 grammar (joins, derived tables,
  CTEs, GROUP BY/HAVING, CASE, LIKE, BETWEEN, IN, subqueries, EXPLAIN,
  CREATE/DROP INDEX); the binder reports these as `UNSUPPORTED` for now, so
  Phase 2 only needs binder/planner/executor work.
* Bound expressions are frozen dataclasses with structural equality, which is
  what GROUP BY matching needs. The `Aggregate` plan node is the place where
  grouping keys will be added.
* Storage is column-oriented already; plan nodes are pure data with a
  `to_json()` for `EXPLAIN`; the catalog is lock-protected for the Phase 4
  server; the execution context carries a cancellation event.

## Design decisions (where the spec leaves room)

* **CSV**: completely empty lines (also `\r\n`-only lines) are skipped.
  A field consisting only of spaces/tabs is treated like an empty field for
  non-STRING columns (NULL) and is not considered during inference. Header-only
  input yields an empty table of STRING columns; input without a header record
  is an `INGEST_ERROR`. A quote character inside an unquoted field is kept
  literally; text after a closing quote is an `INGEST_ERROR`.
  With an explicit schema and a header, the schema's spelling of column names is
  used.
* **Ingestion request errors**: an unknown type name in an explicit schema,
  a non-boolean `header`, an invalid `delimiter` (must be one ASCII character
  other than `"`, CR, LF) and `header:false` without a schema are
  `INVALID_REQUEST`.
* **JSON**: keys are matched ASCII case-insensitively; two keys that differ only
  in case (in one object or across objects) are an `INGEST_ERROR` (duplicate
  column). Lone UTF-16 surrogates in strings and numbers that overflow FLOAT64
  are `INGEST_ERROR`. Values of non-STRING columns given as JSON strings are
  trimmed of spaces/tabs before conversion (CSV rule).
* **Literals / CAST**: `TIMESTAMP '…'` literals and `CAST(… AS TIMESTAMP)`
  require the full timestamp syntax of types.md §3 (a bare date is only accepted
  by ingestion, as ingestion.md states explicitly). `CAST` from STRING trims
  ASCII whitespace for BOOLEAN/INT64/DECIMAL/FLOAT64 (as the CAST table says)
  but not for DATE/TIMESTAMP. FLOAT64 → STRING uses Python's shortest
  round-trip `repr` (`-0.0` → `0.0`).
* **Promotion**: an INT64 operand combined with a DECIMAL is promoted to
  `DECIMAL(18,0)`; values with more than 18 digits raise `NUMERIC_OVERFLOW`
  (also in comparisons, as types.md §2 states). Arithmetic involving the
  untyped `NULL` literal types the NULL as INT64 (`NULL / 0` is an INT64 NULL).
  `SUM(NULL)` is INT64, `AVG(NULL)` FLOAT64.
* **Decimal division** computes the exact quotient and rounds once to FLOAT64.
  `AVG` over INT64/DECIMAL sums exactly before the single final division;
  float `SUM`/`AVG` use `math.fsum`.
* **LIMIT/OFFSET** must be constant INT64 expressions; `NULL` means "no limit".
* **Query options**: `mode` accepts `auto` and `row` (this engine is
  row/batch based); `vectorized` and unknown values of known enum options are
  `UNSUPPORTED`; ill-typed option values are `INVALID_REQUEST`. `threads`,
  `join`, `optimize`, `use_indexes`, `native` are validated and otherwise ignored.
* Protocol ops of later phases (`explain`, `save`, `open`, `stats`) answer
  `UNSUPPORTED`; unknown ops `INVALID_REQUEST`.
* Not-yet-implemented SQL (GROUP BY, joins, subqueries, CTEs, CASE, LIKE,
  BETWEEN, IN, scalar functions other than `PQ_SLEEP`, EXPLAIN, index DDL) →
  `UNSUPPORTED`, never a wrong result. `SELECT DISTINCT` and
  `COUNT/SUM/AVG(DISTINCT x)` are implemented.
* **Memory budget**: materialized rows (sort buffers, DISTINCT sets, results)
  are accounted at ~64 bytes + 16 bytes per value against
  `--max-query-memory-mb` (default 4096) → `RESOURCE_LIMIT`.
* Default limits: `--max-ingest-bytes` 4 GiB, `--max-table-rows` 200,000,000.
* Responses are serialized with ASCII escaping (`\uXXXX`) so the output is always
  valid UTF-8 JSON on one line.

## Known limitations

* Phase 1 only: no GROUP BY, joins, subqueries, CTEs, scalar function library,
  EXPLAIN, persistent storage, indexes or HTTP server yet.
* Single-threaded execution; the CSV/JSON readers hold the whole input in memory.
* Conformance runner note: `cases/phase1/limits_and_output.pqt` lines 34 and 39
  expect the engine to echo a request `id` of `{"nested":[1,"x"]}` / `"abc"`,
  but `tests/conformance/runner.py` (line 216) overwrites every request's `id`
  with the step number before sending it and then requires the response `id` to
  equal that number. No engine can satisfy both checks, so these two cases fail
  in the public runner even though the engine echoes ids verbatim (verified
  directly and by `tests/test_engine.py::CatalogTests.test_id_echo`).
