# Phases and Capability Strings

An engine reports capabilities via `{"op":"capabilities"}`. Conformance test
files declare the capabilities they require; tests whose capabilities are not
claimed are reported as **`not_implemented`** (never as passed). A phase is
complete for an engine only when **all** tests of that phase are run and pass
(see acceptance/README.md).

| Capability | Phase | Meaning |
|---|---|---|
| `phase1` | 1 | protocol, session/exec CLI, catalog ops (`load`, `tables`, `schema`, `drop`, `reset`, `version`, `capabilities`) |
| `ingest.csv` | 1 | CSV ingestion incl. inference & explicit schema |
| `ingest.json` | 1 | JSON array ingestion |
| `ingest.jsonl` | 1 | JSON Lines ingestion |
| `sql.basic` | 1 | single-table `SELECT` with projection, `WHERE`, `ORDER BY`, `LIMIT`/`OFFSET`, arithmetic, comparisons, `AND/OR/NOT`, `IS NULL`, aliases, `COUNT/SUM/MIN/MAX/AVG` without `GROUP BY`, `CAST`, all types |
| `phase2` | 2 | full parser pipeline with structured errors (`PARSE_ERROR` positions), `EXPLAIN` |
| `sql.groupby` | 2 | `GROUP BY`, `HAVING`, `DISTINCT`, `COUNT(DISTINCT)` |
| `sql.join` | 2 | `INNER`, `LEFT`, `CROSS` joins |
| `sql.functions` | 2 | all scalar functions of functions.md (except `PQ_SLEEP`), `CASE`, `LIKE`, `BETWEEN`, `IN` lists |
| `sql.subquery` | 2 | uncorrelated scalar / `IN` / `EXISTS` subqueries, derived tables |
| `sql.cte` | 2 | `WITH` |
| `sql.correlated_subquery` | 2 (optional) | correlated subqueries |
| `phase3` | 3 | row & column layouts, statistics (`stats`), predicate pushdown, column pruning |
| `storage.pqcf` | 3 | `save`/`open` PQCF v1 incl. PLAIN/DICT/RLE, checksums, atomic writes |
| `storage.mmap` | 3 | memory-mapped `open` |
| `index.hash` | 3 | hash indexes |
| `index.btree` | 3 | ordered indexes |
| `phase4` | 4 | HTTP server per protocol.md §7 and concurrency.md |
| `http.streaming` | 4 | `/v1/query/stream` |
| `test.functions` | 1–4 | `--enable-test-functions` (`PQ_SLEEP`, `sleep` op) |
| `phase5` | 5 | the Phase 5 option set below |
| `exec.row` | 5 | `mode: "row"` (row-at-a-time / Volcano) |
| `exec.vectorized` | 5 | `mode: "vectorized"` (batch/column-at-a-time) |
| `exec.parallel` | 5 | `threads` > 1 for scans and aggregations |
| `join.hash` | 5 | `join: "hash"` |
| `join.merge` | 5 | `join: "merge"` (sort-merge) |
| `join.nested_loop` | 5 | `join: "nested_loop"` |
| `native.kernels` | 5 / M9 | `native: true` uses libpqkernels when `--native-kernels` is given |

Phase documents: [phase-1.md](phase-1.md) … [phase-5.md](phase-5.md),
[native-kernels.md](native-kernels.md).

## Requirement-change capabilities

Claimed only by engines that adopted a change request from `spec/changes/`
(architectural-change experiment family); suites requiring them are skipped
for other engines.

| capability | phase | meaning |
|---|---|---|
| `change.union_all` | CR-1 | `UNION ALL` per [`../changes/union-all.md`](../changes/union-all.md) |
| `change.decimal38` | CR-2 | `DECIMAL` precision 38 and PQCF v2 per [`../changes/decimal38.md`](../changes/decimal38.md) |
