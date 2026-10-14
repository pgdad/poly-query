# Embedding PolyQuery in a Rust program

The PolyQuery engine is a library crate, `polyquery`. Its embedding API, the
module **`polyquery::api`**, lets any Rust program create engine instances,
load CSV, run SQL and get typed results, and read and write PQCF files — in
the program's own process, without starting `bin/polyquery` and without any
network connection. It implements
[`spec/apps/embedding.md`](../../spec/apps/embedding.md).

* [Building and depending on the library](#building-and-depending-on-the-library)
* [A complete minimal program](#a-complete-minimal-program)
* [API reference](#api-reference)
* [Value-type mapping](#value-type-mapping)
* [Errors](#errors)
* [Resource management](#resource-management)
* [Thread safety](#thread-safety)
* [Larger examples](#larger-examples)

## Building and depending on the library

Requirements: Rust 1.96 or newer (edition 2024) and Cargo. The crate has no
dependencies besides the standard library, so it builds offline.

`make build` in `implementations/rust` builds the library together with the
engine binary, `pqledger` and the example (`cargo build --release
--workspace`); `make test` runs all unit tests. A separate project does not
need that step — Cargo compiles the library as part of the project's build.

Step by step, for a new project:

1. Create the project:

   ```bash
   cargo new hello-polyquery
   cd hello-polyquery
   ```

2. Add the library as a **path dependency** in `Cargo.toml`, pointing at the
   directory that contains the engine's `Cargo.toml` (absolute, or relative to
   your project):

   ```toml
   [package]
   name = "hello-polyquery"
   version = "0.1.0"
   edition = "2024"

   [dependencies]
   polyquery = { path = "/path/to/implementations/rust" }
   ```

3. Use the API in `src/main.rs` (see the [minimal program](#a-complete-minimal-program)):

   ```rust
   use polyquery::api::{Config, Database};
   ```

4. Build and run, offline if you like:

   ```bash
   mkdir -p data
   cargo run --release --offline
   ```

Building in release mode is recommended: the engine is much faster with
optimizations. Nothing else is required — no environment variables, no
runtime files. (The `polyquery` binary installs a custom global allocator,
`polyquery::alloc::ArenaLocalAlloc`, that helps heavily parallel workloads; a
program may register it with `#[global_allocator]` too, but does not need to.)

## A complete minimal program

```rust
use polyquery::api::{
    Column, ColumnType, Config, Database, LoadOptions, OpenOptions, QueryOptions, Value,
};

fn main() -> Result<(), polyquery::api::Error> {
    // 1. Create an instance. File paths are resolved inside "data".
    let db = Database::create(Config::new("data").threads(2).max_query_memory_mb(512))?;

    // 2. Load CSV (here from memory) with an explicit schema.
    let csv = "region,amount\nnorth,10.50\nsouth,3.25\nnorth,4.00\n";
    let options = LoadOptions {
        schema: Some(vec![
            Column::new("region", ColumnType::String),
            Column::new("amount", ColumnType::Decimal { precision: 18, scale: 2 }),
        ]),
        ..LoadOptions::default()
    };
    db.load_csv_text("sales", csv, &options)?;

    // 3. Query. The result has typed columns and native values.
    let result = db.query_with(
        "SELECT region, SUM(amount) AS total, COUNT(*) AS n FROM sales GROUP BY region ORDER BY region",
        &QueryOptions { timeout_ms: Some(5_000), ..QueryOptions::default() },
    )?;
    let names: Vec<String> = result
        .columns()
        .iter()
        .map(|c| format!("{} {}", c.name, c.column_type))
        .collect();
    println!("{}", names.join(", "));
    for row in &result {
        if let [Value::String(region), Value::Decimal(total), Value::Int64(n)] = row.as_slice() {
            println!("{region}: {total} in {n} sales (unscaled {}, scale {})",
                total.unscaled(), total.scale());
        }
    }

    // 4. Errors carry the specification's error code; the instance stays usable.
    if let Err(e) = db.query("SELECT nope FROM sales") {
        println!("error: {} ({})", e.code_str(), e.message());
    }

    // 5. Save as PQCF, open the file as another table, list the tables.
    db.save("sales", "sales.pqcf")?;
    db.open("archive", "sales.pqcf", &OpenOptions::default())?;
    for table in db.tables() {
        println!("{}: {} rows, {} columns", table.name, table.row_count, table.columns.len());
    }
    db.drop_table("archive")?;

    // 6. Release the instance (dropping it does the same).
    db.close();
    Ok(())
}
```

Output:

```
region STRING, total DECIMAL(18,2), n INT64
north: 14.50 in 2 sales (unscaled 1450, scale 2)
south: 3.25 in 1 sales (unscaled 325, scale 2)
error: SEMANTIC_ERROR (unknown column 'nope')
archive: 3 rows, 2 columns
sales: 3 rows, 2 columns
```

## API reference

Everything is in `polyquery::api`. The crate's other modules (`engine`,
`planner`, `exec`, …) are the engine's internals, public for the engine's own
binaries and tests; programs should use only `polyquery::api`.

All fallible operations return `polyquery::api::Result<T>` =
`Result<T, polyquery::api::Error>`. The error codes each operation can return
are listed with it; any operation may also return `INTERNAL_ERROR` (an engine
bug, contained).

### `Config` — instance configuration

A builder; every method takes and returns `Config`. The settings correspond
to the options of `bin/polyquery` (`spec/protocol/protocol.md` §2).

| method | meaning | default |
|---|---|---|
| `Config::new(data_dir)` | the data directory (`--data-dir`): root of all file paths | — |
| `.max_query_memory_mb(u64)` | per-query memory limit in MiB (`--max-query-memory-mb`) | 4096 |
| `.threads(usize)` | default worker threads per query (`--threads`) | CPUs, at most 16 |
| `.max_ingest_bytes(u64)` | largest load input (`--max-ingest-bytes`) | 4 GiB |
| `.max_table_rows(u64)` | largest table (`--max-table-rows`) | 500,000,000 |
| `.max_join_rows(u64)` | largest join result (`--max-join-rows`) | 100,000,000 |
| `.query_timeout_ms(u64)` | default query timeout, 0 = none (`--query-timeout-ms`) | 0 |
| `.enable_test_functions(bool)` | enables the test-only `PQ_SLEEP` (`--enable-test-functions`) | false |
| `.data_dir()` | the configured data directory | |

**Path safety** (protocol.md §6): every path given to `load_csv_file`,
`save` and `open` must be relative, must not contain `..` components and is
resolved inside the data directory; anything else fails with
`ACCESS_DENIED`.

### `Database` — an engine instance

| operation | result | errors |
|---|---|---|
| `Database::create(config: Config)` | a new instance with an empty catalog | `NOT_FOUND` (data directory missing), `INVALID_REQUEST` (threads or memory 0) |
| `db.load_csv_file(table: &str, path: &str, options: &LoadOptions)` | `TableInfo` of the new table | `ALREADY_EXISTS`, `ACCESS_DENIED`, `IO_ERROR`, `INGEST_ERROR`, `CONVERSION_ERROR`, `RESOURCE_LIMIT`, `INVALID_REQUEST` |
| `db.load_csv_text(table: &str, csv: &str, options: &LoadOptions)` | as above, from in-memory text | as above (no path errors) |
| `db.create_table(table: &str, columns: &[Column], rows: Vec<Vec<Value>>, replace: bool)` | a table from native values | `ALREADY_EXISTS`, `TYPE_ERROR` (value of another type), `CONVERSION_ERROR` (decimal scale), `NUMERIC_OVERFLOW`, `INGEST_ERROR` (column names), `INVALID_REQUEST` (row width) |
| `db.create_table_from_query(table: &str, sql: &str, replace: bool)` | stores a query's result as a table (`CREATE TABLE … AS`) | those of `query`, `ALREADY_EXISTS` |
| `db.query(sql: &str)` | `QueryResult` | `PARSE_ERROR`, `SEMANTIC_ERROR`, `TYPE_ERROR`, runtime errors (`DIVISION_BY_ZERO`, `NUMERIC_OVERFLOW`, `CONVERSION_ERROR`, `INVALID_ARGUMENT`, `SUBQUERY_CARDINALITY`), `TIMEOUT`, `RESOURCE_LIMIT`, `UNSUPPORTED` |
| `db.query_with(sql: &str, options: &QueryOptions)` | as `query`, with per-query options | as above, `INVALID_REQUEST` (threads 0) |
| `db.save(table: &str, path: &str)` | writes the table as a PQCF file (atomically: temporary file + rename); returns the file size in bytes | `NOT_FOUND`, `ACCESS_DENIED`, `IO_ERROR` |
| `db.open(table: &str, path: &str, options: &OpenOptions)` | opens a PQCF file as a table, recreating the indexes recorded in it; `TableInfo` | `ALREADY_EXISTS`, `ACCESS_DENIED`, `IO_ERROR`, `STORAGE_CORRUPT`, `STORAGE_VERSION_UNSUPPORTED` |
| `db.drop_table(table: &str)` | removes a table | `NOT_FOUND` |
| `db.tables()` | `Vec<TableInfo>`, ordered by name (case-insensitively) | — |
| `db.table(table: &str)` | `TableInfo` of one table | `NOT_FOUND` |
| `db.schema(table: &str)` | `Vec<Column>` of one table | `NOT_FOUND` |
| `db.data_dir()` | `&Path` | — |
| `db.close()` | releases the instance (consumes it) | — |

`query` executes one statement: a query (`SELECT`, `WITH`, `UNION ALL`),
`EXPLAIN`, `CREATE INDEX` or `DROP INDEX` (`spec/sql/`). Table and column
names are case-insensitive. Statements run on a snapshot of the catalog;
`load`, `create_table*`, `open` and `drop_table` replace the catalog
atomically. A failed operation changes nothing.

### Option and info types

```rust
pub struct LoadOptions {
    pub header: bool,                 // default true; false requires `schema`
    pub delimiter: char,              // default ','; one ASCII char, not '"', CR, LF
    pub schema: Option<Vec<Column>>,  // default None: infer the types
    pub replace: bool,                // default false
}

pub struct OpenOptions {
    pub replace: bool,                // default false
    pub mmap: bool,                   // default false: read the file whole;
                                      // true: memory-map it, decode chunks on use
}

pub struct QueryOptions {             // None = instance default
    pub threads: Option<usize>,       // worker threads (≥ 1)
    pub timeout_ms: Option<u64>,      // → TIMEOUT
    pub max_rows: Option<u64>,        // more result rows → RESOURCE_LIMIT
}

pub struct TableInfo {
    pub name: String,
    pub columns: Vec<Column>,
    pub row_count: u64,
}

pub struct Column {
    pub name: String,
    pub column_type: ColumnType,
}
```

All option types implement `Default`; write
`LoadOptions { replace: true, ..LoadOptions::default() }`.

CSV loading follows `spec/data-types/ingestion.md` §1: RFC 4180, a header
record by default, type inference when no schema is given (inference never
produces DECIMAL — give a schema for exact amounts), unquoted empty fields are
NULL.

### `QueryResult`

| method | result |
|---|---|
| `columns()` | `&[Column]`: names and types in select-list order |
| `column_names()` | iterator of `&str` |
| `column_types()` | iterator of `ColumnType` |
| `column_index(name)` | `Option<usize>` (ASCII case-insensitive) |
| `row_count()`, `is_empty()` | number of rows |
| `rows()` | `&[Vec<Value>]`, one value per column |
| `row(i)` | `Option<&[Value]>` |
| `value(row, column)` | `Option<&Value>` |
| `into_rows()`, `into_parts()` | the rows, or `(columns, rows)`, by value |
| `&result` in a `for` loop | iterates the rows |

### `ColumnType`

```rust
pub enum ColumnType {
    Boolean, Int64, Float64,
    Decimal { precision: u8, scale: u8 },
    String, Date, Timestamp,
}
```

`name()` (and `Display`) give the canonical type name of
`spec/data-types/types.md` (`INT64`, `DECIMAL(18,2)`, `STRING`, …);
`ColumnType::parse("NUMERIC(10,2)")` accepts the aliases; `is_numeric()`.

## Value-type mapping

Result values are native Rust values, never JSON text:

| SQL type | `Value` variant | Rust representation |
|---|---|---|
| NULL (of any type) | `Value::Null` | distinct from every value |
| `BOOLEAN` | `Value::Boolean(bool)` | `bool` |
| `INT64` | `Value::Int64(i64)` | `i64` |
| `FLOAT64` | `Value::Float64(f64)` | binary64 (`-0.0` is returned as `0.0`) |
| `DECIMAL(p,s)` | `Value::Decimal(Decimal)` | exact: `unscaled() -> i128` and `scale() -> u8` (value = unscaled × 10^−scale); the scale is always the column's `s` |
| `STRING` | `Value::String(String)` | UTF-8 `String` |
| `DATE` | `Value::Date(Date)` | `days_since_epoch() -> i32` (days since 1970-01-01, negative before); `ymd()`, `Date::from_ymd(y, m, d)` |
| `TIMESTAMP` | `Value::Timestamp(Timestamp)` | `micros_since_epoch() -> i64` (microseconds since 1970-01-01 00:00:00, no time zone); `date()` |

Helpers: `Value::is_null`, `as_bool`, `as_i64`, `as_f64`, `as_decimal`,
`as_str`, `as_date`, `as_timestamp` (each `Option`, `None` for NULL or another
type), and `From` conversions from `bool`, `i64`, `f64`, `Decimal`, `String`,
`&str`, `Date`, `Timestamp` and `Option<T>` (None → NULL) for building rows for
`create_table`.

Text forms (`Display`): `Decimal` `-12.50` (exactly `scale` decimals),
`Date` `2026-01-31`, `Timestamp` `2026-01-31 08:15:00` (with `.ffffff` when
the microseconds are not 0), `Value` the canonical text of its value
(FLOAT64 as shortest round-trip text such as `0.1` or `3.0`; NULL as the empty
string). `Decimal`, `Date` and `Timestamp` implement `FromStr` for the same
forms (`"12.50".parse::<Decimal>()`); `Decimal::new(unscaled, scale)`,
`rescale(scale)` and `to_f64()` are available.

## Errors

`polyquery::api::Error` is the error type of every operation. It implements
`std::error::Error` and `Display` (`CODE: message`).

| method | result |
|---|---|
| `code()` | `ErrorCode`, an enum of the codes of `spec/errors/errors.md` (`ErrorCode::ParseError`, `ErrorCode::NotFound`, …) |
| `code_str()` | the code as specified, e.g. `"PARSE_ERROR"` (`ErrorCode::as_str()` too) |
| `message()` | the human-readable message |

```rust
use polyquery::api::ErrorCode;

match db.query(sql) {
    Ok(result) => { /* … */ }
    Err(e) if e.code() == ErrorCode::ParseError => eprintln!("syntax: {}", e.message()),
    Err(e) => eprintln!("error: {e}"),          // "SEMANTIC_ERROR: unknown column 'x'"
}
```

An error never leaves the instance in a broken state: the catalog is unchanged
and the next operation works normally. A panic inside the engine is caught and
reported as `INTERNAL_ERROR` (the panic message still goes through the
process's panic hook, by default to stderr).

## Resource management

* A `Database` owns its tables (in memory, or memory-mapped PQCF files when
  opened with `mmap: true`). `close()` — or simply dropping the value, e.g.
  at the end of its scope — releases them. Queries that are still running in
  other threads keep the table versions they use alive until they finish.
* Results are plain owned values (`QueryResult`, `Vec<Vec<Value>>`); they do
  not borrow from the instance and stay valid after it is closed.
* Each operation runs on a short-lived helper thread with a large, guarded
  stack (the calling thread blocks until it finishes), so deeply nested SQL
  fails with `RESOURCE_LIMIT` instead of overflowing the caller's stack;
  queries may additionally use the instance's worker threads (`threads`).
  Memory used by a query is limited by `max_query_memory_mb`
  (`RESOURCE_LIMIT` when exceeded).
* Files written by `save` are complete when it returns (written to a
  temporary file, synced and renamed). A memory-mapped file must not be
  modified in place while it is open; replacing it by renaming (as `save`
  does) is safe.

## Thread safety

`Database` is `Send + Sync`. **One instance may be used from several threads
at once**, e.g. shared through an `Arc<Database>`:

```rust
use std::sync::Arc;
use std::thread;

let db = Arc::new(db);
let handles: Vec<_> = (0..4)
    .map(|i| {
        let db = Arc::clone(&db);
        thread::spawn(move || db.query(&format!("SELECT COUNT(*) AS n FROM sales WHERE amount > {i}")))
    })
    .collect();
for h in handles {
    println!("{:?}", h.join().unwrap()?.value(0, 0));
}
```

Concurrent queries run in parallel, each on a consistent snapshot of the
tables it reads (`spec/concurrency/`). Changes to the catalog (loads, opens,
drops, `create_table*`) are serialized with each other and become visible
atomically; a query started before a change does not see it. Several
instances may exist in one process; they share nothing but the process (and
the engine's worker pool).

## Larger examples

* [`examples/embed-demo`](examples/embed-demo/src/main.rs) — the minimal
  standalone program of embedding.md §5 (`bin/pq-embed-demo DATA_DIR CSV_FILE
  SQL`): create, load a CSV file, query, print CSV, report errors as
  `error: CODE: MESSAGE`. It is a separate Cargo package that depends on the
  library by path exactly as described above.
* [`app/`](app/) — `pqledger`, a complete application on the API
  (see [APP.md](APP.md)): it opens PQCF files with `mmap`, builds tables from
  native values (`create_table`), materializes derived tables with
  `create_table_from_query`, runs all reports as SQL and writes the ledger with
  `save` (`app/src/ledger.rs`, `app/src/commands.rs`).
