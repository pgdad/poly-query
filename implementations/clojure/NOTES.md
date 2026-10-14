# NOTES — embedding API and pqledger (application task)

Working notes for the application task (`spec/apps/embedding.md`,
`spec/apps/pqledger.md`). User/developer documentation: [APP.md](APP.md),
[EMBEDDING.md](EMBEDDING.md); the engine itself: [README.md](README.md).

## Status (end of session 2, 2026-10-14)

Everything in the task's definition of done passes:

* `make build test` — engine/API unit tests and pqledger unit tests
  (`app/test`, 26 tests / 197 assertions) pass.
* `tests/apps/pqledger/runner.py --app bin/pqledger --embed-demo
  bin/pq-embed-demo --trace` — pqledger 24/24, embed-demo 3/3.
* Conformance: 660/660 (default), 3870/3870 (`--modes`), 660/660
  (`--transport http`); `tests/concurrency/http_suite.py` 19/19;
  `robustness_probe.py --only expression_limits --require-pass` pass.
* Capabilities unchanged (no change to `version`/capability code).
* Scale check (bankgen, 100,610-transaction ledger): import of the 100k
  file ≈ 0.9 s, re-import (all duplicates) ≈ 1.3 s, every report/list/
  budget/query 0.2–1.1 s (with the AOT cache).

## Layout

* `src/polyquery/api.clj` — the public API (`create`, `load!`,
  `load-rows!`, `query` → `Result`, `save!`, `open!`, `drop!`, `tables`,
  `schema`, `close`/`with-open`, `error-code`). It calls the protocol's
  operation handlers (`protocol/handle-op`, `protocol/open-query`), so the
  CLI and the API share one implementation; the only engine change was a
  pluggable result-value function (`:value-fn`) so the API receives runtime
  values instead of JSON values.
* `src/polyquery/api/values.clj` — native value mapping (Long, BigDecimal,
  Double, String, Boolean, LocalDate, LocalDateTime, nil).
* `app/` — pqledger, a separate tools.deps project (`:local/root ".."`):
  `cli` (argument parsing), `config`/`ini` (configuration), `rules`
  (rules and budgets files), `statement` (bank CSV → transactions),
  `importer` (duplicates, batch), `ledger` (PQCF tables via the API, the
  category-resolution SQL), `reports` (one SQL query per report),
  `output` (table/csv/json), `errors` (exit codes), `main`.
* `examples/embed-demo/` — minimal example, separate tools.deps project.
* `script/compile-client.clj` — AOT-compiles a client against the engine
  jar; `script/pqledger-training.sh` records pqledger's JVM AOT cache.

## Design decisions

* Category resolution is SQL: rule patterns become LIKE patterns (`*`→`%`,
  `?`→`_`; `%`/`_` are forbidden in patterns, and LIKE has no escape
  character, so the translation is exact), matched against
  `UPPER(merchant)` (ASCII-only, like the spec's case-insensitivity); the
  first rule per distinct merchant is `MIN(rule_no)`. Overrides win via
  `COALESCE`. The view is a CTE prefix (`ledger/with-ledger-view`); for
  `query` it is materialized as table `ledger`.
* Ledger writes rewrite the whole table (`load-rows!` + `save!`, atomic
  rename). `transactions.pqcf` is written last on `init`, and on `import`
  transactions are saved before batches.
* `share` is computed in the host with BigDecimal HALF_UP (spent values are
  non-negative, so this is half away from zero).
* Duplicate detection: counts per (date, amount, merchant) of the account
  come from a GROUP BY query; the host decides which file records are new.
* pqledger runs its work on a thread with a 256 MiB stack (deep ad-hoc SQL).

## Known limitations / possible next steps

* Each import rewrites the full transactions file: O(ledger) per import
  (≈ 1 s per 100k rows); fine for the spec's scale, but an append-only
  scheme (or row groups appended in place) would be faster for huge ledgers.
* Results of `pq/query` are fully materialized (no streaming cursor API).
* A crash between saving `transactions.pqcf` and `batches.pqcf` during
  import could leave a batch number present only in transactions; the next
  import takes the max of both, so ids/batches are never reused.
