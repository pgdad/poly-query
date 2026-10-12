# Working notes — x86-64 assembly engine

## Status (Phase 5 + change CR-1 UNION ALL)

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
optimizer `optimizer.S` (constant folding that keeps failing subtrees,
AND/OR simplification) runs from `plan_block` when `optimize` is true;
pushdown / index selection stay on with `optimize:false` (the conformance
`--modes` matrix expects IndexScans with optimize:false). README "Phase 5"
has the full description and the measurements (`bench/bench.sh`).

Later additions: stable ORDER BY everywhere (`sort_rows`: (row, sequence)
pairs; top-N heaps tie-break on the sequence too), parallel sort
(`pexec_sort`: sorted runs + pairwise parallel merges), parallel batch
nested-loop join (`pexec_nl`, parts sized by pair count), merge join with
radix sort for integer-like keys and vectorized key evaluation, error replay
in `exec_query_result` (a data error in a batch/parallel run re-runs the
query in the row baseline so multi-error queries report the baseline's
error), optimizer moved *after* physical planning (so `optimize` never
changes which rows are scanned).

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

* Join reordering for chains of inner joins (not implemented).
* Parallel hash build and merge-join sort; DISTINCT via partitioned
  hashing; canonical (left-major) output order for hash joins that build
  on the left input.
* Vector fast paths for IN lists, BETWEEN, LIKE prefix patterns, CASE.
* Possible improvements from Phase 4: release `cat_lock` during `save`,
  `stats` and `CREATE INDEX`; decode mmap'd PQCF columns once in the server
  instead of per query child.
