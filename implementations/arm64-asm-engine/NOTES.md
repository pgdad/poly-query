# Working notes (arm64-asm-engine)

## Status (task: optimize latency, analytics workload @1m, session 1)
- Definition of done met so far: conformance unchanged (660/660, --modes
  3870/3870 also with PQ_PARALLEL_MIN_ROWS=1, http 660, http_suite 19/19),
  `make build test` pass, README "Latency optimization" has the
  before/after table (sum ~520 -> ~58 ms). Keep it current if numbers move.
- Benchmark: `bench/workload.sh DATA_DIR [RUNS] [OPTIONS_JSON]` (data:
  `python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pq1m
  --jobs 1`, DATA_DIR = /tmp/pq1m/1m; PQ_ENGINE=path overrides the binary;
  before: bench/workload-before.txt = commit e38bcc1 measured with the same
  script). The script reads responses from a regular file: bash `read` on a
  pipe is one syscall per byte (inflated wall times before that fix).
- Done (see README "Latency optimization" for the design): mallopt tuning;
  vectorized DISTINCT aggregates; parallel normalized-key radix sort and
  parallel top-N (sort.S); worker pool + thread_boost (uclamp) +
  pool_wake; hash-join fast paths, LEFT join build on smaller preserved
  side (SWAP_LBUILD); dictionary memo in veval; gt_ids / inline
  accumulation / partition-indexed merge in vagg.S; merge-join radix sort.
- Tools: PQ_TRACE_PAR=1 (per par_run: fn, tasks, wall, max task, sum),
  PQ_POOL_SPIN=us. Sampling profiler: /tmp/pqb/prof.sh style (gdb runs the
  engine, a loop sends SIGINT; `pkill -f` patterns can kill your own shell —
  use `pkill -x polyquery`). Diff harness idea: run the same queries under
  several option sets (row / vectorized / threads 1,3,16 / merge /
  optimize=false), compare exact output for ORDER BY, multisets otherwise.
- Measuring: big/little cores and EAS make numbers noisy; use >= 9 runs
  and medians; compare binaries with a git worktree of an older commit.
- Later in session 1: parallel merge join (radix index sort + chunked
  merge balanced by left+right work), parallel k-way merge for group order,
  radix sort of index row ids (q03), IS NULL bitmap path, memo only for
  "complex" trees. Merge join q10/q11: 70/107 -> 8/12 ms.
- Gotcha: GNU as numeric labels: `01:` IS label `1` (b.ne 1f jumps to it).
  Also local `9:` labels in helpers placed after a loop can capture an
  earlier `b 9b` (vagg agg_task hang). Use distinct numbers.
- Next candidates: q19 CTE (aggregate ~1.9 ms + merge ~1.2 ms + CTE
  materialization); sort encode phase (string prefix loads) and projection
  (48 MB of cells for q15); q11 vkey_cells materialization; hash-join
  build is serial; row mode is the spec's baseline (left alone).

## Status (change CR-2 decimal38, session 1)
- Conformance incl. changes/decimal38 (69/69): all phases 660/660,
  `--modes` 3870/3870, `--transport http` 660/660, http_suite 19/19;
  `make build test lint` pass. Capability `change.decimal38` claimed.
- Design: README "Change CR-2". Wide DECIMAL (p > 18) payload = pointer to a
  boxed i128; wdec.S has the 256-bit toolkit and all wide operations;
  `BR_WIDE` (pq.inc) is the narrow/wide test. Comparisons: no casts between
  decimals / INT64 vs wide (cmp_typed is exact and allocation-free); INT64 vs
  narrow DECIMAL -> saturating cast (T_SATF). Join keys of different
  encodings: try_hash_key casts both to saturating DECIMAL(W, max s).
- Avoid per-row/per-pair boxing in comparisons: nested-loop joins evaluate
  conditions per pair and the request arena only grows (RESOURCE_LIMIT).
- Boxed values must be deep-copied whenever a table arena is rebuilt
  (storage.S val_copy_in) — same rule as strings.
- PQCF: version 2 iff a wide column exists (pqcf_save scans the columns);
  reader pr_wide decodes PLAIN / RLE wide chunks.
- Fuzzed (throw-away harness /tmp/d38fuzz, outside the repo; Python
  decimal oracle): ~30k random queries x 9 option sets over CSV / JSON /
  row layout / indexes / PQCF round trips — 0 failures after the join fix.
  Open spec question (pre-existing, narrow too): INT64 -> DECIMAL promotion
  overflow is raised even if the other operand is NULL.
- Next: nothing required; possible: vectorized wide kernels (no boxing).

## Gotchas (CR-2)
- Never compare wide payloads with `cmp x0, x1` (pointers): use cmp_typed /
  value_cmp / wv_eq. Sites that special-case T_STR usually need BR_WIDE too.
- Type words may carry T_SATF (bit 24): extract scale / precision with ubfx,
  never `lsr #T_SCALE_SHIFT`.
- i256_from128 clobbers x3; keep values in callee-saved registers around it.

## Status (change CR-3 plan separation, session 1) — complete
- Conformance unchanged: all phases 591/591, `--modes` 3456/3456,
  `--transport http` 591/591, http_suite 19/19; capability set identical;
  `make build test lint` pass (new: tests/unit/test_optimizer.S, 42 cases:
  builder + every rule alone + optimizer on/off).
- Structure (README "Change CR-3", module map): logical.S (LogicalNode,
  lp_build, lp_exprs visitor, lp_print) -> optimize.S (rule table) +
  rule_prune / rule_fold / rule_simplify / rule_pushdown / rule_joinorder
  -> physical.S (phys_plan: placement, keys, algorithm, access paths,
  columns, build side, top-N PN_TOPN, PN_XMODE / PN_XTHREADS) -> exec.S
  (exec_settings installs the plan's mode / threads).
- Options: protocol writes planner inputs g_opt_* (plan.S); executor reads
  only g_x_mode / g_x_threads (set from the plan root).
- Rule order matters for identical plans: prune, fold, simplify,
  push_filters, reorder_joins, push_join_conditions (see README).
- optimize=false: no rule runs; physical.S still places conjuncts (same
  code as before) and uses RV_USED for unpruned scans (Phase 3 §3 + the
  --modes suite need pushdown / pruning / index scans with optimize=false).
- Differential check (throw-away, /tmp/diff/difftest.py, outside the repo):
  old vs new binary on every conformance SQL + /tmp/diff/cases/extra.pqt,
  explain + query x 10 option sets: 0 differences.
- Debug: PQ_TRACE_PLAN=1 prints the logical plan after every rule.

## Status (change CR-1 UNION ALL, session 1) — complete
- Conformance (incl. changes/union_all 22/22): all phases 591/591,
  `--modes` 3456/3456, `--transport http` 591/591, http_suite 19/19;
  `make build test lint` pass.
- Design: README "Change CR-1". Compound = binder level without range
  variables (bq_bind_union), branches nested below it; PO_UNION plan node
  (children in PN_KIDS/PN_NKIDS = join key fields); ex_union concatenates
  row pointers; branch columns are CAST to the common type at bind time.
- Tests added: test_parser (grammar, errors), test_plan (EXPLAIN shape,
  rows, errors), run_mode_tests.sh (7 UNION ALL queries x 8 option sets).
- Ad-hoc differential checks (outside the repo, /tmp/ua): correlated
  branches, CTE-in-compound / compound-in-CTE, nested compounds, DECIMAL /
  FLOAT promotion, NULL branches — identical under row / vectorized /
  threads / join / optimize=false with PQ_PARALLEL_MIN_ROWS=1.

## Status (Phase 5, session 1) — complete (definition of done met)
- Conformance: all phases 569/569, `--modes` 3324/3324 (also with
  `PQ_PARALLEL_MIN_ROWS=1`, which forces parallel tasks on tiny inputs —
  use it to test the parallel code paths), `--transport http` 569/569,
  http_suite 19/19. `make build test lint` pass (new: tests/unit/
  test_exec5.S — 30 cases x 6 settings; tests/sh/run_mode_tests.sh — 30
  queries x 8 option sets).
- Options: protocol.S parse_exec_opts -> TLS g_x_mode / g_x_join /
  g_x_threads / g_x_optimize (exec.S); default threads = --threads or
  min(nprocs, 8); threads < 1 UNSUPPORTED; g_par_min_rows (16384, env
  PQ_PARALLEL_MIN_ROWS).
- mode row = Volcano iterators (volcano.S: it_open / it_next; ex_tuples
  and ex_project dispatch to it_drain / it_project), sort-based grouping,
  qsort_r sorting, single-threaded.
- vectorized: vexec.S (veval kernels + row fallback, vfilter_sel, dict
  truth tables, NEON compare, vkey_cells tasks), vagg.S (hash aggregation,
  partial tables, gt_pmerge partitioned parallel merge, emit_groups,
  vdistinct), ops.S (filter / project tasks), join.S (hash join: hj_table,
  parallel probe; merge join: mj_side radix/qsort index sort; NL with
  keys), sort.S (normalized-key radix sort, parallel chunk sort + merge
  rounds for string keys), exec.S scan tasks over scan_ranges.
- parallel.S: par_run (worker threads with own arena + setjmp, arenas
  adopted by the caller, first error re-raised), wk_inline fallback,
  expr_par_safe.
- optimize.S: constant folding (try_eval), predicate simplification,
  join reordering (opt_join_order, regions >= 3 inputs; PN_MASK + combine()
  slot-wise AND). optimize=false also disables top-N and the hash build-side
  swap. Pushdown / pruning / index choice stay (Phase 3 suite runs with
  optimize=false in --modes and expects them).
- order_keys appends every visible column as a tie-breaker: ORDER BY output
  is identical in every mode even with ties.
- Benchmark: bench/bench.sh DATA_DIR (data: pqgen.py generate --scale 1m
  --out /tmp/pqbench/1m --jobs 1 — multiprocessing fails in the sandbox);
  before (commit d21cf39): bench/baseline-before.txt, after:
  bench/results-after.txt, README table.
- Fuzzing: /tmp/fz/fuzz.py (throw-away, outside the repo) compared 5
  option sets on > 5000 random queries (2-4-way joins, LEFT, grouping,
  DISTINCT, ORDER BY with ties / DESC / NULLS, LIMIT): 0 mismatches after
  fixing vfilter (right operand of AND must also be evaluated where the
  left one is NULL, like the row evaluator).

## Possible next steps
- vectorized streaming projection; better join cardinality estimates;
  parallel hash-join build; radix sort with NULLs in the keys.

## Gotchas (phase 5)
- Tuple width can be 0 (SELECT without FROM): copy loops must check it.
- Worker threads must not evaluate subqueries (SubPlan caches are shared):
  gate every parallel operator with expr_par_safe.
- Unit tests run with default (vectorized) mode: unordered results come
  in first-appearance order, not sorted.
- ENTER n saves x19..x(18+2n) only: a function using x25 needs ENTER 4.
- Every mode must evaluate the same operands as eval (errors!): AND/OR
  short-circuit only on the deciding value.

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
IN lists) -> plan.S (plan_statement / plan_query: logical.S lp_build ->
optimize.S rules -> physical.S phys_plan; plan_explain JSON) -> exec.S
(exec_plan; subquery evaluation ev_subq/ev_exists/ev_insub) with eval.S
(expressions, aggregates).
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
