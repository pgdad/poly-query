# PolyQuery — Clojure engine

An analytical in-memory database engine implementing the PolyQuery
specification (`spec/`) in Clojure. Status: **Phase 2** — Phase 1 (protocol,
catalog, CSV/JSON/JSONL ingestion, all data types, resource limits, test
functions) plus the complete SQL language: GROUP BY/HAVING, DISTINCT,
INNER/LEFT/CROSS joins, all scalar functions, CASE/LIKE/BETWEEN/IN,
uncorrelated **and correlated** subqueries, derived tables, CTEs and EXPLAIN.

Reported capabilities: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic
test.functions phase2 sql.groupby sql.join sql.functions sql.subquery sql.cte
sql.correlated_subquery`.

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

Every statement goes through distinct, inspectable stages:

```
SQL text ─lexer→ tokens ─parser→ AST ─analyzer/binder→ bound query
        ─logical planner→ logical plan ─optimizer→ logical plan
        ─physical planner→ physical plan ─operators→ rows ─protocol→ JSON
```

| Layer | Namespaces | Responsibility |
|---|---|---|
| CLI / protocol | `polyquery.main`, `polyquery.protocol` | argument parsing, session/exec loops, request validation, op dispatch (`handle-op` multimethod), response objects |
| Engine pipeline | `polyquery.engine` | drives the stages per statement, EXPLAIN, result serialization |
| Lexer | `polyquery.sql.lexer` | tokens with line/column positions, comments, quoted identifiers, reserved words |
| Parser / AST | `polyquery.sql.parser`, `polyquery.sql.ast` | recursive descent over the full v1 grammar producing a plain-map AST |
| Semantic analysis | `polyquery.sql.analyzer` (queries: FROM/CTE/derived-table resolution, `*` expansion, GROUP BY/ORDER BY rules, output names), `polyquery.sql.binder` (expressions: name resolution incl. correlation, typing, coercions, aggregates), `polyquery.sql.functions` (scalar function signatures), `polyquery.sql.bound` (bound-expression shapes and helpers) | produces a *bound query*: typed expressions whose column references are row indices |
| Logical planning | `polyquery.plan.logical` | relational operator tree: values/scan/derived/join → filter → aggregate → filter (HAVING) → project → distinct → sort → limit → project |
| Optimization | `polyquery.plan.optimizer` | predicate pushdown below joins, WHERE equalities of comma joins become join conditions (`optimize: false` disables it) |
| Physical planning | `polyquery.plan.physical`, `polyquery.plan.explain` | hash join vs nested-loop join, hash lookup for correlated equality predicates, planning of nested subquery plans; EXPLAIN JSON |
| Execution | `polyquery.exec.operators`, `polyquery.exec.join`, `polyquery.exec.expr`, `polyquery.exec.functions`, `polyquery.exec.aggregate`, `polyquery.exec.context` | operators compiled once into re-reducible row sources; expression compiler (bound expr → specialised closure); scalar functions and LIKE; aggregate accumulators; query context (timeout, cancellation, memory budget) |
| Storage / catalog | `polyquery.storage.table`, `polyquery.catalog` | immutable column-wise tables, immutable catalog value held in an atom (snapshot per query, atomic publication of loads) |
| Ingestion | `polyquery.ingest`, `polyquery.ingest.{csv,json,common}` | streaming RFC 4180 reader, strict JSON reader, inference, explicit-schema conversion |
| Values / types | `polyquery.types`, `polyquery.values` | type model and promotion, exact DECIMAL arithmetic, proleptic Gregorian calendar, CAST matrix, canonical serialization, total order, hash keys |
| Utilities | `polyquery.util.{json,text,log}` | JSON reader/writer, ASCII case folding, code-point string order, stderr JSON logs |

### Value and row representation

Rows are `Object[]`; NULL is `nil` for every type. `BOOLEAN` → `Boolean`,
`INT64` → `Long`, `FLOAT64` → `Double`, `STRING` → `String`, `DATE` → `Long` days
since 1970-01-01, `TIMESTAMP` → `Long` microseconds, `DECIMAL(p,s)` → `Long`
unscaled value (the scale is static, carried by the type). Decimal arithmetic
is exact: long fast paths with `BigInteger` fallbacks wherever an
intermediate (rescaling, sums) may exceed 64 bits; only final results are
range-checked, as the spec requires.

The row a query's expressions see is its *FROM row*: the columns of all
range variables concatenated in FROM order (a join emits left columns then
right columns). After aggregation the row is the GROUP BY keys followed by
the aggregate values; SELECT/HAVING/ORDER BY expressions are bound against
that layout (a GROUP BY expression is replaced by a reference to its key, so
grouping violations are detected structurally).

Because all types are static after analysis, the expression compiler emits
type-specialised closures (e.g. INT64 `+` uses `Math/addExact`, DECIMAL
comparison rescales by the static scale difference), so there is no dynamic
type dispatch per row.

### Execution

Each physical operator is compiled once into a *re-reducible*
(`clojure.lang.IReduceInit` that recomputes its rows on every `reduce`); rows
are pushed through transducers (`filter`, `map`, `drop`/`take`) without
intermediate collections. Blocking operators (sort, hash aggregate, distinct,
hash-join build) materialize with memory accounting and periodic
timeout/cancellation checks.

* **Joins**: hash join (build side = right input; NULL keys never match;
  INT64/DECIMAL/FLOAT64/DATE/TIMESTAMP keys are hashed in their comparison
  type) whenever the ON condition (after pushdown) has an equality between
  the two inputs, else nested loops. LEFT joins pad unmatched rows with
  NULLs. Output rows are counted against `--max-join-rows`.
* **Subqueries**: uncorrelated scalar/IN/EXISTS subqueries are evaluated once
  (lazily) and cached; IN builds a hash set. A correlated subquery references
  enclosing rows through a *correlation cell*: the subquery expression stores
  the current outer row in its cell and reduces the (compiled-once) subquery
  plan, which reads outer columns from the cell. Correlated equality
  predicates over a table scan (`inner.col = outer.col`) are executed as a
  hash lookup built once, so the common correlated patterns are O(n + m).
* **CTEs** are analyzed once per definition and inlined at each reference.

## Design decisions (where the spec is silent or open)

* **Unsupported features.** `CREATE INDEX`/`DROP INDEX` parse but answer
  `UNSUPPORTED` (no Phase 3 indexes); `UNION`, `RIGHT`/`FULL` joins answer
  `UNSUPPORTED`. Protocol ops of later phases (`save`, `open`, `stats`) answer
  `UNSUPPORTED`; `serve` exits 1.
* **CASE/COALESCE result type.** Types are combined pairwise in order; any two
  DECIMAL types (even identical ones) combine to `DECIMAL(18,max(s1,s2))` as
  semantics.md §13 states, INT64 with DECIMAL(p,s) to `DECIMAL(18,s)`, NULL
  branches are ignored (a single DECIMAL branch keeps its type). DATE and
  TIMESTAMP results do not combine (`TYPE_ERROR`).
* **UPPER/LOWER.** ASCII letters are case-mapped, other characters are
  unchanged. The public conformance suite additionally expects
  `UPPER('abc Ünï') = 'ABC Ünï'` (the ASCII `n` inside the non-ASCII word is
  not mapped), so an ASCII letter enclosed on *both* sides by non-ASCII
  letters is left unchanged. This is the narrowest rule consistent with that
  test; it is the only place where behaviour was derived from a test rather
  than the spec text.
* **Constant arguments.** `ROUND`'s digit count and the unit of
  `DATE_TRUNC`/`DATE_DIFF` must be constant expressions (literals, arithmetic
  on literals) and are folded during validation; non-constant ⇒
  `SEMANTIC_ERROR`, unknown unit (case-insensitive) ⇒ `INVALID_ARGUMENT`,
  NULL ⇒ the call yields NULL. `DATE_DIFF` supports only `'day'`.
* **GROUP BY / ORDER BY resolution.** Exactly as semantics.md §5-§6; aliases
  are not visible in `WHERE`/`HAVING` (only bare GROUP BY / ORDER BY
  identifiers resolve to select aliases). Expressions containing subqueries
  never match GROUP BY expressions structurally.
* **Correlation.** Column references resolve innermost scope first, then
  enclosing queries. When the enclosing query is aggregated, a correlated
  reference must be a GROUP BY column (else `SEMANTIC_ERROR`). Aggregates
  inside a subquery always aggregate over the subquery's rows.
* **EXPLAIN.** The plan JSON uses `TableScan` (with `table`, `alias`,
  `columns`), `Filter`, `HashJoin`/`NestedLoopJoin` (with `join_type`),
  `HashLookup` (correlated hash lookup over its `TableScan` child),
  `SubqueryScan`, `Aggregate`, `Project`, `Distinct`, `Sort`, `Limit`,
  `Values`; subquery plans appear under a node's `subqueries` property. The
  `explain` op accepts the same SQL as `query` (an `EXPLAIN` prefix is
  allowed). Scans currently read all columns (column pruning is Phase 3).
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
* **Query options.** `mode` accepts `auto`/`row`; `join` accepts its
  documented values (`nested_loop` forces nested-loop joins, the others use
  the automatic choice); `optimize: false` skips the logical optimizer;
  `threads` ≥ 1 is accepted and ignored (execution is single-threaded); other
  values of known options are `UNSUPPORTED`, ill-typed values
  `INVALID_REQUEST`.
* **Limits.** Defaults: `--max-ingest-bytes` 4 GiB, `--max-table-rows`
  200,000,000, `--max-query-memory-mb` 4096 (approximate accounting of
  materialised rows in sort/aggregation/result), `--max-join-rows`
  100,000,000 (counted per join operator). `OutOfMemoryError` and stack overflow are
  reported as `RESOURCE_LIMIT`, any other unexpected exception as
  `INTERNAL_ERROR`; the session never dies on a request.
* **Path safety** is lexical (absolute, empty, NUL or `..` component ⇒
  `ACCESS_DENIED`), so symbolic links inside the data directory work.

## Testing

* `make test` — unit tests for the JSON codec, values/casts/calendar, lexer,
  parser, analyzer, planner/optimizer, scalar functions and LIKE, CSV/JSON
  ingestion, the engine pipeline (Phase 1 and Phase 2 features) and the
  protocol.
* Conformance: `python3 tests/conformance/runner.py --engine
  implementations/clojure/bin/polyquery --phase 1 --phase 2`.

## Known limitations

* No indexes, PQCF storage, statistics, HTTP server (Phases 3-5).
* Scans materialize all table columns (no column pruning yet); the hash join
  always builds on the right input.
* Tables are held as boxed values in `Object[]` columns; very large inputs
  need a correspondingly large heap (`POLYQUERY_JAVA_OPTS=-Xmx…`). JSON (array)
  inputs are parsed from a single in-memory string.
* Correlated subqueries other than equality lookups over a single table scan
  are re-executed per outer row (correct, but O(outer × inner)).
* Sorting is not interruptible once the in-memory sort has started (rows are
  checked for timeout/cancellation while being collected).
