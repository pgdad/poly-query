# Phase 1 — In-Memory Data Engine

**Required capabilities:** `phase1`, `ingest.csv`, `ingest.json`, `ingest.jsonl`, `sql.basic`, `test.functions`.

Scope:

* CLI modes `version`, `capabilities`, `session`, `exec` (protocol.md §2–§6).
* Operations: `load`, `query`, `tables`, `schema`, `drop`, `reset`, `version`,
  `capabilities`, `sleep` (test functions).
* Ingestion of CSV, JSON, JSONL with inference and explicit schemas (ingestion.md).
* All data types incl. DECIMAL, DATE, TIMESTAMP, NULL (types.md).
* SQL subset `sql.basic`: `SELECT [*|expr [AS alias], …] FROM table [alias]
  [WHERE expr] [ORDER BY …] [LIMIT n] [OFFSET n]`, `SELECT` without `FROM`,
  arithmetic, comparisons, `AND`/`OR`/`NOT`, `IS [NOT] NULL`, `CAST`, literals of
  every type, and the aggregates `COUNT(*)`, `COUNT(x)`, `SUM`, `MIN`, `MAX`, `AVG`
  over the whole table (no `GROUP BY`).
  A Phase-1 engine encountering valid Phase-2 syntax it does not support MUST
  answer `UNSUPPORTED` (or `PARSE_ERROR`), never a wrong result.
* Path safety (`ACCESS_DENIED`), resource limits (`max_rows` ⇒ `RESOURCE_LIMIT`).
* Deterministic results: identical requests produce identical responses
  (modulo `stats` and, without ORDER BY, row order).

Conformance suites: `tests/conformance/cases/phase1/*`.
