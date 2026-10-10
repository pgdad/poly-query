# PolyQuery — Java engine

An in-memory analytical database engine implementing the PolyQuery specification
(`spec/`), currently at **Phase 2**: protocol, catalog, CSV/JSON/JSONL ingestion, all data
types, the complete SQL v1 grammar (GROUP BY/HAVING, DISTINCT, INNER/LEFT/CROSS joins,
all scalar functions, CASE/LIKE/BETWEEN/IN, uncorrelated **and correlated** subqueries,
derived tables, CTEs, EXPLAIN), structured errors, resource limits and test functions.

Capabilities: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic test.functions phase2
sql.groupby sql.join sql.functions sql.subquery sql.cte sql.correlated_subquery`.

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
| `sql.ast` | Immutable AST (sealed interfaces + records) for the full v1 grammar |
| `sql.parser` | Recursive-descent parser (WITH, joins, subqueries, CASE, IN, LIKE, BETWEEN, EXPLAIN, CREATE/DROP INDEX); `PARSE_ERROR` carries `line`/`column` |
| `sql.analyzer` | Semantic validation: `Scope` (range variables, correlation), `ExpressionBinder` + `TypeCoercion` + `ScalarFunctionBinder` (typing), `Analyzer` (per query level: FROM/joins/derived tables/CTEs, GROUP BY rewriting, ORDER BY resolution → `BoundQuery`), `LogicalPlanner` (`BoundQuery` → logical plan) |
| `plan` | Bound (typed) expressions (`BoundExpr`, `BoundExprs` traversal), aggregate calls, subqueries, logical plan nodes, expression formatter |
| `optimizer` | `LogicalOptimizer`: predicate pushdown into joins and scans, CROSS→INNER join conversion (disabled by `optimize: false`) |
| `physical` | `PhysicalPlan` nodes, `PhysicalPlanner` (hash vs nested-loop joins, hash lookup for correlated filters), `PlanExplainer` (EXPLAIN JSON) |
| `exec` | Volcano operators (scan, filter, project, hash aggregate, distinct, hash/nested-loop join, sort, limit, hash-lookup filter), `OperatorBuilder` (physical plan → operators), `ExpressionCompiler` (bound expression → closures), `ScalarFunctions`, `SubqueryRunner`, `ExecContext` (timeout, memory budget, row/join limits, correlation frames) |
| `storage` | Immutable columnar tables (`ColumnVector`: primitive arrays + null bitmaps), thread-safe `Catalog` |
| `ingest` | CSV parser + type inference, JSON / JSON Lines ingestion |
| `engine` | `Engine` façade used by every front-end; config; path safety |
| `protocol` | JSON request handling/validation, result serialization, structured logger |
| `Main` | CLI (`version`, `capabilities`, `session`, `exec`) |

Query pipeline (each stage is a separate class and data structure):

```
SQL text ─Lexer→ tokens ─Parser→ AST (Statement/Query/Expr)
   ─Analyzer/ExpressionBinder→ BoundQuery per query level (typed BoundExpr, resolved names)
   ─LogicalPlanner→ LogicalPlan ─LogicalOptimizer→ LogicalPlan
   ─PhysicalPlanner→ PhysicalPlan ─OperatorBuilder/ExpressionCompiler→ Operator tree ─Executor→ rows
```

`EXPLAIN` renders the physical plan (`TableScan`, `Filter`, `Project`, `Aggregate`,
`Distinct`, `HashJoin`/`NestedLoopJoin` with `join_type`, `Sort`, `Limit`, `Values`,
`HashLookupFilter`); plans of subqueries appear under a `subqueries` property of the node that
evaluates them.

### Subqueries and correlation

Every query level gets a *correlation frame* id. A column that does not resolve in the current
level is looked up in enclosing levels (derived tables and CTE bodies cannot see the range
variables of the level that contains them) and bound as `OuterRef(frame, index)`; the
reference is recorded in every level between the reference and its target, so each subquery
knows exactly which outer values it depends on. At run time a subquery expression sets its
frame to the row it is evaluated on, runs (or re-opens) its operator tree and restores the
frame. Uncorrelated subqueries run once; correlated ones are memoized by the values of their
outer references. A filter inside a correlated subquery of the form `inner_expr = outer_ref`
becomes a `HashLookupFilter`: the uncorrelated input is hashed once and each execution only
probes it, which turns the usual O(outer × inner) evaluation into O(outer + inner).
In aggregated queries, correlated subqueries in SELECT/HAVING/ORDER BY see a frame row rebuilt
from the group keys; referencing an ungrouped column there is a `SEMANTIC_ERROR`.

### Joins

Joins associate left to right. ON conditions are split into equi-join keys
(`left_expr = right_expr`) and a residual; with at least one key a hash join is used (hash
table on the right input; for LEFT JOIN the right side must be the build side), otherwise a
nested-loop join over the materialized right input. NULL keys never match. Equal values of
different DECIMAL scales hash identically. Every join operator counts its output rows against
`--max-join-rows` (`RESOURCE_LIMIT`). The `join` query option `hash`/`nested_loop` forces an
algorithm where applicable (`merge` and `auto` currently mean "choose").

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

* `CREATE INDEX` / `DROP INDEX` are parsed and answered with `UNSUPPORTED` (no Phase 3
  indexes yet); `UNION`, `RIGHT JOIN` and `FULL JOIN` are `UNSUPPORTED`. Unknown function
  names are `SEMANTIC_ERROR`.
* `UPPER`/`LOWER` map ASCII letters only. Following the public conformance suite
  (`UPPER('abc Ünï')` = `'ABC Ünï'`), a *word* (maximal run of letters/digits) that contains a
  non-ASCII character is left unchanged as a whole.
* Common type of CASE results / COALESCE arguments: identical types are kept
  (`DECIMAL(10,2)` stays `DECIMAL(10,2)`); otherwise numeric promotion (INT64 with DECIMAL
  gives `DECIMAL(18,s)`), any other mix (including DATE with TIMESTAMP) is `TYPE_ERROR`.
* `ROUND(x, n)`, `DATE_TRUNC(unit, t)` and `DATE_DIFF(unit, a, b)` require constant `n`/`unit`
  (`SEMANTIC_ERROR` otherwise), evaluated during analysis; units are case-insensitive;
  a NULL constant yields NULL. `DATE_DIFF` supports `'day'` only (`INVALID_ARGUMENT` else).
  `ROUND` of an INT64 with negative `n` rounds half away from zero (`ROUND(15, -1)` = 20).
* Numeric functions applied to a NULL literal keep the null type (`ABS(NULL)` is reported as
  STRING), functions with a fixed result type use it (`LENGTH(NULL)` is INT64).
* GROUP BY ordinals and aliases refer to select items after `*` expansion; an identifier is
  only treated as an alias if it does not name an input column. SELECT aliases are not visible
  in WHERE or HAVING (`SEMANTIC_ERROR`), only in GROUP BY and ORDER BY as specified.
* A parenthesized join nested on the right of another join may not reference range variables
  outside the parentheses in its ON condition (`UNSUPPORTED`).
* A CTE body is analyzed where it is defined, even if the CTE is never referenced.
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
  `vectorized` is `UNSUPPORTED`. `optimize: false` disables logical optimization; `join`
  selects the join algorithm (see Joins). `threads`, `use_indexes`, `native` and `query_id`
  are validated and otherwise ignored. Ill-typed option values are
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
python3 tests/conformance/runner.py --engine implementations/java/bin/polyquery --phase 1 --phase 2
```

Unit tests (`src/test/java`, run by `make test`) cover the lexer, parser, types, ingestion,
protocol, and end-to-end SQL (grouping, joins with every join strategy and with optimization
disabled, functions, subqueries, CTEs, EXPLAIN). During development the conformance suite was
also run with `optimize: false` and with each forced join algorithm, and randomized queries
(joins, grouping, IN/EXISTS/scalar subqueries, correlated or not, derived tables, CTEs) were
cross-checked against SQLite.

## Known limitations

* No Phase 3+ features yet: indexes, statistics, PQCF storage, row layout, HTTP server
  (`serve` exits with status 1), vectorized/parallel execution, merge join.
* Scans materialize all columns of a table (no column pruning yet); EXPLAIN reports them all.
* The hash join always builds on the right input.
* Execution is single-threaded and row-at-a-time.
* Each ingestion reads the whole input into memory before parsing.
