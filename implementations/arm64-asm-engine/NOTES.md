# Working notes (arm64-asm-engine)

## Status (Phase 5, session 1) — in progress
- Conformance: all phases 569/569, `--modes` 3324/3324 (also with
  `PQ_PARALLEL_MIN_ROWS=1`, which forces parallel tasks on tiny inputs —
  use it to test the parallel code paths). `make build test` pass.
- Options (protocol.S parse_exec_opts -> TLS g_x_mode / g_x_join /
  g_x_threads / g_x_optimize in exec.S; default threads = --threads or
  min(nprocs, 8)). Capabilities phase5, exec.*, join.* claimed.
- New modules: join.S (hash / merge / nested-loop joins), vexec.S (batch
  expression evaluator veval, vfilter, vkey_cells), vagg.S (hash
  aggregation, partial tables merged in task order), parallel.S (par_run:
  worker threads with own arena/setjmp, arenas adopted by the caller).
- mode row = old executor (per-tuple eval, sort-based grouping);
  vectorized = batch scans/filters, hash aggregation, vectorized join keys.
- optimize=false disables: top-N, hash-join build-side swap (and future
  logical rewrites). Pushdown / pruning / index choice stay (Phase 3 suite
  runs with optimize=false in --modes and expects them).
- Benchmark: bench/bench.sh DATA_DIR (data: pqgen.py generate --scale 1m
  --out /tmp/pqbench/1m --jobs 1); baseline before Phase 5 in
  bench/baseline-before.txt.

## Next steps (Phase 5)
- constant folding / predicate simplification (optimize=true only)
- dictionary-code comparisons for STRING = constant, explicit NEON kernel
- vectorized projection; faster merge join (vectorized keys)
- README: Phase 5 section with before/after table

## Status (Phase 4, session 1) — complete
- Conformance: session and `--transport http` both 554/554 for phases 1-3
  (phase 5: 15 not_implemented, out of scope). `tests/concurrency/http_suite.py`
  19/19. `make build test lint` pass (new: test_catalog.S, tests/sh/run_http_tests.sh).
- New modules: http.S (listener, connection threads, HTTP framing, routing,
  streaming, shutdown), server.S (query registry, admission control,
  cancellation, disconnect watchdog, metrics), log.S (JSON logs).
- Runtime state moved to TLS (TLS_ADDR / TLS_LDR macros, pq.inc).
- catalog.S rewritten: immutable refcounted versions (snapshot isolation);
  index registry lives in the version (index.S CAT_FIELD macro).
- protocol.S: handle_request (transport independent, forced op / prebuilt
  JNode for HTTP endpoints), op table with catalog access mode, op_query
  admission + streaming hooks; out_columns / out_rows / put_error_object.
- exec.S: exec_plan_stream (batched projection to a sink).
- Verified with throw-away scripts outside the repo (/tmp/pqt): 16-thread
  mixed stress (loads/replaces/drops/indexes/save/open/queries/streams/
  cancels) for 20 s with snapshot-consistency checks — no errors, clean
  exit; RSS stable over repeated load/query rounds (no leaks).
- Possible next steps: interruptible sorts; Phase 5 (intra-query threads,
  execution modes, join algorithms).

## Gotchas (phase 4)
- Never `pkill -f 'polyquery serve'` from a shell whose own command line
  contains that text (kills the shell). Use PIDs.
- Every request must begin its catalog access explicitly (op table CA_*,
  op_query calls cat_read_begin / cat_write_begin); catalog functions called
  with no active version silently start a *write* transaction (unit tests).
- `.irp` with quoted arguments: cpp does not expand macros inside quotes.
- handle_request's g_jmpbuf frame is dead after it returns: code outside it
  (http.S) must not call anything that raises.

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
- Phase 5: parallelism, execution options (mode/join/optimize/threads).

## Gotchas
- Library modules must not reference globals defined in main.S (unit tests
  link everything except main.o).
- glibc data symbols (stdin/stderr) must be loaded via GOT_LOAD (PIE).
- Binding mutates the AST in place: never bind a node twice (shared operands
  of IN/CASE/BETWEEN are bound once and referenced by several comparisons).

## How to test
    make -C implementations/arm64-asm-engine build test
    python3 tests/conformance/runner.py --engine implementations/arm64-asm-engine/bin/polyquery --phase 1 --phase 2 -v
