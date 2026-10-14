# Embedding PolyQuery in a Python program

The PolyQuery engine is an importable Python package, `polyquery`. A program
creates an engine instance (`polyquery.Database`) and uses it **in-process**:
no server, no subprocess, no network connection. This guide is for developers;
it implements `spec/apps/embedding.md`.

* [1. Requirements and building](#1-requirements-and-building)
* [2. Depending on the library from a separate project](#2-depending-on-the-library-from-a-separate-project)
* [3. A complete minimal program](#3-a-complete-minimal-program)
* [4. API reference](#4-api-reference)
* [5. Value-type mapping](#5-value-type-mapping)
* [6. Errors](#6-errors)
* [7. Resource management](#7-resource-management)
* [8. Thread safety and processes](#8-thread-safety-and-processes)
* [9. Larger examples](#9-larger-examples)

## 1. Requirements and building

* CPython **3.14** (`python3`). The library uses only the standard library;
  there is nothing to install and no third-party dependency.
* The package is the directory `implementations/python/polyquery/`.

```sh
cd implementations/python
make build     # byte-compiles polyquery/ (and the app and example), smoke-tests the launchers
make test      # unit tests, including tests/test_api.py for this API
```

`make build` is optional for a library user (Python compiles modules on
first import), but it pre-compiles the bytecode so that the first start is
fast and a read-only installation never needs to write `__pycache__`.

## 2. Depending on the library from a separate project

The library is used the standard Python way: its parent directory (the
directory that *contains* `polyquery/`) goes on the module search path.
Nothing is copied into your project. Pick one of these, in order of
preference:

**a) A virtual environment with a path entry (recommended).** `venv` is part
of the standard library and works offline:

```sh
cd my-project
python3 -m venv --without-pip .venv
# add the directory that contains polyquery/ as a path entry of the venv:
.venv/bin/python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])'
#   -> e.g. /home/me/my-project/.venv/lib/python3.14/site-packages
echo /path/to/implementations/python > .venv/lib/python3.14/site-packages/polyquery.pth
.venv/bin/python app.py
```

A `.pth` file in `site-packages` lists directories that the interpreter adds
to `sys.path` at startup (module `site`). Updating the engine (a `git pull`
plus `make build`) needs no reinstall.

**b) `PYTHONPATH`**, e.g. in a launcher script (this is what
`bin/pq-embed-demo` does):

```sh
PYTHONPATH=/path/to/implementations/python python3 app.py
```

**c) A `sys.path` entry set by the program itself** before the import
(what `app/entry.py`, the entry point of pqledger, does; useful together
with `python3 -I`, which ignores `PYTHONPATH`):

```python
import sys
sys.path.insert(0, "/path/to/implementations/python")
import polyquery
```

Check the setup with
`python3 -c 'import polyquery; print(polyquery.ENGINE_NAME, polyquery.ENGINE_VERSION)'`.

## 3. A complete minimal program

```python
"""Total amount per name from a CSV file."""

import sys

import polyquery


def main(data_dir: str) -> int:
    try:
        with polyquery.Database(data_dir) as db:           # create (and close) an instance
            db.load("sales", path="sales.csv")              # data_dir/sales.csv, header row
            result = db.query(
                "SELECT name, SUM(amount) AS total FROM sales GROUP BY name ORDER BY name",
                timeout_ms=5000,
            )
    except polyquery.Error as e:
        print(f"error: {e.code}: {e.message}", file=sys.stderr)
        return 1
    print(result.columns, result.types)                     # ('name', 'total') ('STRING', 'FLOAT64')
    for name, total in result:                              # rows are tuples of native values
        print(f"{name}: {total:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
```

With `sales.csv` containing `name,amount\nann,10.5\nbob,2\nann,1\n` it prints

```
('name', 'total') ('STRING', 'FLOAT64')
ann: 11.50
bob: 2.00
```

(CSV schema inference never yields DECIMAL; pass `schema=[("name", "STRING"),
("amount", "DECIMAL(10,2)")]` to `load` for exact decimals.)

## 4. API reference

Everything below is importable from the top-level package
(`polyquery.Database`, …); it is defined in `polyquery/api.py`. Names not
listed here (the rest of the package) are internal and may change.

### `polyquery.Database(data_dir=".", *, max_query_memory_mb=4096, threads=None, max_ingest_bytes=4 GiB, max_table_rows=200_000_000, max_join_rows=100_000_000, worker_processes=False, native_kernels=None)`

Creates one engine instance with an empty catalog.

| parameter | meaning (CLI equivalent) |
|---|---|
| `data_dir` | directory (str or path-like) against which the relative paths of `load`, `save` and `open` are resolved (`--data-dir`). It must exist, else `Error` `NOT_FOUND`. Paths must be relative and must not contain `..` components, else `ACCESS_DENIED` (protocol.md §6). |
| `max_query_memory_mb` | per-query memory budget; exceeding it fails the query with `RESOURCE_LIMIT` (`--max-query-memory-mb`) |
| `threads` | default parallelism of queries that do not pass `threads` (`--threads`); `None`: automatic (one partition per CPU, at most 16, for large vectorized pipelines) |
| `max_ingest_bytes`, `max_table_rows`, `max_join_rows` | as `--max-ingest-bytes`, `--max-table-rows`, `--max-join-rows` |
| `worker_processes` | `False` (default): parallel pipelines run their partitions one after the other **in the calling thread**; the instance never starts a process. `True`: like `bin/polyquery`, large parallel pipelines run in forked worker processes (POSIX `fork`; faster for big analytical queries on many cores) |
| `native_kernels` | path of the optional native kernel library `libpqkernels.so` (`--native-kernels`) |

Invalid arguments raise `Error` with code `INVALID_ARGUMENT`.

Properties: `data_dir` (absolute path), `closed` (bool).

### Loading

**`load(table, *, path=None, text=None, schema=None, header=True, delimiter=",", replace=False) -> TableInfo`**
— the protocol's `load` of CSV (spec/data-types/ingestion.md §1). Exactly one
of `path` (a file relative to `data_dir`) or `text` (CSV as a `str`) is
required. `schema` is a sequence of `(name, type)` pairs (or `ColumnInfo`),
types written as in types.md (`"INT64"`, `"DECIMAL(18,2)"`, aliases allowed);
without it the column types are inferred. `header=False` requires a schema.
`delimiter` is one ASCII character. Loading an existing table name fails with
`ALREADY_EXISTS` unless `replace=True`, which replaces it atomically.
Errors: `INGEST_ERROR`, `CONVERSION_ERROR`, `NOT_FOUND` (file),
`ACCESS_DENIED` (path), `RESOURCE_LIMIT` (size limits), `INVALID_ARGUMENT`.

**`create_table(table, schema, rows, *, replace=False) -> TableInfo`** — a
table from native values: `rows` is an iterable of sequences with one value
per column of `schema`, each of the column type's Python type (§5) or `None`.
DECIMAL values (`Decimal` or `int`) must be exact at the column's scale
(`Decimal("1.5")` is fine for `DECIMAL(18,2)`, `Decimal("1.005")` is not).
Errors: `CONVERSION_ERROR` (a value does not fit; the message names row and
column), `INVALID_ARGUMENT` (row length, schema), `ALREADY_EXISTS`.

**`create_table_as(table, sql, *, replace=False, threads=None, timeout_ms=None) -> TableInfo`**
— runs a query and stores its result as a table (the query may read the
table it replaces: the statement completes before the catalog changes).
Errors: those of `query`, plus `INGEST_ERROR` for duplicate result column
names.

### Queries

**`query(sql, *, threads=None, timeout_ms=None, max_rows=None, mode="auto", join="auto", optimize=True, use_indexes=True) -> Result`**
— executes one SQL statement (spec/sql) and returns its complete result.

| option | meaning |
|---|---|
| `threads` | parallelism of this query (≥ 1); default: the instance's `threads` |
| `timeout_ms` | the statement fails with `TIMEOUT` when it runs longer (parsing, planning and execution count); `None`/`0`: no timeout |
| `max_rows` | the statement fails with `RESOURCE_LIMIT` if its result has more rows |
| `mode` | `auto`, `row` or `vectorized` (execution engine) |
| `join` | `auto`, `hash`, `merge`, `nested_loop` |
| `optimize`, `use_indexes` | the logical optimizer / index access paths |

Errors: every SQL error code of spec/errors (`PARSE_ERROR`, `SEMANTIC_ERROR`,
`TYPE_ERROR`, `DIVISION_BY_ZERO`, `NUMERIC_OVERFLOW`, `CONVERSION_ERROR`,
`INVALID_ARGUMENT`, `SUBQUERY_CARDINALITY`, `RESOURCE_LIMIT`, `TIMEOUT`, …).
`CREATE INDEX` / `DROP INDEX` / `EXPLAIN` statements are accepted too.

### `polyquery.Result`

| member | meaning |
|---|---|
| `columns` | tuple of the column names |
| `types` | tuple of the canonical type names (`"INT64"`, `"DECIMAL(18,2)"`, `"STRING"`, …) |
| `schema` | tuple of `ColumnInfo(name, type)` |
| `rows` | list of row tuples of native values (§5) |
| `row_count`, `len(result)` | number of rows |
| `iter(result)`, `result[i]` | the rows |
| `column(name)` | list of the values of one column (`KeyError` if absent) |
| `scalar()` | the only value of a 1×1 result (`ValueError` otherwise) |
| `to_dicts()` | rows as `{column: value}` dicts |

A `Result` is a plain value: it stays valid after the database is closed.

### Storage

**`save(table, path) -> int`** — writes the table (with its index
definitions) to the PQCF file `path` (relative to `data_dir`, spec/storage),
atomically (temporary file, fsync, rename); returns the file size in bytes.
Errors: `NOT_FOUND` (table), `ACCESS_DENIED`, `IO_ERROR`.

**`open(table, path, *, replace=False, mmap=False) -> TableInfo`** — opens a
PQCF file as a table and recreates its indexes; `mmap=True` maps the file and
decodes columns lazily. Errors: `NOT_FOUND`, `ALREADY_EXISTS`,
`STORAGE_CORRUPT`, `STORAGE_VERSION_UNSUPPORTED`, `ACCESS_DENIED`, `IO_ERROR`.

### Catalog

| operation | result / errors |
|---|---|
| `drop(table)` | removes the table and its indexes; `NOT_FOUND` |
| `tables()` | list of `TableInfo`, ordered by name |
| `schema(table)` | `TableInfo`; `NOT_FOUND` |
| `exists(table)` | bool |

Table and column names are matched ASCII case-insensitively and reported
with their original spelling (ingestion.md).

### `polyquery.TableInfo`, `polyquery.ColumnInfo`

Frozen dataclasses: `TableInfo(name: str, row_count: int, columns:
tuple[ColumnInfo, ...])`, `ColumnInfo(name: str, type: str)`.

### Lifecycle

`close()` releases the instance; `with polyquery.Database(...) as db:` calls
it on exit. See §7.

### Other names

* `polyquery.Error` — the exception class (§6).
* `polyquery.VALUE_TYPES` — `{"INT64": int, "DECIMAL": Decimal, …}`, the
  mapping of §5 as data.
* `polyquery.configure_interpreter()` — optional: raises the interpreter's
  recursion limit (and the stack size of threads created afterwards) as
  `bin/polyquery` does, so that statements nested up to the engine's
  statement limits (nesting depth 4,096, 200,000 operands) can be processed.
  Without it, very deeply nested statements fail cleanly with
  `RESOURCE_LIMIT` earlier. It changes process-wide settings, so it is left
  to the program to call it.
* `polyquery.ENGINE_NAME`, `ENGINE_VERSION`, `SPEC_VERSION`.

## 5. Value-type mapping

| SQL type | Python value | notes |
|---|---|---|
| `BOOLEAN` | `bool` | |
| `INT64` | `int` | always within −2⁶³ … 2⁶³−1 |
| `FLOAT64` | `float` | always finite; `-0.0` may occur |
| `DECIMAL(p,s)` | `decimal.Decimal` | exact, with exponent `-s`: `DECIMAL(18,2)` 12.5 is `Decimal("12.50")`, so `str()` gives the canonical text; up to 38 digits |
| `STRING` | `str` | |
| `DATE` | `datetime.date` | years 0001–9999 |
| `TIMESTAMP` | `datetime.datetime` | naive, meaning UTC, microsecond precision |
| NULL (any type) | `None` | distinct from every value (also from `""`, `0`, `False`) |

`create_table` accepts the same types (plus `int` for `DECIMAL`/`FLOAT64`,
a `datetime.date` for `TIMESTAMP`, and an aware `datetime`, which is
converted to UTC). Column types are reported as the canonical names of
spec/data-types/types.md (`Result.types`, `ColumnInfo.type`).

Note on `Decimal` arithmetic in your own code: Python's default decimal
context has 28 significant digits; use `decimal.localcontext()` with a higher
precision for arithmetic on `DECIMAL(38,s)` values.

## 6. Errors

Every operation raises **`polyquery.Error`** (a subclass of `Exception`) on
failure, with

* `code` — the specification's error code (`spec/errors/error-codes.json`):
  `PARSE_ERROR`, `SEMANTIC_ERROR`, `TYPE_ERROR`, `NUMERIC_OVERFLOW`,
  `DIVISION_BY_ZERO`, `CONVERSION_ERROR`, `INVALID_ARGUMENT`,
  `SUBQUERY_CARDINALITY`, `INGEST_ERROR`, `UNSUPPORTED`, `ACCESS_DENIED`,
  `NOT_FOUND`, `ALREADY_EXISTS`, `RESOURCE_LIMIT`, `TIMEOUT`, `IO_ERROR`,
  `STORAGE_CORRUPT`, `STORAGE_VERSION_UNSUPPORTED`, `INVALID_REQUEST` (use of a
  closed instance), `INTERNAL_ERROR` (an engine bug);
* `message` — a human-readable message (also `str(error)`);
* `details` — a dict with structured details (e.g. `line`, `column`,
  `table`, `measure`) or `None`.

```python
try:
    db.query("SELECT nope FROM t")
except polyquery.Error as e:
    if e.code == "SEMANTIC_ERROR":
        ...
```

An error never leaves the instance in a broken state: a failed `load`,
`create_table*` or `open` changes nothing, and the instance stays usable.
Out-of-memory and too-deep recursion inside the engine are reported as
`RESOURCE_LIMIT`; no other exception type escapes an operation (misuse
such as a non-string table name is reported as `Error` `INVALID_ARGUMENT`).

## 7. Resource management

* An instance holds its tables in memory (and memory maps for
  `open(..., mmap=True)`). **`close()`** drops all tables and, if
  `worker_processes=True` was used, stops the worker processes. It is
  idempotent; afterwards every operation raises `Error` `INVALID_REQUEST`.
* Prefer the context manager: `with polyquery.Database(dir) as db: ...`.
* An unreferenced, unclosed instance is cleaned up by the garbage collector,
  but relying on that is not recommended.
* Tables are immutable; `load(..., replace=True)`, `create_table*(...,
  replace=True)` and `open(..., replace=True)` swap them atomically. Results
  are independent copies.
* `save` writes atomically, so a crash never leaves a half-written file.

## 8. Thread safety and processes

* **One instance may be used from several threads at once.** The catalog is
  internally synchronized, every statement plans against a consistent
  snapshot of it, and catalog changes are atomic. Concurrent queries
  interleave (CPython's GIL); they do not run in parallel on several cores.
  Do not call `close()` while other threads still use the instance.
* **Several instances may exist in one process**; they share nothing (each
  has its own catalog).
* By default an instance never starts a process, never opens a network
  connection and runs everything in the calling thread. With
  `worker_processes=True`, large parallel pipelines fork worker processes
  (the CLI's behaviour; POSIX only) — do not combine that with your own use
  of `fork` while a query runs.
* The engine pauses CPython's cyclic garbage collector while an operation
  runs (it allocates many short-lived objects); it is re-enabled afterwards.

## 9. Larger examples

* [`examples/embed-demo/embed_demo.py`](examples/embed-demo/embed_demo.py) —
  the minimal example of embedding.md §5: `bin/pq-embed-demo DATA_DIR
  CSV_FILE SQL` loads a CSV file and prints a query result as CSV. It uses
  only the public API and runs as a separate program (its launcher sets
  `PYTHONPATH`).
* [`app/`](app/) — **pqledger**, a complete application on this API: PQCF
  files as storage (`open`/`save`), tables from native values
  (`create_table`), derived tables (`create_table_as`), reports as SQL with
  typed results. Start with `app/pqledger/ledger.py`; the user guide is
  [APP.md](APP.md).
