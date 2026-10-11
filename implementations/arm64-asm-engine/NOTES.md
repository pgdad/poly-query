# Working notes (arm64-asm-engine)

## Status (Phase 3, session 1) — complete
- Conformance: `--phase 1 --phase 2 --phase 3` = 554/554 (phase 3 143/143).
  `make build test lint` pass (new unit tests test_storage, test_pqcf,
  index cases in test_plan, tests/sh/run_storage_tests.sh).
- Modules: storage.S (table_finalize: null bitmaps, dictionary encoding, row
  layout, rebuild into a fresh arena; tbl_get; table_stats), index.S (HASH /
  BTREE, CREATE/DROP INDEX, lookups), access.S (simple predicates,
  selectivity, index choice, row-group skip test), pqcf.S (CRC-32, writer,
  validating reader, op_save/op_open), plan.S pp_access (estimates, hash join
  build side by swapping inputs), exec.S ex_scan (index scans, row groups).
- Verified with throw-away fuzzers outside the repo (/tmp/fz): index vs no
  index vs row/dict layouts; independent Python PQCF writer/reader (read,
  write, byte mutations); row-group skipping vs a Python oracle; SIGKILL
  during repeated saves. All clean.
- Index choice rule: selectivity <= 10%, or equality/IN lookup expected to
  return <= 16 rows (needed for the tiny `people` table in indexes.pqt).
- Possible next steps: cleanup of stale `.x.tmp-*` files on save; ordered
  output from BTREE indexes; index nested-loop joins; lazy mmap decoding.

## Gotchas (phase 3)
- Commit from implementations/arm64-asm-engine with `git add .` — never
  `git add -A` at the workspace root (agent worktrees live in
  workspace/.claude and would be committed as gitlinks).
- PR_* names belong to the planner's Pred struct (pq.inc); pqcf.S uses RD_*.

## Status (Phase 2, session 1)
- Conformance: `--phase 1 --phase 2` reports 411/411 pass (phase 1 225/225,
  phase 2 186/186 incl. the optional `sql.correlated_subquery` file).
- `make build test lint` pass. Unit tests: test_rt, test_values, test_json,
  test_parser, test_ingest, test_binder (SQL -> bind -> plan -> exec),
  test_functions, test_plan (EXPLAIN shape, joins, grouping, subqueries)
  + tests/sh CLI smoke tests.
- Performance (100k-row generated data): joins, GROUP BY, DISTINCT,
  IN-subqueries all run in ~1-15 ms.

## Pipeline / where things are
lexer.S -> parser.S (AST) -> binder.S (bind_query: scopes, typing,
grouping; functions.S/strfuncs.S for scalar functions, CASE, LIKE, BETWEEN,
IN lists) -> plan.S (plan_statement: logical plan, physical rewrite,
plan_explain JSON) -> exec.S (exec_plan; subquery evaluation ev_subq/
ev_exists/ev_insub) with eval.S (expressions, aggregates).
Shared structures: include/pq.inc (BoundQuery, RV, BoundFrom, SubPlan,
CteDef, PlanNode, TupleSet, EvalCtx). Frame macros: include/frame.inc.

## Design points to remember
- Tuples = u32 row id per range variable (ROW_NULL for LEFT JOIN padding).
- Column refs: N_B rv, N_VAL column, N_OP = outer depth (correlation);
  the EvalCtx chain (EC_OUTER) mirrors the binder context chain.
- Derived tables / CTEs are materialised into columnar Tables (cached unless
  the subquery is correlated, BQ_CORR). Uncorrelated expression subqueries
  are cached too (IN-subquery values sorted for binary search).
- Grouping is sort-based; GROUP BY expressions in SELECT/HAVING/ORDER BY are
  replaced by NK_GKEY (group_rewrite).
- UPPER/LOWER: a whitespace-delimited word containing non-ASCII is left
  unchanged (required by phase2/functions.pqt).

## Hardening done
- Two QA passes (≈2000 random join/group/subquery queries vs sqlite3, several
  hundred hand-written function/type cases): fixed DECIMAL common type,
  null-typed unary/ABS/ROUND/FLOOR, strict CAST to TIMESTAMP, grouping check
  for outer references from subqueries, ON-clause scope of parenthesised
  joins, subquery plans in EXPLAIN.
- Possible next steps: column pruning through derived tables/CTEs, hash-join
  build-side selection by cardinality (Phase 3), decorrelation.

## What is missing (later phases)
- Phase 3+: storage (PQCF), indexes (CREATE/DROP INDEX answer UNSUPPORTED),
  stats, HTTP server, parallelism, execution options.

## Gotchas
- Library modules must not reference globals defined in main.S (unit tests
  link everything except main.o).
- glibc data symbols (stdin/stderr) must be loaded via GOT_LOAD (PIE).
- Binding mutates the AST in place: never bind a node twice (shared operands
  of IN/CASE/BETWEEN are bound once and referenced by several comparisons).

## How to test
    make -C implementations/arm64-asm-engine build test
    python3 tests/conformance/runner.py --engine implementations/arm64-asm-engine/bin/polyquery --phase 1 --phase 2 -v
