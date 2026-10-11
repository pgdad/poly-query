# Working notes — x86-64 assembly engine

## Status (Phase 5)

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

## Invariants to keep

* Output order of every mode = row baseline order (parts concatenated in
  order; groups sorted by first tuple; hash chains in build order; merge
  join emits per left tuple). Breaking it makes `modes_test.sh` fail.
* Vectorized evaluation must only compute fallible operations on rows the
  row engine evaluates (active masks in `veval`).
* Anything executed inside workers must not write shared state: plans with
  subqueries run with 1 part (`pexec_threads`), lazily decoded PQCF columns
  are decoded first (`par_prepare`).

## Next steps / ideas

* Join reordering for chains of inner joins (not implemented).
* Parallel hash build / merge-join sort; parallel final sort (merge of
  sorted parts); DISTINCT via partitioned hashing.
* Vector fast paths for IN lists, BETWEEN, LIKE prefix patterns, CASE.
* Possible improvements from Phase 4: release `cat_lock` during `save`,
  `stats` and `CREATE INDEX`; decode mmap'd PQCF columns once in the server
  instead of per query child.
