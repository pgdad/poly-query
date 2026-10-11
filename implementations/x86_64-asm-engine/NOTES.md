# Working notes — x86-64 assembly engine

## Status (Phase 3)

* Public conformance suite: `python3 tests/conformance/runner.py --engine
  implementations/x86_64-asm-engine/bin/polyquery --phase 1 --phase 2
  --phase 3` → 554/554 pass (phase 1 225/225, phase 2 186/186 incl. the
  optional correlated-subquery file, phase 3 143/143).
* `make build test lint` pass: unit tests `test_text`, `test_json`,
  `test_ingest`, `test_hash`, `test_sql`, `test_storage` (CRC-32, UTF-8,
  layouts, statistics, indexes) and `tests/session_test.sh` (e2e incl.
  Phase 3 storage/index cases).
* Capabilities claimed: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic
  test.functions phase2 sql.groupby sql.join sql.functions sql.subquery
  sql.cte sql.correlated_subquery phase3 storage.pqcf storage.mmap index.hash
  index.btree`.

## What works (Phase 3 additions)

* Row / column layouts (`table.S`), NULL bitmaps, dictionary encoding,
  `col_get` accessor used by the evaluator.
* `stats` op; lazily computed per-column statistics.
* CREATE/DROP INDEX (HASH, BTREE); `schema` lists indexes and layout.
* Planner (`planner.S`): pushdown, index selection, row-group skipping,
  estimates, hash-join build side; EXPLAIN shows IndexScan/Filter/build.
* PQCF v1 save/open (`pqcf.S`), all encodings, validation, atomic save;
  `mmap:true` opens decode lazily per column (`pqcf_load_col` via `col_get`).

## Verification done outside the suite (scripts not part of the build)

* Independent Python PQCF decoder over every table × encoding × row-group
  size the engine writes: byte-exact agreement (alignment, CRCs, trailing
  bitmap bits, min/max).
* Corruption fuzzing (bit flips, truncation, metadata mutation with fixed CRC):
  only STORAGE_CORRUPT / STORAGE_VERSION_UNSUPPORTED or correct data.
* Hand-crafted files for every §3.4 validity rule.
* Differential planner test: random predicates/joins with indexes on/off,
  optimize off, row layout and PQCF-backed tables with small row groups.
* SIGKILL during repeated saves: the target is always complete.
* 1M-row transactions: load 0.3 s, save 0.3 s, open 0.2 s, indexed lookups ms.

## Next steps (Phase 4+)

* HTTP server (`serve`), concurrency, streaming.
