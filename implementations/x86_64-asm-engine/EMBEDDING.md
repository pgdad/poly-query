# Embedding PolyQuery in an x86-64 program

This guide is for developers who want to use the PolyQuery engine **as a library**
from their own x86-64 assembly program (or from C, or anything else that can call a
C-ABI function). The engine then runs in-process: no server, no child process,
no sockets. The API implements `spec/apps/embedding.md`.

What you get from `make build`:

| file | what it is |
|---|---|
| `lib/libpolyquery.a` | the library: the whole engine pre-linked into one object; only the 19 public `pq_*` functions are global symbols, so nothing in the engine can clash with your own symbols |
| `include/polyquery.h` | declarations for C callers: types, constants, prototypes |
| `include/polyquery.inc` | the same constants plus every structure's field offsets and sizes, for assembly callers |

Larger examples: [`examples/embed-demo/`](examples/embed-demo/) (about 300 lines,
the program shown in [§9](#9-a-complete-minimal-program)) and [`app/`](app/) (the
`pqledger` application, see [APP.md](APP.md)), which uses the API for all of its data
access.

## 1. Building the library and depending on it

Prerequisites: GNU binutils 2.42 (`as`, `ld`, `ar`, `objcopy`), gcc 13.3 as the
assembler/linker driver, GNU make, glibc. No other libraries are needed.

Step by step, for a separate project in its own directory:

1. Build the engine and library once:

   ```sh
   make -C /path/to/implementations/x86_64-asm-engine build
   ```

   This creates `lib/libpolyquery.a` (and the engine CLI, `pqledger` and the demo).

2. In your project, include the offsets in your `.S` files (they are preprocessed by
   gcc, so `#include` works):

   ```asm
   #include "polyquery.inc"
   ```

3. Assemble with the engine's `include/` on the include path, and link against the
   library plus libm and libpthread. A complete `Makefile` for a one-file project
   (this is `examples/embed-demo/Makefile`):

   ```make
   POLYQUERY ?= /path/to/implementations/x86_64-asm-engine

   myprog: myprog.S $(POLYQUERY)/include/polyquery.inc $(POLYQUERY)/lib/libpolyquery.a
   	gcc -c -I$(POLYQUERY)/include -Wa,--noexecstack -g -o myprog.o myprog.S
   	gcc -no-pie -Wl,-z,noexecstack -o myprog myprog.o \
   	    -L$(POLYQUERY)/lib -lpolyquery -lm -lpthread
   ```

   Link with **`-no-pie`**: the engine code uses absolute addresses in a few tables
   (linking a PIE works but needs text relocations, and the linker warns).

4. From C the same applies: `#include "polyquery.h"`, compile with
   `-I$(POLYQUERY)/include` and link with `-no-pie -L$(POLYQUERY)/lib -lpolyquery -lm
   -lpthread`.

`make -C examples/embed-demo POLYQUERY=$PWD` builds the demo exactly this way.

## 2. Calling convention and conventions of the API

* Every function is a plain System V AMD64 function: arguments in `rdi, rsi, rdx,
  rcx, r8, r9`, then on the stack; result in `rax`/`eax`; `rbx, rbp, r12–r15` are
  preserved; the stack must be 16-byte aligned at the `call`. No function is
  variadic, so `%al` does not matter.
* Every operation returns an **`int` status** in `eax`: `PQ_OK` (0) or a `PQ_E_*`
  code (§6). Results come back through out-parameters.
* Strings passed in are NUL-terminated UTF-8 (`const char *`), except the
  `pq_load_text` data, which has an explicit length.
* `int64_t` fields everywhere: all option structures consist of 8-byte fields, so a
  zero-filled structure (`.zero PQ_LOAD_SIZE`) means "all defaults". Passing NULL
  instead of an options pointer also means "all defaults".
* The engine runs each call on its own 1 GiB lazily committed stack (virtual memory
  only), so even huge SQL statements cannot overflow your thread's stack; they fail
  with `RESOURCE_LIMIT` instead.

## 3. API reference

### Instances

```c
int  pq_create(const pq_config *config, pq_db **out);
void pq_close(pq_db *db);
```

`pq_create` makes an engine instance. `config` may be NULL (all defaults). Fields of
`pq_config` (offsets `PQ_CONFIG_*`), each 0/NULL = default:

| field | offset | meaning | default |
|---|---|---|---|
| `data_dir` | 0 | directory for `load`/`save`/`open` paths (like `--data-dir`) | `"."` |
| `max_query_memory_mb` | 8 | per-query memory limit (`--max-query-memory-mb`) | 4096 |
| `threads` | 16 | default threads per query (`--threads`) | online CPUs, at most 16 |
| `max_ingest_bytes` | 24 | `--max-ingest-bytes` | unlimited |
| `max_table_rows` | 32 | `--max-table-rows` | 200,000,000 |
| `max_join_rows` | 40 | `--max-join-rows` | 100,000,000 |
| `query_timeout_ms` | 48 | default query timeout (`--query-timeout-ms`) | none |
| `enable_test_functions` | 56 | 1 = `--enable-test-functions` | off |

Errors: `PQ_E_INVALID_ARGUMENT` (NULL `out`, a negative value); `*out` is then NULL
and `pq_errmsg(NULL)` tells why. The data directory is not checked at creation;
paths are checked by each operation (path safety exactly as `--data-dir`, protocol
§6: absolute paths and `..` components ⇒ `ACCESS_DENIED`).

`pq_close` drops all tables of the instance and frees it (NULL is ignored). The
pointer is invalid afterwards. Results, lists and schemas you still hold stay valid:
they are independent allocations.

### Loading data

```c
int pq_load_file(pq_db *db, const char *table, const char *path,
                 const pq_load_options *options, int64_t *rows_out);
int pq_load_text(pq_db *db, const char *table, const char *data, size_t len,
                 const pq_load_options *options, int64_t *rows_out);
```

The protocol's `load` operation: CSV (or JSON / JSON Lines) from a file under the
data directory or from memory, into a new table. `rows_out` (may be NULL) receives
the row count. `pq_load_options` (`PQ_LOAD_*`, 48 bytes):

| field | offset | meaning |
|---|---|---|
| `format` | 0 | `"csv"` (NULL), `"json"`, `"jsonl"` |
| `header` | 8 | `PQ_HEADER_DEFAULT` (0, a header row), `PQ_HEADER_YES` (1), `PQ_HEADER_NO` (2; needs a schema) |
| `delimiter` | 16 | CSV delimiter byte; 0 = `,` |
| `replace` | 24 | 1 = replace an existing table (else `ALREADY_EXISTS`) |
| `schema` | 32 | array of `pq_column_def {const char *name; const char *type;}` (16 bytes each), or NULL to infer types |
| `schema_len` | 40 | entries in `schema` |

Ingestion follows `spec/data-types/ingestion.md`: an unquoted empty CSV field is
NULL, a quoted empty field `""` is the empty string (STRING columns). Errors:
`INGEST_ERROR`, `ALREADY_EXISTS`, `ACCESS_DENIED`, `NOT_FOUND`/`IO_ERROR` (file),
`RESOURCE_LIMIT`, `INVALID_REQUEST` (bad schema type name, header without schema).

### Queries

```c
int  pq_query(pq_db *db, const char *sql, const pq_query_options *options, pq_result **out);
void pq_result_free(pq_result *result);
int  pq_create_table(pq_db *db, const char *table, const char *sql,
                     const pq_query_options *options, int64_t replace, int64_t *rows_out);
int64_t pq_value_text(const pq_result *result, int64_t row, int64_t col, char *buf, size_t cap);
```

`pq_query` runs one SQL statement (SELECT, UNION ALL, WITH, EXPLAIN, CREATE/DROP
INDEX) and on success stores a result in `*out` (NULL on failure). Statements
without output (CREATE INDEX) give a result with 0 columns and 0 rows; EXPLAIN gives
one STRING column `plan`. `pq_query_options` (`PQ_QOPT_*`, 56 bytes):

| field | offset | meaning |
|---|---|---|
| `threads` | 0 | worker threads, 0 = the instance default |
| `timeout_ms` | 8 | 0 = none (or the instance's `query_timeout_ms`) ⇒ `TIMEOUT` |
| `max_rows` | 16 | 0 (or negative) = no limit; N > 0: more than N result rows ⇒ `RESOURCE_LIMIT` |
| `mode` | 24 | `"auto"` (NULL), `"row"`, `"vectorized"` |
| `join` | 32 | `"auto"` (NULL), `"hash"`, `"merge"`, `"nested_loop"` |
| `optimize` | 40 | 0 default (on), 1 on, 2 off |
| `use_indexes` | 48 | 0 default (on), 1 on, 2 off |

`pq_create_table` runs a query and stores its result as a new table `table`
(`CREATE TABLE ... AS SELECT`); with `replace` ≠ 0 an existing table is replaced,
and the query may read the table it replaces (e.g. `SELECT * FROM t UNION ALL SELECT
* FROM new_rows ORDER BY id`). Only SELECT queries are accepted (else
`UNSUPPORTED`).

`pq_value_text` writes the canonical text of a value (`spec/data-types/types.md`
§9, as `CAST(x AS STRING)`: `-12.50`, `2026-01-02`, `true`, `2026-01-02 10:00:00`)
into `buf` (NUL-terminated, truncated to `cap - 1` bytes) and returns the full text
length. NULL gives `""`. It reads only the `pq_result` structure, so it also works on
results your program builds itself, and it does not take the lock.

### Files and the catalog

```c
int  pq_save(pq_db *db, const char *table, const char *path, const char *encoding);
int  pq_open(pq_db *db, const char *table, const char *path, int64_t flags);
int  pq_drop(pq_db *db, const char *table);
int  pq_tables(pq_db *db, pq_table_list **out);
void pq_table_list_free(pq_table_list *list);
int  pq_schema(pq_db *db, const char *table, pq_schema **out);
void pq_schema_free(pq_schema *schema);
```

* `pq_save` writes a PQCF file atomically (`encoding` NULL/`"auto"`, `"plain"`,
  `"dict"`, `"rle"`). Missing directory ⇒ `IO_ERROR`, unknown table ⇒ `NOT_FOUND`.
* `pq_open` opens a PQCF file as a table; `flags`: `PQ_OPEN_REPLACE` (1),
  `PQ_OPEN_MMAP` (2, memory-mapped, columns decoded on first use). Errors
  `STORAGE_CORRUPT`, `STORAGE_VERSION_UNSUPPORTED`, `ALREADY_EXISTS`, `IO_ERROR`,
  `NOT_FOUND`.
* `pq_drop` removes a table and its indexes (`NOT_FOUND` if unknown).
* `pq_tables` returns `{int64 count; pq_table_info *tables}` with
  `pq_table_info {const char *name; int64 row_count}` (16 bytes), sorted by name.
* `pq_schema` returns `{const char *name; int64 row_count; int64 ncols; pq_column
  *columns}` (`PQ_SCH_*`); unknown table ⇒ `NOT_FOUND`.

### Errors and version

```c
int         pq_errcode(const pq_db *db);   /* last call's status; db NULL: pq_create's */
const char *pq_errmsg(const pq_db *db);    /* its message ("" after success) */
const char *pq_error_name(int code);       /* "PARSE_ERROR", ..., "OK" */
const char *pq_version(void);              /* "polyquery-x86_64-asm 0.1.0" */
```

## 4. Results and the value-type mapping

```
pq_result (PQ_RES_*)          pq_column (PQ_COL_*, 32 bytes)     pq_value (PQ_VAL_*, 24 bytes)
 0 ncols    int64              0 name       char*                 0  payload (16 bytes, below)
 8 columns  pq_column*         8 type_name  char* "DECIMAL(18,2)" 16 is_null int64 (≠0: NULL)
16 nrows    int64             16 type       int32 PQ_TYPE_*
24 values   pq_value*         20 precision  int32 (DECIMAL)
                              24 scale      int32 (DECIMAL)
```

Values are row-major: value (r, c) is at `values + (r * ncols + c) * 24`
(`PQ_VAL_SIZE`). The column type tells which payload is valid:

| SQL type | `type` | payload (offset 0) | |
|---|---|---|---|
| `BOOLEAN` | `PQ_TYPE_BOOLEAN` 1 | `int64` 0 / 1 | `PQ_VAL_BOOL` |
| `INT64` | `PQ_TYPE_INT64` 2 | `int64` | `PQ_VAL_I64` |
| `FLOAT64` | `PQ_TYPE_FLOAT64` 3 | IEEE binary64 (`movsd PQ_VAL_F64(v), %xmm0`) | `PQ_VAL_F64` |
| `DECIMAL(p,s)` | `PQ_TYPE_DECIMAL` 4 | exact unscaled integer as 128-bit two's complement: `lo` (offset 0) and `hi` (offset 8); value = unscaled / 10^s, `s` = column `scale`. For p ≤ 18 `hi` is the sign extension of `lo`. | `PQ_VAL_DEC_LO`, `PQ_VAL_DEC_HI` |
| `STRING` | `PQ_TYPE_STRING` 5 | `char *ptr` (offset 0, UTF-8, also NUL-terminated) and `int64 len` (offset 8) | `PQ_VAL_STR_PTR`, `PQ_VAL_STR_LEN` |
| `DATE` | `PQ_TYPE_DATE` 6 | `int64` days since 1970-01-01 (negative before) | `PQ_VAL_DAYS` |
| `TIMESTAMP` | `PQ_TYPE_TIMESTAMP` 7 | `int64` microseconds since 1970-01-01 00:00:00 | `PQ_VAL_MICROS` |
| NULL | any | `is_null` ≠ 0, payload all zero | `PQ_VAL_IS_NULL` |

A column of an untyped `NULL` literal (`SELECT NULL AS x`) is reported as STRING (all
values NULL), as in the protocol. `type_name` is the canonical name of
`spec/data-types/types.md` (`INT64`, `DECIMAL(18,2)`, ...).

## 5. Memory and resource management

| object | allocated by | freed by |
|---|---|---|
| `pq_db` | `pq_create` | `pq_close` |
| `pq_result` | `pq_query` | `pq_result_free` (one block: header, columns, values and all strings) |
| `pq_table_list` | `pq_tables` | `pq_table_list_free` |
| `pq_schema` | `pq_schema` | `pq_schema_free` |
| `pq_errmsg` / `pq_error_name` / `pq_version` strings | the library | never (an error message stays valid until the next call on the same instance) |

Everything returned to you is a single `malloc` block owned by you; free it with the
matching function (all three are `free`, so freeing with `free` also works). You may
keep results after closing the instance. Strings you pass in are copied when
needed; the library keeps no pointer to your memory after a call returns.

Inside, each instance owns its tables (one arena per table); the request memory is
reused across calls and bounded by `max_query_memory_mb`. The library also creates up
to `threads − 1` worker threads on first parallel use; they live for the rest of the
process and sleep when idle. The library installs no signal handlers and never
changes the CPU affinity of your threads.

## 6. Errors

Each failing call returns the code of `spec/errors` and records it on the instance:

| code | name | code | name |
|---|---|---|---|
| 1 | `PARSE_ERROR` | 13 | `NOT_FOUND` |
| 2 | `SEMANTIC_ERROR` | 14 | `ALREADY_EXISTS` |
| 3 | `TYPE_ERROR` | 15 | `CANCELLED` |
| 4 | `NUMERIC_OVERFLOW` | 16 | `RESOURCE_LIMIT` |
| 5 | `DIVISION_BY_ZERO` | 17 | `IO_ERROR` |
| 6 | `CONVERSION_ERROR` | 18 | `STORAGE_CORRUPT` |
| 7 | `INVALID_ARGUMENT` | 19 | `STORAGE_VERSION_UNSUPPORTED` |
| 8 | `SUBQUERY_CARDINALITY` | 20 | `INTERNAL_ERROR` |
| 9 | `INVALID_REQUEST` | 21 | `OVERLOADED` |
| 10 | `INGEST_ERROR` | 22 | `SHUTTING_DOWN` |
| 11 | `UNSUPPORTED` | 23 | `TIMEOUT` |
| 12 | `ACCESS_DENIED` | | |

`pq_errcode(db)` / `pq_errmsg(db)` return the last call's code and message (the
engine's message, e.g. `unknown column 'nope'`); `pq_error_name(code)` the name.
A NULL or invalid argument gives `INVALID_ARGUMENT`. **An error never leaves an
instance half-changed**: a failed load / open / create-table publishes nothing, and
the instance stays fully usable.

## 7. Thread safety

* All API calls are serialized by one process-wide mutex: the engine core keeps its
  per-request state in process globals, so **calls never run concurrently, on the
  same instance or on different ones**. It is therefore safe to call the API from
  any number of threads, with any instances; calls simply queue.
* Several instances may exist; each has its own tables and configuration (the
  active instance's catalog is swapped in for each call).
* A single query may still use several threads internally (`threads`).
* `pq_value_text`, `pq_error_name` and `pq_version` do not take the lock.
* Do not `fork()` while another thread is inside the library.

## 8. Calling from C

```c
#include <stdio.h>
#include "polyquery.h"

int main(void) {
    pq_config cfg = { .data_dir = "data" };
    pq_db *db;  pq_result *r;
    if (pq_create(&cfg, &db) != PQ_OK) return 1;
    if (pq_load_file(db, "t", "t.csv", NULL, NULL) != PQ_OK ||
        pq_query(db, "SELECT COUNT(*) AS n FROM t", NULL, &r) != PQ_OK) {
        fprintf(stderr, "error: %s: %s\n", pq_error_name(pq_errcode(db)), pq_errmsg(db));
        pq_close(db);
        return 1;
    }
    printf("%s = %lld\n", r->columns[0].name, (long long)r->values[0].u.i64);
    pq_result_free(r);
    pq_close(db);
    return 0;
}
```

(Shown for C callers; the project itself contains no C source.)

## 9. A complete minimal program

`count.S` — loads `t.csv` from directory `data` and prints the row count. Build with
the Makefile of §1.

```asm
#include "polyquery.inc"
    .section .note.GNU-stack, "", @progbits
    .section .rodata
dir:   .asciz "data"
file:  .asciz "t.csv"
tbl:   .asciz "t"
sql:   .asciz "SELECT COUNT(*) AS n FROM t"
okfmt: .asciz "%s = %ld\n"
errfmt:.asciz "error: %s: %s\n"
    .text
    .globl main
main:
    push %rbx
    push %r12
    sub $(PQ_CONFIG_SIZE + 24), %rsp    /* config at 0, db at 64, result at 72 */
    lea 0(%rsp), %rdi                    /* zeroed config = defaults ... */
    xor %esi, %esi
    mov $PQ_CONFIG_SIZE, %edx
    call memset
    lea dir(%rip), %rax                  /* ... except the data directory */
    mov %rax, PQ_CONFIG_DATA_DIR(%rsp)
    lea 0(%rsp), %rdi
    lea PQ_CONFIG_SIZE(%rsp), %rsi
    call pq_create
    test %eax, %eax
    jnz 9f
    mov PQ_CONFIG_SIZE(%rsp), %rbx       /* db */
    mov %rbx, %rdi
    lea tbl(%rip), %rsi
    lea file(%rip), %rdx
    xor %ecx, %ecx                       /* options: defaults (header row) */
    xor %r8d, %r8d                       /* rows_out: not needed */
    call pq_load_file
    test %eax, %eax
    jnz 8f
    mov %rbx, %rdi
    lea sql(%rip), %rsi
    xor %edx, %edx
    lea PQ_CONFIG_SIZE+8(%rsp), %rcx
    call pq_query
    test %eax, %eax
    jnz 8f
    mov PQ_CONFIG_SIZE+8(%rsp), %r12     /* pq_result* */
    mov PQ_RES_COLUMNS(%r12), %rax
    mov PQ_COL_NAME(%rax), %rsi          /* column 0's name */
    mov PQ_RES_VALUES(%r12), %rax
    mov PQ_VAL_I64(%rax), %rdx           /* row 0, column 0: INT64 */
    lea okfmt(%rip), %rdi
    xor %eax, %eax
    call printf
    mov %r12, %rdi
    call pq_result_free
    mov %rbx, %rdi
    call pq_close
    xor %eax, %eax
    jmp 10f
8:  mov %rbx, %rdi                       /* error: CODE: message */
    call pq_errcode
    mov %eax, %edi
    call pq_error_name
    mov %rax, %r12
    mov %rbx, %rdi
    call pq_errmsg
    mov %rax, %rdx
    mov stderr(%rip), %rdi
    lea errfmt(%rip), %rsi
    mov %rdx, %rcx
    mov %r12, %rdx
    xor %eax, %eax
    call fprintf
    mov %rbx, %rdi
    call pq_close
9:  mov $1, %eax
10: add $(PQ_CONFIG_SIZE + 24), %rsp
    pop %r12
    pop %rbx
    ret
```

## 10. Where to look next

* [`examples/embed-demo/demo.S`](examples/embed-demo/demo.S): the `pq-embed-demo
  DATA_DIR CSV_FILE SQL` program (load, query, CSV output of every type, errors).
* [`app/`](app/): `pqledger`, a complete application on the API — loading tables from
  generated CSV text with explicit schemas, `pq_create_table` to rewrite tables,
  `pq_save`/`pq_open` for its PQCF ledger, typed values for output formatting.
* [`tests/test_api.S`](tests/test_api.S): unit tests of every operation.
* `src/api.S`: the implementation (how API calls map onto the engine's protocol
  operations).
