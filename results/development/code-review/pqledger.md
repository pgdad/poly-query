# pqledger application review (2026-10-14)

Four read-only AI reviewers (two implementations each) checked every implementation's
pqledger application and embedding API against `spec/apps/pqledger.md` and
`spec/apps/embedding.md`, reading only (no builds, no runs). The asked questions: docs quality
(APP.md, EMBEDDING.md), whether reports, lists, budgets and category resolution are computed by
SQL in the embedded engine, and code quality. Findings below are the reviewers'; the ones marked
*unverified* have not been confirmed by a test.

| implementation | docs | SQL use | code quality | app lines | docs words |
|---|---|---|---|---|---|
| Python | 5 | compliant | 4 | 2,267 | 5,646 |
| Go | 5 | compliant | 4 | 3,233 | 5,658 |
| Rust | 5 | compliant | 4 | 3,188 | 5,444 |
| Java | 5 | compliant | 4 | 3,667 | 9,606 |
| Clojure | 5 | compliant | 4 | 1,962 | 5,907 |
| Common Lisp | 5 | compliant | 4 | 2,008 | 6,333 |
| x86-64 assembly | 5 | compliant | 4 | 6,823 | 6,223 |
| AArch64 assembly | 5 | compliant | 4.5 | 7,601 | 6,287 |

(The assembly engines are a separate cohort; the table only lists them side by side.)

**All eight resolve categories the same way in SQL**: the rules become a table, each glob is
translated to a LIKE pattern (`*`→`%`, `?`→`_`, safe because the spec forbids `%`/`_` in
patterns and LIKE has no escape), the first matching rule wins via `MIN(rule_no)` (Java: an
ordered `CASE WHEN … LIKE …`), and `COALESCE(override, rule, 'uncategorized')`. Every report,
list, budget, accounts and export is one SQL statement; the hosts compute only the `share`
column (exact integer or decimal arithmetic) and the duplicate decision from SQL counts (the
AArch64 app does even that in SQL). Ledger updates are `UNION ALL` queries saved as PQCF.

## Findings

* **Multi-file ledger updates are not atomic** (*unverified*; Python, Go, Rust, Java, Clojure):
  an import replaces `transactions.pqcf` and `batches.pqcf` one after the other, so a failure
  between the two (disk full, crash) leaves a batch without its rows or the reverse — against
  §10 "a failing command leaves the ledger unchanged". Common Lisp stages every file before
  renaming any; the reviewers did not flag the assembly engines. No test injects such a failure.
* **Spec gap — `list --category uncategorized`**: §8.1 does not say whether `C` must be a valid
  category name (§3.3 excludes `uncategorized` from category names). Go rejects it as a usage
  error, Python lists the uncategorized rows. No test covers it; recorded for the next spec
  revision.
* Go: `bin/pqledger` runs `make build` when the binary is missing (borderline for §1's launcher
  rule; the tests always build first).
* Java: rule matching evaluates the ordered CASE once per transaction (rows × rules LIKE tests);
  Rust/Go/Python/Clojure match distinct merchants. Not a correctness issue; the hidden 100k-row
  case runs in 0.3 s per command.
* Thin unit tests for the ledger/report layer in Go (2 tests), Rust (none in `ledger.rs`) and
  Common Lisp; Clojure and Python test reports against a real engine.
* Small: redundant `UPPER(merchant)` (Python, Rust, Clojure), dead `Rule.like_pattern()` (Python),
  undocumented public `Date::from_days`/`Timestamp::from_micros` (Rust), the Java embed-demo has
  no build file of its own (EMBEDDING.md gives the `javac` recipe), Common Lisp caps
  `[engine] threads` at 256 silently, AArch64 leaves some aggregate result types to the engine's
  typing rules where x86-64 casts explicitly (printed values unaffected).

No reviewer found code that special-cases tests.
