# Embedding PolyQuery in a Go program

The Go engine is also a library: package **`polyquery`**, the root package
of the Go module `polyquery` in `implementations/go/`. A program uses it
in-process — no engine process is started and no network connection is
opened — to load data, run SQL and read typed results
(spec/apps/embedding.md).

* Minimal example: [`examples/embed-demo/`](examples/embed-demo/main.go)
  (a separate module, built as `bin/pq-embed-demo`).
* Larger example: the personal-finance application [`app/`](app/) — see
  [APP.md](APP.md); its storage layer `app/internal/ledger` uses
  `CreateTable`, `CreateTableAs`, `OpenTable`, `SaveTable` and `Query`.
* API documentation in the source: `go doc polyquery` (or
  `go doc -all polyquery`) in `implementations/go/`.

Contents: [Building](#1-building-the-library) ·
[Depending on it](#2-using-it-from-another-project) ·
[A complete program](#3-a-complete-minimal-program) ·
[API reference](#4-api-reference) · [Values](#5-value-type-mapping) ·
[Errors](#6-errors) · [Resources](#7-resource-management) ·
[Threads](#8-thread-safety)

## 1. Building the library

Requirements: Go 1.27 (`go1.27.1` tested), `make`, optionally a C compiler
for cgo (only used to load the optional native kernel library). The module
has no requirements; everything builds offline.

```bash
cd implementations/go
make build      # compiles every package of the module (the library included),
                # build/polyquery, build/pqledger and build/pq-embed-demo
make test       # go test ./... (engine, library and application tests)
```

`make build` sets `GOTOOLCHAIN=local`, `GOPROXY=off`, `-trimpath` and, on
amd64, `GOEXPERIMENT=simd` (explicit SIMD kernels). A dependent project
does not need these settings: without `GOEXPERIMENT=simd` the engine
compiles its portable loops and gives identical results. Go compiles the
library from source as part of the dependent program, so "building the
library" means compiling the package; there is no separate artifact.

## 2. Using it from another project

Go modules use the library with a `require` plus a `replace` that points to
the local checkout. Step by step, for a new project in `~/src/myapp`:

1. Create the module:

   ```bash
   mkdir -p ~/src/myapp && cd ~/src/myapp
   go mod init example.com/myapp
   ```

2. Add the dependency on the module `polyquery` and point it at the engine
   directory (absolute or relative path):

   ```bash
   go mod edit -require=polyquery@v0.0.0 \
               -replace=polyquery=/path/to/polyquery/implementations/go
   ```

   `go.mod` then reads:

   ```
   module example.com/myapp

   go 1.27.1

   require polyquery v0.0.0

   replace polyquery => /path/to/polyquery/implementations/go
   ```

   No `go.sum` entries are needed for a directory replacement, and nothing
   is downloaded (`GOPROXY=off` works).

3. Import the package and use it (next section): `import "polyquery"`.

4. Build and run as usual: `go build ./...`, `go run .`, `go test ./...`.

`examples/embed-demo/go.mod` is exactly such a project
(`replace polyquery => ../..`); `make build` builds it with
`cd examples/embed-demo && go build`.

Only the package `polyquery` is public. The engine's `internal/...`
packages cannot be imported from other modules (Go's `internal` rule), so
the public API is the whole contract.

## 3. A complete minimal program

```go
package main

import (
	"context"
	"errors"
	"fmt"
	"log"

	"polyquery"
)

func main() {
	db, err := polyquery.New(polyquery.Config{DataDir: "."})
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	csv := "day,amount\n2026-01-01,10.50\n2026-01-02,-3.25\n2026-01-02,0.75\n"
	schema := []polyquery.Column{
		{Name: "day", Type: polyquery.TypeDate},
		{Name: "amount", Type: polyquery.DecimalType(18, 2)},
	}
	if _, err := db.LoadText("t", csv, &polyquery.LoadOptions{Schema: schema}); err != nil {
		log.Fatal(err)
	}

	res, err := db.Query(context.Background(),
		"SELECT day, SUM(amount) AS total, COUNT(*) AS n FROM t GROUP BY day ORDER BY day", nil)
	if err != nil {
		log.Fatal(err)
	}
	for _, row := range res.Rows {
		day := row[0].(polyquery.Date)      // DATE
		total := row[1].(polyquery.Decimal) // DECIMAL(18,2), exact
		n := row[2].(int64)                 // INT64
		fmt.Println(day, total, n)
	}

	_, err = db.Query(context.Background(), "SELECT nope FROM t", nil)
	var pe *polyquery.Error
	if errors.As(err, &pe) {
		fmt.Println(pe.Code, "-", pe.Message) // SEMANTIC_ERROR - unknown column "nope"
	}
}
```

Output:

```
2026-01-01 10.50 1
2026-01-02 -2.50 2
SEMANTIC_ERROR - unknown column "nope"
```

The same program is the package's `Example` test (`example_test.go`), so
it is compiled and checked by `make test`.

## 4. API reference

All operations are methods of `*polyquery.DB` unless noted. Every error is
a `*polyquery.Error` (§6). Options parameters are pointers; `nil` selects
all defaults.

### Instance

| Declaration | Description |
|---|---|
| `func New(cfg Config) (*DB, error)` | Creates an instance with an empty catalog. Fails with `NOT_FOUND` if `DataDir` does not exist, `IO_ERROR` if it is not a directory or the native kernels cannot be loaded, `INVALID_ARGUMENT` for negative limits. |
| `func (db *DB) Close() error` | Drops every table and releases the instance. Idempotent; later calls of other methods fail with `INVALID_REQUEST`. |
| `const Version` | Engine version (`polyquery capabilities`/`version` report the same). |
| `func Capabilities() []string` | The engine's capability strings. |

`Config` — every zero field selects the default of the CLI option named:

| Field | CLI option | Default |
|---|---|---|
| `DataDir string` | `--data-dir` | `.` |
| `MaxQueryMemoryMB int64` | `--max-query-memory-mb` | 4096 |
| `Threads int` | `--threads` | min(16, CPUs) |
| `MaxIngestBytes int64` | `--max-ingest-bytes` | 4 GiB |
| `MaxTableRows int64` | `--max-table-rows` | 500,000,000 |
| `MaxJoinRows int64` | `--max-join-rows` | 100,000,000 |
| `EnableTestFunctions bool` | `--enable-test-functions` | false |
| `NativeKernels string` | `--native-kernels` | none |
| `Logger *slog.Logger` | (`--log-level`) | discard |

File paths of `LoadFile`, `SaveTable` and `OpenTable` are relative to
`DataDir` and checked as in protocol.md §6: absolute paths and `..`
components fail with `ACCESS_DENIED`.

### Loading data

| Declaration | Description |
|---|---|
| `func (db *DB) LoadFile(table, path string, opts *LoadOptions) (*TableInfo, error)` | Loads a CSV/JSON/JSONL file as a table (the protocol's `load` with `path`). |
| `func (db *DB) LoadText(table, data string, opts *LoadOptions) (*TableInfo, error)` | Loads in-memory text (`load` with `data`). |
| `func (db *DB) CreateTable(table string, columns []Column, rows [][]any, opts *CreateOptions) (*TableInfo, error)` | Creates a table from Go values (§5); `rows` may be empty. Wrong value types fail with `TYPE_ERROR`, values that do not fit a DECIMAL column with `NUMERIC_OVERFLOW` / `INVALID_ARGUMENT`. |
| `func (db *DB) CreateTableAs(ctx context.Context, table, sql string, opts *CreateOptions) (*TableInfo, error)` | Runs a query and stores its result as a table (CREATE TABLE AS). Columns of the untyped `NULL` literal become STRING. |

`LoadOptions`: `Format` (`polyquery.CSV` default, `JSON`, `JSONL`),
`Schema []Column` (nil: infer, ingestion.md §1.1), `NoHeader bool` (the
first CSV record is data; requires `Schema`), `Delimiter byte` (default
`,`), `Replace bool`. Load errors: `INGEST_ERROR`, `CONVERSION_ERROR`
(details `record`, `column_name`), `NOT_FOUND`, `ACCESS_DENIED`,
`ALREADY_EXISTS` (table exists and `Replace` is false), `RESOURCE_LIMIT`.

`CreateOptions`: `Replace bool`; `Query QueryOptions` (CreateTableAs only).

`TableInfo`: `Name string`, `RowCount int64`, `Columns []Column`,
`Indexes []IndexInfo` (filled by `Schema` only; `IndexInfo` has `Name`,
`Column`, `Kind` = `"HASH"` or `"BTREE"`).

### Queries

| Declaration | Description |
|---|---|
| `func (db *DB) Query(ctx context.Context, sql string, opts *QueryOptions) (*Result, error)` | Executes one statement (SELECT … / WITH … / EXPLAIN / CREATE INDEX / DROP INDEX) and returns the complete result. |
| `func (db *DB) QueryRows(ctx context.Context, sql string, opts *QueryOptions) (*Rows, error)` | Executes one statement and streams its result. |
| `func (r *Result) RowCount() int` | Number of rows. |
| `func (r *Rows) Next() bool`, `Values() []any`, `Columns() []Column`, `Err() error`, `Close() error` | Cursor in the `database/sql` style: `for rows.Next() { v := rows.Values() }`, then check `rows.Err()`. |

`Result` has `Columns []Column` (name and type) and `Rows [][]any`
(`Rows[i][j]` is the value of column `j`, §5).

`QueryOptions` (protocol query options):

| Field | Protocol option | Meaning |
|---|---|---|
| `Threads int` | `threads` | worker threads; 0 = `Config.Threads` |
| `Timeout time.Duration` | `timeout_ms` | 0 = none; exceeded ⇒ `TIMEOUT` |
| `MaxRows int64` | `max_rows` | 0 = unlimited (unlike the protocol, where 0 allows no rows); more rows ⇒ `RESOURCE_LIMIT` |
| `Mode string` | `mode` | `""`/`auto`, `row`, `vectorized`; others ⇒ `UNSUPPORTED` |
| `Join string` | `join` | `""`/`auto`, `hash`, `merge`, `nested_loop` |
| `NoOptimize bool` | `optimize: false` | skip the logical optimizer |
| `NoIndexes bool` | `use_indexes: false` | never use indexes |
| `Native bool` | `native` | use loaded native kernels |

Cancelling `ctx` stops a running query with `CANCELLED`.

### Storage and catalog

| Declaration | Description |
|---|---|
| `func (db *DB) SaveTable(table, path string, opts *SaveOptions) (int64, error)` | Writes the table (and its index definitions) as a PQCF file, atomically replacing an existing file; returns the size. `SaveOptions`: `RowGroupSize int`, `Encoding` (`auto`, `plain`, `dict`, `rle`). Errors `NOT_FOUND`, `ACCESS_DENIED`, `IO_ERROR`. |
| `func (db *DB) OpenTable(table, path string, opts *OpenOptions) (*TableInfo, error)` | Reads a PQCF v1/v2 file as a table and rebuilds its indexes. `OpenOptions`: `Replace bool`, `Mmap bool` (map the file and decode chunks lazily). Errors `NOT_FOUND`, `STORAGE_CORRUPT`, `STORAGE_VERSION_UNSUPPORTED`, `ALREADY_EXISTS`. |
| `func (db *DB) DropTable(table string) error` | Removes a table and its indexes (`NOT_FOUND` if absent). |
| `func (db *DB) Tables() ([]TableInfo, error)` | All tables, ordered by name. |
| `func (db *DB) Schema(table string) (*TableInfo, error)` | One table's columns, row count and indexes. |

Table and column names are matched case-insensitively (ASCII), as in SQL.

### Types

| Declaration | Description |
|---|---|
| `type Column struct { Name string; Type Type }` | A column. |
| `type Type struct { Kind Kind; Precision, Scale int }` | A column type; `String()` gives the canonical name (`"INT64"`, `"DECIMAL(18,2)"`, …). |
| `TypeBoolean`, `TypeInt64`, `TypeFloat64`, `TypeString`, `TypeDate`, `TypeTimestamp`, `DecimalType(p, s)` | Type values. |
| `func ParseType(name string) (Type, error)` | Parses a type name or alias (`BIGINT`, `NUMERIC(10,3)`, `VARCHAR`, …). |
| `KindBoolean`, `KindInt64`, `KindFloat64`, `KindDecimal`, `KindString`, `KindDate`, `KindTimestamp` | Type kinds. |

## 5. Value-type mapping

Result values (and `CreateTable` inputs) are typed Go values; **NULL is
`nil`** for every type, distinct from every value (an empty string is
`""`, never `nil`).

| SQL type | Go type | Notes |
|---|---|---|
| `BOOLEAN` | `bool` | |
| `INT64` | `int64` | `CreateTable` also accepts `int`, `int32` |
| `FLOAT64` | `float64` | |
| `DECIMAL(p,s)` | `polyquery.Decimal` | exact: an unscaled integer of up to 38 digits and the scale `s`. `String()` is the canonical text (`"-0.50"`); `Unscaled() *big.Int`, `UnscaledInt64() (int64, bool)`, `Scale()`, `Sign()`, `Cmp()`, `Rat() *big.Rat`, `Float64()`. Build with `NewDecimal(unscaled, scale)`, `DecimalFromBig`, `ParseDecimal("12.50")`. `CreateTable` rescales a `Decimal` (or `int64`/`int`) to the column's scale when that is exact. |
| `STRING` | `string` | UTF-8 |
| `DATE` | `polyquery.Date` | `int64` days since 1970-01-01 (proleptic Gregorian). `String()` → `YYYY-MM-DD`, `YMD()`, `Time()` (midnight UTC); `DateOf(y, m, d)`, `ParseDate`. `CreateTable` also accepts `time.Time`. |
| `TIMESTAMP` | `polyquery.Timestamp` | `int64` microseconds since 1970-01-01 00:00:00 (no time zone). `String()` → `YYYY-MM-DD HH:MM:SS[.ffffff]`, `Time()` (UTC); `TimestampOf(time.Time)`, `ParseTimestamp`. |

A result column whose expression is the bare `NULL` literal is reported as
`STRING` (as in the protocol) and contains only `nil`.

Type switch over a value:

```go
switch v := value.(type) {
case nil:                 // NULL
case int64:               // INT64
case polyquery.Decimal:   // DECIMAL
case string:              // STRING
case polyquery.Date:      // DATE
case polyquery.Timestamp: // TIMESTAMP
case float64:             // FLOAT64
case bool:                // BOOLEAN
}
```

## 6. Errors

Every failing operation returns a `*polyquery.Error`:

```go
type Error struct {
	Code    Code           // e.g. polyquery.CodeParseError == "PARSE_ERROR"
	Message string
	Details map[string]any // e.g. "line"/"column" of a PARSE_ERROR
}
```

`err.Error()` is `"CODE: message"`. Inspect it with `errors.As(err, &pe)`
or `polyquery.ErrorCode(err)` (returns `""` for nil or foreign errors).
The constants `CodeParseError`, `CodeSemanticError`, `CodeTypeError`,
`CodeNumericOverflow`, `CodeDivisionByZero`, `CodeConversionError`,
`CodeInvalidArgument`, `CodeSubqueryCardinality`, `CodeInvalidRequest`,
`CodeIngestError`, `CodeUnsupported`, `CodeAccessDenied`, `CodeNotFound`,
`CodeAlreadyExists`, `CodeCancelled`, `CodeResourceLimit`, `CodeIOError`,
`CodeStorageCorrupt`, `CodeStorageVersion`, `CodeInternalError`,
`CodeTimeout` are the codes of spec/errors/error-codes.json.

An error never leaves the instance in a broken state: a failed load,
create, open or query changes nothing in the catalog, and an unexpected
internal failure (a panic inside the engine) is reported as
`INTERNAL_ERROR` instead of crashing the program.

## 7. Resource management

* Call `Close` when done (`defer db.Close()`); it drops all tables. Memory
  is then reclaimed by the garbage collector, and memory-mapped PQCF files
  (`OpenOptions.Mmap`) are unmapped once no table or result refers to them.
* `Result` values are ordinary Go values, independent of the instance —
  they stay valid after `Close`.
* A `Rows` cursor holds the query's resources until it is exhausted or
  closed: `defer rows.Close()`.
* Per-query memory is bounded by `Config.MaxQueryMemoryMB`
  (`RESOURCE_LIMIT` when exceeded); `QueryOptions.Timeout` and the
  context bound the running time.
* Tables live in memory; `SaveTable` persists one, `OpenTable` brings it
  back (with `Mmap`, lazily).

## 8. Thread safety

A `*DB` is **safe for concurrent use by multiple goroutines**: every
statement reads an immutable snapshot of the catalog taken when it starts,
and loads, creates, drops and opens publish a new catalog atomically
(copy-on-write), so a concurrent query sees a table either entirely before
or entirely after a change. This is the same engine object the HTTP
server (`polyquery serve`) shares between its workers. Each query may also
use several worker threads itself (`Threads`).

A `*Rows` cursor must be used by one goroutine at a time. Several `DB`
instances may exist in one process; they share nothing (except loaded
native kernels, which are read-only).
