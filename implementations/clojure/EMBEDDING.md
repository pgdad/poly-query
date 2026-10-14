# Embedding PolyQuery in a Clojure program

The PolyQuery engine of this directory is also a **library**: any Clojure (or
JVM) program can create engine instances in its own process, load CSV, run
SQL and get typed native values back, save and open PQCF files — without
starting a process or opening a network connection. The public API is the
namespace **`polyquery.api`** (value mapping documented in
`polyquery.api.values`). It implements `spec/apps/embedding.md`.

`bin/polyquery` and the library share one implementation: the API calls the
same operation handlers as the protocol (`polyquery.protocol`), so an API
call validates and behaves exactly like the protocol operation of the same
name (`spec/protocol/protocol.md`).

Contents: [Building](#building-the-library) ·
[Depending on it](#depending-on-the-library-step-by-step) ·
[A complete minimal program](#a-complete-minimal-program) ·
[API reference](#api-reference) · [Value mapping](#value-mapping) ·
[Errors](#errors) · [Resource management](#resource-management) ·
[Thread safety](#thread-safety) · [Examples](#larger-examples)

## Building the library

Requirements: a JDK (tested with OpenJDK 27), the Clojure CLI (tools.deps)
with Clojure 1.12.3, GNU make. The library has **no dependencies** besides
`org.clojure/clojure`.

```sh
cd implementations/clojure
make build      # among others: target/polyquery.jar
make test       # unit tests, including test/polyquery/api_test.clj
```

The library comes in two forms; use either:

| form | what | when |
|---|---|---|
| source | this directory is a tools.deps project (`deps.edn`, sources in `src/`) | simplest; Clojure compiles the engine when your program loads it (a few seconds on first use) |
| jar | `target/polyquery.jar`, built by `make build`: the AOT-compiled engine and API | faster start-up; also usable from Java/Leiningen/Maven as a plain jar |

## Depending on the library, step by step

1. Build it once with `make build` (needed for the jar form; the source
   form works without a build, but `make test` is a good check).
2. Create your project with a `deps.edn`:

   ```clojure
   ;; myapp/deps.edn
   {:paths ["src"]
    :deps {org.clojure/clojure {:mvn/version "1.12.3"}
           ;; source form: the engine's project directory
           polyquery/engine {:local/root "/path/to/implementations/clojure"}}}
   ```

   or, for the AOT-compiled jar:

   ```clojure
   {:paths ["src"]
    :deps {org.clojure/clojure {:mvn/version "1.12.3"}
           polyquery/engine {:local/root "/path/to/implementations/clojure/target/polyquery.jar"}}}
   ```

   A relative `:local/root` is resolved against your project directory
   (`app/deps.edn` uses `".."`, `examples/embed-demo/deps.edn` `"../.."`).

3. Require the API in your code: `(:require [polyquery.api :as pq])`.
4. Run with `clojure -M -m myapp.core` (or build an uberjar / AOT-compile as
   for any tools.deps project; see `script/compile-client.clj` and the
   Makefile targets of `pqledger` and `pq-embed-demo` for an AOT build that
   reuses the engine jar's classes).

**JVM options.** None are required. Two are useful:

* `-Xss16m` (or running queries on a thread created with a large stack
  size) for very deeply nested SQL expressions — the engine accepts nesting
  up to depth 4,096 and its recursive parser needs stack for that;
  `pqledger` runs its work on a thread with a 256 MiB stack;
* `--enable-native-access=ALL-UNNAMED` only if you use the optional native
  kernels (README, “Native kernels”).

## A complete minimal program

```clojure
;; myapp/src/myapp/core.clj
(ns myapp.core
  (:require [polyquery.api :as pq]))

(defn -main [& _]
  (with-open [db (pq/create {:data-dir "data" :threads 2})]
    (pq/load! db "sales"
              {:text "region,amount,day\neast,10.50,2026-09-01\nwest,4.25,2026-09-02\neast,1.00,2026-09-03\n"
               :schema [["region" "STRING"] ["amount" "DECIMAL(10,2)"] ["day" "DATE"]]})
    (let [r (pq/query db (str "SELECT region, SUM(amount) AS total, MAX(day) AS last_day "
                              "FROM sales GROUP BY region ORDER BY region"))]
      (println (pq/column-names r) (pq/column-types r) (pq/row-count r))
      (doseq [row (pq/rows r)] (prn row)))
    (pq/save! db "sales" "sales.pqcf")          ; data/sales.pqcf
    (try
      (pq/query db "SELECT nope FROM sales")
      (catch clojure.lang.ExceptionInfo e
        (println "error:" (pq/error-code e) (ex-message e))))))
```

```
$ mkdir data && clojure -M -m myapp.core
[region total last_day] [STRING DECIMAL(18,2) DATE] 2
["east" 11.50M #object[java.time.LocalDate 0x698394bf "2026-09-03"]]
["west" 4.25M #object[java.time.LocalDate 0x31887330 "2026-09-02"]]
error: SEMANTIC_ERROR unknown column 'nope'
```

## API reference

All functions are in `polyquery.api`. Table names, column names and paths
are strings. Option maps use keywords; option names are the protocol's with
`-` for `_` (`:timeout-ms` ↔ `timeout_ms`). Every function except `create`,
`close`, `closed?`, `version` and the result accessors takes an instance as
its first argument and throws an [API error](#errors) on failure.

### Instances

**`(create)` / `(create config)`** → `polyquery.api.Engine`

Creates an engine instance with its own empty catalog. `config` keys (all
optional):

| key | meaning | default |
|---|---|---|
| `:data-dir` | directory (string or `java.io.File`) that every file path is resolved against, with the path safety of `--data-dir` (protocol.md §6: e.g. absolute paths and `..` components ⇒ `ACCESS_DENIED`) | `"."` |
| `:max-query-memory-mb` | per-query memory limit (`--max-query-memory-mb`) | 4096 |
| `:threads` | default worker threads of a query | min(8, processors) |
| `:max-ingest-bytes` | largest accepted load input | 4 GiB |
| `:max-table-rows` | largest table | 200,000,000 |
| `:max-join-rows` | largest join result | 100,000,000 |
| `:test-functions?` | enable `PQ_SLEEP` and the other test functions | `false` |

Limits must be positive integers, else `INVALID_REQUEST`. The data directory
is not created and need not exist until a file is read or written.

**`(close db)`** — closes the instance and releases its tables (including
memory-mapped files); idempotent. `Engine` implements `java.io.Closeable`,
so `with-open` closes it. Any later operation on it throws
`INVALID_REQUEST`.

**`(closed? db)`** → boolean.

**`(version)`** → map of the engine's version information, e.g.
`{"engine" "polyquery-clojure" "engine_version" "0.1.0" "capabilities" […] …}`.

### Loading

**`(load! db table source-opts)`** → `{:table :row-count :columns}`

Loads CSV (or JSON / JSON Lines) into a new table, as the protocol's `load`.
`source-opts` (exactly one of `:path` and `:text`):

| key | meaning | default |
|---|---|---|
| `:path` | file path, relative to the data directory | — |
| `:text` | the input itself, a string | — |
| `:format` | `"csv"`, `"json"` or `"jsonl"` | `"csv"` |
| `:schema` | explicit schema: `[["id" "INT64"] …]` or `[{:name "id" :type "INT64"} …]` (canonical type names, `spec/data-types/types.md`) | inferred (ingestion.md §3) |
| `:header` | CSV: is the first record a header? | `true` |
| `:delimiter` | CSV field delimiter: a character or a one-character string | `\,` |
| `:replace` | replace an existing table of that name | `false` (`ALREADY_EXISTS`) |
| `:layout` | `:column` or `:row` in-memory layout | `:column` |
| `:dictionary` | dictionary-encode string columns | engine default |

`:columns` of the result is `[{:name "id" :type "INT64"} …]`.
Errors: `INGEST_ERROR` (malformed input, with details), `NOT_FOUND`,
`ACCESS_DENIED`, `ALREADY_EXISTS`, `RESOURCE_LIMIT`, `INVALID_REQUEST`.

**`(load-rows! db table columns rows)` / `(load-rows! db table columns rows {:replace true})`**
→ same as `load!`

Creates a table directly from native values (an extension; no text is
parsed): `columns` as `:schema` above, `rows` a sequence of rows, each a
sequence of values in column order, `nil` for NULL. Values must be of the
[mapped classes](#value-mapping) (integers are accepted for `DECIMAL` and
`FLOAT64`, `java.time.Instant` for `TIMESTAMP`). A wrong class ⇒
`INVALID_REQUEST`; too many fractional digits for a decimal ⇒
`CONVERSION_ERROR`; out of range ⇒ `NUMERIC_OVERFLOW`.

### Querying

**`(query db sql)` / `(query db sql opts)`** → `polyquery.api.Result`

Executes one SQL statement (`spec/sql/`; `SELECT`, `WITH`, `UNION ALL`,
`EXPLAIN`, `CREATE INDEX`, …). `opts`:

| key | meaning | default |
|---|---|---|
| `:threads` | worker threads (≥ 1) | the instance's `:threads` |
| `:timeout-ms` | time limit, 0 = none (⇒ `TIMEOUT`) | 0 |
| `:max-rows` | more result rows ⇒ `RESOURCE_LIMIT` | none |
| `:mode` | `"auto"`, `"row"`, `"vectorized"` | `"auto"` |
| `:join` | `"auto"`, `"hash"`, `"merge"`, `"nested_loop"` | `"auto"` |
| `:optimize`, `:use-indexes`, `:native` | booleans | engine defaults |

Accessors of a `Result` (a record with fields `:columns`, `:rows`,
`:row-count`, so keyword access works too):

| function | returns |
|---|---|
| `(columns r)` | `[{:name "total" :type "DECIMAL(18,2)"} …]` |
| `(column-names r)` | `["region" "total" …]` |
| `(column-types r)` | canonical type names: `["STRING" "DECIMAL(18,2)" …]` |
| `(row-count r)` | number of rows (a long) |
| `(rows r)` | vector of rows, each a vector of [native values](#value-mapping) |
| `(row-maps r)` | vector of maps from column name (string) to value |

The whole result is materialized in memory; use `:max-rows`, `LIMIT` or an
aggregate for large tables.

### Storage and catalog

**`(save! db table path)` / `(save! db table path opts)`** → `{:path :bytes}`

Writes a table to a PQCF file (relative to the data directory), atomically
replacing an existing file. `opts`: `:row-group-size`, `:encoding`
(`"auto"`, `"plain"`, `"dict"`, `"rle"`). Errors: `NOT_FOUND`,
`ACCESS_DENIED`, `IO_ERROR`.

**`(open! db table path)` / `(open! db table path opts)`** → `{:table :row-count :columns}`

Opens a PQCF file as a table (any conforming implementation's files), with
its indexes. `opts`: `:replace` (default `false`), `:mmap` (memory-map
instead of reading; default `false`), `:layout`. Errors: `NOT_FOUND`,
`ALREADY_EXISTS`, `STORAGE_CORRUPT`, `STORAGE_VERSION_UNSUPPORTED`,
`ACCESS_DENIED`.

**`(drop! db table)`** → `nil`; `NOT_FOUND` if there is no such table.

**`(tables db)`** → `[{:name "sales" :row-count 3} …]`, sorted by name.

**`(schema db table)`** → `{:table :row-count :columns [{:name :type} …]
:indexes [{:name :column :kind} …] :layout :column}`; `NOT_FOUND` if absent.

Indexes are created with SQL: `(pq/query db "CREATE INDEX ix ON t (id) USING BTREE")`.

### Error helpers

**`(error-code e)`** → the code string of an API error, `nil` for any other
throwable. **`(error-details e)`** → its details map (string keys) or `nil`.

## Value mapping

Result values (and `load-rows!` input) are JVM values, never JSON text:

| PolyQuery type | Clojure / JVM value | example |
|---|---|---|
| `INT64` | `java.lang.Long` | `42` |
| `DECIMAL(p,s)` | `java.math.BigDecimal` with scale exactly `s` (exact) | `11.50M` |
| `FLOAT64` | `java.lang.Double` (binary64) | `1.5` |
| `STRING` | `java.lang.String` | `"east"` |
| `BOOLEAN` | `java.lang.Boolean` | `true` |
| `DATE` | `java.time.LocalDate` | `#object[java.time.LocalDate "2026-09-03"]` |
| `TIMESTAMP` | `java.time.LocalDateTime` (no time zone; microsecond precision) | `2026-09-03T12:30:00.000001` |
| NULL (any type) | `nil` | `nil` |

NULL is `nil` and no non-NULL value is `nil`, so NULL is always
distinguishable (`false` is a BOOLEAN value, `""` a STRING value). The
conversions to and from the engine's internal representation (scaled longs
for decimals, days and microseconds since 1970-01-01 for dates and
timestamps) are `polyquery.api.values/->native` and `->runtime`; the helpers
`micros->local-date-time` and `local-date-time->micros` convert timestamps.

## Errors

Every failure of an API function is thrown as a `clojure.lang.ExceptionInfo`:

* `(ex-message e)` — the message;
* `(:polyquery/code (ex-data e))`, or `(pq/error-code e)` — the
  specification's error code (`spec/errors/error-codes.json`):
  `PARSE_ERROR`, `SEMANTIC_ERROR`, `TYPE_ERROR`, `NUMERIC_OVERFLOW`,
  `DIVISION_BY_ZERO`, `CONVERSION_ERROR`, `INVALID_ARGUMENT`,
  `SUBQUERY_CARDINALITY`, `INVALID_REQUEST`, `INGEST_ERROR`, `UNSUPPORTED`,
  `ACCESS_DENIED`, `NOT_FOUND`, `ALREADY_EXISTS`, `CANCELLED`,
  `RESOURCE_LIMIT`, `IO_ERROR`, `STORAGE_CORRUPT`,
  `STORAGE_VERSION_UNSUPPORTED`, `INTERNAL_ERROR`, `TIMEOUT`;
* `(:polyquery/details (ex-data e))`, or `(pq/error-details e)` — extra
  information where the protocol gives some (e.g. `{"record" 3}` for an
  `INGEST_ERROR` in the third CSV record), else absent;
* `(ex-cause e)` — the underlying Java exception, when there is one.

Unexpected internal failures (including `OutOfMemoryError` during a query)
are mapped as by the protocol, e.g. to `RESOURCE_LIMIT` or `INTERNAL_ERROR`,
so a caller only ever needs to catch `ExceptionInfo`. An error never leaves
the instance in a changed or unusable state: a failing `load!` creates no
table, a failing query changes nothing, and the next call works normally.

```clojure
(try
  (pq/query db "SELECT 1/0")
  (catch clojure.lang.ExceptionInfo e
    (case (pq/error-code e)
      "DIVISION_BY_ZERO" :handle-it
      (throw e))))
```

## Resource management

* An instance holds its tables in memory (or memory-mapped, `open!` with
  `:mmap true`). `close` (or leaving `with-open`) drops them so the garbage
  collector can reclaim memory and unmap files; the files themselves are not
  touched. Instances that are not closed are reclaimed when unreachable.
* A query's working memory is bounded by `:max-query-memory-mb`; exceeding
  it fails the query with `RESOURCE_LIMIT`. The JVM heap (`-Xmx`) must be
  large enough for your tables plus that working memory.
* Parallel query workers (`:threads` > 1) run on a process-wide cached pool
  of **daemon** threads that is not owned by an instance; idle workers end
  by themselves. Nothing needs to be shut down besides closing instances,
  and a program exits normally when its `-main` returns.
* `save!` writes to a temporary file and renames it, so a crash never leaves
  a half-written PQCF file behind.

## Thread safety

* **Several instances** may exist in one process; they are fully
  independent (separate catalogs and data directories).
* **One instance may be used from several threads at once.** Every query
  runs on a consistent snapshot of the catalog; catalog changes (`load!`,
  `load-rows!`, `open!`, `drop!`, `CREATE INDEX`) are published atomically,
  so a concurrent query sees a table either entirely before or entirely
  after the change. This is the same machinery the `serve` HTTP server uses
  for its concurrent clients. Two threads replacing the *same* table race:
  the last one wins.
* `Result` values are immutable Clojure data and may be shared freely.
* `close` while other threads are using the instance makes their *later*
  calls fail with `INVALID_REQUEST`; calls already running complete.

## Larger examples

* [`examples/embed-demo`](examples/embed-demo/src/embed_demo/main.clj) — the
  minimal example program (embedding.md §5): `bin/pq-embed-demo DATA_DIR
  CSV_FILE SQL` loads a CSV file as table `t`, runs the SQL and prints the
  result as CSV; engine errors print `error: CODE: MESSAGE` and exit 1. It
  is a separate tools.deps project depending on the engine through
  `:local/root`.
* [`app/`](app/) — **pqledger** ([APP.md](APP.md)), a complete application
  on the API: it opens PQCF tables, builds tables from native values with
  `load-rows!`, runs all reports as SQL, saves the ledger with `save!` and
  maps API errors to its exit codes (`app/src/pqledger/ledger.clj` is the
  part that talks to the engine).
* `test/polyquery/api_test.clj` — unit tests showing every operation.
