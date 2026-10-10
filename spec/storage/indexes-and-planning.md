# Indexes, Statistics and Query Planning

## 1. Physical representations (Phase 3)

Engines MUST implement both an in-memory **row-oriented** representation
(a sequence of row tuples) and an in-memory **column-oriented** representation
(one typed vector per column plus null bitmap). Which one a table uses is
selected by the `load`/`open` option `{"options":{"layout":"row"|"column"}}`
(default implementation-defined). Query results MUST be identical for both
layouts. `schema` responses MAY report `"layout"`.

Engines MUST support **dictionary encoding** for STRING columns in the columnar
in-memory representation (applied automatically when beneficial or forced by
`{"options":{"dictionary":true}}`).

## 2. Indexes

* `HASH` index: supports equality lookups (`col = const`, `col IN (consts)`).
* `BTREE` index (or an equivalent ordered structure such as a sorted
  permutation/skip list): supports equality and range predicates
  (`<, <=, >, >=, BETWEEN`) and MAY be used to produce ordered output.
* Indexes are single-column. NULLs are not returned by any index lookup
  (no predicate above matches NULL).
* Index contents are rebuilt when the table is (re)loaded/opened; indexes on a
  dropped/replaced table are dropped (on replace) unless re-created.
* **Correctness requirement:** a query MUST return identical results with
  `use_indexes: true` and `use_indexes: false`.

## 3. Statistics, pushdown, pruning, cost-based choices

Engines MUST maintain per-table statistics (row count; per column: null count,
min, max, approximate distinct count) and expose them via the `stats` operation.

The planner MUST implement:

1. **Predicate pushdown** — conjuncts of `WHERE` referencing a single range
   variable are evaluated at (or immediately above) that table's scan, before
   joins; for PQCF-backed tables, row groups whose min/max exclude a
   `col <op> constant` conjunct are skipped.
2. **Column pruning** — scans only materialize columns referenced by the query.
3. **Index selection** — for a conjunct `col = c`, `col IN (…)` or a range on an
   indexed column, choose an index scan when its estimated selectivity is
   ≤ 10% of the table rows (estimate from statistics: equality ≈ 1/distinct,
   ranges by linear interpolation between min and max for numeric/temporal
   types, 1/3 otherwise); otherwise a full scan.
4. **Join build-side selection** — for hash joins, build on the input with the
   smaller estimated cardinality (inner joins; for LEFT JOIN, the right side is
   the build side).

Additional optimizations are allowed provided results are unchanged.

## 4. EXPLAIN plan JSON

`explain` returns a tree of plan nodes:

```json
{"op": "Project", "columns": ["id","name"], "children": [
  {"op": "Filter", "predicate": "…", "children": [
    {"op": "IndexScan", "table": "people", "index": "people_id", "kind": "HASH",
     "columns": ["id","name"], "children": []}]}]}
```

Every node has `op` (string) and `children` (array). Other properties are free
form, except that the following MUST be accurate because conformance tests
inspect them:

| Node `op` | Required properties |
|---|---|
| `TableScan` | `table` (catalog table name), `columns` (array of column names actually read, in any order) |
| `IndexScan` | `table`, `index` (index name), `columns` |
| `HashJoin`, `MergeJoin`, `NestedLoopJoin` | `join_type` (`"INNER"`, `"LEFT"`, `"CROSS"`) |

Engines MUST use these op names for those operators; other node names
(`Filter`, `Project`, `Aggregate`, `Sort`, `Limit`, `Distinct`, `Values`, …)
are recommended. Tests only assert: the presence/absence of an `IndexScan` with
a given index; the column set of a `TableScan`; join algorithm node names when a
`join` option forces them.
