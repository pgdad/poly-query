/*
 * polyquery.h - public embedding API of the PolyQuery x86-64 assembly engine
 * (spec/apps/embedding.md).  Declarations only: the library itself is
 * written in assembly (lib/libpolyquery.a, link with -lpolyquery -lm
 * -lpthread).  The same constants and structure offsets for assembly
 * callers are in polyquery.inc.  See EMBEDDING.md for the full guide.
 *
 * Conventions
 *   - System V AMD64 calling convention; every function is a plain C
 *     function.
 *   - Every operation returns an int status: PQ_OK (0) or one of the
 *     PQ_E_* error codes of spec/errors (the error's message is then
 *     available from pq_errmsg(db) until the next call on that instance).
 *   - Memory returned to the caller (results, table lists, schemas) is
 *     malloc'd by the library and owned by the caller, who releases it with
 *     the matching pq_*_free function.  Everything else stays owned by the
 *     library.
 *   - All calls are serialized by one process-wide lock: any instance may
 *     be used from any thread, calls on any instances never run
 *     concurrently (a query may itself use several worker threads).
 */
#ifndef POLYQUERY_H
#define POLYQUERY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PQ_API_VERSION 1

/* ------------------------------------------------------------ status codes */
#define PQ_OK                          0
#define PQ_E_PARSE_ERROR               1
#define PQ_E_SEMANTIC_ERROR            2
#define PQ_E_TYPE_ERROR                3
#define PQ_E_NUMERIC_OVERFLOW          4
#define PQ_E_DIVISION_BY_ZERO          5
#define PQ_E_CONVERSION_ERROR          6
#define PQ_E_INVALID_ARGUMENT          7
#define PQ_E_SUBQUERY_CARDINALITY      8
#define PQ_E_INVALID_REQUEST           9
#define PQ_E_INGEST_ERROR              10
#define PQ_E_UNSUPPORTED               11
#define PQ_E_ACCESS_DENIED             12
#define PQ_E_NOT_FOUND                 13
#define PQ_E_ALREADY_EXISTS            14
#define PQ_E_CANCELLED                 15
#define PQ_E_RESOURCE_LIMIT            16
#define PQ_E_IO_ERROR                  17
#define PQ_E_STORAGE_CORRUPT           18
#define PQ_E_STORAGE_VERSION_UNSUPPORTED 19
#define PQ_E_INTERNAL_ERROR            20
#define PQ_E_OVERLOADED                21
#define PQ_E_SHUTTING_DOWN             22
#define PQ_E_TIMEOUT                   23

/* ------------------------------------------------------------ type kinds */
#define PQ_TYPE_NULL      0   /* only the type of an untyped NULL literal */
#define PQ_TYPE_BOOLEAN   1
#define PQ_TYPE_INT64     2
#define PQ_TYPE_FLOAT64   3
#define PQ_TYPE_DECIMAL   4
#define PQ_TYPE_STRING    5
#define PQ_TYPE_DATE      6
#define PQ_TYPE_TIMESTAMP 7

/* pq_load_options.header (tri-state so that a zeroed struct means defaults) */
#define PQ_HEADER_DEFAULT 0   /* a header row (the default) */
#define PQ_HEADER_YES     1
#define PQ_HEADER_NO      2   /* no header row: an explicit schema is required */

/* pq_open flags */
#define PQ_OPEN_REPLACE 1     /* replace an existing table of that name */
#define PQ_OPEN_MMAP    2     /* memory-map the file, decode columns lazily */

/* ------------------------------------------------------------ structures */

typedef struct pq_db pq_db;   /* opaque engine instance */

/* Instance configuration (pq_create).  Zero / NULL fields take the CLI
 * defaults: data_dir "." ; memory 4096 MiB ; threads = online CPUs (max 16);
 * no ingest-size limit ; 200,000,000 table rows ; 100,000,000 join rows ;
 * no default query timeout ; test functions disabled. */
typedef struct pq_config {
    const char *data_dir;            /*  0: --data-dir                      */
    int64_t max_query_memory_mb;     /*  8: --max-query-memory-mb           */
    int64_t threads;                 /* 16: --threads (default per query)   */
    int64_t max_ingest_bytes;        /* 24: --max-ingest-bytes              */
    int64_t max_table_rows;          /* 32: --max-table-rows                */
    int64_t max_join_rows;           /* 40: --max-join-rows                 */
    int64_t query_timeout_ms;        /* 48: --query-timeout-ms              */
    int64_t enable_test_functions;   /* 56: --enable-test-functions (0/1)   */
} pq_config;                         /* 64 bytes */

/* One column of an explicit load schema. */
typedef struct pq_column_def {
    const char *name;                /*  0 */
    const char *type;                /*  8: type name, e.g. "DECIMAL(18,2)" */
} pq_column_def;                     /* 16 bytes */

/* Options of pq_load_file / pq_load_text (NULL = all defaults). */
typedef struct pq_load_options {
    const char *format;              /*  0: "csv" (NULL), "json", "jsonl"   */
    int64_t header;                  /*  8: PQ_HEADER_DEFAULT (0) = yes, PQ_HEADER_YES (1), PQ_HEADER_NO (2) */
    int64_t delimiter;               /* 16: CSV delimiter byte, 0 = ','     */
    int64_t replace;                 /* 24: 1 = replace an existing table   */
    const pq_column_def *schema;     /* 32: explicit schema or NULL (infer) */
    int64_t schema_len;              /* 40: number of schema entries        */
} pq_load_options;                   /* 48 bytes */

/* Options of pq_query (NULL = all defaults). */
typedef struct pq_query_options {
    int64_t threads;                 /*  0: >= 1, 0 = instance default      */
    int64_t timeout_ms;              /*  8: 0 = none (instance default)     */
    int64_t max_rows;                /* 16: < 0 = no limit; else RESOURCE_LIMIT above */
    const char *mode;                /* 24: "auto" (NULL), "row", "vectorized" */
    const char *join;                /* 32: "auto" (NULL), "hash", "merge", "nested_loop" */
    int64_t optimize;                /* 40: 0 = default (on), 1 on, 2 off   */
    int64_t use_indexes;             /* 48: 0 = default (on), 1 on, 2 off   */
} pq_query_options;                  /* 56 bytes */

/* A result column. */
typedef struct pq_column {
    const char *name;                /*  0: UTF-8, NUL-terminated           */
    const char *type_name;           /*  8: canonical name, "DECIMAL(18,2)" */
    int32_t type;                    /* 16: PQ_TYPE_*                       */
    int32_t precision;               /* 20: DECIMAL precision, else 0       */
    int32_t scale;                   /* 24: DECIMAL scale, else 0           */
    int32_t reserved;                /* 28 */
} pq_column;                         /* 32 bytes */

/* A value.  Which member is valid follows from the column's type:
 *   BOOLEAN    u.boolean (0 / 1)
 *   INT64      u.i64
 *   FLOAT64    u.f64
 *   DECIMAL    u.dec: the exact unscaled value as a 128-bit two's
 *              complement integer (hi:lo); value = unscaled / 10^scale
 *   STRING     u.str: UTF-8 bytes (NUL-terminated as well) and length
 *   DATE       u.days: days since 1970-01-01
 *   TIMESTAMP  u.micros: microseconds since 1970-01-01 00:00:00
 * is_null != 0 marks SQL NULL (u is then all zero). */
typedef struct pq_value {
    union {
        int64_t i64;
        double f64;
        int64_t boolean;
        int64_t days;
        int64_t micros;
        struct { uint64_t lo; int64_t hi; } dec;
        struct { const char *ptr; int64_t len; } str;
    } u;                             /*  0 */
    int64_t is_null;                 /* 16 */
} pq_value;                          /* 24 bytes */

/* A query result: values are row-major, value (row r, column c) is
 * values[r * ncols + c].  One allocation owned by the caller. */
typedef struct pq_result {
    int64_t ncols;                   /*  0 */
    pq_column *columns;              /*  8 */
    int64_t nrows;                   /* 16 */
    pq_value *values;                /* 24 */
} pq_result;

/* A table of the catalog. */
typedef struct pq_table_info {
    const char *name;                /*  0 */
    int64_t row_count;               /*  8 */
} pq_table_info;                     /* 16 bytes */

typedef struct pq_table_list {
    int64_t count;                   /*  0 */
    pq_table_info *tables;           /*  8: sorted by name (case-insensitive) */
} pq_table_list;

/* A table's schema: its name, row count and columns (as pq_column). */
typedef struct pq_schema {
    const char *name;                /*  0 */
    int64_t row_count;               /*  8 */
    int64_t ncols;                   /* 16 */
    pq_column *columns;              /* 24 */
} pq_schema;

/* ------------------------------------------------------------ operations */

/* Creates an instance.  On success *out is the instance and PQ_OK is
 * returned; on failure *out is NULL and pq_errmsg(NULL) describes it. */
int pq_create(const pq_config *config, pq_db **out);

/* Closes the instance: drops its tables and frees all its memory. */
void pq_close(pq_db *db);

/* Loads CSV / JSON / JSONL into `table`, from a file relative to the data
 * directory (path safety as --data-dir) or from in-memory text.  rows_out
 * (may be NULL) receives the row count. */
int pq_load_file(pq_db *db, const char *table, const char *path,
                 const pq_load_options *options, int64_t *rows_out);
int pq_load_text(pq_db *db, const char *table, const char *data, size_t len,
                 const pq_load_options *options, int64_t *rows_out);

/* Executes one SQL statement; on success *out is the result (free it with
 * pq_result_free).  On failure *out is NULL. */
int pq_query(pq_db *db, const char *sql, const pq_query_options *options,
             pq_result **out);
void pq_result_free(pq_result *result);

/* Creates (or with replace != 0 replaces) `table` from the result of the
 * query `sql` (CREATE TABLE ... AS SELECT semantics; the query may read the
 * table it replaces).  rows_out (may be NULL) receives the row count. */
int pq_create_table(pq_db *db, const char *table, const char *sql,
                    const pq_query_options *options, int64_t replace,
                    int64_t *rows_out);

/* Canonical value text (types.md §9, as CAST(... AS STRING); DECIMAL with
 * its scale, e.g. "-12.50") of result value (row, col), NUL-terminated, into
 * buf of size cap.  Returns the text length (excluding the NUL); if it is
 * >= cap the text was truncated.  NULL values give "" (length 0). */
int64_t pq_value_text(const pq_result *result, int64_t row, int64_t col,
                      char *buf, size_t cap);

/* Saves `table` to a PQCF file (path relative to the data directory).
 * encoding: NULL / "auto", "plain", "dict" or "rle". */
int pq_save(pq_db *db, const char *table, const char *path, const char *encoding);

/* Opens a PQCF file as `table`; flags: PQ_OPEN_REPLACE | PQ_OPEN_MMAP. */
int pq_open(pq_db *db, const char *table, const char *path, int64_t flags);

/* Drops a table (PQ_E_NOT_FOUND if unknown). */
int pq_drop(pq_db *db, const char *table);

/* Lists the tables; free with pq_table_list_free. */
int pq_tables(pq_db *db, pq_table_list **out);
void pq_table_list_free(pq_table_list *list);

/* Reads a table's schema; free with pq_schema_free. */
int pq_schema(pq_db *db, const char *table, pq_schema **out);
void pq_schema_free(pq_schema *schema);

/* Error of the last failed call on db (or of pq_create when db is NULL):
 * code PQ_E_* (PQ_OK if the last call succeeded) and message. */
int pq_errcode(const pq_db *db);
const char *pq_errmsg(const pq_db *db);

/* Name of a status code: "PARSE_ERROR", ... ("OK" for PQ_OK). */
const char *pq_error_name(int code);

/* Library version text, e.g. "polyquery-x86_64-asm 0.1.0". */
const char *pq_version(void);

#ifdef __cplusplus
}
#endif

#endif /* POLYQUERY_H */
