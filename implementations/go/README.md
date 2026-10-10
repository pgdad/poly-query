# PolyQuery — Go engine

An analytical in-memory database engine implementing the PolyQuery
specification (`spec/`), currently **Phase 2** (in-memory data engine with
the complete SQL v1 query language).

## Build prerequisites

* Go 1.27 (tested with `go1.27.1`), standard library only — `go.mod` has no
  requirements; builds work offline (`GOTOOLCHAIN=local`, `GOPROXY=off`).
* `make`.

```bash
make build      # → build/polyquery
make test       # unit tests (go test ./...)
make lint       # go vet + gofmt check
make fmt        # gofmt -w
make clean
bin/polyquery session --data-dir DIR    # launcher; builds on first use if needed
```

## Libraries

None. Only the Go standard library is used (`ENGINE.json` lists no libraries).

## Capabilities

`phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`, `sql.basic`,
`test.functions`, `phase2`, `sql.groupby`, `sql.join`, `sql.functions`,
`sql.subquery`, `sql.cte`, `sql.correlated_subquery`.

## Design overview

A statement flows through distinct, inspectable stages, one package each:

```
SQL text ─lexer→ tokens ─parser→ AST ─analyzer→ logical plan ─optimizer→ logical plan
        ─physical→ physical plan ─exec→ operator tree → rows
```

| Package | Responsibility |
|---|---|
| `cmd/polyquery` | CLI: modes `version`, `capabilities`, `session`, `exec` (`serve` is reserved for Phase 4), option parsing, JSON logs on stderr |
| `internal/protocol` | JSON request decoding/validation, op dispatch (incl. `explain`), single-line JSON response writer, session loop and exec mode |
| `internal/engine` | Facade owning config + catalog: path safety, file loading with limits, the query pipeline, `EXPLAIN`, `max_rows`, timeouts |
| `internal/sql/lexer` | Tokens with 1-based line/column positions; comments, quoted identifiers, reserved keywords |
| `internal/sql/ast`, `internal/sql/parser` | Recursive-descent parser for the full v1 grammar producing an AST; `PARSE_ERROR` carries `line`/`column` |
| `internal/analyzer` | Semantic validation: scopes and range variables, CTE environments, name resolution (incl. outer scopes for correlation), typing with implicit promotions, function signatures, aggregate/grouping rules, ORDER BY resolution; produces the logical plan |
| `internal/plan` | Bound typed expressions and logical plan nodes (`Scan`, `Values`, `Filter`, `Project`, `Aggregate`, `Join`, `Sort`, `Limit`, `Distinct`); every produced column has a statement-unique `ColumnID` |
| `internal/optimizer` | Logical rewrites: predicate pushdown through joins (WHERE/ON conjuncts on one input move below the join, spanning conjuncts become join conditions, so comma joins become inner joins) |
| `internal/physical` | Physical planning: hash join for equi-joins (build side by estimated size), nested-loop join otherwise, hash aggregation, hash distinct, top-N sort; column pruning (scans read only referenced columns); correlated-subquery helpers; EXPLAIN JSON |
| `internal/exec` | Volcano operators; expressions compiled to closures against the input row layout; all scalar functions, LIKE, CASE, BETWEEN, IN; subquery evaluation; cancellation checks; approximate memory accounting; `--max-join-rows` |
| `internal/storage` | Immutable column-oriented tables (typed vectors + null flags) and a thread-safe catalog with atomic publish/replace |
| `internal/ingest` | CSV (RFC 4180 + spec rules) and strict JSON/JSONL parsers, schema inference and explicit-schema conversion |
| `internal/types` | Type system: canonical names/aliases, values, exact DECIMAL arithmetic (int64 unscaled + 128-bit products, big-int sums), proleptic Gregorian DATE/TIMESTAMP, CAST matrix, text parsing/formatting, ordering |
| `internal/errs` | Structured errors with stable codes and optional details |

### Column IDs instead of positions

Expressions reference columns by `ColumnID`, not by row position. Plan
rewrites (pushdown, pruning, redirecting grouped columns) therefore never
renumber anything; the executor resolves IDs to row positions once, when it
compiles an expression against its input's layout. A column that is not in
the layout is an outer reference of a correlated subquery and reads the
current parameter value.

### Aggregation

Following semantics.md §5 literally, after binding the select list, HAVING
and ORDER BY of an aggregated query, every subexpression structurally equal
(canonical string incl. column IDs) to a GROUP BY key is replaced by a
reference to the key column and every aggregate call by a reference to its
aggregate column; any input column reference left over is a grouping
violation (`SEMANTIC_ERROR`). Correlated subqueries evaluated after grouping
get their references to grouped columns redirected to the key columns.

### Subqueries and CTEs

* Uncorrelated scalar/IN/EXISTS subqueries are evaluated once per statement
  (lazily) and cached; IN builds a hash set (NULL-aware three-valued logic).
* Correlated subqueries are evaluated per distinct combination of outer
  values (memoized). Inside their plans, a filter `inner = outer` over an
  uncorrelated input becomes a `ParamLookup` (input hashed once per query),
  and other uncorrelated subtrees are `Materialize`d once, so typical
  correlated EXISTS/COUNT/MAX patterns run in near-linear time.
* CTEs are inlined: each reference re-analyzes the definition in its
  definition environment (fresh column IDs, so a CTE can be self-joined).
  Every CTE is also validated once even when unreferenced.

### EXPLAIN

`EXPLAIN <query>` returns one STRING column `plan` with the JSON plan; the
`explain` op returns the same tree as an object. Nodes: `TableScan` (`table`,
`columns` actually read), `Values`, `Filter`, `Project`, `Aggregate`,
`HashJoin`/`NestedLoopJoin` (`join_type`), `Sort` (`top_n` when combined with a
literal LIMIT), `Limit`, `Distinct`, `ParamLookup`, `Materialize`, and
`Subquery` (children of the operator that evaluates them).

### Value representation

A `types.Value` is `{Null, I int64, F float64, S string}`; the static type of
the producing expression decides which field is meaningful (INT64, BOOLEAN,
DECIMAL unscaled, DATE days and TIMESTAMP microseconds share `I`). Tables store
typed vectors per column. Hash keys (grouping, DISTINCT, joins, IN sets) use a
canonical byte encoding in which equal values per types.md §7 encode equally
(DECIMALs normalized by scale, `-0.0 = 0.0`, NULLs equal).

## Decisions on points the spec leaves open

* **INT64 ↔ DECIMAL comparison** follows types.md §2 literally: the INT64 side
  is promoted to `DECIMAL(18,s)` and a value that needs more than 18 digits
  raises `NUMERIC_OVERFLOW`. For arithmetic, INT64 operands keep scale 0
  (so `1.5 * 2` is `DECIMAL(18,1)`), `/` converts both sides directly to FLOAT64.
* **Null-typed expressions** (`NULL + NULL`, `SUM(NULL)`, `MIN(NULL)`) keep the
  null type and are reported as `STRING`; arithmetic with one NULL operand takes
  the other operand's type.
* **Explicit-schema errors**: an unknown type name or invalid DECIMAL parameters
  in a `load` schema, `header: false` without a schema, or an invalid delimiter
  are `INVALID_REQUEST` (malformed request fields).
* **Whitespace-only CSV fields** are treated as empty for non-STRING columns
  (NULL; not considered during inference); STRING columns keep the raw text.
* **Empty CSV input** with `header: true` is an `INGEST_ERROR` unless an
  explicit schema is given (then the table is empty).
* **JSON keys** differing only in case are duplicate column names
  (`INGEST_ERROR`); explicit schemas match keys case-insensitively.
* **CAST from STRING** trims ASCII whitespace; `CAST(... AS TIMESTAMP)` requires
  the full timestamp syntax of types.md §3 (a bare date is a `CONVERSION_ERROR`;
  ingestion does accept dates for TIMESTAMP columns as specified).
  `FLOAT64 → DECIMAL` rounds the shortest round-trip decimal representation.
* **FLOAT64 output** uses the shortest round-trip representation, `-0` as `0.0`,
  and integral values keep a `.0` suffix.
* **LIMIT/OFFSET** must be constant INT64 expressions: non-constant ⇒
  `SEMANTIC_ERROR`, non-INT64 ⇒ `TYPE_ERROR`, negative ⇒ `INVALID_ARGUMENT`,
  `NULL` ⇒ no limit.
* **Query options**: `mode` accepts `auto`/`row` (`vectorized` ⇒ `UNSUPPORTED`);
  `optimize: false` skips the logical optimizer; `join: "nested_loop"` forces
  nested-loop joins (`hash`/`merge`/`auto` use the default choice);
  `threads`, `use_indexes`, `native`, `query_id` are validated and accepted
  (single-threaded execution, no indexes yet). Ill-typed option values ⇒
  `INVALID_REQUEST`.
* **Ops of later phases** (`save`, `open`, `stats`) answer `UNSUPPORTED`;
  unknown ops answer `INVALID_REQUEST`. `serve` exits with status 1.
  `CREATE INDEX` / `DROP INDEX` parse and answer `UNSUPPORTED` (no index
  capability yet).
* **UPPER/LOWER**: functions.md says "ASCII letters only are case-mapped",
  while the conformance suite expects `UPPER('abc Ünï') = 'ABC Ünï'` (the
  ASCII `n` inside a non-ASCII word stays lowercase). The engine maps ASCII
  letters of words (maximal runs of non-whitespace) that consist only of
  ASCII characters and leaves words containing other characters unchanged;
  for ASCII text this is exactly the specified behaviour.
* **NULL-typed arguments**: functions whose result type is "same as the
  argument" (`ABS`, `ROUND`, `FLOOR`, `CEIL`, `NULLIF`) keep the null type for a
  NULL literal argument (reported as `STRING`); functions with a fixed result
  type (`LENGTH` → INT64, `YEAR` → INT64, `DATE_TRUNC` → TIMESTAMP, …) report it.
  `ROUND(x, NULL)` is NULL. Constant parameters (`ROUND` digits, units) are
  evaluated during analysis; units are case-insensitive.
* **CASE/COALESCE unification** follows semantics.md §13 strictly: numeric
  promotion only, so mixing DATE and TIMESTAMP results is a `TYPE_ERROR`.
  Branch values are converted to the result type (DECIMAL rescaled).
* **HAVING** cannot reference select-list aliases (only GROUP BY and ORDER BY
  can, as specified); such references are unknown columns (`SEMANTIC_ERROR`).
* **GROUP BY alias** matching uses explicit aliases only; ORDER BY name
  matching uses all output names (aliases, column names and `_colN`).
* A qualified reference `r.c` resolves against the innermost range variable
  named `r`; it does not fall through to outer scopes if `r` lacks `c`.
* **Hash joins** are used when the join condition has at least one
  `left_expr = right_expr` conjunct; other conjuncts are evaluated as a
  residual. For INNER joins the smaller (estimated) input is the build side.
* `--max-join-rows` limits the output of every individual join operator.
* Defaults: `--max-query-memory-mb 4096`, `--max-ingest-bytes 4 GiB`,
  `--max-table-rows 500000000`. Memory accounting covers retained rows (sort
  buffers, hash tables, materialized join inputs and results).

## Known limitations

* Phase 3+ features (indexes, PQCF storage, statistics, HTTP server, execution
  modes) are not implemented yet.
* Execution is single-threaded and row-at-a-time.
* Predicates are not pushed into derived tables/CTEs, and correlated
  subqueries whose correlation is not an equality (e.g. `q.age < p.age`)
  rescan their input per distinct outer value.
* Sorting is not interruptible by a timeout while the in-memory sort itself
  runs (input consumption is).
