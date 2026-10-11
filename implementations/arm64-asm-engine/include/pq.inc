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
// Column (32 bytes). Column data is columnar: one u64 payload per row plus
// one null flag byte per row (1 = NULL).
#define COL_NAME   0       // Str*
#define COL_TYPE   8       // u32 type
#define COL_DATA   16      // u64* payloads [nrows]
#define COL_NULLS  24      // u8*  null flags [nrows]
#define COL_SIZE   32

// Table (64 bytes + embedded arena). All table memory (columns, strings)
// lives in the table's own arena, freed by table_free.
#define TBL_NAME   0       // Str* (allocated in the table arena)
#define TBL_NCOLS  8       // u64
#define TBL_NROWS  16      // u64
#define TBL_COLS   24      // Column* [ncols]
#define TBL_ARENA  32      // embedded Arena (AR_SIZE bytes)
#define TBL_SIZE   64

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
#define Q_SIZE      128

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
// Produced by bind_query, consumed by exec_query.
// The executor evaluates, per result row, a "matrix row" of width
// BQ_NOUT + BQ_NEXTRA cells: first the visible output expressions, then the
// hidden extra expressions (ORDER BY keys that are not output columns).
// Cells are 16 bytes: [0] payload u64, [8] isnull u64.
#define BQ_TABLE    0      // Table* or 0 (SELECT without FROM)
#define BQ_NOUT     8      // u64 number of output columns
#define BQ_OUT      16     // OutCol* array
#define BQ_WHERE    24     // Node* or 0 (evaluated in row context)
#define BQ_ISAGG    32     // u64 1 if aggregated query (single group)
#define BQ_NAGG     40     // u64 number of aggregate slots
#define BQ_AGGS     48     // Node** NK_AGG nodes indexed by slot
#define BQ_NORDER   56     // u64
#define BQ_ORDER    64     // OrderKey* array
#define BQ_LIMIT    72     // i64, -1 = no limit
#define BQ_OFFSET   80     // i64 >= 0
#define BQ_NEXTRA   88     // u64
#define BQ_EXTRA    96     // Node** hidden expressions
#define BQ_SIZE     112

// Output column (32 bytes)
#define OC_EXPR   0        // Node* bound expression
#define OC_NAME   8        // Str* output name
#define OC_TYPE   16       // u32 type (T_NULL is reported as STRING)
#define OC_SIZE   32

// Order key (16 bytes)
#define OK_CELL   0        // u64 index of the matrix cell holding the key
#define OK_DESC   8        // u32 1 = descending
#define OK_NFIRST 12       // u32 1 = NULLs sort first
#define OK_SIZE   16

// Evaluation context (32 bytes) passed to eval
#define EC_TABLE   0       // Table* (or 0)
#define EC_ROW     8       // u64 row index
#define EC_AGGV    16      // cell array of aggregate results (16 bytes per slot) or 0
#define EC_SIZE    32

// Result set produced by exec_query (rows already sorted, offset/limit applied)
#define RS_WIDTH   0       // u64 cells per row (nout + nextra)
#define RS_NROWS   8       // u64
#define RS_ROWS    16      // u8** array of row pointers (each width*16 bytes)
#define RS_SIZE    32

#endif
