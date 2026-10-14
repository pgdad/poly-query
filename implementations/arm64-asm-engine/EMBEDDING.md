# Embedding PolyQuery (AArch64 assembly engine) — developer guide

This guide shows how to use the PolyQuery engine **as a library**, in-process,
from any AArch64 assembly program (or from C). No `bin/polyquery` process and
no network connection is involved: your program links the engine and calls it
directly. The API implements `spec/apps/embedding.md`.

* Library: `lib/libpolyquery.a` (static archive, built by `make build`)
* Header for C callers: `include/polyquery.h` (declarations only)
* Include file for assembly callers: `include/polyquery.inc` (the same
  constants and every structure offset as `#define`s)
* Examples: `examples/embed-demo/demo.S` (minimal program, launcher
  `bin/pq-embed-demo`) and `app/` (the `pqledger` application, a larger
  program built on the same API — see [APP.md](APP.md))

---

## 1. Building the library and depending on it

### 1.1 Build the library

Prerequisites: an AArch64 Linux host with GNU `make`, `gcc` (used only as the
assembler/linker driver) and binutils (`ld`, `objcopy`, `ar`).

```sh
cd implementations/arm64-asm-engine
make build            # engine, lib/libpolyquery.a, pqledger, pq-embed-demo
make lib              # only lib/libpolyquery.a
```

`lib/libpolyquery.a` contains one relocatable object made from every engine
module except the CLI's `main.o`. Only the `pq_*` API symbols are global; all
engine internals are local, so they cannot collide with your own symbols.
The engine needs glibc's `libm` and `libpthread` (dynamically linked).

### 1.2 Use it from a separate project (step by step, with make)

1. Choose where the engine lives, e.g. `POLYQUERY=/opt/polyquery` (the
   `implementations/arm64-asm-engine` directory, or a copy of its `include/`
   and `lib/` directories).
2. Run `make build` (or `make lib`) there once.
3. In your `.S` file: `#include "polyquery.inc"` (use the `.S` suffix — capital
   S — so gcc runs the C preprocessor).
4. Write a Makefile that adds the include directory and links the archive
   plus `-lm -lpthread` (order matters: the archive before the system
   libraries):

```make
POLYQUERY ?= /opt/polyquery
CC        ?= gcc

PQ_CFLAGS := -I$(POLYQUERY)/include
PQ_LIBS   := -L$(POLYQUERY)/lib -lpolyquery -lm -lpthread

myprog: myprog.S $(POLYQUERY)/include/polyquery.inc $(POLYQUERY)/lib/libpolyquery.a
	$(CC) $(PQ_CFLAGS) -g -Wa,--fatal-warnings -o $@ myprog.S $(PQ_LIBS)
```

5. `make` and run. The result is an ordinary PIE executable; nothing from the
   engine directory is needed at run time.

`examples/embed-demo/Makefile` is exactly this recipe; the top-level `make
build` invokes it with `POLYQUERY=$(CURDIR)`.

**From C** the same two lines apply with `#include "polyquery.h"`:
`gcc -I$POLYQUERY/include prog.c -L$POLYQUERY/lib -lpolyquery -lm -lpthread`.
(The repository itself contains no C code; the header exists for C callers.)

---

## 2. Calling convention

* Every function follows the **AAPCS64**: integer/pointer arguments in
  `x0`–`x7` (32-bit `int`/`uint32_t` arguments in `w` registers), result in
  `x0` (`w0` for `int` status codes). `x19`–`x28`, `x29`, `sp` and the low 64
  bits of `v8`–`v15` are preserved; everything else (`x0`–`x18`, `v0`–`v7`,
  `v16`–`v31`, flags) may be clobbered.
* `sp` must be 16-byte aligned at each `bl`. Keep a frame record
  (`stp x29, x30, [sp, #-N]!; mov x29, sp`) like any other glibc call.
* Strings are NUL-terminated UTF-8 (`const char *`). Structures are passed by
  pointer; their layouts are fixed (offsets below and in `polyquery.inc`).
* Status: every `int` function returns `PQ_OK` (0) or a `PQ_E_*` error code.

---

## 3. API reference

### 3.1 Types (byte offsets; `polyquery.inc` names in brackets)

**`pq_db`** — opaque instance handle (`pq_db *`).

**`pq_config`** (56 bytes, `PQCFG_SIZE`) — all-zero means engine defaults.

| off | field | `.inc` | meaning |
|---|---|---|---|
| 0 | `const char *data_dir` | `PQCFG_DATA_DIR` | data directory (as `--data-dir`); NULL ⇒ current directory. Must exist. All load/save/open paths are relative to it and must stay inside it (protocol.md §6 path safety) |
| 8 | `uint64_t max_query_memory_mb` | `PQCFG_QUERY_MEM_MB` | per-query memory limit (`--max-query-memory-mb`); 0 ⇒ 4096 |
| 16 | `uint64_t threads` | `PQCFG_THREADS` | default query thread count (`--threads`); 0 ⇒ min(CPUs, 8) |
| 24 | `uint64_t max_ingest_bytes` | `PQCFG_INGEST_BYTES` | 0 ⇒ 4 GiB |
| 32 | `uint64_t max_table_rows` | `PQCFG_TABLE_ROWS` | 0 ⇒ 200,000,000 |
| 40 | `uint64_t max_join_rows` | `PQCFG_JOIN_ROWS` | 0 ⇒ 100,000,000 |
| 48 | `uint32_t flags` | `PQCFG_FLAGS` | `PQ_CFG_TEST_FUNCTIONS` (= `--enable-test-functions`) |
| 52 | `uint32_t reserved` | | must be 0 |

**`pq_coldef`** (16 bytes, `PQCD_SIZE`) — one explicit schema column:
`+0 const char *name` (`PQCD_NAME`), `+8 const char *type` (`PQCD_TYPE`, type
text such as `"INT64"`, `"BIGINT"`, `"DECIMAL(18,2)"`, `"DATE"`).

**`pq_load_opts`** (32 bytes, `PQLO_SIZE`) — all-zero ⇒ CSV with header,
`,` delimiter, inferred schema, no replace.

| off | field | `.inc` | meaning |
|---|---|---|---|
| 0 | `const pq_coldef *schema` | `PQLO_SCHEMA` | NULL ⇒ schema inference |
| 8 | `uint64_t nschema` | `PQLO_NSCHEMA` | number of `pq_coldef` entries |
| 16 | `uint32_t format` | `PQLO_FORMAT` | `PQ_FORMAT_CSV` (0), `PQ_FORMAT_JSON`, `PQ_FORMAT_JSONL` |
| 20 | `uint32_t delimiter` | `PQLO_DELIMITER` | CSV delimiter byte; 0 ⇒ `,` |
| 24 | `uint32_t flags` | `PQLO_FLAGS` | `PQ_LOAD_NO_HEADER` (CSV has no header; schema required), `PQ_LOAD_REPLACE` (replace an existing table) |
| 28 | `uint32_t reserved` | | must be 0 |

**`pq_query_opts`** (32 bytes, `PQQO_SIZE`) — all-zero ⇒ defaults.

| off | field | `.inc` | meaning |
|---|---|---|---|
| 0 | `uint64_t threads` | `PQQO_THREADS` | 0 ⇒ the instance default |
| 8 | `uint64_t timeout_ms` | `PQQO_TIMEOUT_MS` | 0 ⇒ none; else `TIMEOUT` after that many ms |
| 16 | `uint64_t max_rows` | `PQQO_MAX_ROWS` | 0 ⇒ unlimited; a larger result ⇒ `RESOURCE_LIMIT` |
| 24 | `uint32_t mode` | `PQQO_MODE` | `PQ_MODE_AUTO` (0), `PQ_MODE_ROW`, `PQ_MODE_VECTORIZED` |
| 28 | `uint32_t reserved` | | must be 0 |

**`pq_result`** (32 bytes, `PQR_SIZE`):

| off | field | `.inc` |
|---|---|---|
| 0 | `uint64_t ncols` | `PQR_NCOLS` |
| 8 | `uint64_t nrows` | `PQR_NROWS` |
| 16 | `pq_column *columns` — `ncols` entries | `PQR_COLUMNS` |
| 24 | `pq_value *values` — `nrows × ncols` entries, row-major | `PQR_VALUES` |

The value of row `r`, column `c` is at
`values + (r * ncols + c) * PQV_SIZE` (or call `pq_value_at`).

**`pq_column`** (32 bytes, `PQC_SIZE`): `+0 const char *name` (`PQC_NAME`),
`+8 const char *type_name` (`PQC_TYPE_NAME`, the canonical type name of
types.md, e.g. `"INT64"`, `"DECIMAL(18,2)"`), `+16 uint32_t type` (`PQC_TYPE`,
`PQ_T_*`), `+20 uint32_t precision` and `+24 uint32_t scale` (`PQC_PRECISION`,
`PQC_SCALE`, DECIMAL only).

**`pq_value`** (24 bytes, `PQV_SIZE`): `+0` the value (`PQV_V`: `int64_t`,
`double` or `const char *`), `+8 int64_t aux` (`PQV_AUX`), `+16 uint32_t
is_null` (`PQV_IS_NULL`), `+20 uint32_t type` (`PQV_TYPE`, = the column's
`PQ_T_*`).

### 3.2 Value-type mapping

| SQL type | `PQ_T_*` | representation in `pq_value` |
|---|---|---|
| `BOOLEAN` | `PQ_T_BOOLEAN` (1) | `v` = 0 (false) or 1 (true) |
| `INT64` | `PQ_T_INT64` (2) | `v` = signed 64-bit integer |
| `DECIMAL(p,s)` | `PQ_T_DECIMAL` (3) | exact: unscaled 128-bit two's-complement integer, `v` = low 64 bits, `aux` = high 64 bits (the sign extension of `v` when p ≤ 18); value = unscaled ÷ 10^s, `s` = `pq_column.scale`. Example: `-12.50` in `DECIMAL(18,2)` is `v = -1250, aux = -1` |
| `FLOAT64` | `PQ_T_FLOAT64` (4) | `v` = IEEE binary64 (load with `ldr d0, [x, #PQV_V]`) |
| `STRING` | `PQ_T_STRING` (5) | `v` = pointer to UTF-8 bytes, NUL-terminated; `aux` = byte length |
| `DATE` | `PQ_T_DATE` (6) | `v` = days since 1970-01-01 (negative before) |
| `TIMESTAMP` | `PQ_T_TIMESTAMP` (7) | `v` = microseconds since 1970-01-01 00:00:00 |
| NULL (any type) | the column's type | `is_null` = 1, `v` = `aux` = 0 — always test `is_null` first |

`pq_format_value` converts a value to the text of types.md §9 (without
quotes) when you need text rather than the native value.

### 3.3 Functions

All functions taking a `pq_db *` report failures through the return status
and record the error in the instance (§4).

| function | parameters → result | notes / errors |
|---|---|---|
| `int pq_create(const pq_config *cfg, pq_db **out)` | `cfg` may be NULL (defaults); `*out` = new instance | `NOT_FOUND` (data directory missing), `INVALID_REQUEST` (NULL `out`), `RESOURCE_LIMIT`. On failure `*out` = NULL and the error is read with `pq_errcode(NULL)` / `pq_errname(NULL)` / `pq_errmsg(NULL)` on the same thread |
| `void pq_close(pq_db *db)` | | stops the instance's worker thread and frees its tables and catalog. NULL is ignored. Results already returned stay valid |
| `int pq_load_file(db, const char *table, const char *path, const pq_load_opts *opts)` | `path` relative to the data directory; `opts` may be NULL | as the protocol `load` operation: `INGEST_ERROR`, `ALREADY_EXISTS` (without `PQ_LOAD_REPLACE`), `ACCESS_DENIED` (path outside the data directory), `NOT_FOUND`, `IO_ERROR`, `RESOURCE_LIMIT`, `INVALID_ARGUMENT` |
| `int pq_load_text(db, const char *table, const char *text, size_t len, const pq_load_opts *opts)` | CSV / JSON / JSONL data in memory (`len` bytes, need not be NUL-terminated) | as `pq_load_file` |
| `int pq_query(db, const char *sql, const pq_query_opts *opts, pq_result **out)` | one SQL statement; `opts` may be NULL; `*out` = result | every SQL error code (`PARSE_ERROR`, `SEMANTIC_ERROR`, `TYPE_ERROR`, `DIVISION_BY_ZERO`, …), `TIMEOUT`, `RESOURCE_LIMIT`. `*out` = NULL on failure. `EXPLAIN …` returns its plan as a one-row STRING result |
| `int pq_query_into(db, const char *table, const char *sql, const pq_query_opts *opts, int replace)` | runs `sql` and stores its result as table `table` (non-zero `replace` replaces an existing one) | an extension used by `pqledger` to build helper tables without copying rows through the caller |
| `int pq_save(db, const char *table, const char *path)` | writes the table as a PQCF file (atomically: temporary file + rename) | `NOT_FOUND`, `ACCESS_DENIED`, `IO_ERROR` |
| `int pq_open(db, const char *table, const char *path, int replace)` | registers a PQCF file as table `table` | `NOT_FOUND`, `ALREADY_EXISTS` (replace = 0), `STORAGE_CORRUPT`, `STORAGE_VERSION_UNSUPPORTED` |
| `int pq_drop(db, const char *table)` | | `NOT_FOUND` |
| `int pq_tables(db, pq_result **out)` | result columns `name STRING`, `row_count INT64`, ordered by name | |
| `int pq_schema(db, const char *table, pq_result **out)` | result columns `name STRING`, `type STRING` (canonical type name), one row per column in order | `NOT_FOUND` |
| `void pq_result_free(pq_result *res)` | frees a result; NULL is ignored | |
| `const pq_value *pq_value_at(const pq_result *res, uint64_t row, uint64_t col)` | pointer to a value, or NULL if out of range | |
| `size_t pq_format_value(const pq_column *col, const pq_value *val, uint32_t flags, char *buf, size_t cap)` | writes the value text (types.md §9, no quotes; NULL ⇒ empty) like `snprintf`: at most `cap − 1` bytes plus NUL; returns the full length | `flags` = `PQ_FMT_FLOAT_FIXED6`: FLOAT64 as `printf("%.6f")` with `-0.000000` → `0.000000` (the format of pqledger.md §7); default: shortest round-trip text |
| `int pq_errcode(const pq_db *db)` | code of the instance's most recent failed call (`PQ_OK` after a success) | |
| `const char *pq_errname(const pq_db *db)` | e.g. `"PARSE_ERROR"`; `"OK"` if none | |
| `const char *pq_errmsg(const pq_db *db)` | the message; `""` if none | valid until the next call on `db` |
| `const char *pq_code_name(int code)` | code → name (`0` → `"OK"`) | static string |
| `const char *pq_version(void)` | engine version string | static string |

---

## 4. Errors

Every failing call returns a non-zero `PQ_E_*` code — the specification's
error codes (`spec/errors/error-codes.json`), numbered as in the table at the
top of `polyquery.h` / `polyquery.inc` (`PQ_E_PARSE_ERROR` = 1, …,
`PQ_E_NOT_FOUND` = 12, …). The code's name and the message are available
from the instance until its next call:

```asm
    bl   pq_query                 // w0 = status
    cbz  w0, 1f
    mov  x0, x19                  // x19 = db
    bl   pq_errname               // "SEMANTIC_ERROR"
    ...
    mov  x0, x19
    bl   pq_errmsg                // "unknown table 'nope'"
```

An error never invalidates the instance: tables loaded before stay
available, and the next call works normally (a failed load/open/drop changes
nothing). A NULL `db`, `sql` or `out` argument returns `PQ_E_INVALID_REQUEST`.
Out-of-memory inside the engine is reported as `RESOURCE_LIMIT`.

---

## 5. Resource management (who owns what)

* **Instance**: created by `pq_create`, owned by you, released by exactly one
  `pq_close`. It owns its tables (in memory) and a worker thread.
* **Results**: every `pq_result` from `pq_query`, `pq_tables` or `pq_schema` is
  one `malloc`'ed block owned by you; free it with `pq_result_free` (not
  `free`). All column names, type names and STRING values point into that
  block and stay valid until it is freed — also after `pq_close` of the
  instance that produced it.
* **Inputs**: all strings and structures you pass (`pq_config`, SQL text,
  paths, `pq_load_opts`, schemas, loaded text) are copied or used only during
  the call; you keep ownership and may free or reuse them on return.
* **Error strings** (`pq_errname`, `pq_errmsg`) belong to the instance;
  `pq_code_name` and `pq_version` return static strings. Never free them.
* **Files**: the engine only reads/writes files during `pq_load_file`,
  `pq_save` and `pq_open`; no descriptor stays open between calls.

---

## 6. Thread safety

* Several instances may exist in one process; each has its own data
  directory, limits and tables.
* Every function may be called from **any thread**, also on the same
  instance concurrently. Calls are **serialised process-wide**: an API call
  waits for a process-wide lock, so one call runs at a time (inside it the
  engine may still use several worker threads for one query, per the
  `threads` option). This makes concurrent use safe but not parallel; for
  parallel queries, run the HTTP server (`bin/polyquery serve`) instead.
* Each call runs on the instance's own worker thread (with the 256 MiB stack
  the engine's expression-depth guard expects), so your calling thread's
  stack size does not matter.
* Results are immutable plain memory: they may be read from any thread
  without locking and freed from any thread.
* `pq_errcode/pq_errname/pq_errmsg(NULL)` (the `pq_create` failure) are per
  calling thread.

---

## 7. A complete minimal program

`hello.S` — creates an instance with defaults, runs a query, prints both
values (an INT64 and a STRING), cleans up and reports errors with their code.

```asm
// hello.S — smallest useful PolyQuery embedding: one instance, one query.
//   build: gcc -I$PQ/include -o hello hello.S -L$PQ/lib -lpolyquery -lm -lpthread
#include "polyquery.inc"

    .section .rodata
sql:    .asciz "SELECT 6 * 7 AS answer, 'forty-two' AS name"
fmt_ok: .asciz "%s = %lld, %s = %s\n"
fmt_er: .asciz "error: %s: %s\n"

    .text
    .global main
    .type main, %function
    .p2align 2
main:
    stp  x29, x30, [sp, #-48]!          // frame record + 2 callee-saved pairs
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    str  xzr, [sp, #32]                 // [sp+32] pq_db*, [sp+40] pq_result*
    str  xzr, [sp, #40]

    mov  x0, #0                         // pq_create(NULL = defaults: data dir ".")
    add  x1, sp, #32
    bl   pq_create
    cbnz w0, .Lcreate_err
    ldr  x19, [sp, #32]                 // x19 = db

    mov  x0, x19                        // pq_query(db, sql, NULL options, &res)
    adrp x1, sql
    add  x1, x1, :lo12:sql
    mov  x2, #0
    add  x3, sp, #40
    bl   pq_query
    cbnz w0, .Lquery_err
    ldr  x20, [sp, #40]                 // x20 = result

    ldr  x9, [x20, #PQR_COLUMNS]        // column 0 / 1 names
    ldr  x10, [x20, #PQR_VALUES]        // row 0: values[0], values[1]
    adrp x0, fmt_ok
    add  x0, x0, :lo12:fmt_ok
    ldr  x1, [x9, #PQC_NAME]
    ldr  x2, [x10, #PQV_V]              // INT64 -> i64
    ldr  x3, [x9, #PQC_SIZE + PQC_NAME]
    ldr  x4, [x10, #PQV_SIZE + PQV_V]   // STRING -> const char*
    bl   printf

    mov  x0, x20
    bl   pq_result_free
    mov  x0, x19
    bl   pq_close
    mov  w0, #0
    b    .Lret

.Lquery_err:                            // the instance stays usable after errors
    mov  x0, x19
    bl   pq_errname
    mov  x1, x0
    mov  x0, x19
    str  x1, [sp, #40]
    bl   pq_errmsg
    mov  x2, x0
    ldr  x1, [sp, #40]
    adrp x0, fmt_er
    add  x0, x0, :lo12:fmt_er
    bl   printf
    mov  x0, x19
    bl   pq_close
    mov  w0, #1
    b    .Lret
.Lcreate_err:                           // pq_errname/pq_errmsg(NULL): pq_create failure
    mov  x0, #0
    bl   pq_errname
    str  x0, [sp, #40]
    mov  x0, #0
    bl   pq_errmsg
    mov  x2, x0
    ldr  x1, [sp, #40]
    adrp x0, fmt_er
    add  x0, x0, :lo12:fmt_er
    bl   printf
    mov  w0, #1
.Lret:
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret
    .size main, .-main

    .section .note.GNU-stack,"",%progbits
```

```console
$ PQ=/path/to/implementations/arm64-asm-engine
$ gcc -I$PQ/include -o hello hello.S -L$PQ/lib -lpolyquery -lm -lpthread
$ ./hello
answer = 42, name = forty-two
```

The same program in C, for comparison:

```c
#include <stdio.h>
#include "polyquery.h"

int main(void) {
    pq_db *db;
    pq_result *res;
    if (pq_create(NULL, &db) != PQ_OK) {
        fprintf(stderr, "error: %s: %s\n", pq_errname(NULL), pq_errmsg(NULL));
        return 1;
    }
    if (pq_query(db, "SELECT 6 * 7 AS answer, 'forty-two' AS name", NULL, &res) != PQ_OK) {
        fprintf(stderr, "error: %s: %s\n", pq_errname(db), pq_errmsg(db));
        pq_close(db);
        return 1;
    }
    printf("%s = %lld, %s = %s\n",
           res->columns[0].name, (long long)pq_value_at(res, 0, 0)->v.i64,
           res->columns[1].name, pq_value_at(res, 0, 1)->v.str);
    pq_result_free(res);
    pq_close(db);
    return 0;
}
```

### 7.1 Loading data and walking a result

The usual sequence (see `examples/embed-demo/demo.S` for the full code):

1. Zero a 56-byte `pq_config` on the stack, store the data directory pointer
   at `PQCFG_DATA_DIR`, call `pq_create(&cfg, &db)`.
2. `pq_load_file(db, "t", "file.csv", NULL)` — CSV with a header row,
   inferred schema, path relative to the data directory. For an explicit
   schema build `pq_coldef` entries and point `PQLO_SCHEMA`/`PQLO_NSCHEMA` at
   them.
3. `pq_query(db, sql, NULL, &res)`.
4. Loop `r` over `[res+PQR_NROWS]` and `c` over `[res+PQR_NCOLS]`; the value
   address is `[res+PQR_VALUES] + (r*ncols + c)*PQV_SIZE`; test
   `[v+PQV_IS_NULL]`, then dispatch on `[v+PQV_TYPE]` or call
   `pq_format_value(col, v, PQ_FMT_FLOAT_FIXED6, buf, cap)` for text.
5. `pq_result_free(res)`, `pq_close(db)`.

`examples/embed-demo` (`pq-embed-demo DATA_DIR CSV_FILE SQL`) does exactly
this and prints CSV in the pqledger §7 format:

```console
$ printf 'a,b\n1,x\n2,y\n' > /tmp/d/t.csv
$ bin/pq-embed-demo /tmp/d t.csv "SELECT a, b, a*1.5 AS c FROM t ORDER BY a"
a,b,c
1,x,1.5
2,y,3.0
$ bin/pq-embed-demo /tmp/d t.csv "SELEC"; echo $?
error: PARSE_ERROR: syntax error at or near 'SELEC'
1
```

### 7.2 The larger example

`app/` is the `pqledger` application ([APP.md](APP.md)). It uses the same
API: `app/commands.S` opens the ledger's PQCF files with `pq_open`, loads
rule and budget tables from in-memory CSV with `pq_load_text` and explicit
schemas, builds intermediate tables with `pq_query_into`, renders results
from the `pq_value`s in `app/output.S`, and persists with `pq_save`.

---

## 8. Implementation notes

* `src/api.S` implements the API on top of the engine's protocol layer: each
  call builds the same request the CLI would send and runs it through the
  same request handler, so library and CLI behave identically (errors,
  limits, path safety). Query results are converted straight from the
  engine's columnar result into a `pq_result`, without JSON.
* Each instance keeps its own catalog version; the worker thread installs it
  into the engine for the duration of a call.
* The archive is produced by `ld -r` of all engine objects followed by
  `objcopy -G pq_*`, so only the API is exported (`nm -g lib/libpolyquery.a`).
