# PolyQuery Engine Protocol — version 1

Every engine exposes the **same** external protocol so that harnesses can swap
engines without changing workloads.

## 1. Engine layout contract

Each implementation directory `implementations/<lang>/` MUST provide:

| Path | Purpose |
|---|---|
| `Makefile` with targets `build`, `test`, `lint`, `fmt`, `clean` | `make -C implementations/<lang> build` must produce a runnable engine from a fresh clone using only the documented toolchain. `test` runs the implementation's own unit tests. |
| `bin/polyquery` | executable launcher (shell script allowed) — the **only** entry point used by harnesses. Must work from any current directory. |
| `README.md` | build prerequisites, design overview, library list (with versions), known limitations |
| `ENGINE.json` | static metadata: `{"language": "...", "track": "A"|"B", "libraries": [{"name","version","purpose"}]}` |

## 2. CLI

```
bin/polyquery version                       # prints the version JSON (§5.10) and exits 0
bin/polyquery capabilities                  # prints the capabilities JSON (§5.9) and exits 0
bin/polyquery session [options]             # JSONL request/response loop on stdin/stdout
bin/polyquery exec [options] (--request FILE | --request -)
                                            # executes a JSON request, or a JSON array of
                                            # requests in order, prints one response per
                                            # line, exits 0 (even if requests failed)
bin/polyquery serve [options] --port N      # HTTP server (Phase 4)
```

Common options (all modes; unknown options ⇒ exit code 2 with a message on stderr):

| Option | Default | Meaning |
|---|---|---|
| `--data-dir DIR` | current directory | root for all file paths in requests |
| `--enable-test-functions` | off | enables `PQ_SLEEP` |
| `--max-query-memory-mb N` | impl-defined (≥ 1024) | per-query memory budget |
| `--max-ingest-bytes N` | ≥ 2 GiB | ingestion size limit |
| `--max-table-rows N` | ≥ 200,000,000 | |
| `--max-join-rows N` | ≥ 100,000,000 | |
| `--threads N` | impl-defined | default worker threads per query (Phase 5) |
| `--log-level LEVEL` | `info` | `debug`, `info`, `warn`, `error`, `off`; logs go to **stderr** only |
| `--native-kernels PATH` | none | path to `libpqkernels` shared library (optional, §native) |

`serve` additional options: `--host` (default `127.0.0.1`), `--port`
(required; `0` = pick a free port), `--workers N` (max concurrently executing
queries, default = CPU count), `--queue-depth N` (max queued queries waiting for
a worker, default 64), `--query-timeout-ms N` (default 0 = none),
`--shutdown-grace-ms N` (default 10000), `--max-request-bytes N` (default 1 GiB).
On startup, `serve` MUST print exactly one line to **stdout**:
`{"event":"listening","host":"127.0.0.1","port":<actual port>}` and flush it.

Stdout in `session`/`exec` mode carries only protocol responses. Exit codes:
0 normal, 2 usage error, 1 fatal error.

## 3. Session mode

* Requests are read from stdin, **one JSON object per line** (UTF-8, LF
  terminated). Blank lines are ignored.
* For every request, exactly one response object is written to stdout as a
  single line, in request order, and flushed before reading the next request.
* A line that is not valid JSON, or not an object, produces a response with
  error `INVALID_REQUEST` (and `"id": null`); the session continues.
* EOF on stdin ⇒ exit 0. The catalog lives for the duration of the process.
* Responses MUST NOT contain raw newlines (serialize JSON on one line).

## 4. Requests and responses

Every request is an object with `"op"` (string) and optional `"id"` (any JSON
value, echoed verbatim in the response; `null` if absent). Unknown fields are
ignored. Unknown `op` ⇒ `INVALID_REQUEST`. Missing/ill-typed required fields ⇒
`INVALID_REQUEST`.

Success response: `{"id": …, "ok": true, …op-specific fields…}`.
Error response: `{"id": …, "ok": false, "error": {"code": "…", "message": "…", "details": {…}?}}`
where `code` is from errors.md. `details` is optional (e.g. `{"line":1,"column":8}`).

Engines MAY add extra fields to any response object (e.g. `"stats"`); harnesses
MUST ignore unknown fields. Field order is not significant.

## 5. Operations

### 5.1 `load`
```json
{"op":"load","table":"people","format":"csv","path":"people.csv",
 "schema":[{"name":"id","type":"INT64"}],          // optional
 "options":{"header":true,"delimiter":","},         // optional (CSV only)
 "replace":false}                                   // optional
```
`format`: `csv` | `json` | `jsonl`. Exactly one of `path` (relative to
`--data-dir`, §6) or `data` (inline string content). Response:
`{"ok":true,"table":"people","row_count":3,"columns":[{"name":"id","type":"INT64"}, …]}`.

### 5.2 `query`
```json
{"op":"query","sql":"SELECT …","options":{ … }}
```
Options (all optional; unknown options ignored; unsupported values of known
options ⇒ `UNSUPPORTED`):

| option | values | meaning |
|---|---|---|
| `max_rows` | int ≥ 0 | result rows above this ⇒ `RESOURCE_LIMIT` |
| `timeout_ms` | int ≥ 0 | 0 = none |
| `result` | `"rows"` (default) \| `"count"` | `count`: omit `rows` from the response (benchmarking) — `row_count` still exact |
| `mode` | `"auto"` (default) \| `"row"` \| `"vectorized"` | execution model (Phase 5) |
| `threads` | int ≥ 1 | parallelism (Phase 5) |
| `join` | `"auto"` \| `"hash"` \| `"merge"` \| `"nested_loop"` | forced join algorithm (Phase 5) |
| `optimize` | bool, default true | false ⇒ no logical optimization (baseline) |
| `use_indexes` | bool, default true | false ⇒ never use indexes |
| `native` | bool, default false | use native kernels when loaded (§native) |
| `query_id` | string | client-assigned id, used for cancellation (HTTP) |

Response:
```json
{"id":…,"ok":true,
 "columns":[{"name":"id","type":"INT64"},{"name":"total","type":"DECIMAL(18,2)"}],
 "rows":[[1,"10.50"],[2,null]],
 "row_count":2,
 "stats":{"elapsed_us":123}}          // stats optional, recommended
```
Values per types.md §9. For statements (`CREATE INDEX`, `DROP INDEX`):
`columns: []`, `rows: []`, `row_count: 0`. `EXPLAIN`: one STRING column `plan`.

### 5.3 `explain`
`{"op":"explain","sql":"SELECT …","options":{…}}` ⇒
`{"ok":true,"plan":{…plan JSON…}}` (see indexes-and-planning.md §4).

### 5.4 `tables`
`{"op":"tables"}` ⇒ `{"ok":true,"tables":[{"name":"people","row_count":3}, …]}` sorted by name (case-insensitive).

### 5.5 `schema`
`{"op":"schema","table":"people"}` ⇒
`{"ok":true,"table":"people","row_count":3,"columns":[{"name":…,"type":…}],"indexes":[{"name":…,"column":…,"kind":"HASH"|"BTREE"}]}`.
Unknown table ⇒ `NOT_FOUND`.

### 5.6 `drop`
`{"op":"drop","table":"people"}` — removes the table and its indexes. Unknown ⇒ `NOT_FOUND`.

### 5.7 `save` / `open` (Phase 3)
`{"op":"save","table":"t","path":"t.pqcf"}` writes PQCF v1 (storage/pqcf-v1.md)
atomically; response `{"ok":true,"path":"t.pqcf","bytes":N}`. `save` never
creates directories: a missing parent directory ⇒ `IO_ERROR`; an unknown table ⇒
`NOT_FOUND`. Saving over an existing file replaces it atomically (storage spec §5),
even if that file is currently open by this engine. Options
`{"options":{"row_group_size":N,"encoding":"auto"|"plain"|"dict"|"rle"}}` MAY be
honored (`encoding` forces an encoding where applicable — used by interop tests;
`plain` MUST be supported, others SHOULD).

`{"op":"open","table":"t","path":"t.pqcf","options":{"mmap":true}}` loads a
PQCF file as table `t` (`replace` as in load). Corrupt ⇒ `STORAGE_CORRUPT`;
newer version ⇒ `STORAGE_VERSION_UNSUPPORTED`. Indexes listed in the file
metadata are recreated. Index names are global in the catalog: if any of them
already exists (on another table, or on the table being replaced *after* its
indexes have been removed by `replace`), `open` fails with `ALREADY_EXISTS`
and changes nothing. With `replace: true`, the replaced table's indexes are
dropped first.

### 5.8 `stats` (Phase 3)
`{"op":"stats","table":"t"}` ⇒
`{"ok":true,"table":"t","row_count":N,"columns":[{"name":…,"type":…,"null_count":k,"distinct_count":d,"min":v,"max":v}]}`
`min`/`max` serialized per types.md §9 (null if no non-null values). `distinct_count`
MAY be approximate (within ±10% or ±1, whichever is larger).

### 5.9 `capabilities`
`{"op":"capabilities"}` ⇒ `{"ok":true,"protocol_version":1,"capabilities":["phase1", …]}`
using the capability strings in phases/README.md. An engine MUST NOT claim a
capability whose tests it does not intend to pass.

### 5.10 `version`
`{"op":"version"}` ⇒
```json
{"ok":true,"engine":"polyquery-rust","engine_version":"0.1.0","language":"rust",
 "protocol_version":1,"spec_version":"1.0.0",
 "runtime":"rustc 1.96.0","build":{"profile":"release","flags":"…"}}
```

### 5.11 `reset`
Drops all tables and indexes. `{"ok":true}`.

### 5.12 `sleep` (test functions only)
`{"op":"sleep","ms":N}` — only with `--enable-test-functions`; otherwise `INVALID_REQUEST`.

## 6. Path safety

All `path` values are resolved against `--data-dir`. A path that is absolute,
empty, contains a NUL, or contains a `..` component ⇒ `ACCESS_DENIED`. Engines
MUST NOT open any file outside the data directory as a result of a request
(symbolic links inside the data directory are followed; that is the operator's
responsibility). SQL text can never name files.

## 7. HTTP API (Phase 4)

HTTP/1.1, JSON bodies (`Content-Type: application/json`), UTF-8. Keep-alive
SHOULD be supported. Responses always carry a JSON body (except `/metrics`).

| Method & path | Body | Success |
|---|---|---|
| `GET /health` | – | `200 {"status":"ok"}` (`503 {"status":"shutting_down"}` during shutdown) |
| `GET /v1/version` | – | `200` version object (§5.10) |
| `GET /v1/capabilities` | – | `200` capabilities object |
| `POST /v1/query` | `{"sql":…, "options":{…}}` | `200` query response (§5.2) |
| `POST /v1/query/stream` | same | `200`, `Content-Type: application/x-ndjson`, chunked (§7.2) |
| `POST /v1/explain` | `{"sql":…}` | `200` explain response |
| `GET /v1/tables` | – | `200` tables response |
| `GET /v1/tables/{name}/schema` | – | `200` schema response |
| `GET /v1/tables/{name}/stats` | – | `200` stats response |
| `PUT /v1/tables/{name}?format=csv\|json\|jsonl[&replace=true][&header=false]` | raw data | `201` load response |
| `DELETE /v1/tables/{name}` | – | `200 {"ok":true}` |
| `POST /v1/request` | any protocol request object (§5) | `200` its response (errors mapped per §7.1) |
| `GET /v1/queries` | – | `200 {"ok":true,"queries":[{"query_id":…,"state":"queued"\|"running","elapsed_ms":…}]}` |
| `DELETE /v1/queries/{query_id}` | – | `200 {"ok":true,"cancelled":true}`; unknown/finished ⇒ `404 NOT_FOUND` |
| `GET /metrics` | – | `200` Prometheus text format 0.0.4 (§7.3) |

Unknown path ⇒ `404` with error `NOT_FOUND`; wrong method ⇒ `405` with
`INVALID_REQUEST`. Body larger than `--max-request-bytes` ⇒ `413 RESOURCE_LIMIT`.
Malformed JSON ⇒ `400 INVALID_REQUEST`.

If `options.query_id` is absent the server assigns one; the server MUST return it
in the `X-PolyQuery-Query-Id` response header for `/v1/query` and `/v1/query/stream`.
A `query_id` already in use by a running query ⇒ `409 ALREADY_EXISTS`.

### 7.1 Error → HTTP status

| Status | Codes |
|---|---|
| 400 | `PARSE_ERROR`, `SEMANTIC_ERROR`, `TYPE_ERROR`, `CONVERSION_ERROR`, `INVALID_ARGUMENT`, `INVALID_REQUEST`, `INGEST_ERROR`, `NUMERIC_OVERFLOW`, `DIVISION_BY_ZERO`, `SUBQUERY_CARDINALITY`, `UNSUPPORTED` |
| 403 | `ACCESS_DENIED` |
| 404 | `NOT_FOUND` |
| 409 | `ALREADY_EXISTS`, `CANCELLED` |
| 413 | `RESOURCE_LIMIT` |
| 500 | `INTERNAL_ERROR`, `IO_ERROR`, `STORAGE_CORRUPT`, `STORAGE_VERSION_UNSUPPORTED` |
| 503 | `OVERLOADED`, `SHUTTING_DOWN` |
| 504 | `TIMEOUT` |

### 7.2 Streaming

`POST /v1/query/stream` responds with `Transfer-Encoding: chunked` NDJSON:

```
{"type":"header","query_id":"q1","columns":[{"name":"id","type":"INT64"}]}
{"type":"rows","rows":[[1],[2],…]}          (zero or more; each ≤ 10,000 rows)
{"type":"end","row_count":12345}
```
If an error occurs **before** the header was sent, the server responds with a
normal (non-streamed) error response and HTTP status. After the header, an error
is reported as a final line `{"type":"error","error":{…}}` (HTTP status already 200).
The server MUST produce rows incrementally and MUST NOT buffer more than a
bounded number of batches (≤ 16) ahead of the client (backpressure: if the
client stops reading, query execution blocks). Client disconnect cancels the query.

### 7.3 Metrics

Prometheus text exposition. Required metric families (more allowed):

```
polyquery_queries_total{status="ok"|"error"}         counter
polyquery_queries_in_flight                          gauge   (running)
polyquery_queries_queued                             gauge
polyquery_queries_rejected_total                     counter (OVERLOADED)
polyquery_queries_cancelled_total                    counter
polyquery_queries_timeout_total                      counter
polyquery_query_duration_seconds_sum / _count        summary
polyquery_tables                                     gauge
polyquery_uptime_seconds                             gauge
```

### 7.4 Structured logs

Server logs are JSON lines on stderr, each with at least `ts` (RFC 3339 UTC),
`level`, `msg`; query completion events include `query_id`, `status`,
`duration_ms`, `rows`. Logs MUST NOT include table data values or full request bodies at `info` level.
