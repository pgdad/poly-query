# PolyQuery — Rust engine (Track A)

An analytical database engine implementing the PolyQuery specification
(`spec/`) in Rust, using **only the standard library** (no crates).

Status: **Phase 2** (SQL parser and query engine). Capabilities claimed:
`phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`, `sql.basic`,
`test.functions`, `phase2`, `sql.groupby`, `sql.join`, `sql.functions`,
`sql.subquery`, `sql.cte`, `sql.correlated_subquery`.

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
| `planner::binder` | semantic analysis: name resolution (`scope`: range variables, CTE environments, correlation), expression typing (`exprs`), function signatures (`functions`), the grouping rule, ORDER BY/GROUP BY ordinal and alias resolution; produces a `LogicalPlan` of bound, typed `Expr`s |
| `planner::typing` | numeric promotion, comparability, common types (CASE/COALESCE) |
| `planner::logical` | logical algebra: Scan, Filter, Project, Aggregate, Join (INNER/LEFT/CROSS), Distinct, Sort, Limit |
| `planner::optimizer` | predicate pushdown (WHERE/ON conjuncts to the scans; cross joins with equality predicates become inner joins) and column pruning |
| `planner::physical` | physical plan: hash join (equi-keys, build side by estimated cardinality; LEFT builds right) vs nested-loop join, hash aggregate, top-N sort, `ParamLookup` for correlated subqueries; EXPLAIN JSON |
| `exec` | pull-based (Volcano) operators; expression evaluator; scalar functions; aggregate accumulators; subquery evaluation with memoization; per-query context (timeout, cancellation flag, memory budget, join-row limit) |
| `engine` | transport-independent facade: load/drop/reset/query/explain, path safety, limits |
| `protocol` | request validation, response building, `session` (JSON lines) and `exec` modes |
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
  `INVALID_REQUEST`; unsupported values (`mode: "vectorized"`, unknown
  `result`/`join` values) are `UNSUPPORTED`. `threads`, `optimize`,
  `use_indexes` and `native` are accepted and currently have no effect.
* **Ops of later phases** (`save`, `open`, `stats`) and `CREATE/DROP INDEX`
  answer `UNSUPPORTED`; `serve` exits with status 1.
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
* **Join option** `join: "hash" | "nested_loop"` is honored (nested loop
  disables hash joins); `merge` falls back to automatic selection.
* **Robustness**: requests are processed on a thread with a 256 MiB stack;
  the parser limits nesting depth and operator-chain length (10,000) and the
  JSON parser depth (512);
  panics are caught and reported as `INTERNAL_ERROR` (logged to stderr).
* **Defaults**: `--max-query-memory-mb 4096`, `--max-ingest-bytes 4 GiB`,
  `--max-table-rows 500,000,000`; memory accounting is approximate and covers
  materializing operators (sort, aggregation state, result rows).

## Known limitations

* Phase 3+ features (indexes, PQCF storage, statistics, HTTP server, row
  layout, vectorized/parallel execution) are not implemented and are
  reported as `UNSUPPORTED`.
* Execution is single-threaded and row-at-a-time.
* Correlated subqueries whose correlation is not an equality on a
  parameter-independent input are re-executed per distinct outer value
  (memoized), i.e. nested-loop cost.
* Filters are not pushed through projections (into derived tables/CTEs).
