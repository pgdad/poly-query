# SQL Semantics

Processing of a statement is: **lex → parse → semantic validation (binding,
typing) → logical plan → physical plan → execution**. Errors detected before
execution MUST be reported without executing anything. Conformance tests only
check the error *code*, not which phase raised it, except where this document
explicitly says "at validation".

## 1. Name resolution

* The catalog contains **tables** (from `load`/`open`) and **indexes**. Names
  are matched ASCII case-insensitively; the output spelling is the declared one.
* A `FROM` table reference resolves in this order: CTE names visible at that
  point (innermost `WITH` first; a CTE is visible to later CTEs of the same
  `WITH` and to the main query, not to itself or earlier ones), then catalog
  tables. Unknown ⇒ `SEMANTIC_ERROR`.
* Each `table_ref` introduces a *range variable* named by its alias if given,
  else by the table/CTE name. Two range variables with the same name in one
  `FROM` ⇒ `SEMANTIC_ERROR`.
* A qualified column `r.c` resolves against range variable `r`. An unqualified
  column `c` resolves against all range variables of the current `FROM`; zero
  matches ⇒ continue to outer query scopes (correlation, §8); >1 matches ⇒
  `SEMANTIC_ERROR` ("ambiguous column").
* A CTE column list `cte(a,b)` renames the CTE's output columns; count mismatch
  ⇒ `SEMANTIC_ERROR`. Output columns of a derived table/CTE whose names are
  duplicated can only be referenced if unambiguous.
* `*` expands to all columns of all range variables in `FROM` order; `r.*` to
  the columns of `r`. `SELECT *` without `FROM` ⇒ `SEMANTIC_ERROR`.

## 2. SELECT without FROM

`SELECT 1 + 2 AS x` produces exactly one row. `WHERE` without `FROM` filters
that single row.

## 3. Output column names

* `expr AS alias` / `expr alias` ⇒ `alias`.
* A bare (possibly qualified) column reference ⇒ the column's name.
* `*` expansions ⇒ the column names.
* Anything else ⇒ `_colN` where N is the 1-based position of the item in the
  final output column list (after `*` expansion).

Duplicate output names are allowed.

## 4. Evaluation order of clauses

1. `FROM` (including joins) produces the input relation.
2. `WHERE` filters rows (aggregates in `WHERE` ⇒ `SEMANTIC_ERROR`).
3. `GROUP BY` / aggregation.
4. `HAVING` filters groups.
5. `SELECT` list is evaluated.
6. `DISTINCT` removes duplicate output rows (§7 of types.md equality).
7. `ORDER BY`.
8. `OFFSET`, then `LIMIT`.

## 5. Grouping and aggregation

* A query is *aggregated* if it has `GROUP BY`, or any aggregate function in
  `SELECT`/`HAVING`/`ORDER BY`. `HAVING` without aggregation and without
  `GROUP BY` makes the query aggregated with a single group.
* `GROUP BY` items are expressions over input columns. An unqualified
  identifier in `GROUP BY` that does not resolve to an input column but equals
  (case-insensitively) a `SELECT` alias refers to that select item's expression.
  A positive integer literal `k` in `GROUP BY` refers to the k-th select item
  (out of range ⇒ `SEMANTIC_ERROR`).
* In an aggregated query, every column reference in `SELECT`, `HAVING` and
  `ORDER BY` outside an aggregate argument MUST be part of an expression that
  is (structurally) equal to a `GROUP BY` expression, else `SEMANTIC_ERROR`.
  Structural equality compares resolved column bindings, literal values,
  operators and function names (case-insensitive). Precisely: after replacing
  every subexpression structurally equal to a GROUP BY expression by a
  placeholder, no input column reference may remain outside aggregate
  arguments. Examples: `GROUP BY a+1` permits `SELECT (a+1)*2` but not
  `SELECT a`; `GROUP BY a` permits `SELECT a+0`.
* Aggregate calls MUST NOT be nested (`SUM(COUNT(x))` ⇒ `SEMANTIC_ERROR`).
* An aggregated query **without** `GROUP BY` always returns exactly one row,
  even on empty input (COUNT = 0, other aggregates NULL).
* With `GROUP BY` on empty input: zero rows.
* NULLs in grouping keys form their own group.
* Aggregate semantics: see functions.md §2.

## 6. ORDER BY

* An `ORDER BY` item that is a positive integer literal `k` refers to output
  column k (out of range ⇒ `SEMANTIC_ERROR`).
* An unqualified identifier that equals (case-insensitively) an output column
  name/alias refers to that output column (output names take precedence over
  input columns). Ambiguity among several output columns with that name ⇒
  `SEMANTIC_ERROR` unless they are the same expression.
* Otherwise the item is an expression over input columns (allowed only if the
  query is not `DISTINCT`, or the expression is in the select list; violating
  that for `DISTINCT` ⇒ `SEMANTIC_ERROR`). In aggregated queries the grouping
  rule of §5 applies.
* Default direction `ASC`; NULL ordering per types.md §7. Sorting is by the
  keys in order; values of incomparable types never occur in one column.
* **Determinism:** the relative order of rows that are equal on all ORDER BY
  keys is implementation-defined. Without ORDER BY, row order is
  implementation-defined. Conformance tests either use a total order or compare
  results as multisets.

## 7. Joins

* `INNER JOIN … ON c`: pairs of left/right rows where `c` is TRUE.
* `LEFT JOIN … ON c`: inner join result plus every left row with no matching
  right row, padded with NULLs for the right columns.
* `CROSS JOIN` / `,`: Cartesian product.
* Joins associate left-to-right: `a JOIN b ON … JOIN c ON …` is `(a ⋈ b) ⋈ c`.
  The `ON` expression may reference any range variable introduced so far in
  the same `from_item`.
* Equality join predicates follow normal comparison semantics: NULL keys never
  match.
* Engines MUST enforce `--max-join-rows` (default ≥ 100,000,000 intermediate
  rows) ⇒ `RESOURCE_LIMIT`.

## 8. Subqueries

* **Derived tables** `(query) alias` behave like a table with the query's output.
* **Scalar subquery** `(query)` in an expression: MUST produce exactly one
  column (else `SEMANTIC_ERROR`). Zero rows ⇒ NULL; more than one row ⇒
  `SUBQUERY_CARDINALITY` at runtime. Its type is the column's type.
* `x [NOT] IN (query)`: query MUST produce one column of a type comparable with
  `x`. Semantics follow SQL: `x IN S` is TRUE if some element equals x; else
  NULL if x is NULL (and S non-empty) or S contains a NULL; else FALSE.
  `NOT IN` is the three-valued negation. `x IN (empty)` is FALSE even if x is NULL.
* `x [NOT] IN (e1, e2, …)` is `x = e1 OR x = e2 OR …` (and its negation).
* `EXISTS (query)`: TRUE iff the query returns ≥ 1 row; never NULL.
* **Uncorrelated** subqueries (capability `sql.subquery`) are required in Phase 2.
* **Correlated** subqueries — a subquery referencing a column of an enclosing
  query's range variable — are capability `sql.correlated_subquery` (optional
  in v1). Engines not supporting them MUST report `UNSUPPORTED`, never a wrong
  result. When supported, the subquery is evaluated (logically) once per outer row.

## 9. CTEs

`WITH` defines non-recursive named queries. Each CTE MAY be evaluated once and
reused or inlined; results MUST be identical. A CTE name shadows a catalog table
of the same name within the query (after its definition). There is no recursion:
inside its own definition a CTE's name resolves exactly as if the CTE did not
exist (so `WITH people AS (SELECT * FROM people)` reads the catalog table, and
`WITH a AS (SELECT * FROM a)` is an unknown-table `SEMANTIC_ERROR` when no table
`a` exists). Duplicate CTE names in one `WITH` ⇒ `SEMANTIC_ERROR`.

## 10. DISTINCT

`SELECT DISTINCT` removes duplicate rows using equality where NULLs are equal.
`SELECT ALL` is the default.

## 11. LIKE

`s LIKE p`: both STRING (else `TYPE_ERROR`). `%` matches any sequence of zero or
more characters, `_` matches exactly one character (code point). Matching is
case-sensitive and covers the whole string. No escape character in v1. NULL
operand ⇒ NULL.

## 12. BETWEEN

`x BETWEEN a AND b` ≡ `x >= a AND x <= b` (with x evaluated once).
`NOT BETWEEN` is its negation.

## 13. CASE

* Searched `CASE WHEN c1 THEN r1 … [ELSE e] END`: the first `ci` that is TRUE
  selects `ri`; none ⇒ `e` or NULL.
* Simple `CASE x WHEN v1 THEN r1 …` ≡ `CASE WHEN x = v1 THEN r1 …`.
* Result type: common type of all `ri`/`e` (numeric promotion; otherwise all
  must have the same type or be NULL, else `TYPE_ERROR`).
  Common DECIMAL type of DECIMAL(p1,s1), DECIMAL(p2,s2) is DECIMAL(18,max(s1,s2)).

## 14. Statements

* `CREATE INDEX [IF NOT EXISTS] name ON table (column) [USING HASH|BTREE]`
  (default `BTREE`). Index names are global in the catalog. Existing name ⇒
  `ALREADY_EXISTS` unless `IF NOT EXISTS`. Unknown table/column ⇒
  `SEMANTIC_ERROR`. Result: zero columns, zero rows. Capability `index.hash` /
  `index.btree`; an unsupported kind ⇒ `UNSUPPORTED`.
* `DROP INDEX [IF EXISTS] name`; unknown ⇒ `NOT_FOUND` unless `IF EXISTS`.
* `EXPLAIN query` returns a result with one column `plan` of type STRING and
  one row containing the JSON plan text (see indexes-and-planning.md).
* Tables are created/dropped only via protocol operations, not SQL DDL.

## 15. Resource limits

Every query runs with: a row-count limit on the result (`options.max_rows`,
exceeding it ⇒ `RESOURCE_LIMIT`), a memory budget (`--max-query-memory-mb`,
exceeding ⇒ `RESOURCE_LIMIT`; accounting may be approximate), and an optional
timeout (`options.timeout_ms` ⇒ `TIMEOUT`). See protocol.md and concurrency.md.
