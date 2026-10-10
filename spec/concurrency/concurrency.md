# Concurrency Contract

Applies to `serve` mode (Phase 4) and to intra-query parallelism (Phase 5).

## 1. Isolation model

* Tables are immutable values. The catalog maps names to (table, indexes).
* Every query takes a **snapshot** of the catalog entries it references at the
  moment it starts executing; it MUST see exactly those versions for its whole
  execution, even if other requests concurrently replace or drop the tables.
  A concurrently dropped table remains readable by queries already holding it.
* Catalog mutations (`load`, `open`, `drop`, `reset`, `CREATE/DROP INDEX`) are
  **atomic and linearizable**: a query observes either all or none of a
  mutation. Mutations MAY be serialized with each other.
* Any number of queries MAY run concurrently (concurrent readers). Readers
  MUST NOT block each other except through the worker limit.
* A `load` of a large file MUST NOT block concurrent queries on other tables
  for the duration of parsing (parse first, then publish atomically).

## 2. Admission control and backpressure

* `--workers N`: at most N queries execute simultaneously.
* `--queue-depth Q`: up to Q further queries wait (FIFO) for a worker.
* A query arriving when N are executing and Q are waiting is rejected
  immediately with `OVERLOADED` (HTTP 503) and counted in
  `polyquery_queries_rejected_total`.
* Non-query endpoints (`/health`, `/metrics`, `/v1/queries`, cancellation)
  MUST remain responsive while all workers are busy.
* Streaming responses apply backpressure to execution (protocol.md §7.2).

## 3. Timeouts

The effective timeout of a query is `options.timeout_ms` if > 0, else the
server's `--query-timeout-ms` if > 0, else none. Time spent queued counts
toward the timeout. On expiry the query stops (within 100 ms for engines'
operators; `PQ_SLEEP` within 20 ms) and fails with `TIMEOUT`.

## 4. Cancellation

`DELETE /v1/queries/{id}` requests cancellation of a queued or running query.
The query stops within 100 ms (operator checks at least every 65,536 rows or
10 ms) and its response is `CANCELLED`. Cancelling a finished/unknown id ⇒
`NOT_FOUND`. A client disconnect cancels its query.

## 5. Graceful shutdown

On SIGTERM or SIGINT the server:

1. stops accepting new connections (and answers queries on existing
   connections with `SHUTTING_DOWN`; `/health` returns 503);
2. lets running and queued queries finish, up to `--shutdown-grace-ms`;
3. cancels any still running (`CANCELLED`) and closes connections;
4. exits with status 0.

## 6. Intra-query parallelism (Phase 5)

`options.threads` (or `--threads`) bounds the number of worker threads a query
uses for parallel scans and aggregations. Results MUST be identical (up to
FLOAT64 tolerance and row order where not specified) to single-threaded
execution. Integer and DECIMAL aggregates MUST be exact regardless of thread count.

## 7. Session/CLI modes

`session` and `exec` process requests sequentially; no concurrency guarantees
beyond correctness are required there.
