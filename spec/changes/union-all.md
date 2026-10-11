# Change request CR-1: `UNION ALL`

Status: adopted for the *architectural change* experiment family (capability
`change.union_all`). Applies identically to every language. Spec version for
engines claiming this change: 1.1.0-cr1.

## 1. Grammar (replaces the `query` production of `spec/sql/grammar.md`)

```ebnf
query          = [ with_clause ] compound
                 [ order_by ] [ limit_clause ] ;
compound       = select_core { "UNION" "ALL" select_core } ;
```

* `UNION` without `ALL` (i.e. `UNION` / `UNION DISTINCT`) remains reserved and
  answers `UNSUPPORTED`.
* Branches are plain `select_core`s: a branch cannot carry its own `ORDER BY` or
  `LIMIT`, and parenthesized branches are not supported (`PARSE_ERROR`).
* `UNION ALL` is allowed wherever `query` is allowed: top level, CTE bodies,
  derived tables, scalar / `IN` / `EXISTS` subqueries, and `EXPLAIN`.

## 2. Semantics

* The result is the concatenation of the rows of all branches; **duplicates are
  kept**. Without `ORDER BY` the row order is unspecified.
* All branches must produce the same number of columns, otherwise
  `SEMANTIC_ERROR`.
* Output column *i* has the common type of column *i* of every branch, using the
  rule for `CASE` results (semantics.md §13): numeric promotion
  (INT64 < DECIMAL(18,s) < FLOAT64, DECIMAL scale = max of the scales); otherwise
  all branches must have the same type; a branch column that is the untyped
  `NULL` literal adopts the common type of the others (all-NULL ⇒ type of an
  untyped NULL column as in a plain `SELECT NULL`). Any other mismatch ⇒
  `TYPE_ERROR`. Values are converted to the output type exactly as by
  promotion (an INT64 that does not fit DECIMAL(18,s) ⇒ `NUMERIC_OVERFLOW`).
* Output column names are those of the **first** branch.
* `ORDER BY` and `LIMIT`/`OFFSET` after the last branch apply to the whole
  result. In a compound query, `ORDER BY` items may only be output column names
  (of the first branch) or 1-based positions; any other expression ⇒
  `SEMANTIC_ERROR`.
* `max_rows` / `RESOURCE_LIMIT` apply to the final result.
* `EXPLAIN` shows a node with `op` = `UnionAll` whose `children` are the branch
  plans, in order.

## 3. Execution options

All Phase 5 options (`mode`, `threads`, `join`, `optimize`, `native`) must give
identical results (as multisets, or as sequences when `ORDER BY` fully orders
the result).

## 4. Conformance

Public cases: `tests/conformance/cases/changes/union_all.pqt`
(`@requires change.union_all`). Engines that claim `change.union_all` must pass
them and keep passing every earlier phase.
