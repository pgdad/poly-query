# PolyQuery — Go engine

An analytical database engine implementing the PolyQuery specification
(`spec/`), currently **Phase 3**: the complete SQL v1 query language over
row- or column-oriented in-memory tables, persistent PQCF v1 columnar files,
statistics, hash and ordered indexes and a planner with predicate pushdown,
row-group skipping, column pruning and index selection.

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
`sql.subquery`, `sql.cte`, `sql.correlated_subquery`, `phase3`,
`storage.pqcf`, `storage.mmap`, `index.hash`, `index.btree`.

`storage.mmap` uses real memory mapping (`syscall.Mmap`, standard library)
on all Unix platforms; on other platforms `open` falls back to reading the
file into memory (chunks are still decoded lazily).

## Design overview

A statement flows through distinct, inspectable stages, one package each:

```
SQL text ─lexer→ tokens ─parser→ AST ─analyzer→ logical plan ─optimizer→ logical plan
        ─physical→ physical plan ─exec→ operator tree → rows
```

| Package | Responsibility |
|---|---|
| `cmd/polyquery` | CLI: modes `version`, `capabilities`, `session`, `exec` (`serve` is reserved for Phase 4), option parsing, JSON logs on stderr |
| `internal/protocol` | JSON request decoding/validation, op dispatch (incl. `explain`, `save`, `open`, `stats`), single-line JSON response writer, session loop and exec mode |
| `internal/engine` | Facade owning config + catalog: path safety, file loading with limits, the query pipeline, `EXPLAIN`, `CREATE/DROP INDEX`, `save`/`open`/`stats`, `max_rows`, timeouts |
| `internal/sql/lexer` | Tokens with 1-based line/column positions; comments, quoted identifiers, reserved keywords |
| `internal/sql/ast`, `internal/sql/parser` | Recursive-descent parser for the full v1 grammar producing an AST; `PARSE_ERROR` carries `line`/`column` |
| `internal/analyzer` | Semantic validation: scopes and range variables, CTE environments, name resolution (incl. outer scopes for correlation), typing with implicit promotions, function signatures, aggregate/grouping rules, ORDER BY resolution; produces the logical plan |
| `internal/plan` | Bound typed expressions and logical plan nodes (`Scan`, `Values`, `Filter`, `Project`, `Aggregate`, `Join`, `Sort`, `Limit`, `Distinct`); every produced column has a statement-unique `ColumnID` |
| `internal/optimizer` | Logical rewrites: predicate pushdown through joins (WHERE/ON conjuncts on one input move below the join, spanning conjuncts become join conditions, so comma joins become inner joins) and through projections (derived tables, CTEs), sorts and DISTINCT, so that predicates end up directly above table scans |
| `internal/physical` | Physical planning: access paths (index selection from statistics, row-group skipping filters), hash join for equi-joins (build side by estimated cardinality), nested-loop join otherwise, hash aggregation, hash distinct, top-N sort; column pruning (scans read only referenced columns); correlated-subquery helpers; EXPLAIN JSON |
| `internal/exec` | Volcano operators (table scan with row-group skipping, index scan, …); expressions compiled to closures against the input row layout; all scalar functions, LIKE, CASE, BETWEEN, IN; subquery evaluation; cancellation checks; approximate memory accounting; `--max-join-rows` |
| `internal/storage` | Immutable tables split into row groups, each either column-oriented (typed vectors with validity bitmaps, STRING columns optionally dictionary-encoded, chunks optionally decoded lazily) or row-oriented (tuples); per-group min/max/null statistics; lazily computed table statistics |
| `internal/index` | Single-column HASH (hash map value → row IDs) and BTREE (sorted permutation with binary search) indexes |
| `internal/catalog` | Copy-on-write catalog of tables and globally named indexes: every mutation publishes a new immutable snapshot atomically |
| `internal/pqcf` | PQCF v1 reader (full validation, PLAIN/DICT/RLE decoding, CRC-32, memory mapping with lazy chunk decoding) and atomic writer (encoding choice, statistics, temp file + fsync + rename + directory fsync) |
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

### Storage (Phase 3)

* **Layouts.** `load`/`open` accept `{"layout": "row"|"column"}` (default
  `column`) and `{"dictionary": true}`. Tables are split into row groups of
  65,536 rows (PQCF tables keep the file's row groups). In the column layout
  each group holds one vector per column (`[]int64` for BOOLEAN, INT64,
  DECIMAL unscaled, DATE, TIMESTAMP; `[]float64`; `[]string` or dictionary
  + `[]uint32` codes) plus an LSB-first validity bitmap (absent when the
  chunk has no NULLs). STRING chunks are dictionary-encoded automatically
  when they have fewer distinct values than half their rows, or always with
  `dictionary: true`. The row layout stores `[]types.Row` tuples. Scans,
  index scans, statistics and `save` work on both through one row-group
  reader, so results are identical by construction (and the conformance
  suite was also run with row layout, forced dictionaries and tiny row
  groups as defaults).
* **PQCF writing** follows the spec byte-exactly: chunks start at 8-byte
  aligned offsets with zero padding, NULL slots are zero / empty / code 0,
  validity bitmaps only when `null_count > 0`, `min`/`max` for every type
  except STRING (optional per spec, omitted to avoid cross-language string
  ordering issues). `encoding: auto` uses RLE when the run count is below
  n/4 (BOOLEAN, INT64, DECIMAL, DATE, TIMESTAMP) and DICT when the distinct
  count is below n/2 (STRING); forced encodings fall back to PLAIN for types
  they do not apply to. `row_group_size` defaults to 65,536.
* **Atomic saves**: the file is written to `.<target>.tmp-<random>` in the
  target directory, fsynced, renamed over the target and the directory is
  fsynced. Stale temporary files of earlier crashed saves to the same target
  are removed by the next save (never those of saves in progress).
* **PQCF reading** validates header (magic, version 0 ⇒ `STORAGE_CORRUPT`,
  version > 1 or flags ≠ 0 ⇒ `STORAGE_VERSION_UNSUPPORTED`), footer,
  metadata CRC, UTF-8 and every structural rule of §2; unknown encodings ⇒
  `STORAGE_VERSION_UNSUPPORTED`. Bytes between chunks must be zero (the spec
  only allows zero padding; this makes bit flips there detectable, too).
  Chunk decoding checks the CRC, bitmap NULL count, exact chunk size and all
  value rules of §3.4. Without `mmap` the whole file is verified and
  decoded at `open`; with `mmap: true` (column layout) the file is
  memory-mapped and each chunk is verified and decoded on first access (a
  query touching a damaged chunk fails with `STORAGE_CORRUPT`). Decoded data
  never aliases the mapping, which is unmapped once the table is no longer
  referenced. Malformed or missing `min`/`max` metadata is treated as
  unknown (it only enables skipping).
* **Statistics**: per row group (null count, min, max — computed for loaded
  data, taken from file metadata for lazily decoded PQCF chunks) and per
  table column (null count, min, max, distinct count), computed on first use
  and cached. Distinct counts are exact up to 131,072 distinct values and
  HyperLogLog estimates (≈0.8% error) beyond, bounding memory on big tables.

### Indexes and planning

* `CREATE INDEX` builds the index immediately; HASH maps values (DECIMAL
  unscaled at the column scale, `-0.0` normalized) to ascending row IDs;
  BTREE is a sorted permutation of the non-NULL rows (ties by row ID)
  answering equality and range lookups by binary search. NULLs are never
  indexed. Indexes are stored in the catalog with the exact table version
  they were built for; they are listed in PQCF metadata on `save` and rebuilt
  on `open`.
* **Search arguments**: WHERE conjuncts `col op const`, `const op col`,
  `col BETWEEN const AND const` and `col IN (consts)` (also through the
  implicit INT64→DECIMAL and DATE→TIMESTAMP promotions) are translated into
  the column's own domain (e.g. `int_col > 2.5` ⇒ `int_col > 2`,
  `int_col = 2.5` ⇒ no rows, `date_col < TIMESTAMP '… 12:00'` ⇒
  `date_col <= …`). Constants are evaluated at planning time; a constant
  that fails to evaluate just disables the optimization.
* **Row-group skipping**: a table scan below a filter skips row groups whose
  min/max (or all-NULL) statistics exclude any search argument.
* **Index selection** (indexes-and-planning.md §3): candidates are a single
  `=`/`IN` conjunct (HASH or BTREE) or all range conjuncts on one column
  combined into one interval (BTREE). Selectivity: points/distinct for
  equality, linear interpolation between min and max for numeric/temporal
  ranges, 1/3 otherwise. The most selective candidate is used if its
  selectivity is ≤ 10%, or — for point lookups — if it is expected to return
  at most 5 rows (only relevant for tables under 50 rows, where one key is
  already more than 10% of the table but a probe is still cheaper than a
  scan; the conformance suite expects an index scan for an equality on an
  8-row table). The conjuncts answered by the lookup are dropped, the rest
  stay in a filter above the `IndexScan`. `use_indexes: false` disables
  index selection.
* **Join build side**: estimated cardinalities use the same statistics
  (product of conjunct selectivities, 1/3 for non-sargable conjuncts).
* **EXPLAIN**: `TableScan` (`table`, `columns`, `layout`, `row_groups`,
  `row_group_filters`) and `IndexScan` (`table`, `index`, `kind`, `columns`
  = all columns the query reads from the table, including the indexed one,
  `condition`, `lookup`).

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
* **Unknown ops** answer `INVALID_REQUEST`. `serve` (Phase 4) exits with
  status 1.
* **Storage options**: an invalid `layout`, non-boolean `dictionary`/`mmap`,
  non-positive `row_group_size` or unknown `encoding` value is
  `INVALID_REQUEST`. `open` answers like `load` (`table`, `row_count`,
  `columns`); `schema` additionally reports `layout`.
* **CREATE INDEX** checks table and column (`SEMANTIC_ERROR`) before the
  index name (`ALREADY_EXISTS`); `IF NOT EXISTS` with a taken name does
  nothing even if the existing index is on another table. Index names are
  case-insensitive like table names. `EXPLAIN` of `CREATE/DROP INDEX` is
  `INVALID_REQUEST`.
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

* Phase 4+ features (HTTP server, execution modes) are not implemented yet.
* Execution is single-threaded and row-at-a-time.
* Indexes are not used for `OR` predicates, `NOT IN`/`<>`, expressions over
  the column (e.g. `col + 1 = 5`) or INT64/DECIMAL columns compared with
  FLOAT64 values, and not to produce ordered output. Predicates are not
  pushed through GROUP BY or LIMIT.
* Correlated subqueries whose correlation is not an equality (e.g.
  `q.age < p.age`) rescan their input per distinct outer value.
* Sorting is not interruptible by a timeout while the in-memory sort itself
  runs (input consumption is).
