# Working notes — x86-64 assembly engine

## Status (Phase 2)

* Public conformance suite: `python3 tests/conformance/runner.py --engine
  implementations/x86_64-asm-engine/bin/polyquery --phase 1 --phase 2` →
  411/411 pass (phase 1 225/225, phase 2 186/186 incl. the optional
  correlated-subquery file).
* `make build test lint` pass: unit tests `test_text`, `test_json`,
  `test_ingest`, `test_hash`, `test_sql` (pipeline incl. Phase 2 statements)
  and `tests/session_test.sh` (e2e).
* Capabilities claimed: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic
  test.functions phase2 sql.groupby sql.join sql.functions sql.subquery
  sql.cte sql.correlated_subquery`.

## What works

* CLI: `version`, `capabilities`, `session`, `exec --request FILE|-`; all
  common options parsed (`--opt value` and `--opt=value`), unknown ⇒ exit 2;
  `--max-join-rows` enforced.
* Ops: load, query, explain, tables, schema, drop, reset, version,
  capabilities, sleep; save/open/stats ⇒ UNSUPPORTED (Phase 3).
* Ingestion CSV/JSON/JSONL with inference and explicit schemas, limits.
* Full SQL grammar: WITH (CTEs, column lists), SELECT [DISTINCT|ALL], `*`,
  `q.*`, FROM with INNER/LEFT/CROSS/comma joins, parenthesised joins, derived
  tables, WHERE, GROUP BY (expressions, aliases, ordinals), HAVING, ORDER BY,
  LIMIT/OFFSET; all scalar functions, CASE, LIKE, BETWEEN, IN lists,
  scalar / IN / EXISTS subqueries (uncorrelated cached, correlated
  re-executed), EXPLAIN (statement and op), CREATE/DROP INDEX parsed
  (UNSUPPORTED). PARSE_ERROR carries `details.line/column`.

## Module map

See README.md (layer table). Layouts: `include/pq.inc` (runtime, JSON DOM,
Table/Column, Schema), `include/sql.inc` (tokens, statement / query / FROM /
expression nodes, plan `QP_*`, FROM plan `FP_*`, range variables `RV_*`,
results `RS_*`, eval context, hash table).

## Next steps (Phase 3+)

* Row/column layouts, statistics (`stats`), predicate pushdown into scans
  (WHERE conjuncts on one range variable), column pruning (the binder already
  records referenced columns in `RV_USED`; EXPLAIN reports them).
* Hash / BTREE indexes (`CREATE INDEX` already parses into `STMT_CREATE_INDEX`).
* PQCF save/open.
