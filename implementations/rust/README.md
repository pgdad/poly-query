# PolyQuery — Rust engine (Track A)

An analytical database engine implementing the PolyQuery specification
(`spec/`) in Rust, using **only the standard library** (no crates).

Status: **Phase 3** (storage and indexing). Capabilities claimed:
`phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`, `sql.basic`,
`test.functions`, `phase2`, `sql.groupby`, `sql.join`, `sql.functions`,
`sql.subquery`, `sql.cte`, `sql.correlated_subquery`, `phase3`,
`storage.pqcf`, `storage.mmap`, `index.hash`, `index.btree`.

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
| `storage` | immutable tables in row layout, column layout (typed vectors + validity bitmap, dictionary-encoded STRING) or PQCF-file-backed (lazily decoded row groups); `stats` (per-column statistics), `index` (hash and ordered indexes), `pqcf` (CRC-32, mmap, reader, writer) |
| `catalog` | case-insensitive table map of `Arc<Table>` (queries hold snapshots) |
| `ingest` | CSV (RFC 4180 + spec rules), JSON array and JSON Lines readers, type inference, explicit schemas |
| `sql` | lexer (positions for `PARSE_ERROR` details), AST, recursive-descent parser for the **full** v1 grammar |
| `planner::binder` | semantic analysis: name resolution (`scope`: range variables, CTE environments, correlation), expression typing (`exprs`), function signatures (`functions`), the grouping rule, ORDER BY/GROUP BY ordinal and alias resolution; produces a `LogicalPlan` of bound, typed `Expr`s |
| `planner::typing` | numeric promotion, comparability, common types (CASE/COALESCE) |
| `planner::logical` | logical algebra: Scan, Filter, Project, Aggregate, Join (INNER/LEFT/CROSS), Distinct, Sort, Limit |
| `planner::optimizer` | predicate pushdown (WHERE/ON conjuncts to the scans, also through pass-through projections of derived tables/CTEs; cross joins with equality predicates become inner joins) and column pruning |
| `planner::access` | access paths: recognizes `col <op> const` / `BETWEEN` / `IN` / `IS NULL` conjuncts, estimates selectivity from statistics, chooses index scans, selects PQCF row groups by min/max |
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
  `result`/`join` values) are `UNSUPPORTED`. `use_indexes: false`
  disables index scans; `threads`, `optimize` and `native` are accepted and
  currently have no effect.
* **`serve`** (Phase 4) exits with status 1.
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

## Known limitations

* The HTTP server (Phase 4) and the Phase 5 execution options are not
  implemented.
* Execution is single-threaded and row-at-a-time.
* Indexes are not used for joins (index nested-loop join), for OR
  predicates, or to produce ordered output.
* Correlated subqueries whose correlation is not an equality on a
  parameter-independent input are re-executed per distinct outer value
  (memoized), i.e. nested-loop cost.
* Filters are pushed through projections only for conjuncts over
  pass-through columns (not through aggregations, DISTINCT or LIMIT).
