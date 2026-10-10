# PolyQuery — Common Lisp implementation

An in-memory analytical SQL engine implementing the PolyQuery specification
(`spec/`) in ANSI Common Lisp on SBCL. Current scope: **Phases 1 and 2**
(protocol, catalog, CSV/JSON/JSONL ingestion, all data types, the complete
SQL grammar and semantics — joins, grouping, DISTINCT, all scalar functions,
CASE/LIKE/BETWEEN/IN, uncorrelated *and correlated* subqueries, derived
tables, CTEs, EXPLAIN — resource limits, test functions).

## Build prerequisites

* SBCL 2.6.9 (`sbcl` on `PATH`), with its bundled ASDF and `sb-rt` contrib.
* GNU make, a POSIX shell.
* No network access and no third-party libraries are needed.

```sh
make build      # compiles with ASDF and saves build/polyquery (standalone executable)
make test       # runs the unit tests (sb-rt)
make lint       # clean recompile; fails on any compiler WARNING
make fmt        # whitespace normalisation (there is no standard CL formatter)
make clean
bin/polyquery version
```

`bin/polyquery` is a small shell launcher that execs `build/polyquery` and works
from any directory. The executable is saved with `:save-runtime-options`, so
SBCL's runtime does not interpret any command-line arguments; the heap
(8 GiB dynamic space) and control stack (64 MiB) sizes are fixed at build time.

## Libraries

None. Only ANSI Common Lisp, SBCL extensions (`sb-ext`, `sb-sys`, `sb-int`,
`sb-impl`, `sb-thread`, `sb-unix`) and the bundled `asdf`/`uiop`/`sb-rt`
contribs are used (`ENGINE.json` lists no libraries).

## Capabilities

`phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`, `sql.basic`,
`test.functions`, `phase2`, `sql.groupby`, `sql.join`, `sql.functions`,
`sql.subquery`, `sql.cte`, `sql.correlated_subquery`.

## Architecture

A statement goes through the stages required by the spec, each with its own
data structures and module (`src/`, loaded in this order by `polyquery.asd`):

```
SQL text --lexer--> tokens --parser--> AST --binder--> BOUND-QUERY
  --planner--> logical plan (LP-*) --optimizer--> logical plan
  --physical planner--> physical plan (PP-*) --compiler--> iterators --> rows
```

| Layer | Files | Responsibility |
|---|---|---|
| util | `errors`, `numbers`, `json` | `pq-error` condition with stable codes; exact numeric text parsing, correctly rounded float parsing, shortest round-trip float printing; strict RFC 8259 JSON reader/writer |
| types | `types`, `temporal`, `values`, `compare` | type representation, aliases, promotion lattice and result-type unification; DATE/TIMESTAMP calendar math; text conversion, `CAST`, canonical serialization; total ordering |
| storage | `table`, `catalog` | immutable column-oriented tables; case-insensitive catalog with atomic publish (mutex-protected) |
| ingest | `common`, `csv`, `json` | CSV parsing on raw UTF-8 octets, JSON/JSONL; type inference and explicit-schema conversion |
| sql | `lexer`, `ast`, `parser` | tokenizer with line/column positions; AST structures; recursive-descent parser for the full grammar of `grammar.md` (`PARSE_ERROR` carries `details.line`/`column`) |
| analyzer | `bound`, `functions`, `binder`, `query` | semantic validation. `bound`: bound expression nodes and the analysed-query representation; `functions`: the scalar function registry (typing + implementation per function); `binder`: expressions — name resolution through nested scopes, typing, implicit promotions, CASE/LIKE/BETWEEN/IN, subqueries; `query`: CTEs, FROM/joins/derived tables, `*` expansion, output naming, GROUP BY alias/ordinal resolution, the structural grouping rewrite, HAVING, DISTINCT, ORDER BY resolution, constant LIMIT/OFFSET |
| plan | `logical`, `optimizer`, `physical` | logical plan construction (`Scan`, `Values`, `Filter`, `Join`, `Aggregate`, `Project`, `Distinct`, `Sort`, `Limit`); logical rewrites (predicate pushdown, column pruning); physical operator selection and EXPLAIN JSON rendering |
| exec | `context`, `expressions`, `aggregates`, `operators` | query context (deadline, cancellation flag, memory budget, join row limit); expression compiler to closures (incl. subquery evaluation); aggregate accumulators; Volcano-style operators |
| protocol | `requests`, `cli` | JSON-lines request dispatch (`query`, `explain`, catalog ops), validation and responses; CLI modes `version`, `capabilities`, `session`, `exec` |

### Values and expressions

Values are untyped at runtime; the static type in the plan decides their
meaning: NULL is `:null`, BOOLEAN is `t`/`nil`, INT64 an integer, FLOAT64 a
`double-float`, DECIMAL(p,s) its unscaled integer, STRING a Lisp string,
DATE days and TIMESTAMP microseconds since the epoch. Exactness comes from
Lisp's unbounded integers: INT64 and DECIMAL arithmetic is computed exactly
and range-checked afterwards; SUM/AVG accumulate exactly.

Bound expressions (`B-LITERAL`, `B-COLUMN`, `B-PARAM`, `B-OP`, `B-AGG`) are
typed trees; every column reference is a position in the row of the operator
that evaluates it. Expressions are compiled once per statement into closures
with all type dispatch (promotions, comparators, hash-key normalization) done
at compile time.

### Planning

* **Logical plan.** The FROM row is the concatenation of all range
  variables' columns; joins associate left to right; derived tables and CTE
  references are planned as nested sub-plans. Aggregated queries project from
  an aggregation row `[group keys..., aggregates...]` produced by the
  structural GROUP BY rewrite of semantics.md §5.
* **Optimizer.** *Predicate pushdown* splits WHERE and ON conditions into
  conjuncts and moves each one to the lowest valid place: the preserved side
  of a LEFT JOIN, either side of an inner join, or an inner join's condition
  (so comma joins with a WHERE equality become hash joins); conjuncts on the
  NULL-supplying side of a LEFT JOIN stay above it. *Column pruning*
  propagates the set of required columns top-down and renumbers column
  positions, so every `TableScan` reads only referenced columns.
* **Physical plan.** Joins with equality conjuncts between the two sides
  become `HashJoin` (build side: the right input; remaining conjuncts form a
  residual), others `NestedLoopJoin` (`join_type` INNER/LEFT/CROSS);
  aggregation and DISTINCT are hash based; `ORDER BY … LIMIT n` with a
  literal limit becomes a bounded `TopN`; inside correlated subqueries a
  filter `column = outer value` over a scan becomes a `HashLookupScan` (the
  table is hashed once and probed per evaluation).
* **EXPLAIN** (statement and `explain` op) renders the physical plan as JSON
  (indexes-and-planning.md §4). Plans of subqueries appear under a node's
  `"subqueries"` key, not under `"children"`.

### Execution

`COMPILE-OPERATOR` turns each physical node into an *opener* (a function
returning a fresh iterator): expressions are compiled once, openers may run
many times. Join hash tables and materialized nested-loop inputs whose
subtree does not depend on correlation parameters are built once and reused
across re-executions of a correlated subquery. Timeouts/cancellation are
checked every few thousand rows in every loop; materialized state is charged
against the memory budget.

### Subqueries and correlation

A subquery used as an expression is a `:SUBQUERY` op whose descriptor holds
its analysed query, physical plan and a *parameter environment*. While a
subquery is analysed, column references it cannot resolve itself are looked
up in the enclosing scopes; each such outer reference becomes a correlation
parameter: a `B-PARAM` inside the subquery and a parameter expression (an
argument of the `:SUBQUERY` op) in the enclosing query. Because parameters
are ordinary arguments, the grouping rewrite, column pruning and pushdown
treat them like any other expression (an outer column used in a subquery of
an aggregated query must be grouped). At runtime the parameter values are
computed from the current outer row, stored in the environment and the
subquery plan is re-opened; results are memoized per distinct parameter
tuple. Uncorrelated subqueries are evaluated once, lazily, so nothing runs
before the whole statement has been analysed.

### Extensibility notes (later phases)

* Physical operator choice is isolated in `plan/physical.lisp`; forced join
  algorithms (Phase 5) and index scans (Phase 3) are additional physical
  operators. Column pruning already yields exact `TableScan` column sets and
  pushdown places single-table conjuncts directly above the scans, where an
  index scan can absorb them.
* The catalog is mutex-protected and tables are immutable, matching the
  snapshot isolation model of concurrency.md; all query state lives in the
  query context and in per-statement compiled closures.

## Decisions on points the spec leaves open

### General

* `UNION`, `RIGHT`/`FULL` joins answer `UNSUPPORTED` (reserved syntax).
  `CREATE INDEX` / `DROP INDEX` are parsed and answer `UNSUPPORTED` (indexes
  are Phase 3). Ops `save`, `open`, `stats` answer `UNSUPPORTED`; `serve`
  exits 1.
* A NULL literal combined with a typed operand takes that operand's role
  (`NULL + 1` is INT64, `NULL / 0` is NULL); when nothing determines a type
  (`-NULL`, `NULL + NULL`, `SUM(NULL)`) the expression keeps the null type and
  is reported as STRING.
* INT64 operands of DECIMAL arithmetic are promoted to DECIMAL(18,0) (so
  `1.5 * 2` is DECIMAL(18,1)). In comparisons an INT64 is promoted to the
  common DECIMAL(18,s) and, per types.md §2, a value needing more than 18
  digits at that scale is `NUMERIC_OVERFLOW` (e.g. `INT64_MAX > 0.5`).
* Unary minus is folded into any unsigned integer literal, also a
  parenthesized one (`-(9223372036854775808)`). A numeric literal directly
  followed by an identifier character (`0x10`, `1abc`, `1e`) is a
  `PARSE_ERROR`.
* `LIMIT NULL` / `OFFSET NULL` mean "no limit"/"no offset"; a non-INT64
  LIMIT is a `TYPE_ERROR`; ORDER BY ordinal 0 is out of range.
* CAST from STRING trims ASCII whitespace. TIMESTAMP literals and
  `CAST(... AS TIMESTAMP)` require the full timestamp syntax of types.md §3
  (a bare date is `CONVERSION_ERROR`); ingestion accepts a DATE text for a
  TIMESTAMP column as the ingestion spec says. FLOAT64 → STRING uses the
  shortest round-trip text.
* `PQ_SLEEP` with a negative argument is `INVALID_ARGUMENT`.
* CSV: a field that is empty after trimming spaces/tabs is NULL for
  non-STRING columns and is ignored by inference. An input without any record (no header) is `INGEST_ERROR`; a
  `header: false` load without schema is `INVALID_REQUEST`; an unknown type
  in an explicit schema is `INVALID_REQUEST`; a delimiter must be one ASCII
  character other than `"`, CR, LF. A path naming a directory is `IO_ERROR`.
* JSON keys that differ only in case are distinct keys, so they produce
  duplicate column names (`INGEST_ERROR`). JSON numbers that do not fit a
  finite FLOAT64 are `INGEST_ERROR` under inference.
* Query option values (for `query` and `explain`): `mode` accepts
  `auto`/`row` (`vectorized` is `UNSUPPORTED`), `threads` ≥ 1 is accepted
  (execution is single-threaded, results are identical),
  `join`/`optimize`/`use_indexes`/`native` are validated and otherwise have
  no effect yet.
* Default limits: query memory budget 2048 MB (approximate accounting of
  materialized rows, hash tables, sort buffers), ingestion 4 GiB,
  200,000,000 table rows, 100,000,000 rows produced by any single join
  operator (`--max-join-rows`). Parser nesting depth is limited to 400
  (deeper input is a `PARSE_ERROR`); heap or stack exhaustion is reported as
  `RESOURCE_LIMIT`.

### SQL semantics (Phase 2)

* **Name resolution.** An unqualified column resolves in the FROM clause of
  its own query first, then in enclosing queries (correlation). A qualifier
  that names a range variable of the current FROM must find the column there.
  An ON condition sees the range variables of the two joined inputs. Derived
  tables and CTE bodies cannot see the FROM clause they appear in, but can see
  enclosing queries.
* **Output names**: a bare column reference (also one resolving to an outer
  query) is named after the column's declared spelling.
* **GROUP BY** ordinals and aliases refer to select items after `*`
  expansion; referring to an item containing an aggregate is
  `SEMANTIC_ERROR`. `GROUP BY 0` / `ORDER BY 0` are out of range; a negative
  literal is an ordinary constant expression.
* **HAVING and WHERE do not see select aliases** (only GROUP BY and ORDER BY
  do, per semantics.md §5/§6); an alias there is an unknown column.
* **ORDER BY** with `SELECT DISTINCT`: an expression must be structurally
  equal to a select item. In any query an ORDER BY expression equal to a
  select item sorts by that output column.
* **Result type of CASE / COALESCE**: NULL branches are ignored; numeric
  branches combine by the promotion table of types.md §2 applied pairwise —
  two DECIMAL branches give DECIMAL(18,max(s1,s2)) even when their types are
  equal; a single typed branch keeps its type. DATE and TIMESTAMP branches
  do not unify (`TYPE_ERROR`), although they are comparable.
* **Simple CASE** `CASE x WHEN v ...` evaluates `x` once; a NULL `x` matches
  no WHEN.
* **ROUND(x, n)**: `n` must be a constant INT64 expression and is evaluated
  during analysis (it determines the DECIMAL result scale); `ROUND(x, NULL)`
  is NULL. FLOAT64 rounding works on the exact binary value.
* **DATE_TRUNC / DATE_DIFF** units are constant strings matched
  case-insensitively; an unknown unit is `INVALID_ARGUMENT`, raised when the
  query is compiled for execution (after all analysis errors).
* **UPPER / LOWER** map ASCII letters only. The public conformance suite
  expects `UPPER('abc Ünï')` = `'ABC Ünï'` (and `LOWER('ABC ÜNÏ')` =
  `'abc ÜNÏ'`), i.e. the ASCII `n` inside a word with non-ASCII letters stays
  unchanged. The engine therefore maps case per *word* (maximal run of
  letters): a word containing a non-ASCII letter is left as it is, words of
  ASCII letters are mapped.
* **CONCAT** renders arguments with the CAST-to-STRING text (DECIMAL with
  its scale, TIMESTAMP per types.md §9, booleans `true`/`false`).
* **LIMIT/OFFSET** expressions are analysed (constant, INT64) with the
  statement but evaluated when it is compiled for execution, so a runtime
  error there never hides an analysis error.
* **Subquery evaluation**: uncorrelated subqueries run at most once per
  statement, lazily; correlated ones once per distinct tuple of outer values.
  A scalar subquery stops after the second row (`SUBQUERY_CARDINALITY`), an
  EXISTS after the first.
* **Aggregates inside subqueries** always belong to the subquery, even if
  their arguments only reference outer columns.
* **max-join-rows** limits the number of rows produced by each join
  operator.

## Testing

* `make test` — unit tests (sb-rt) for numeric parsing/formatting, temporal
  values, types, JSON, lexer/parser, CSV/JSON ingestion, expression
  evaluation, and Phase 2 analysis/planning/execution (joins, pushdown and
  pruning visible in EXPLAIN, grouping, DISTINCT, subqueries, correlation,
  CTEs, functions).
* Conformance: `python3 tests/conformance/runner.py --engine
  implementations/common-lisp/bin/polyquery --phase 1 --phase 2`.

## Known limitations

* Indexes, persistent storage, statistics (Phase 3), the HTTP server
  (Phase 4) and the Phase 5 execution options are not implemented yet.
* Execution is single-threaded and row-at-a-time.
* Correlated subqueries are executed per distinct outer value (memoized);
  only equality correlations directly on a base-table scan use a hash lookup,
  other correlated shapes rescan their inputs per evaluation.
* Loads materialize the whole input in memory (file octets plus parsed fields)
  before building columns.
