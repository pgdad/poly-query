# PolyQuery — Common Lisp implementation

An in-memory analytical SQL engine implementing the PolyQuery specification
(`spec/`) in ANSI Common Lisp on SBCL. Current scope: **Phase 1** (protocol,
catalog, CSV/JSON/JSONL ingestion, all data types, the `sql.basic` subset,
resource limits, test functions).

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
`test.functions`.

## Architecture

Processing follows the spec's pipeline, one module per stage
(`src/`, loaded in this order by `polyquery.asd`):

| Layer | Files | Responsibility |
|---|---|---|
| util | `errors`, `numbers`, `json` | `pq-error` condition with stable codes; exact numeric text parsing, correctly rounded float parsing, shortest round-trip float printing; strict RFC 8259 JSON reader/writer |
| types | `types`, `temporal`, `values`, `compare` | type representation, aliases, promotion lattice; DATE/TIMESTAMP calendar math; text conversion, `CAST`, canonical serialization; total ordering |
| storage | `table`, `catalog` | immutable column-oriented tables; case-insensitive catalog with atomic publish (mutex-protected for later concurrency) |
| ingest | `common`, `csv`, `json` | CSV parsing on raw UTF-8 octets, JSON/JSONL; type inference and explicit-schema conversion |
| sql | `lexer`, `ast`, `parser` | tokenizer with line/column positions; AST structures; recursive-descent parser for the **full** grammar of `grammar.md` |
| analyzer | `bound`, `functions`, `binder`, `query` | semantic analysis: name resolution, typing and implicit promotions, aggregate analysis (GROUP-BY-style structural rewrite), ORDER BY resolution, constant LIMIT/OFFSET |
| plan | `planner` | logical plan: `Scan`/`Values` → `Filter` → `Aggregate` → `Project` → `Sort` → `Limit`, with column pruning at the scan |
| exec | `context`, `expressions`, `aggregates`, `operators` | query context (deadline, cancellation flag, memory budget); expression compiler to closures; aggregate accumulators; Volcano-style iterators |
| protocol | `requests`, `cli` | JSON-lines request dispatch, validation and responses; CLI modes `version`, `capabilities`, `session`, `exec` |

Values are untyped at runtime; the static type in the plan decides their
meaning: NULL is `:null`, BOOLEAN is `t`/`nil`, INT64 an integer, FLOAT64 a
`double-float`, DECIMAL(p,s) its unscaled integer, STRING a Lisp string,
DATE days and TIMESTAMP microseconds since the epoch. Exactness comes from
Lisp's unbounded integers: INT64 and DECIMAL arithmetic is computed exactly
and range-checked afterwards; SUM/AVG accumulate exactly.

Expressions are compiled once per query into closures with all type dispatch
done at compile time. Operators are iterators (`build-iterator` generic
function per plan node), which keeps the row-at-a-time baseline required by
Phase 5 and leaves room for vectorized operators beside it.

### Extensibility notes (later phases)

* The parser already accepts the whole grammar (joins, GROUP BY, subqueries,
  CTEs, CASE, LIKE, BETWEEN, IN, EXPLAIN, CREATE/DROP INDEX); the binder
  reports these as `UNSUPPORTED` today. Adding them means extending the
  binder and planner, not the front end.
* Aggregation analysis already implements the structural GROUP BY rewrite of
  semantics.md §5 (with an empty GROUP BY list), and accumulators are created
  per group through factories.
* Scans read only referenced columns (column pruning), which the EXPLAIN
  `scan-columns` checks of Phase 3 rely on.
* The catalog is mutex-protected and tables are immutable, matching the
  snapshot isolation model of concurrency.md.

## Decisions on points the spec leaves open

* **Unsupported Phase-2 features** (GROUP BY, HAVING, DISTINCT, joins,
  subqueries, CTEs, CASE, LIKE, BETWEEN, IN, EXPLAIN, index statements, the
  scalar functions of functions.md other than `PQ_SLEEP`) answer
  `UNSUPPORTED`; `UNION`, `RIGHT`/`FULL` joins likewise. Unknown function
  names are `SEMANTIC_ERROR`. `COUNT(DISTINCT x)` and the other DISTINCT
  aggregates are implemented.
* Ops `explain`, `save`, `open`, `stats` answer `UNSUPPORTED`; `serve` exits 1.
* The NULL literal behaves as INT64 in arithmetic (`NULL + 1` is INT64,
  `NULL / 0` is NULL); an expression of the null type is reported as STRING.
* INT64 operands of DECIMAL arithmetic are promoted to DECIMAL(18,0) (so
  `1.5 * 2` is DECIMAL(18,1)); comparisons between numeric types are exact.
* `LIMIT NULL` / `OFFSET NULL` mean "no limit"/"no offset"; a non-INT64
  LIMIT is a `TYPE_ERROR`; ORDER BY ordinal 0 is out of range.
* CAST from STRING trims ASCII whitespace; `CAST('2024-01-01' AS TIMESTAMP)`
  is accepted (midnight). FLOAT64 → STRING uses the shortest round-trip text.
* `PQ_SLEEP` with a negative argument is `INVALID_ARGUMENT`.
* CSV: an input without any record (no header) is `INGEST_ERROR`; a
  `header: false` load without schema is `INVALID_REQUEST`; an unknown type
  in an explicit schema is `INVALID_REQUEST`; a delimiter must be one ASCII
  character other than `"`, CR, LF. A path naming a directory is `IO_ERROR`.
* JSON keys that differ only in case are distinct keys, so they produce
  duplicate column names (`INGEST_ERROR`). JSON numbers that do not fit a
  finite FLOAT64 are `INGEST_ERROR` under inference.
* Query option values: `mode` accepts `auto`/`row` (`vectorized` is
  `UNSUPPORTED`), `threads` ≥ 1 is accepted (execution is single-threaded,
  results are identical), `join`/`optimize`/`use_indexes`/`native` are
  validated and otherwise have no effect in Phase 1.
* Default limits: query memory budget 2048 MB (approximate accounting of
  materialized rows), ingestion 4 GiB, 200,000,000 table rows. Parser
  nesting depth is limited to 400 (deeper input is a `PARSE_ERROR`); heap or
  stack exhaustion is reported as `RESOURCE_LIMIT`.

## Testing

* `make test` — unit tests for numeric parsing/formatting, temporal values,
  types, JSON, lexer/parser, CSV/JSON ingestion and expression evaluation.
* Conformance: `python3 tests/conformance/runner.py --engine
  implementations/common-lisp/bin/polyquery --phase 1`.

## Known limitations

* Only Phase 1 features (see above).
* Two public conformance cases (`limits_and_output.pqt` lines 34 and 39)
  cannot pass with the current runner: `runner.py` overwrites every request's
  `id` with the step index before sending it, while those cases expect a
  custom `id` to be echoed. The engine echoes `id` verbatim as required by
  protocol.md §4 (verified manually).
* Loads materialize the whole input in memory (file octets plus parsed fields)
  before building columns.
