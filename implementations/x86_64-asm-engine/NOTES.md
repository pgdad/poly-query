# Working notes — x86-64 assembly engine

## Status (Phase 4)

* Public conformance suite, both transports:
  `python3 tests/conformance/runner.py --engine implementations/x86_64-asm-engine/bin/polyquery [--transport http]`
  → phase 1 225/225, phase 2 186/186, phase 3 143/143 (phase 5 not claimed:
  15 not_implemented).
* `python3 tests/concurrency/http_suite.py --engine implementations/x86_64-asm-engine/bin/polyquery`
  → 19/19.
* `make build test lint` pass: unit tests `test_text`, `test_json`,
  `test_ingest`, `test_hash`, `test_sql`, `test_storage`, `test_planner`,
  `test_http` (HTTP parser, URL helpers, status mapping),
  `tests/session_test.sh` and `tests/server_test.sh` (serve end-to-end with
  curl: endpoints, errors, streaming, admission, cancellation, metrics, logs,
  graceful shutdown).
* Capabilities claimed: `phase1 ingest.csv ingest.json ingest.jsonl sql.basic
  test.functions phase2 sql.groupby sql.join sql.functions sql.subquery
  sql.cte sql.correlated_subquery phase3 storage.pqcf storage.mmap index.hash
  index.btree phase4 http.streaming`.

## Phase 4 design in one paragraph

`server.S`: network thread (poll loop: HTTP, health, metrics, query registry,
admission) + catalog worker thread (all catalog operations, serialized,
holding `cat_lock` except while `load` parses). Each admitted query runs in a
`fork()`ed child (snapshot = copy-on-write address space), forked under
`trylock(cat_lock)`; the child writes the response directly to the socket and
reports status/rows in a MAP_SHARED record. Cancellation = SIGUSR1 →
`g_cancel_flag` → `check_deadline` raises CANCELLED. Streaming: row sink hook
in `exec_plan` (`g_sink_plan`/`g_row_sink`) for unsorted, non-aggregated,
non-DISTINCT queries. See README "HTTP server" for details.

## Verification done outside the suites (scripts in /tmp, not part of the build)

* 1M-row load (49 MB CSV) through `/v1/request` while polling `/health` and
  querying another table: health ~0.5 ms, queries ~4 ms during the load.
* Streaming 1M rows: first byte after ~5 ms (pipelined) vs ~75 ms (ORDER BY).
* curl: `Expect: 100-continue` uploads, chunked PUT, HTTP/1.0, pipelined
  requests, percent-encoded table names.

## Next steps / ideas

* Phase 5 (execution modes, parallelism, join algorithms) not started.
* Possible improvements: release `cat_lock` during `save` / `open` parsing
  (like `load`); decode mmap'd PQCF columns once in the server instead of per
  query child.
