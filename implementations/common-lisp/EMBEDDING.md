# Embedding PolyQuery in a Common Lisp program

The PolyQuery engine of this directory is an ordinary **ASDF system**,
`"polyquery"`. Loading it gives a program the whole engine in its own
process — no server, no subprocess, no network — through the public API in
the package **`POLYQUERY.API`**: create an engine instance, load CSV, run SQL
and get typed Lisp values back, save tables as PQCF files and open them
again. (`bin/polyquery`, the protocol front end, is built from the same
system and uses the same engine functions.)

Contents: [Building and depending on the library](#building-and-depending-on-the-library) ·
[A complete minimal program](#a-complete-minimal-program) ·
[API reference](#api-reference) · [Value types](#value-types) ·
[Errors](#errors) · [Resource management](#resource-management) ·
[Thread safety](#thread-safety) · [Larger examples](#larger-examples)

## Building and depending on the library

Requirements: SBCL 2.6.9 with its bundled ASDF. The library uses only SBCL
and its contribs (`sb-posix`, `sb-bsd-sockets`), which ASDF loads
automatically.

### 1. Build (optional)

```sh
make -C implementations/common-lisp build
```

builds the executables `build/polyquery`, `build/pqledger` and
`build/pq-embed-demo` and compiles the library's fasls into `build/fasl/`.
A program that depends on the system does not need this step: ASDF compiles
the sources on first use (into its usual cache,
`~/.cache/common-lisp/sbcl-…/`) and recompiles only what changed.

The system definition is `implementations/common-lisp/polyquery.asd`:

| system | contents |
|---|---|
| `"polyquery"` | the engine and its embedding API (package `POLYQUERY.API`) |
| `"polyquery/tests"` | the engine's unit tests (`make test`) |

### 2. Tell ASDF where the system is

Use one of ASDF's standard mechanisms — no files are copied:

* a source registry file, once per machine (recommended):

  ```sh
  mkdir -p ~/.config/common-lisp/source-registry.conf.d
  echo '(:directory "/path/to/implementations/common-lisp/")' \
    > ~/.config/common-lisp/source-registry.conf.d/50-polyquery.conf
  ```

* or the environment variable, per shell or per build:

  ```sh
  export CL_SOURCE_REGISTRY="/path/to/implementations/common-lisp/:$CL_SOURCE_REGISTRY"
  ```

* or, in a build script, `(asdf:load-asd #p"/path/to/implementations/common-lisp/polyquery.asd")`.

### 3. Depend on it in your system

```lisp
;;;; my-report.asd
(defsystem "my-report"
  :depends-on ("polyquery")
  :components ((:file "main")))
```

```lisp
;;;; main.lisp
(defpackage #:my-report
  (:use #:common-lisp)
  (:local-nicknames (#:pq #:polyquery.api)))   ; a short local name for the API
(in-package #:my-report)
```

### 4. Load, run or build an executable

```sh
sbcl --eval '(require :asdf)' --eval '(asdf:load-system "my-report")' ...
```

To ship a standalone executable, load the system and call
`sb-ext:save-lisp-and-die` with `:executable t` and your entry function as
`:toplevel`, as `build.lisp` does for the three programs of this directory.
The engine processes deeply nested SQL recursively; for statements near its
limits (see README *Change request CR-6*) start SBCL with a large control
stack (`--control-stack-size 1024`, as the Makefile does). Ordinary
statements need nothing special.

`examples/embed-demo/` is exactly such a separate project (its own `.asd`,
depending only on `"polyquery"`, using only `POLYQUERY.API`); copied
anywhere, it builds unchanged with `CL_SOURCE_REGISTRY` pointing at this
directory and at the copy.

## A complete minimal program

```lisp
;;;; totals.lisp — sbcl --script totals.lisp   (with CL_SOURCE_REGISTRY set as above)
(require :asdf)
(asdf:load-system "polyquery")

(defpackage #:totals
  (:use #:common-lisp)
  (:local-nicknames (#:pq #:polyquery.api)))
(in-package #:totals)

(pq:with-database (db :data-dir "/tmp" :threads 4)
  ;; a table from in-memory CSV text, with an explicit schema
  (pq:load-csv db "sales"
               :text (format nil "region,amount~%north,10.50~%south,3.25~%north,0.75~%")
               :schema '(("region" "STRING") ("amount" "DECIMAL(18,2)")))
  (handler-case
      (let ((result (pq:query db "SELECT region, SUM(amount) AS total, COUNT(*) AS n
                                  FROM sales GROUP BY region ORDER BY region")))
        (format t "~{~A~^ | ~}~%" (pq:result-column-names result))   ; region | total | n
        (pq:do-result-rows (row result)
          (destructuring-bind (region total n) (coerce row 'list)
            ;; TOTAL is an exact rational, e.g. 45/4 for 11.25
            (format t "~A | ~A | ~D~%" region (pq:decimal-string total 2) n))))
    (pq:engine-error (e)
      (format *error-output* "error: ~A: ~A~%" (pq:engine-error-code e) (pq:engine-error-message e))
      (sb-ext:exit :code 1))))
```

Output:

```
region | total | n
north | 11.25 | 2
south | 3.25 | 1
```

## API reference

All symbols below are exported from `POLYQUERY.API`. Every operation that
takes a database signals `ENGINE-ERROR` on failure ([Errors](#errors)).

### Instances

**`(make-database &key data-dir max-query-memory-mb threads max-ingest-bytes max-table-rows max-join-rows)`** → `database`

Creates an engine instance with an empty catalog.

| argument | meaning (the `bin/polyquery` option) | default |
|---|---|---|
| `data-dir` | the data directory, a string or pathname, absolute or relative to the process's working directory (`--data-dir`). Paths given to `load-csv`, `save-table` and `open-table` are relative to it and may not leave it (no absolute paths, no `..`: `ACCESS_DENIED`). The directory is not created or checked here. | the current directory |
| `max-query-memory-mb` | memory limit of one query in MB (`--max-query-memory-mb`) | 2048 |
| `threads` | default worker threads per query (`--threads`) | one per CPU, at most 16 |
| `max-ingest-bytes` | largest CSV input (`--max-ingest-bytes`) | 4 GiB |
| `max-table-rows` | largest table (`--max-table-rows`) | 200,000,000 |
| `max-join-rows` | largest join result (`--max-join-rows`) | 100,000,000 |

Numeric arguments must be positive integers (`INVALID_REQUEST`); `nil` means
the default.

**`(close-database database)`** → `nil` — releases the instance's tables.
Idempotent; afterwards every other operation signals `INVALID_REQUEST`.

**`(with-database (var &rest make-database-arguments) &body body)`** — binds
`var` to a new instance, evaluates `body` and closes the instance on exit,
also a non-local one. Returns the values of `body`.

**`(database-open-p database)`**, **`(database-data-dir database)`** — whether
the instance is open; its data directory as an absolute native path with a
trailing `/`. `database` is a structure type.

### Loading and storing tables

**`(load-csv database table &key path text schema (header t) (delimiter #\,) replace)`** → row count, columns

Loads CSV (`spec/data-types/ingestion.md` §1) into the table named `table`
from exactly one of `path` (a file relative to the data directory, string or
pathname) and `text` (the CSV itself, a string). `schema` is an optional list
of `(name type)` entries, `type` a type name such as `"INT64"` or
`"DECIMAL(18,2)"` (aliases like `"BIGINT"` are accepted); without it the
column types are inferred (INT64, FLOAT64, BOOLEAN, DATE, TIMESTAMP or
STRING — never DECIMAL). `header nil` requires a schema. `delimiter` is a
character or a one-character string. Without `replace`, an existing table
of that name is `ALREADY_EXISTS`. Returns the number of rows and, as a
second value, the table's columns (a list of `column`).
Errors: `INVALID_REQUEST`, `ALREADY_EXISTS`, `ACCESS_DENIED`, `NOT_FOUND`
(no such file), `INGEST_ERROR`, `CONVERSION_ERROR`, `RESOURCE_LIMIT`, `IO_ERROR`.

**`(create-table database table columns rows &key replace)`** → row count

Creates a table from Lisp data: `columns` is a list of `(name type)` entries
as for `load-csv`, `rows` a sequence (list or vector) of rows, each a
sequence of native values in column order ([Value types](#value-types);
`+null+` for NULL). A value that does not fit its column is
`INVALID_REQUEST` (wrong kind of value), `CONVERSION_ERROR` (a DECIMAL with
more fractional digits than the scale) or `NUMERIC_OVERFLOW`. This is an
addition to the operations embedding.md requires; pqledger uses it to write
its ledger tables.

**`(save-table database table path)`** → file size in bytes

Writes the table as a PQCF file at `path` (relative to the data directory),
replacing an existing file atomically (written to a temporary file, synced,
renamed). Errors: `NOT_FOUND`, `ACCESS_DENIED`, `IO_ERROR`.

**`(open-table database table path &key replace)`** → row count

Opens the PQCF file at `path` (relative to the data directory; written by
any PolyQuery implementation) as the table `table`, recreating the indexes
listed in the file. Without `replace`, an existing table is
`ALREADY_EXISTS`. Errors also: `NOT_FOUND`, `ACCESS_DENIED`,
`STORAGE_CORRUPT`, `STORAGE_VERSION_UNSUPPORTED`, `IO_ERROR`.

**`(drop-table database table)`** → `nil` — removes the table and its
indexes; `NOT_FOUND` if there is none.

**`(list-tables database)`** → list of table names, sorted
case-insensitively.

**`(table-exists-p database table)`** → generalized boolean.

**`(table-schema database table)`** → list of `column`, and the row count as
a second value; `NOT_FOUND` if there is no such table.

Table and column names are matched ASCII case-insensitively, as in SQL.

### Queries and results

**`(query database sql &key threads timeout-ms max-rows (mode :auto))`** → `result`

Executes one SQL statement (`spec/sql/`: a query, `EXPLAIN`, or
`CREATE INDEX`/`DROP INDEX`). `threads` overrides the instance's default
worker threads for this query; `timeout-ms` aborts it with `TIMEOUT` after
that many milliseconds; `max-rows` makes a result with more rows a
`RESOURCE_LIMIT` error; `mode` selects the executor (`:auto`, `:row` or
`:vectorized`). Errors: `PARSE_ERROR`, `SEMANTIC_ERROR`, `TYPE_ERROR`,
`NUMERIC_OVERFLOW`, `DIVISION_BY_ZERO`, `CONVERSION_ERROR`,
`INVALID_ARGUMENT`, `SUBQUERY_CARDINALITY`, `UNSUPPORTED`, `TIMEOUT`,
`RESOURCE_LIMIT`, `INVALID_REQUEST`.

A **`result`** (a structure) is complete and independent of the instance: it
stays valid after the instance is closed.

| function | returns |
|---|---|
| `(result-columns result)` | the columns, a list of `column` |
| `(result-column-names result)` | the column names, a list of strings |
| `(result-column-types result)` | the canonical type names (`"INT64"`, `"DECIMAL(18,2)"`, …), a list of strings |
| `(result-row-count result)` | the number of rows |
| `(result-rows result)` | the rows: a simple-vector of simple-vectors of native values |
| `(result-value result row column)` | one value; `row` is 0-based, `column` a 0-based index or a column name (`NOT_FOUND` if there is none) |
| `(do-result-rows (row result [value]) &body body)` | macro: evaluates `body` with `row` bound to each row vector in order, then returns `value` |

A **`column`** (a structure) has the readers **`column-name`** and
**`column-type`** (the canonical type name).

### Value helpers

| function | meaning |
|---|---|
| `+null+` | the NULL value (the keyword `:null`) |
| `(null-value-p value)` | true for NULL |
| `(make-date year month day)` | the DATE value of a valid calendar date (`INVALID_REQUEST` otherwise) |
| `(date-components days)` | year, month and day of a DATE value, as three values |
| `(date-string days)` | `"YYYY-MM-DD"` |
| `(timestamp-string micros)` | `"YYYY-MM-DD HH:MM:SS"` or `"…SS.ffffff"` |
| `(decimal-string rational scale)` | canonical DECIMAL text with `scale` decimals (`-12.50`), rounding half away from zero if needed |
| `(decimal-type-scale type)` | the scale of a DECIMAL type (a type name or a `column`), else `nil` |
| `(value-text value type)` | the canonical text of a value of `type` (a type name or a `column`) as in `spec/data-types/types.md` §9 without JSON quotes; `nil` for NULL |

## Value types

Result values (and the values `create-table` accepts) are native Lisp objects:

| SQL type | Lisp value | example |
|---|---|---|
| `INT64` | `integer` (within the signed 64-bit range) | `42` |
| `DECIMAL(p,s)` | `rational`, exact: an integer or a ratio | `-12.50` → `-25/2`, `3.00` → `3` |
| `FLOAT64` | `double-float` | `0.5d0` |
| `STRING` | `string` | `"Café"` |
| `BOOLEAN` | `t` / `nil` | |
| `DATE` | `integer`: days since 1970-01-01 | `2026-01-01` → `20454` |
| `TIMESTAMP` | `integer`: microseconds since 1970-01-01 00:00:00 (UTC, no zone) | |
| NULL (any type) | the keyword `:null` (`+null+`) | |

Because DECIMAL values are rationals, arithmetic on them in Lisp stays exact;
the column's type (`result-column-types`) tells the scale for printing
(`decimal-string`, `value-text`). NULL is never `nil`, so a NULL BOOLEAN is
distinguishable from false. Dates and timestamps are plain integers so they
compare and subtract directly; use `date-components`/`date-string` (or
`make-date`) to convert. An untyped `NULL` literal column is reported as
`STRING`.

## Errors

Every failing operation signals **`engine-error`**, a subclass of `error`:

| reader | value |
|---|---|
| `(engine-error-code e)` | the error code of `spec/errors/error-codes.json` as a string: `"PARSE_ERROR"`, `"NOT_FOUND"`, … |
| `(engine-error-message e)` | the human-readable message |

The report of the condition is `CODE: MESSAGE`. Out-of-memory conditions and
statements too deep for the stack become `RESOURCE_LIMIT`, unexpected
internal failures `INTERNAL_ERROR`. Misuse of the API itself — a closed
instance, a non-string SQL, a bad option value — is `INVALID_REQUEST`.

**An error leaves the instance usable**: a failed load or open changes no
table, a failed query has no effect, and the next call works normally.

```lisp
(handler-case (pq:query db "SELECT nope FROM t")
  (pq:engine-error (e)
    (if (string= (pq:engine-error-code e) "SEMANTIC_ERROR")
        (warn "bad query: ~A" (pq:engine-error-message e))
        (error e))))
```

## Resource management

An instance holds its tables in memory (tables opened from PQCF files read
the file when opened; nothing stays open on disk afterwards). Release them
with `close-database`, or let `with-database` do it — the standard
`with-` idiom, which closes on any exit:

```lisp
(pq:with-database (db :data-dir "/srv/data")
  (pq:open-table db "events" "events.pqcf")
  (pq:result-row-count (pq:query db "SELECT * FROM events WHERE kind = 'click'")))
```

Memory is reclaimed by the garbage collector once neither the instance nor
any result refers to it; results are independent copies and may be kept
after closing. Several instances may exist in one process; each has its own
catalog, data directory and limits. The per-query memory limit
(`max-query-memory-mb`) bounds the working memory of one query; in addition
the engine keeps the whole process below a soft heap limit derived from
SBCL's dynamic space and the machine's memory, and turns heap exhaustion into
`RESOURCE_LIMIT` instead of crashing. Start SBCL with a dynamic space large
enough for your data (`--dynamic-space-size`, e.g. `8192` MB).

The engine runs its numeric code with SBCL's floating-point traps masked;
the API does this around each call, so callers need no special setup.

## Thread safety

**An instance may be used from several threads at once.** Every operation is
safe to call concurrently on the same instance: the catalog is protected by
a lock and publishes immutable table objects, and each query runs against a
snapshot of the catalog taken when it starts, so a concurrent `load-csv`,
`create-table … :replace t`, `open-table` or `drop-table` never disturbs a
running query (it sees the old or the new table, never a mix). This is the
same mechanism the engine's HTTP server uses for its concurrent clients.
Concurrent replacements of one table are serialized; the last one wins.
Different instances share nothing and need no coordination.

Two rules: do not call `close-database` while other threads are still using
the instance, and do not have two processes write the same PQCF file at the
same time (saving is atomic per file, but the last writer wins).

A query may itself use several worker threads (`threads`); they are created
and joined inside the call.

## Larger examples

* **`examples/embed-demo/`** — the minimal standalone program
  (`bin/pq-embed-demo DATA_DIR CSV_FILE SQL`): creates an instance, loads a
  CSV file as table `t`, runs one statement and prints the result as CSV;
  engine errors print `error: CODE: MESSAGE` and exit with status 1. It is a
  separate ASDF system (`pq-embed-demo.asd`) that uses only `POLYQUERY.API`.
* **`app/`** — `pqledger`, a complete application on the API (see
  [APP.md](APP.md)): opening and writing PQCF files (`open-table`,
  `create-table`, `save-table`), category resolution, reports and budgets
  as SQL, typed results formatted as table, CSV and JSON. `app/src/ledger.lisp`
  and `app/src/reports.lisp` show the API in use.
