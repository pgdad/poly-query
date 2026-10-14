// =============================================================================
// polyquery.inc — the embedding API for assembly callers (same constants and
// structure offsets as include/polyquery.h). Include it from a .S file:
//     #include "polyquery.inc"
// Functions follow the AAPCS64: arguments x0..x7, result in x0 (w0 for int).
// =============================================================================
#ifndef POLYQUERY_INC
#define POLYQUERY_INC

// ---- error codes
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

// ---- value types
#define PQ_T_BOOLEAN    1
#define PQ_T_INT64      2
#define PQ_T_DECIMAL    3
#define PQ_T_FLOAT64    4
#define PQ_T_STRING     5
#define PQ_T_DATE       6
#define PQ_T_TIMESTAMP  7

// ---- flags
#define PQ_CFG_TEST_FUNCTIONS  1
#define PQ_FORMAT_CSV          0
#define PQ_FORMAT_JSON         1
#define PQ_FORMAT_JSONL        2
#define PQ_LOAD_NO_HEADER      1
#define PQ_LOAD_REPLACE        2
#define PQ_MODE_AUTO           0
#define PQ_MODE_ROW            1
#define PQ_MODE_VECTORIZED     2
#define PQ_FMT_FLOAT_FIXED6    1

// ---- struct pq_config (56 bytes)
#define PQCFG_DATA_DIR      0
#define PQCFG_QUERY_MEM_MB  8
#define PQCFG_THREADS       16
#define PQCFG_INGEST_BYTES  24
#define PQCFG_TABLE_ROWS    32
#define PQCFG_JOIN_ROWS     40
#define PQCFG_FLAGS         48
#define PQCFG_SIZE          56

// ---- struct pq_coldef (16 bytes)
#define PQCD_NAME   0
#define PQCD_TYPE   8
#define PQCD_SIZE   16

// ---- struct pq_load_opts (32 bytes)
#define PQLO_SCHEMA     0
#define PQLO_NSCHEMA    8
#define PQLO_FORMAT     16
#define PQLO_DELIMITER  20
#define PQLO_FLAGS      24
#define PQLO_SIZE       32

// ---- struct pq_query_opts (32 bytes)
#define PQQO_THREADS    0
#define PQQO_TIMEOUT_MS 8
#define PQQO_MAX_ROWS   16
#define PQQO_MODE       24
#define PQQO_SIZE       32

// ---- struct pq_column (32 bytes)
#define PQC_NAME        0
#define PQC_TYPE_NAME   8
#define PQC_TYPE        16
#define PQC_PRECISION   20
#define PQC_SCALE       24
#define PQC_SIZE        32

// ---- struct pq_value (24 bytes)
#define PQV_V           0       // i64 / f64 / const char*
#define PQV_AUX         8       // STRING length, DECIMAL high 64 bits
#define PQV_IS_NULL     16
#define PQV_TYPE        20
#define PQV_SIZE        24

// ---- struct pq_result (32 bytes)
#define PQR_NCOLS       0
#define PQR_NROWS       8
#define PQR_COLUMNS     16
#define PQR_VALUES      24
#define PQR_SIZE        32

#endif
