# Working notes — x86-64 assembly engine

## Current task: CR-6 expression size limits (`change.expression_limits`) — DONE

Spec: `spec/changes/expression-limits.md`; README "Change CR-6" has the
limits, design and module list. Public check:
`python3 tests/regression/robustness_probe.py --engine implementations/x86_64-asm-engine/bin/polyquery --only expression_limits --require-pass`
→ pass (exit 0). Conformance 660/660, `--modes` 3870/3870 (also with
`PQ_PAR_MIN=1`), `--transport http` 660/660, http_suite 19/19,
`make build test lint` pass (CR-6 cases at the end of
`tests/session_test.sh`).
What was done:
1. Parser limits (`parser.S`): nesting depth 4096 parser levels
   (`p_enter`), operand count 1,000,000 (`p_operand` in `parse_primary`),
   both `RESOURCE_LIMIT` naming the measure. No text-length limit of its own.
2. Stacks: request thread on the 1 GiB mmap'd stack (guard pages added),
   pool workers 256 MiB (`par.S`), `STACK_CHECK` (pq.inc) at the entry of
   every recursive walker against TLS `t_stack_lo` (util.S), fault handler
   on an alternate stack in every thread maps stack faults to
   `RESOURCE_LIMIT`. The binder's old 400,000-call depth guard
   (`PARSE_ERROR`) is gone.
3. Linear stages: cached `expr_batch_const` (NF_BCDONE/NF_BCONST), fold
   skips parents of failed folds (NF_FOLDERR), lexer literal buffers,
   `veval` scratch compaction, `||` chains via `concat_chain` (eval.S).
4. Timeout: `deadline_tick` (every 1,024 calls, preserves all registers) in
   parser / binder / optimizer / planner walkers.
5. Memory: arena chunks mmap'd (not malloc: freed memory really returns),
   worker arenas share the request budget (`AR_PAR`, `g_par_mem`), fixed
   the 8 MiB vector-scratch leak per parallel part (`par_body`).
Test scripts used (outside the repo, in /tmp/elx: stress.py, wide.py,
wideb.py, deep.py, tmo.py, seq.py) generated hundreds of large statements
in all four probe modes; all answers correct / RESOURCE_LIMIT / TIMEOUT.
Ideas left: CTE lookup in the binder is linear per reference (100,000-CTE
chains time out); a 100,000-branch UNION ALL exceeds the default budget in
parallel modes (each branch's parallel scan allocates ~10 KiB per worker).

## Previous task: optimize latency of benchmarks/workloads/analytics.json (1m)

Measure: `python3 datasets/generators/pqgen.py generate --scale 1m --out /tmp/pqdata --jobs 1`
(`--jobs` > 1 fails in this sandbox: no POSIX semaphores), then
`sh bench/workload.sh /tmp/pqdata/1m 5` (median / best stats.elapsed_us per
query; `PQ_BENCH_OUT=FILE` saves the result rows to diff two builds).
Baseline numbers: `bench/workload-before.txt` (engine at e912c3e).
Done so far (each verified: conformance 660/660, `--modes` with
PQ_PAR_MIN=1 3870/3870, http 660/660, http_suite 19/19, make test, and
byte-identical full results vs the baseline engine on 1m data):
1. default `threads` = `--threads N` or online CPUs capped at 16 (mode
   "row" without `threads` stays 1 thread = baseline) — main.S
   resolve_threads, protocol.S.
2. keysort.S: ORDER BY in batch modes via normalized u64 key words + MSD
   radix per run + parallel merges (fallback: old comparison sort).
3. pexec.S pexec_dsplit: hash-partitioned parallel DISTINCT aggregates
   (single group only; FLOAT64 SUM/AVG/MIN/MAX DISTINCT stay serial).
4. util.S arena chunk pool (reuse released chunks up to 1 GiB; fork child
   calls chunk_pool_forget).
5. GROUP BY local aggregation per part (pexec.S lagg_ok / lagg_merge,
   gfused_part with PT_LMAX / PT_LABORT) for few groups.
6. Parallel hash-join build (pexec.S pexec_build: bkey_part, bins_part
   with disjoint bucket ranges; hooked in exec.S exec_from).
7. Hash-partitioned GROUP BY: first-seen order from per-tuple slots
   (slot_order), parallel emission (pexec_emit / emit_part), radix
   partitioning of the tuples (aux_new, gkey_part counts, dsplit_bounds,
   dscat_part) shared with the DISTINCT aggregates (dkey_part / dins_part,
   open-addressing oset_* for integer-like values).
8. par.S persistent worker pool (par_worker, pool_worker, spin then
   condvar; threads pinned to CPUs of the affinity mask via pool_pin;
   forked serve children: par_after_fork, no pinning). Unpinned, the pool
   was slower on simple scans (threads shared cores) - keep the pinning.
9. Hash join FastTable (pexec.S fins_part, fast_key_ok; probe_part
   label 15) for integer-like keys of one type.
10. keysort: no pre-scan for plain non-NULL columns; STRING keys assumed
   short, KS_TW (trusted words) lowered when encoding sees a long value.
Workload total: 1120 ms -> ~85 ms (README table, bench/workload.sh 7 reps,
bench/workload-before.txt / workload-after.txt).
Results of all 20 queries byte-identical to the baseline engine.
Measuring: the machine is noisy (+-20% between runs); compare builds with
interleaved A/B rounds (per-query minimum), not single runs.
Ideas next: q14 / q15 sorts (~16 ms: ~5 ms scan + projection of 1M rows,
then encode 3, classify 1.3, scatter 1.4, bucket MSD 3.5 ms; entries could
drop the row pointer - rows[seq] - to shrink them), q19 / q07 (high-card
GROUP BY ~6 ms), q10 / q12 joins (~6 ms), q03 index range scan (0.7 ms,
was 0.6 with one thread).

## Status (Phase 5 + CR-1 UNION ALL + CR-3 plan separation + CR-2 DECIMAL(38))

* CR-2 `DECIMAL` precision 38 is complete (capability `change.decimal38`,
  README "Change CR-2"): `changes/decimal38.pqt` 69/69, the whole suite
  660/660, `--modes` 3870/3870, `--transport http` 660/660, http_suite
  19/19, `make build test lint` pass (new `tests/test_dec128.S`, wide-decimal
  table `w` in `tests/modes_test.sh`).
  Representation: narrow (p <= 18) inline i64 as before; wide (p > 18) slot
  = pointer to an immutable 16-byte i128 box (like pstr*), dispatched on
  `dec_is_wide(type)`; all wide math in `src/dec128.S` (256-bit
  intermediates, 192-bit SUM accumulators in AS_LO/AS_HI/AS_VAL).
  Things that are easy to break: (1) every consumer of DECIMAL payloads
  must check wideness (value_cmp, hash_cells, conv_exact, to_num, radix
  sort, PQCF, vec kernels); (2) INT64 vs DECIMAL comparisons are no longer
  cast by the binder (exact compare at run time: eval cmp_values,
  functions cmp_mixed, vec 45/46 paths, exec in_key for IN subqueries,
  planner equi_key_type for join keys); (3) wide boxes for stored data must
  be allocated in the table arena (dec_box_in), computed ones in the
  request / worker arena (dec_box).
  Verified the wide results against Python decimal with scripts kept
  outside the repo: (1) the modes_test `w` table, ~10 aggregate /
  arithmetic / rounding queries in 3 option sets; (2) a random-expression
  fuzzer (20,000 cases: + - * with W / TYPE_ERROR / overflow rules,
  comparisons incl. INT64, ROUND / FLOOR / CEIL, CASTs to DECIMAL / INT64 /
  FLOAT64, unary minus / ABS) - 0 differences; (3) PQCF v2 round trips
  (PLAIN / RLE / auto, eager and mmap) of +-(10^38 - 1) values, plus an
  independent Python decode of the written chunks.
  Possible follow-ups: vectorized (batch) kernels for wide arithmetic and
  comparisons (they run tuple at a time through eval today); a cheaper
  key than boxed DECIMAL(38,s) for INT64 = narrow DECIMAL hash joins.

* CR-3 logical / physical plan separation is complete (README "Change
  CR-3" has the before / after module map). Pipeline per query block
  (`plan.S` `plan_block`, called by the binder): `lp_build` (lplan.S) →
  `optimize_logical` (optimizer.S; rules rule_pushdown.S, rule_prune.S,
  rule_fold.S; none with optimize:false) → `phys_plan` (planner.S).
  Unit tests per rule: `tests/test_optimizer.S` (prints logical plans with
  `lp_print` and compares text). Verified with a differential replay
  against the pre-CR-3 engine (all conformance files + EXPLAIN of every
  query, 9 option sets, 10,800 requests, plus 1,107 edge-case requests):
  byte-identical. The differential script is not in the repo (it lived in
  /tmp); rebuild the old engine with
  `git archive 1d8f2a3 implementations/x86_64-asm-engine | tar -x -C DIR`.
* Behaviour-preservation mechanisms to keep in mind: (1) the physical
  planner places conjuncts of an *unplaced* WHERE Filter itself (Phase 3
  pushdown must stay on with optimize:false); Filters the pushdown rule
  made carry LFF_PUSHED / LFF_RESIDUAL and are mapped verbatim. (2)
  Rewritten expression nodes keep their as-written copy in N_WRITTEN;
  physical analysis (`simple_const`, `analyze_conj`, `find_equi`) goes
  through it, so optimize never changes access paths / join keys. (3) The
  executor reads `g_exec_mode` / `g_exec_threads` (set by
  `phys_exec_settings`), never the raw options.

* CR-1 `UNION ALL` is complete (capability `change.union_all`, README
  "Change CR-1"): `changes/union_all.pqt` 22/22 in every mode, the whole
  suite with `--modes` and `--transport http` 0 failures, http_suite 19/19,
  `make build test lint` pass. Compound plans: `QP_NUNION`/`QP_UNION`
  (binder.S `bind_compound`, exec.S `exec_union`, explain.S `UnionAll`).
  `spec_version` stays `1.0.0` because phase1/catalog.pqt requires it.

* Public conformance suite:
  `python3 tests/conformance/runner.py --engine implementations/x86_64-asm-engine/bin/polyquery`
  → phase 1 225/225, phase 2 186/186, phase 3 143/143, phase 5 15/15.
  `--modes` → 3324/3324 (also with `PQ_PAR_MIN=1`, which forces parallel
  parts onto the tiny test tables — use it whenever touching pexec/vec/par).
* `python3 tests/concurrency/http_suite.py --engine …` → 19/19.
* `make build test lint` pass; `make test` includes `tests/modes_test.sh`
  (differential: row / vectorized / parallel / join algorithms / optimize
  must give byte-identical responses incl. errors).
* Capabilities: Phase 1–4 set plus `phase5 exec.row exec.vectorized
  exec.parallel join.hash join.merge join.nested_loop` (not
  `native.kernels`; the `native` option is accepted and ignored).

## Phase 5 design in one paragraph

Options parsed in `protocol.S` (`check_exec_options` → `g_opt_mode`,
`g_opt_join`, `g_opt_threads`, `g_opt_optimize`). `mode:"row"` with 1 thread
= the untouched Phase 4 interpreter in `exec.S` (baseline). Everything else
goes through `pexec.S` (hooks in `exec_scan`, `exec_plan` WHERE / aggregate /
projection and the hash-join probe in `exec_from`): operators split their
input with `par_for` (`par.S`) and run batches (VB = 1024) through `k_*`
kernels that dispatch to row (`rk_*`) or vector (`vk_*`, `vec.S`) versions.
Workers: thread-local `t_arena` / `t_jmpbuf` / error slot (util.S), TLS cast
buffer (eval.S), TLS vector scratch stack (vec.S). Join algorithm chosen in
`planner.S choose_join` (`FP_ALGO`), merge join in `join.S`. Logical
optimizer rules (see CR-3 above) run when `optimize` is true; pushdown /
index selection stay on with `optimize:false` (the conformance `--modes`
matrix expects IndexScans with optimize:false). README "Phase 5"
has the full description and the measurements (`bench/bench.sh`).

Later additions: stable ORDER BY everywhere (`sort_rows`: (row, sequence)
pairs; top-N heaps tie-break on the sequence too), parallel sort
(`pexec_sort`: sorted runs + pairwise parallel merges), parallel batch
nested-loop join (`pexec_nl`, parts sized by pair count), merge join with
radix sort for integer-like keys and vectorized key evaluation, error replay
in `exec_query_result` (a data error in a batch/parallel run re-runs the
query in the row baseline so multi-error queries report the baseline's
error); `optimize` never changes which rows are scanned (since CR-3 via
N_WRITTEN, before via running the optimizer after physical planning).

Verification beyond the suites: a random-expression fuzzer (kept outside
the repo: generated queries over a table with NULLs in every column type,
compared row/1-thread/optimize:false against vectorized and parallel
option sets, multiset + 1e-9 float tolerance) ran >6,000 queries per
option set, also on row-layout and mmap'd PQCF tables, with no differences.

## Invariants to keep

* Output order of every mode = row baseline order (parts concatenated in
  order; groups sorted by first tuple; hash chains in build order; merge
  join emits per left tuple; ORDER BY is stable). Breaking it makes
  `modes_test.sh` fail. (Exception by design: a hash join building on its
  smaller left input emits right-input order, in every mode.)
* Vectorized evaluation must only compute fallible operations on rows the
  row engine evaluates (active masks in `veval`).
* Anything executed inside workers must not write shared state: plans with
  subqueries run with 1 part (`pexec_threads`), lazily decoded PQCF columns
  are decoded first (`par_prepare`).

## Next steps / ideas

* With the logical plan in place, join reordering for chains of inner
  joins would be a natural next rule (it changes EXPLAIN and row order, so
  it is out of scope for the behaviour-preserving CR-3).
* Parallel hash build and merge-join sort; DISTINCT via partitioned
  hashing; canonical (left-major) output order for hash joins that build
  on the left input.
* Vector fast paths for IN lists, BETWEEN, LIKE prefix patterns, CASE.
* Possible improvements from Phase 4: release `cat_lock` during `save`,
  `stats` and `CREATE INDEX`; decode mmap'd PQCF columns once in the server
  instead of per query child.
