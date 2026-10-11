# Working notes — x86-64 assembly engine

## Status (Phase 1)

* Public conformance suite: `python3 tests/conformance/runner.py --engine
  implementations/x86_64-asm-engine/bin/polyquery --phase 1` → 225/225 pass.
* `make build test` passes: unit tests `test_text` (330), `test_json` (286),
  `test_ingest` (223), `test_sql` (45) and `tests/session_test.sh` (24 e2e).
* Capabilities claimed: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic test.functions`.

## What works

* CLI: `version`, `capabilities`, `session`, `exec --request FILE|-`; all
  common options parsed (`--opt value` and `--opt=value`), unknown ⇒ exit 2.
* Ops: load, query, tables, schema, drop, reset, version, capabilities, sleep;
  explain/save/open/stats ⇒ UNSUPPORTED.
* Ingestion CSV/JSON/JSONL with inference and explicit schemas, limits.
* SQL `sql.basic` incl. all literals, CAST matrix, exact DECIMAL, 3VL,
  ORDER BY (ordinal/alias/expression, NULLS FIRST/LAST), LIMIT/OFFSET,
  whole-table aggregates, `_colN` naming, max_rows, result:"count",
  timeout_ms, PQ_SLEEP.

## Module map

See README.md. Layouts: `include/pq.inc` (runtime, JSON DOM, Table/Column,
Schema), `include/sql.inc` (tokens, AST nodes, SelectStmt, plan, eval ctx).

## Next steps (Phase 2+)

* Parser: replace the `p_unsupported` calls for joins, derived tables,
  subqueries, CASE/IN/BETWEEN/LIKE, WITH, EXPLAIN, CREATE/DROP INDEX with AST
  construction (node kinds to add in `sql.inc`).
* Binder: GROUP BY/HAVING/DISTINCT (structural equality of expressions),
  multiple range variables (EC_ROW becomes one row index per range variable).
* Executor: hash aggregation keyed on value cells; hash join; DISTINCT.
* Scalar functions, CASE, BETWEEN, IN lists and LIKE: done (`src/functions.S`,
  hooked from `bind_expr_node` and `eval`).
