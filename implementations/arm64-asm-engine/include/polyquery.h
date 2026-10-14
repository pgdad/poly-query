/*
 * polyquery.h — embedding API of the PolyQuery AArch64 assembly engine
 * (spec/apps/embedding.md). Declarations only; the implementation is
 * src/api.S, packaged as lib/libpolyquery.a by `make build`.
 *
 * Calling convention: AAPCS64. Every function is callable from C and from
 * assembly (include/polyquery.inc has the same constants and the structure
 * offsets). Link with:  -lpolyquery -lm -lpthread
 *
 * Status: every int-returning function returns PQ_OK (0) or an error code
 * PQ_E_* (the specification's error codes); the message of the last failed
 * call on an instance is pq_errmsg(db). An error leaves the instance usable.
 *
 * Memory: a pq_result is one malloc'ed block owned by the caller and released
 * with pq_result_free(); all strings inside it live until then. Strings passed
 * in are copied; the caller keeps ownership.
 *
 * Threads: every function may be called from any thread; calls are
 * serialised (one call runs at a time in the process). See EMBEDDING.md.
 */
#ifndef POLYQUERY_H
#define POLYQUERY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- error codes (spec/errors/error-codes.json) ---- */
#define PQ_OK                          0
#define PQ_E_PARSE_ERROR               1
#define PQ_E_SEMANTIC_ERROR            2
#define PQ_E_TYPE_ERROR                3
#define PQ_E_NUMERIC_OVERFLOW          4
#define PQ_E_DIVISION_BY_ZERO          5
#define PQ_E_CONVERSION_ERROR          6
#define PQ_E_INVALID_ARGUMENT          7
#define PQ_E_INVALID_REQUEST           8
#define PQ_E_INGEST_ERROR              9
#define PQ_E_UNSUPPORTED              10
#define PQ_E_ACCESS_DENIED            11
#define PQ_E_NOT_FOUND                12
#define PQ_E_ALREADY_EXISTS           13
#define PQ_E_RESOURCE_LIMIT           14
#define PQ_E_IO_ERROR                 15
#define PQ_E_INTERNAL_ERROR           16
#define PQ_E_TIMEOUT                  17
#define PQ_E_SUBQUERY_CARDINALITY     18
#define PQ_E_CANCELLED                19
#define PQ_E_STORAGE_CORRUPT          20
#define PQ_E_STORAGE_VERSION_UNSUPPORTED 21
#define PQ_E_OVERLOADED               22
#define PQ_E_SHUTTING_DOWN            23

/* ---- value types (pq_column.type, pq_value.type) ---- */
#define PQ_T_BOOLEAN    1   /* v.i64 = 0 / 1                                   */
#define PQ_T_INT64      2   /* v.i64                                           */
#define PQ_T_DECIMAL    3   /* unscaled 128-bit integer: v.i64 = low 64 bits,  */
                            /* aux = high 64 bits (sign extension if p <= 18); */
                            /* value = unscaled / 10^scale (pq_column.scale)   */
#define PQ_T_FLOAT64    4   /* v.f64                                           */
#define PQ_T_STRING     5   /* v.str = UTF-8 bytes, NUL-terminated; aux = byte  */
                            /* length (the text may contain NUL bytes)         */
#define PQ_T_DATE       6   /* v.i64 = days since 1970-01-01                   */
#define PQ_T_TIMESTAMP  7   /* v.i64 = microseconds since 1970-01-01 00:00:00  */

/* ---- pq_config.flags ---- */
#define PQ_CFG_TEST_FUNCTIONS  1u   /* as --enable-test-functions */

/* ---- pq_load_opts ---- */
#define PQ_FORMAT_CSV          0u
#define PQ_FORMAT_JSON         1u
#define PQ_FORMAT_JSONL        2u
#define PQ_LOAD_NO_HEADER      1u   /* CSV without a header row (schema required) */
#define PQ_LOAD_REPLACE        2u   /* replace an existing table */

/* ---- pq_query_opts.mode ---- */
#define PQ_MODE_AUTO           0u
#define PQ_MODE_ROW            1u
#define PQ_MODE_VECTORIZED     2u

/* ---- pq_format_value flags ---- */
#define PQ_FMT_FLOAT_FIXED6    1u   /* FLOAT64 as printf("%.6f") (-0 => 0.000000);
                                       default: shortest round-trip text */

typedef struct pq_db pq_db;          /* opaque engine instance */

typedef struct pq_config {           /* all-zero = engine defaults */
    const char *data_dir;            /* +0  NULL => "."; must be a directory */
    uint64_t max_query_memory_mb;    /* +8  0 => default (4096)  */
    uint64_t threads;                /* +16 default query threads, 0 => min(CPUs, 8) */
    uint64_t max_ingest_bytes;       /* +24 0 => default (4 GiB) */
    uint64_t max_table_rows;         /* +32 0 => default (200,000,000) */
    uint64_t max_join_rows;          /* +40 0 => default (100,000,000) */
    uint32_t flags;                  /* +48 PQ_CFG_* */
    uint32_t reserved;               /* +52 must be 0 */
} pq_config;                         /* 56 bytes */

typedef struct pq_coldef {           /* explicit schema entry */
    const char *name;                /* +0 column name */
    const char *type;                /* +8 type text, e.g. "DECIMAL(18,2)", "BIGINT" */
} pq_coldef;                         /* 16 bytes */

typedef struct pq_load_opts {        /* all-zero = CSV, header, ',', inferred */
    const pq_coldef *schema;         /* +0  NULL => schema inference */
    uint64_t nschema;                /* +8  entries in schema */
    uint32_t format;                 /* +16 PQ_FORMAT_* */
    uint32_t delimiter;              /* +20 CSV delimiter byte, 0 => ',' */
    uint32_t flags;                  /* +24 PQ_LOAD_* */
    uint32_t reserved;               /* +28 must be 0 */
} pq_load_opts;                      /* 32 bytes */

typedef struct pq_query_opts {       /* all-zero = defaults */
    uint64_t threads;                /* +0  0 => instance default */
    uint64_t timeout_ms;             /* +8  0 => no timeout */
    uint64_t max_rows;               /* +16 0 => unlimited; else more rows => RESOURCE_LIMIT */
    uint32_t mode;                   /* +24 PQ_MODE_* */
    uint32_t reserved;               /* +28 must be 0 */
} pq_query_opts;                     /* 32 bytes */

typedef struct pq_column {
    const char *name;                /* +0  column name */
    const char *type_name;           /* +8  canonical type name, e.g. "DECIMAL(18,2)" */
    uint32_t type;                   /* +16 PQ_T_* */
    uint32_t precision;              /* +20 DECIMAL precision (else 0) */
    uint32_t scale;                  /* +24 DECIMAL scale (else 0) */
    uint32_t reserved;               /* +28 */
} pq_column;                         /* 32 bytes */

typedef struct pq_value {
    union {
        int64_t i64;                 /* BOOLEAN, INT64, DATE, TIMESTAMP, DECIMAL low */
        double f64;                  /* FLOAT64 */
        const char *str;             /* STRING */
    } v;                             /* +0 */
    int64_t aux;                     /* +8  STRING length / DECIMAL high 64 bits */
    uint32_t is_null;                /* +16 1 = NULL (v and aux are 0) */
    uint32_t type;                   /* +20 PQ_T_* of the column */
} pq_value;                          /* 24 bytes */

typedef struct pq_result {
    uint64_t ncols;                  /* +0  */
    uint64_t nrows;                  /* +8  */
    pq_column *columns;              /* +16 [ncols] */
    pq_value *values;                /* +24 [nrows * ncols], row-major */
} pq_result;                         /* 32 bytes */

/* ---- instance ---- */
int  pq_create(const pq_config *cfg, pq_db **out);
void pq_close(pq_db *db);

/* ---- errors ---- */
int         pq_errcode(const pq_db *db);   /* code of the last failed call (PQ_OK if none) */
const char *pq_errname(const pq_db *db);   /* e.g. "PARSE_ERROR" ("OK" if none) */
const char *pq_errmsg(const pq_db *db);    /* message ("" if none) */
const char *pq_code_name(int code);        /* code -> "PARSE_ERROR", 0 -> "OK" */
/* pq_errcode/pq_errname/pq_errmsg(NULL): the last pq_create failure of the calling thread */

/* ---- tables ---- */
int pq_load_file(pq_db *db, const char *table, const char *path, const pq_load_opts *opts);
int pq_load_text(pq_db *db, const char *table, const char *text, size_t len,
                 const pq_load_opts *opts);
int pq_save(pq_db *db, const char *table, const char *path);
int pq_open(pq_db *db, const char *table, const char *path, int replace);
int pq_drop(pq_db *db, const char *table);
int pq_tables(pq_db *db, pq_result **out);              /* name STRING, row_count INT64 */
int pq_schema(pq_db *db, const char *table, pq_result **out); /* name STRING, type STRING */

/* ---- queries ---- */
int pq_query(pq_db *db, const char *sql, const pq_query_opts *opts, pq_result **out);
int pq_query_into(pq_db *db, const char *table, const char *sql,
                  const pq_query_opts *opts, int replace);   /* result -> new table */

/* ---- results ---- */
void            pq_result_free(pq_result *res);
const pq_value *pq_value_at(const pq_result *res, uint64_t row, uint64_t col);
size_t          pq_format_value(const pq_column *col, const pq_value *val, uint32_t flags,
                                char *buf, size_t cap);   /* text, like snprintf */

const char *pq_version(void);

#ifdef __cplusplus
}
#endif
#endif /* POLYQUERY_H */
