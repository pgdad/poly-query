# Working notes — Java implementation

## Current task: embedding API + pqledger (spec/apps/)

Status (session 2, 2026-10-14): **done**. Every check of the task's definition of done passes.

### What exists

* **Library** `polyquery.api` (src/main/java/polyquery/api): `Database` (create, loadFile/loadText,
  query, createTable/createTableAs, save/open, drop, tables, schema, close), `DatabaseConfig`,
  `LoadOptions`, `QueryOptions`, `Result` (typed values), `Column`/`ColumnType`, `TableSchema`,
  `TableInfo`, `DatabaseException` + `ErrorCode`. `module-info` exports only `polyquery.api`;
  `make build` → `build/polyquery.jar` (modular jar). Developer guide: EMBEDDING.md.
* **pqledger** (app/src/main/java/pqledger, module `pqledger`): `cli` (argument parsing),
  `config` (config/rules/budget files), `importer` (bank CSV reader, amounts, dates, merchant
  normalization, duplicate detection), `ledger` (PQCF ledger + all SQL in `LedgerQueries`),
  `commands`, `output` (table/csv/json). `bin/pqledger`, `build/pqledger.jar`. User guide: APP.md.
* **embed-demo** (examples/embed-demo), `bin/pq-embed-demo`.
* Tests: `make test` runs the engine tests (incl. `ApiTest`) and the app tests
  (app/src/test/java, runner `pqledger.AppTestMain`).

### Results (last run)

* `tests/apps/pqledger/runner.py ... --trace`: 24/24 pqledger cases, 3/3 embed-demo cases.
* conformance: 660/660; `--modes` 3870/3870; `--transport http` 660/660; http_suite and the
  expression_limits robustness probe pass.
* Scale: 100k-record imports ≈ 0.6–0.9 s; reports on a 300k-transaction ledger 0.2–0.5 s.

### Design decisions

* Import computes duplicates in Java (spec §1 allows it) from per-key counts that one SQL
  query returns for the file's date range; new rows are added with `createTable` + a
  `UNION ALL ... ORDER BY id` `createTableAs`, then `save` (the engine's atomic PQCF writes).
  `transactions.pqcf` is written before `batches.pqcf`.
* Category resolution is a SQL `COALESCE(override, CASE WHEN merchant LIKE ... END,
  'uncategorized')`; rule patterns map `*`→`%`, `?`→`_` (patterns never contain `%`/`_`;
  merchants and patterns are both ASCII-upper-cased, so LIKE's case-sensitivity is correct).
* `share` is computed in Java with BigDecimal (HALF_UP = half away from zero for positives).
* stdout is buffered and only printed on success, so failures print nothing to stdout.
* `pqledger` runs on a thread with a 512 MiB stack so deeply nested `query` SQL works.

### Known limitations / ideas

* Import is not atomic across the two files: a crash between writing `transactions.pqcf`
  and `batches.pqcf` would leave a batch unrecorded.
* The whole ledger is opened per invocation (memory-mapped PQCF, so cheap).
