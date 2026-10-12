// =============================================================================
// pq.inc — shared definitions for the PolyQuery AArch64 engine.
//
// Every module includes this file. It defines:
//   * function definition macros
//   * error codes
//   * the type encoding
//   * runtime structures (arena, buffer, string object)
//   * catalog structures (table, column, schema)
//   * JSON DOM nodes
//   * SQL AST (expression nodes, query structures, statements)
//   * bound-query structure produced by the binder and consumed by the executor
//
// Conventions (AAPCS64 everywhere):
//   * all functions keep a frame record (x29/x30) and 16-byte stack alignment
//   * errors are raised with pq_raise* which longjmp()s back to the request
//     dispatcher; they never return. All per-request memory comes from the
//     request arena (g_arena) which is reset after each request, so raising
//     an error never leaks.
//   * a runtime SQL value is the pair (payload:u64 in x0, isnull:0/1 in x1).
//     Its type is known statically from the AST (N_TYPE).
// =============================================================================

#ifndef PQ_INC
#define PQ_INC

// ---------------------------------------------------------------- macros -----
.macro FUNC name
    .text
    .global \name
    .type \name, %function
    .p2align 2
\name:
.endm

.macro LFUNC name
    .text
    .type \name, %function
    .p2align 2
\name:
.endm

.macro ENDF name
    .size \name, .-\name
.endm

// Load the address of a symbol (PC relative, works in PIE).
.macro ADR_L reg, sym
    adrp \reg, \sym
    add  \reg, \reg, :lo12:\sym
.endm

// Load a 64-bit global / 32-bit global.
.macro LDR_G reg, sym
    adrp \reg, \sym
    ldr  \reg, [\reg, :lo12:\sym]
.endm

// Thread-local variables (serve mode runs requests on several threads).
// They live in .tbss/.tdata and are reached with the local-exec TLS model
// (all objects are linked into the one executable).
//   TLS_ADDR xN, sym    address of this thread's copy of sym
//   TLS_LDR  xN, sym    64-bit load of sym
.macro TLS_ADDR reg, sym
    mrs  \reg, tpidr_el0
    add  \reg, \reg, #:tprel_hi12:\sym, lsl #12
    add  \reg, \reg, #:tprel_lo12_nc:\sym
.endm
.macro TLS_LDR reg, sym
    TLS_ADDR \reg, \sym
    ldr  \reg, [\reg]
.endm
// Section directives for thread-local data
.macro TBSS
    .section .tbss,"awT",@nobits
.endm
.macro TDATA
    .section .tdata,"awT",@progbits
.endm

// Load the value of an external (glibc) data symbol through the GOT.
.macro GOT_LOAD reg, sym
    adrp \reg, :got:\sym
    ldr  \reg, [\reg, :got_lo12:\sym]
    ldr  \reg, [\reg]
.endm

// Raise an error with a constant message: RAISE ERR_X, "message"
.macro RAISE code, msg
    mov  w0, #\code
    adr  x1, 9997f
    b    pq_raise
9997: .asciz "\msg"
    .p2align 2
.endm

// Every object file must carry this (no executable stack).
.macro NOTE_GNU_STACK
    .section .note.GNU-stack,"",%progbits
.endm

// ----------------------------------------------------------- error codes -----
// (string names live in rt.S: err_code_name)
#define ERR_NONE                0
#define ERR_PARSE               1
#define ERR_SEMANTIC            2
#define ERR_TYPE                3
#define ERR_NUMERIC_OVERFLOW    4
#define ERR_DIVISION_BY_ZERO    5
#define ERR_CONVERSION          6
#define ERR_INVALID_ARGUMENT    7
#define ERR_INVALID_REQUEST     8
#define ERR_INGEST              9
#define ERR_UNSUPPORTED         10
#define ERR_ACCESS_DENIED       11
#define ERR_NOT_FOUND           12
#define ERR_ALREADY_EXISTS      13
#define ERR_RESOURCE_LIMIT      14
#define ERR_IO                  15
#define ERR_INTERNAL            16
#define ERR_TIMEOUT             17
#define ERR_SUBQUERY_CARDINALITY 18
#define ERR_CANCELLED           19
#define ERR_STORAGE_CORRUPT     20
#define ERR_STORAGE_VERSION     21     // STORAGE_VERSION_UNSUPPORTED
#define ERR_OVERLOADED          22
#define ERR_SHUTTING_DOWN       23
#define ERR_LAST                23

// ------------------------------------------------------------ log levels -----
#define LOG_DEBUG   0
#define LOG_INFO    1
#define LOG_WARN    2
#define LOG_ERROR   3
#define LOG_OFF     4

// ----------------------------------------------------------------- types -----
// A type is a u32:  kind | (precision << 8) | (scale << 16)
// precision/scale are only meaningful for T_DEC.
#define T_NULL      0       // the null type (literal NULL); reported as STRING
#define T_BOOL      1
#define T_INT       2
#define T_DEC       3
#define T_FLOAT     4
#define T_STR       5
#define T_DATE      6
#define T_TS        7
#define T_KIND_MASK 0xff
#define T_PREC_SHIFT  8
#define T_SCALE_SHIFT 16
// Build a decimal type constant: DEC_TYPE(p,s)
#define DEC_TYPE(p,s) (T_DEC | ((p) << 8) | ((s) << 16))

// Payload encodings:
//   BOOL  0/1          INT  i64           DEC  unscaled i64 (|v| <= 10^18-1)
//   FLOAT f64 bits     STR  Str* (see below)
//   DATE  i64 days since 1970-01-01       TS   i64 microseconds since epoch

#define MAX_DEC_UNSCALED 999999999999999999

// ------------------------------------------------------------ string obj -----
// Str: immutable byte string, NUL terminated for convenience.
//   [0] u64 len   [8] bytes[len]  [8+len] 0
#define STR_LEN   0
#define STR_DATA  8

// ----------------------------------------------------------------- arena -----
// Bump allocator over a list of malloc'ed chunks.
#define AR_CUR     0
#define AR_END     8
#define AR_CHUNKS  16      // singly linked list: chunk[0] = next, chunk[8] = size
#define AR_TOTAL   24      // total bytes of chunks (for memory budget)
#define AR_SIZE    32

// ------------------------------------------------------------------- buf -----
// Growable byte buffer (malloc/realloc backed; persistent across requests).
#define BUF_PTR   0
#define BUF_LEN   8
#define BUF_CAP   16
#define BUF_SIZE  32

// --------------------------------------------------------------- catalog -----
// Column (32 bytes). Two physical encodings (COL_ENC):
//   CENC_PLAIN  COL_DATA = u64 payload vector [nrows]
//   CENC_DICT   COL_DATA = DictCol* (STRING only): u32 codes + dictionary
// COL_NULLS is the null bitmap (LSB-first, bit i set = row i is NULL), or 0
// if the column has no NULLs. In the row layout (TBL_LAYOUT = LAYOUT_ROW)
// COL_DATA/COL_NULLS are 0 and values live in the row store.
#define COL_NAME   0       // Str*
#define COL_TYPE   8       // u32 type
#define COL_ENC    12      // u32 CENC_*
#define COL_DATA   16      // u64* payloads [nrows] or DictCol*
#define COL_NULLS  24      // u8* null bitmap or 0
#define COL_SIZE   32
#define CENC_PLAIN 0
#define CENC_DICT  1

// Dictionary-encoded STRING column
#define DC_CODES   0       // u32* codes [nrows]
#define DC_DICT    8       // Str** distinct values [ndict]
#define DC_NDICT   16      // u64
#define DC_SIZE    32

// Null bitmap helpers; all arguments are register *numbers* (9 = x9/w9).
//   NULLBIT_CLEAR base, idx, t1, t2, t3, t4   clear bit idx of bitmap base
//   NULLBIT_TEST  dst, base, idx, t1          w<dst> = bit idx (0/1)
.macro NULLBIT_CLEAR base, idx, t1, t2, t3, t4
    lsr  x\t1, x\idx, #3
    ldrb w\t2, [x\base, x\t1]
    and  w\t3, w\idx, #7
    mov  w\t4, #1
    lsl  w\t4, w\t4, w\t3
    bic  w\t2, w\t2, w\t4
    strb w\t2, [x\base, x\t1]
.endm
.macro NULLBIT_TEST dst, base, idx, t1
    lsr  x\t1, x\idx, #3
    ldrb w\dst, [x\base, x\t1]
    and  w\t1, w\idx, #7
    lsr  w\dst, w\dst, w\t1
    and  w\dst, w\dst, #1
.endm

// Table (128 bytes). All table memory (columns, strings, row store, stats)
// lives in the table's own arena, freed by table_free.
#define TBL_NAME   0       // Str* (allocated in the table arena)
#define TBL_NCOLS  8       // u64
#define TBL_NROWS  16      // u64
#define TBL_COLS   24      // Column* [ncols]
#define TBL_ARENA  32      // embedded Arena (AR_SIZE bytes)
#define TBL_LAYOUT 64      // u32 LAYOUT_COLUMN / LAYOUT_ROW
#define TBL_ROWS   72      // row layout: u8* row store [nrows * stride]
#define TBL_STRIDE 80      // row layout: bytes per row (8*ncols + bitmap, 8-aligned)
#define TBL_STATS  88      // ColStats* [ncols] (computed lazily) or 0
#define TBL_NRG    96      // u64 row groups (PQCF-backed tables) or 0
#define TBL_RGS    104     // RowGroup* [nrg]
#define TBL_REFS   112     // u64 references from catalog versions (atomic)
#define TBL_SIZE   128
#define LAYOUT_COLUMN 0
#define LAYOUT_ROW    1
// Row store: row r at TBL_ROWS + r*TBL_STRIDE holds ncols u64 payloads
// followed by a null bitmap of ceil(ncols/8) bytes (bit c set = NULL).

// Per-column statistics (32 bytes), see storage.S table_stats
#define CST_NULLS     0    // u64 null count
#define CST_DISTINCT  8    // u64 distinct non-null values
#define CST_MIN       16   // payload (valid if null count < nrows)
#define CST_MAX       24   // payload
#define CST_SIZE      32

// PQCF row group (32 bytes) and its per-chunk min/max (32 bytes per column)
#define RG_START   0       // u64 first row
#define RG_NROWS   8       // u64
#define RG_CHUNKS  16      // ChunkStat* [ncols]
#define RG_SIZE    32
#define CK_HASMM   0       // u32 1 = CK_MIN/CK_MAX valid
#define CK_MIN     8       // payload (Str* for STRING)
#define CK_MAX     16      // payload
#define CK_NULLS   24      // u64 null count
#define CK_SIZE    32

// Index (index.S). Single-column; NULLs are never indexed.
#define IX_NAME    0       // Str* (malloc'ed copy)
#define IX_TABLE   8       // Table*
#define IX_COL     16      // u64 column index
#define IX_KIND    24      // u32 IXK_*
#define IX_N       32      // u64 indexed (non-NULL) rows
#define IX_ROWS    40      // u32* row ids: BTREE sorted by value (ties by row)
#define IX_HEADS   48      // HASH: u32* bucket heads (ROW_NULL = empty)
#define IX_NEXT    56      // HASH: u32* next row in chain [nrows]
#define IX_MASK    64      // HASH: u64 bucket mask
#define IX_ARENA   72      // embedded Arena
#define IX_REFS    112     // u64 references from catalog versions (atomic)
#define IX_SIZE    128
#define IXK_HASH   1
#define IXK_BTREE  2

// Catalog version (catalog.S). The catalog is a sequence of immutable
// versions: readers pin the current version for a whole request (snapshot
// isolation); a mutation edits a private copy and publishes it atomically.
// Versions reference their tables and indexes (TBL_REFS / IX_REFS).
#define CV_REFS    0       // u64 pins (requests) + 1 while current (atomic)
#define CV_TABLES  8       // Table** (malloc)
#define CV_NT      16      // u64
#define CV_TCAP    24      // u64
#define CV_IDX     32      // Index** (malloc), creation order
#define CV_NI      40      // u64
#define CV_ICAP    48      // u64
#define CV_SIZE    64

// Index specification (from PQCF metadata), 24 bytes
#define XS_NAME    0       // Str*
#define XS_COL     8       // u64 column index
#define XS_KIND    16      // u32 IXK_*
#define XS_SIZE    24

// PQCF save encodings
#define PENC_AUTO  0
#define PENC_PLAIN 1
#define PENC_DICT  2
#define PENC_RLE   3

// Explicit schema for ingestion (allocated in the request arena).
#define SCH_N      0       // u64 number of columns
#define SCH_NAMES  8       // Str** [n]
#define SCH_TYPES  16      // u32*  [n]
#define SCH_SIZE   24

// Ingestion formats
#define FMT_CSV    0
#define FMT_JSON   1
#define FMT_JSONL  2

// -------------------------------------------------------------- JSON DOM -----
// JNode (32 bytes), allocated in the request arena by json_parse.
#define J_NULL   0
#define J_FALSE  1
#define J_TRUE   2
#define J_NUM    3
#define J_STR    4
#define J_ARR    5
#define J_OBJ    6
#define JN_TYPE   0        // u32
#define JN_COUNT  4        // u32 element count (ARR) / pair count (OBJ)
#define JN_PTR    8        // NUM: Str* raw literal text; STR: Str* decoded;
                           // ARR: JNode** [count]; OBJ: JNode** [2*count] (key,value,...)
                           //      keys are J_STR nodes
#define JN_LINE   16       // u32 1-based line where the value starts (diagnostics)
#define JN_SIZE   32

// -------------------------------------------------------------- SQL AST ------
// Expression node (64 bytes). Fields by kind are documented below.
#define N_KIND   0         // u32 NK_*
#define N_OP     4         // u32 operator / function id / negation flag
#define N_TYPE   8         // u32 static result type (set by parser for literals
                           //     and CAST, by the binder for everything)
#define N_FLAGS  12        // u32 NF_*
#define N_A      16        // ptr child 1
#define N_B      24        // ptr child 2
#define N_C      32        // ptr child 3 / argument array / qualifier / query
#define N_VAL    40        // u64 literal payload / column index / arg count
#define N_NAME   48        // Str* identifier / function name
#define N_LINE   56        // u32 1-based line of the node's first token
#define N_COL    60        // u32 1-based column
#define N_SIZE   64

// Node kinds
#define NK_LIT      1      // N_TYPE type, N_VAL payload, NF_NULL if NULL literal
#define NK_COL      2      // N_NAME column name, N_C qualifier Str* or 0
                           // bound: N_VAL column index, N_TYPE column type,
                           //        N_B = 0 (range variable index; future joins)
#define NK_UNARY    3      // N_OP OP_NEG/OP_POS/OP_NOT, N_A operand
#define NK_BINARY   4      // N_OP OP_*, N_A left, N_B right
#define NK_ISNULL   5      // N_A operand, N_OP 0 = IS NULL, 1 = IS NOT NULL
#define NK_CAST     6      // N_A operand, N_VAL target type (also N_TYPE)
#define NK_FUNC     7      // N_NAME name, N_C Node** args, N_VAL argc,
                           // NF_DISTINCT, NF_STAR (f(*)); bound: N_OP F_*
#define NK_AGG      8      // binder converts aggregate NK_FUNC into NK_AGG:
                           // N_OP F_* aggregate id, N_A argument (0 for COUNT(*)),
                           // N_B slot index (u64), NF_DISTINCT
#define NK_CASE     9      // N_A operand or 0, N_C Node** [w1,t1,w2,t2,...],
                           // N_VAL number of WHEN pairs, N_B ELSE or 0
#define NK_BETWEEN  10     // N_A x, N_B low, N_C high, N_OP 1 if NOT BETWEEN
#define NK_IN       11     // N_A x, N_C Node** list, N_VAL count, N_OP 1 if NOT IN
#define NK_INSUB    12     // N_A x, N_C Query*, N_OP 1 if NOT IN
#define NK_LIKE     13     // N_A x, N_B pattern, N_OP 1 if NOT LIKE
#define NK_EXISTS   14     // N_C Query*
#define NK_SUBQ     15     // N_C Query* (scalar subquery)
#define NK_OUTREF   16     // binder-internal: reference to output column N_VAL
#define NK_GKEY     17     // grouped context: value of GROUP BY key N_VAL
                           // (read from EC_GKEYS)

// Shapes of the *bound* nodes produced by the binder (Phase 2):
//   NK_COL     N_B rv index, N_VAL column index, N_OP outer depth (0 = this query)
//   NK_FUNC    scalar function: N_OP function id (private to functions.S),
//              N_C Node** bound args, N_VAL argc
//   NK_CASE    searched form only: N_A = 0, N_C Node** [w1,t1,...], N_VAL pairs,
//              N_B ELSE or 0 (simple CASE is rewritten to x = v comparisons)
//   NK_IN      N_A = 0, N_C Node** bound comparison nodes (x = e_i), N_VAL count,
//              N_OP 1 if NOT IN
//   NK_LIKE    N_A string, N_B pattern, N_OP 1 if NOT LIKE
//   BETWEEN    rewritten to AND / NOT nodes (no NK_BETWEEN after binding)
//   NK_SUBQ / NK_EXISTS / NK_INSUB: N_C SubPlan* (see plan.S); NK_INSUB N_A x

// Unary operators
#define OP_NEG      1
#define OP_POS      2
#define OP_NOT      3
// Binary operators
#define OP_ADD      10
#define OP_SUB      11
#define OP_MUL      12
#define OP_DIV      13
#define OP_MOD      14
#define OP_CONCAT   15
#define OP_EQ       20
#define OP_NE       21
#define OP_LT       22
#define OP_LE       23
#define OP_GT       24
#define OP_GE       25
#define OP_AND      30
#define OP_OR       31

// Node flags
#define NF_NULL      1     // literal NULL
#define NF_DISTINCT  2     // f(DISTINCT x)
#define NF_STAR      4     // f(*)
#define NF_CONST     8     // binder: expression is constant (no column refs)
#define NF_PAREN     16    // parser: expression was parenthesised

// Function ids (N_OP of bound NK_FUNC / NK_AGG)
#define F_COUNT       1
#define F_SUM         2
#define F_MIN         3
#define F_MAX         4
#define F_AVG         5
#define F_COUNT_STAR  6
#define F_PQ_SLEEP    20

// Select item (32 bytes)
#define SI_EXPR   0        // Node* (0 for * forms)
#define SI_ALIAS  8        // Str* or 0
#define SI_KIND   16       // u32: SIK_EXPR / SIK_STAR / SIK_QSTAR
#define SI_QUAL   24       // Str* qualifier for t.*
#define SI_SIZE   32
#define SIK_EXPR  0
#define SIK_STAR  1
#define SIK_QSTAR 2

// Order item (16 bytes)
#define OI_EXPR   0        // Node*
#define OI_DESC   8        // u32 1 = DESC
#define OI_NULLS  12       // u32 0 = default, 1 = NULLS FIRST, 2 = NULLS LAST
#define OI_SIZE   16

// From item (64 bytes)
#define FR_KIND     0      // u32 FRK_*
#define FR_JOIN     4      // u32 JT_* (for FRK_JOIN)
#define FR_NAME     8      // Str* table/CTE name (FRK_TABLE)
#define FR_ALIAS    16     // Str* alias or 0
#define FR_LEFT     24     // FRK_JOIN: left FromItem*;  FRK_SUBQUERY: Query*
#define FR_RIGHT    32     // FRK_JOIN: right FromItem*
#define FR_ON       40     // FRK_JOIN: ON expr or 0
#define FR_LINE     48     // u32
#define FR_COL      52     // u32
#define FR_SIZE     64
#define FRK_TABLE    1
#define FRK_SUBQUERY 2
#define FRK_JOIN     3
#define JT_INNER     1
#define JT_LEFT      2
#define JT_CROSS     3

// CTE (32 bytes)
#define CTE_NAME   0       // Str*
#define CTE_QUERY  8       // Query*
#define CTE_COLS   16      // Str** column names or 0
#define CTE_NCOLS  24      // u64
#define CTE_SIZE   32

// Query (128 bytes)
#define Q_DISTINCT  0      // u32 1 = SELECT DISTINCT
#define Q_HASFROM   4      // u32 (informational)
#define Q_ITEMS     8      // SelectItem* array (contiguous SI_SIZE records)
#define Q_NITEMS    16     // u64
#define Q_FROM      24     // FromItem* or 0
#define Q_WHERE     32     // Node* or 0
#define Q_GROUP     40     // Node** or 0
#define Q_NGROUP    48     // u64
#define Q_HAVING    56     // Node* or 0
#define Q_ORDER     64     // OrderItem* array (contiguous OI_SIZE records)
#define Q_NORDER    72     // u64
#define Q_LIMIT     80     // Node* or 0
#define Q_OFFSET    88     // Node* or 0
#define Q_CTES      96     // CTE* array (contiguous CTE_SIZE records) or 0
#define Q_NCTES     104    // u64
#define Q_LINE      112    // u32 position of SELECT
#define Q_COL       116    // u32
#define Q_UNION     120    // compound query (UNION ALL): Query** branches
                           //   (plain select cores) or 0; the compound
                           //   record itself keeps only WITH / ORDER BY /
                           //   LIMIT / OFFSET
#define Q_NUNION    128    // u64 number of branches (>= 2) or 0
#define Q_SIZE      144

// Statement (64 bytes)
#define ST_KIND     0      // u32 SK_*
#define ST_FLAGS    4      // u32: bit0 IF [NOT] EXISTS
#define ST_QUERY    8      // Query* (SK_QUERY / SK_EXPLAIN)
#define ST_INDEX    16     // Str* index name (CREATE/DROP INDEX)
#define ST_TABLE    24     // Str* table name (CREATE INDEX)
#define ST_COLUMN   32     // Str* column name (CREATE INDEX)
#define ST_USING    40     // u32 0 = default (BTREE), 1 = HASH, 2 = BTREE
#define ST_SIZE     64
#define SK_QUERY         1
#define SK_EXPLAIN       2
#define SK_CREATE_INDEX  3
#define SK_DROP_INDEX    4

// ----------------------------------------------------------- bound query -----
// Produced by bind_query (binder.S) for one query level (SELECT block incl.
// its WITH, ORDER BY, LIMIT); consumed by the planner (plan.S).
//
// Range variables: every table reference of the FROM clause gets an index
// 0..BQ_NRV-1 in FROM order. A *tuple* is an array of BQ_NRV u32 row ids, one
// per range variable (ROW_NULL = NULL-padded side of a LEFT JOIN). Column
// references are bound to (rv index, column index, outer depth).
//
// After grouping, expressions of the SELECT list, HAVING and ORDER BY are
// evaluated per group: aggregates read EC_AGGV (NK_AGG slot N_B), GROUP BY
// expressions read EC_GKEYS (NK_GKEY index N_VAL).
//
// Result rows ("matrix rows") have BQ_NOUT visible cells followed by
// BQ_NEXTRA hidden cells (ORDER BY keys that are not output columns).
// Cells are 16 bytes: [0] payload u64, [8] isnull u64.
#define BQ_NRV      0      // u64 number of range variables
#define BQ_RVS      8      // RV* array (RV_SIZE records)
#define BQ_NOUT     16     // u64 number of output columns
#define BQ_OUT      24     // OutCol* array
#define BQ_WHERE    32     // Node* or 0 (tuple context)
#define BQ_ISAGG    40     // u64 1 if aggregated query
#define BQ_NAGG     48     // u64 number of aggregate slots
#define BQ_AGGS     56     // Node** NK_AGG nodes indexed by slot
#define BQ_NORDER   64     // u64
#define BQ_ORDER    72     // OrderKey* array
#define BQ_LIMIT    80     // i64, -1 = no limit
#define BQ_OFFSET   88     // i64 >= 0
#define BQ_NEXTRA   96     // u64
#define BQ_EXTRA    104    // Node** hidden expressions
#define BQ_FROM     112    // BoundFrom* or 0 (no FROM)
#define BQ_NGROUP   120    // u64 number of GROUP BY expressions
#define BQ_GROUP    128    // Node** GROUP BY expressions (tuple context)
#define BQ_HAVING   136    // Node* or 0 (group context)
#define BQ_DISTINCT 144    // u64 1 = SELECT DISTINCT
#define BQ_CORR     152    // u64 1 = references an enclosing query (correlated)
#define BQ_SPV      160    // root query only: Vec* of every SubPlan of the
                           //   statement ([0] n, [8] cap, [16] SubPlan**)
#define BQ_UNION    168    // compound (UNION ALL): BoundQuery** branches or 0.
                           //   The compound query level has no range
                           //   variables; BQ_OUT holds the names (first
                           //   branch) and common types, BQ_ORDER /
                           //   BQ_LIMIT / BQ_OFFSET apply to the whole result
#define BQ_NUNION   176    // u64 number of branches or 0
#define BQ_SIZE     192

#define ROW_NULL    0xffffffff

// Range variable (48 bytes)
#define RV_NAME     0      // Str* alias, or table / CTE name
#define RV_TABLE    8      // Table*: catalog table, or a data-less "shape"
                           //   table (names/types) for derived tables / CTEs
#define RV_KIND     16     // u32 RVK_*
#define RV_CTEUP    20     // u32 RVK_CTE: query levels up to the CTE's owner
#define RV_SUB      24     // RVK_DERIVED: SubPlan*; RVK_CTE: CteDef*
#define RV_USED     32     // u8* per-column RVU_* flags: where the column is
                           //   referenced (column pruning)
#define RV_SIZE     48
#define RVU_LOCAL   1      // by an expression of the rv's own query level
#define RVU_OUTER   2      // from a subquery (correlated reference)
#define RVK_BASE    0
#define RVK_DERIVED 1
#define RVK_CTE     2

// Bound FROM tree (48 bytes)
#define BF_KIND     0      // u32 BFK_*
#define BF_JT       4      // u32 JT_* (BFK_JOIN)
#define BF_RV       8      // u64 rv index (BFK_RV)
#define BF_LEFT     16     // BoundFrom*
#define BF_RIGHT    24     // BoundFrom*
#define BF_ON       32     // bound ON expression or 0
#define BF_LO       40     // u32 first rv index of the subtree
#define BF_HI       44     // u32 one past the last rv index
#define BF_SIZE     48
#define BFK_RV      1
#define BFK_JOIN    2

// Subquery / derived table plan holder (48 bytes). Created by the binder
// (SP_BQ), planned by plan.S (SP_LPLAN, SP_PLAN), executed lazily by exec.S;
// results of uncorrelated subqueries are cached for the whole statement.
#define SP_BQ       0      // BoundQuery*
#define SP_PLAN     8      // PlanNode* (physical plan)
#define SP_CACHE    16     // cached result: ResultSet* / Table* / InSet*
#define SP_DONE     24     // u64 1 = SP_CACHE valid
#define SP_INTYPE   32     // u32 NK_INSUB: comparison type of the values
#define SP_LPLAN    40     // LogicalNode* (optimized logical plan)
#define SP_SIZE     48

// CTE definition (48 bytes): one per WITH entry, shared by all references.
#define CD_NAME     0      // Str*
#define CD_SP       8      // SubPlan* of the CTE query
#define CD_SHAPE    16     // Table* shape (column names after renaming)
#define CD_SIZE     48

// Output column (32 bytes)
#define OC_EXPR   0        // Node* bound expression
#define OC_NAME   8        // Str* output name
#define OC_TYPE   16       // u32 type (T_NULL is reported as STRING)
#define OC_ALIASED 20      // u32 1 = name comes from an explicit alias
#define OC_SIZE   32

// Order key (16 bytes)
#define OK_CELL   0        // u64 index of the matrix cell holding the key
#define OK_DESC   8        // u32 1 = descending
#define OK_NFIRST 12       // u32 1 = NULLs sort first
#define OK_SIZE   16

// Evaluation context (48 bytes) passed to eval. A zeroed context is valid
// for constant expressions.
#define EC_TABLES  0       // Table** per range variable (or 0)
#define EC_TUPLE   8       // u32* current tuple (row id per range variable)
#define EC_AGGV    16      // cell array of aggregate results (16 bytes per slot) or 0
#define EC_GKEYS   24      // cell array of GROUP BY key values or 0
#define EC_OUTER   32      // EvalCtx* of the enclosing query (correlation) or 0
#define EC_SIZE    48

// Aggregate state: AGG_STATE_SIZE bytes per slot (layout private to eval.S)
#define AGG_STATE_SIZE 32

// Result set (rows already sorted, offset/limit applied)
#define RS_WIDTH   0       // u64 cells per row (nout + nextra)
#define RS_NROWS   8       // u64
#define RS_ROWS    16      // u8** array of row pointers (each width*16 bytes)
#define RS_SIZE    32

// ---------------------------------------------------------- logical plan -----
// Logical plan (logical.S): relational operators, independent of any
// execution strategy. lp_build translates a bound query level; the optimizer
// rules (optimize.S, rule_*.S) rewrite it; the physical planner (physical.S)
// maps it to PlanNodes. Expressions are bound expressions (Node*). Project
// and Aggregate compute the matrix rows of their query level LN_BQ: output
// expressions BQ_OUT, hidden ORDER BY keys BQ_EXTRA, grouping keys BQ_GROUP,
// aggregate calls BQ_AGGS; Sort orders by BQ_ORDER, Limit uses BQ_LIMIT /
// BQ_OFFSET.
#define LN_OP       0      // u32 LO_*
#define LN_JT       4      // u32 JT_* (Join)
#define LN_LEFT     8      // LogicalNode* input (Join: left input)
#define LN_RIGHT    16     // LogicalNode* right input (Join)
#define LN_PRED     24     // Node* or 0: Filter predicate, Join condition,
                           //   Scan predicate (conjuncts evaluated on the
                           //   scanned range variable), Aggregate HAVING
#define LN_BQ       32     // BoundQuery* of the query level
#define LN_RV       40     // u64 Scan / SubqueryScan: range variable index
#define LN_MASK     48     // u64 Scan / SubqueryScan / Filter / Join: bitmask
                           //   of the range variables the subtree produces
#define LN_COLS     56     // Scan of a base table: u8* per-column "read" flags,
                           //   0 = every column (set by rule prune_columns)
#define LN_KIDS     64     // UnionAll: LogicalNode** branch plans
#define LN_NKIDS    72     // u64
#define LN_SIZE     80

#define LO_SCAN       1    // scan of the base table of rv LN_RV
#define LO_SUBQUERY   2    // SubqueryScan: derived table / CTE rv LN_RV (its
                           //   plan: SP_LPLAN of the rv's SubPlan)
#define LO_VALUES     3    // one empty tuple (SELECT without FROM)
#define LO_FILTER     4
#define LO_JOIN       5    // LN_JT INNER / LEFT / CROSS, condition LN_PRED
#define LO_AGGREGATE  6    // keys + aggregate calls + HAVING + projection
#define LO_PROJECT    7
#define LO_DISTINCT   8
#define LO_SORT       9
#define LO_LIMIT      10
#define LO_UNION      11   // UNION ALL of LN_KIDS (each a query level)
// Expression subqueries (scalar, IN, EXISTS) are expressions (NK_SUBQ /
// NK_INSUB / NK_EXISTS) whose SubPlan carries its own logical plan.

// ------------------------------------------------------------- plan nodes -----
// Physical plan (physical.S): operators with their execution strategy
// (access path, join algorithm and keys, build side, top-N, execution mode),
// executed by exec.S and shown by EXPLAIN. Lower operators (scans, filters,
// joins) produce tuple sets; Aggregate / Project produce result rows;
// Distinct / Sort / Limit transform result rows.
#define PN_OP       0      // u32 PO_*
#define PN_JT       4      // u32 JT_* (joins)
#define PN_LEFT     8      // PlanNode* (the only child of unary operators)
#define PN_RIGHT    16     // PlanNode* (joins)
#define PN_EXPR     24     // Node*: filter predicate / join residual / HAVING
#define PN_BQ       32     // BoundQuery* the node belongs to
#define PN_RV       40     // u64 rv index (scans)
#define PN_NKEYS    48     // u64 hash join keys
#define PN_LKEYS    56     // Node** left key expressions
#define PN_RKEYS    64     // Node** right key expressions
                           // (72: unused)
#define PN_IDX      80     // scans: Index* used by an index scan, or 0
#define PN_IXA      88     // scans: IxAccess* (index access path)
#define PN_PREDS    96     // scans: Pred** simple predicates of PN_EXPR
#define PN_NPREDS   104    // u64
#define PN_EST      112    // u64 estimated output rows (tuple operators)
#define PN_SWAP     120    // u32 1 = hash join inputs swapped (build = left)
#define PN_RGSKIP   124    // u32 scans: row groups skipped (EXPLAIN)
#define PN_MASK     128    // u64 scans / joins: bitmask of the range variables
                           //   of the subtree
#define PN_COLS     136    // base-table scans: u8* per-column flags of the
                           //   columns read (EXPLAIN "columns")
#define PN_TOPN     144    // u32 Sort below a Limit: bounded top-N heap
#define PN_XMODE    148    // u32 plan roots: execution mode XM_ROW / XM_VEC
#define PN_XTHREADS 152    // u64 plan roots: worker threads (>= 1)
#define PN_SIZE     160

// Simple predicate "column op constant" extracted from a scan filter
// (index selection, row-group skipping, estimates). 48 bytes.
#define PR_COL      0      // u64 column index
#define PR_OP       8      // u32 OP_EQ/LT/LE/GT/GE or PRO_IN
#define PR_TYPE     12     // u32 type of the constant(s)
#define PR_VAL      16     // payload; PRO_IN: u64* payloads
#define PR_N        24     // u64 number of values (PRO_IN), else 1
#define PR_NULL     32     // u32 1 = the constant is NULL (never true)
#define PR_SIZE     48
#define PRO_IN      40

// Index access path of an IndexScan (32 bytes)
#define IA_KIND     0      // u32 IAK_EQ (PR_OP EQ / IN) or IAK_RANGE
#define IA_EQ       8      // Pred* (IAK_EQ)
#define IA_LO       16     // Pred* lower bound (GT/GE) or 0
#define IA_HI       24     // Pred* upper bound (LT/LE) or 0
#define IA_SIZE     32
#define IAK_EQ      1
#define IAK_RANGE   2

#define PO_SCAN       1    // table scan of rv PN_RV (base / derived / CTE),
                           //   optional pushed-down filter PN_EXPR
#define PO_VALUES     2    // one empty tuple (SELECT without FROM)
#define PO_FILTER     3    // tuple filter PN_EXPR
#define PO_JOIN       4    // join before the algorithm is chosen (physical.S)
#define PO_HASHJOIN   5    // physical: equi keys + residual PN_EXPR
#define PO_NLJOIN     6    // physical: nested loop, condition PN_EXPR
#define PO_AGGREGATE  7    // grouping + aggregates + HAVING (PN_EXPR) + projection
#define PO_PROJECT    8    // projection of the output (and hidden) columns
#define PO_DISTINCT   9
#define PO_SORT       10
#define PO_LIMIT      11
#define PO_MERGEJOIN  12   // physical: sort-merge on the equi keys + residual
#define PO_UNION      13   // UNION ALL: concatenates the result rows of the
                           //   branch plans PN_KIDS[0..PN_NKIDS) (EXPLAIN
                           //   "UnionAll")
// PO_UNION reuses the join key fields for its children
#define PN_NKIDS    PN_NKEYS
#define PN_KIDS     PN_LKEYS

// Execution options of the current request (Phase 5, protocol.md §5.2),
// thread-local planner inputs defined in plan.S (set by protocol.S):
//   g_opt_mode (u32 XM_*), g_opt_join (u32 XJ_*), g_opt_threads (u64 >= 1),
//   g_opt_optimize (u32 0/1); access.S g_use_indexes. g_def_threads
//   (process-wide, --threads). The physical planner resolves them into the
//   plan (PN_XMODE / PN_XTHREADS, join operators, PN_TOPN); the executor runs
//   with the plan's settings (exec.S g_x_mode / g_x_threads).
#define XM_AUTO     0
#define XM_ROW      1
#define XM_VEC      2
#define XJ_AUTO     0
#define XJ_HASH     1
#define XJ_MERGE    2
#define XJ_NL       3
#define MAX_THREADS 64

// ----------------------------------------------------- vectorized execution --
// (vexec.S) Expressions are evaluated for a batch of up to VBATCH tuples at a
// time. A Vec holds one payload and one NULL byte per batch position; a
// selection vector (u16 positions) lists the positions to evaluate.
#define VBATCH      1024
#define VEC_VALS    0              // u64 [VBATCH]
#define VEC_NULLS   8192           // u8  [VBATCH]
#define VEC_SIZE    9216
// Batch context (one per thread)
#define VB_TUP      0              // u32* tuples of the batch (stride VB_W)
#define VB_W        8              // u64 tuple width (u32 row ids)
#define VB_N        16             // u64 tuples in the batch
#define VB_EC       24             // EvalCtx* (EC_TABLES; EC_TUPLE set for
                                   //   row-at-a-time fallbacks)
#define VB_POOL     32             // Vec** scratch vectors [VPOOL_MAX]
#define VB_POOLN    40             // u64 vectors in use (stack discipline)
#define VB_DCACHE   48             // dictionary truth tables (vexec.S)
#define VB_SIZE     64
#define VPOOL_MAX   64
#define VKEY_MAX    32             // most keys evaluated as vectors at once
// Join key task (vexec.S vkey_cells)
#define VK_TS       0              // TupleSet*
#define VK_KEYS     8              // Node** key expressions
#define VK_NKEYS    16
#define VK_CTX      24             // EvalCtx* (own copy for worker tasks)
#define VK_CELLS    32             // out: nkeys cells per tuple
#define VK_HASH     40             // out: u64 hash per tuple
#define VK_FLAGS    48             // out: u8 1 = a key is NULL
#define VK_LO       56             // tuples [lo, hi)
#define VK_HI       64
#define VK_SIZE     80

// Rows per batch handed to a streaming sink (exec_plan_stream)
#define EXEC_STREAM_BATCH 1000

// Tuple set produced by the lower operators
#define TS_N        0      // u64 number of tuples
#define TS_W        8      // u64 tuple width (BQ_NRV)
#define TS_DATA     16     // u32* tuples [n * w]
#define TS_CAP      24     // u64 capacity in tuples (growable sets)
#define TS_SIZE     32

#endif
