/*
 * polyquery.inc - the embedding API (polyquery.h) for assembly callers:
 * the same constants plus the byte offsets and sizes of every public
 * structure.  Include it from a .S file (preprocessed by cpp:
 * `#include "polyquery.inc"`) or with GNU as `.include` (it contains only
 * #define lines, so use cpp).  See EMBEDDING.md.
 */
#ifndef POLYQUERY_INC
#define POLYQUERY_INC

#define PQ_API_VERSION 1

/* status codes */
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

/* type kinds */
#define PQ_TYPE_NULL      0
#define PQ_TYPE_BOOLEAN   1
#define PQ_TYPE_INT64     2
#define PQ_TYPE_FLOAT64   3
#define PQ_TYPE_DECIMAL   4
#define PQ_TYPE_STRING    5
#define PQ_TYPE_DATE      6
#define PQ_TYPE_TIMESTAMP 7

/* pq_load_options.header */
#define PQ_HEADER_DEFAULT 0
#define PQ_HEADER_YES     1
#define PQ_HEADER_NO      2

/* pq_open flags */
#define PQ_OPEN_REPLACE 1
#define PQ_OPEN_MMAP    2

/* pq_config (64 bytes) */
#define PQ_CONFIG_DATA_DIR        0
#define PQ_CONFIG_MAX_QUERY_MEM   8
#define PQ_CONFIG_THREADS         16
#define PQ_CONFIG_MAX_INGEST      24
#define PQ_CONFIG_MAX_TABLE_ROWS  32
#define PQ_CONFIG_MAX_JOIN_ROWS   40
#define PQ_CONFIG_TIMEOUT_MS      48
#define PQ_CONFIG_TEST_FUNCTIONS  56
#define PQ_CONFIG_SIZE            64

/* pq_column_def (16 bytes) */
#define PQ_COLDEF_NAME 0
#define PQ_COLDEF_TYPE 8
#define PQ_COLDEF_SIZE 16

/* pq_load_options (48 bytes) */
#define PQ_LOAD_FORMAT     0
#define PQ_LOAD_HEADER     8
#define PQ_LOAD_DELIMITER  16
#define PQ_LOAD_REPLACE    24
#define PQ_LOAD_SCHEMA     32
#define PQ_LOAD_SCHEMA_LEN 40
#define PQ_LOAD_SIZE       48

/* pq_query_options (56 bytes) */
#define PQ_QOPT_THREADS     0
#define PQ_QOPT_TIMEOUT_MS  8
#define PQ_QOPT_MAX_ROWS    16
#define PQ_QOPT_MODE        24
#define PQ_QOPT_JOIN        32
#define PQ_QOPT_OPTIMIZE    40
#define PQ_QOPT_USE_INDEXES 48
#define PQ_QOPT_SIZE        56

/* pq_column (32 bytes) */
#define PQ_COL_NAME      0
#define PQ_COL_TYPE_NAME 8
#define PQ_COL_TYPE      16   /* int32 */
#define PQ_COL_PRECISION 20   /* int32 */
#define PQ_COL_SCALE     24   /* int32 */
#define PQ_COL_SIZE      32
#define PQ_COL_SHIFT     5

/* pq_value (24 bytes) */
#define PQ_VAL_I64     0
#define PQ_VAL_F64     0
#define PQ_VAL_BOOL    0
#define PQ_VAL_DAYS    0
#define PQ_VAL_MICROS  0
#define PQ_VAL_DEC_LO  0
#define PQ_VAL_DEC_HI  8
#define PQ_VAL_STR_PTR 0
#define PQ_VAL_STR_LEN 8
#define PQ_VAL_IS_NULL 16
#define PQ_VAL_SIZE    24

/* pq_result */
#define PQ_RES_NCOLS   0
#define PQ_RES_COLUMNS 8
#define PQ_RES_NROWS   16
#define PQ_RES_VALUES  24
#define PQ_RES_SIZE    32

/* pq_table_info (16 bytes) / pq_table_list */
#define PQ_TI_NAME      0
#define PQ_TI_ROW_COUNT 8
#define PQ_TI_SIZE      16
#define PQ_TL_COUNT     0
#define PQ_TL_TABLES    8
#define PQ_TL_SIZE      16

/* pq_schema */
#define PQ_SCH_NAME      0
#define PQ_SCH_ROW_COUNT 8
#define PQ_SCH_NCOLS     16
#define PQ_SCH_COLUMNS   24
#define PQ_SCH_SIZE      32

#endif /* POLYQUERY_INC */
