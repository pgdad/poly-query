/*
 * pq.inc - shared constants, structure layouts and macros for the PolyQuery
 * x86-64 assembly engine.  Included (via the C preprocessor) by every .S file.
 *
 * Conventions
 *   - AT&T syntax, System V AMD64 ABI for every function (own and glibc).
 *   - Functions written with ENTER/LEAVE save all callee-saved registers and
 *     keep %rsp 16-byte aligned; locals live at 0..N(%rsp).
 *   - Errors never return: pq_raise / pq_raisef longjmp to the request
 *     dispatcher, which reports {"ok":false,"error":{...}}.
 *   - Comments use C syntax (the files are preprocessed by cpp).
 */
#ifndef PQ_INC
#define PQ_INC

/* ------------------------------------------------------------ type kinds */
/* packed type = kind | precision << 8 | scale << 16 */
#define T_NULL   0
#define T_BOOL   1
#define T_INT    2
#define T_FLOAT  3
#define T_DEC    4
#define T_STR    5
#define T_DATE   6
#define T_TS     7

#define MKDEC(p, s) (T_DEC | ((p) << 8) | ((s) << 16))

/* ----------------------------------------------------------- error codes */
#define E_PARSE_ERROR          1
#define E_SEMANTIC_ERROR       2
#define E_TYPE_ERROR           3
#define E_NUMERIC_OVERFLOW     4
#define E_DIVISION_BY_ZERO     5
#define E_CONVERSION_ERROR     6
#define E_INVALID_ARGUMENT     7
#define E_SUBQUERY_CARDINALITY 8
#define E_INVALID_REQUEST      9
#define E_INGEST_ERROR         10
#define E_UNSUPPORTED          11
#define E_ACCESS_DENIED        12
#define E_NOT_FOUND            13
#define E_ALREADY_EXISTS       14
#define E_CANCELLED            15
#define E_RESOURCE_LIMIT       16
#define E_IO_ERROR             17
#define E_STORAGE_CORRUPT      18
#define E_STORAGE_VERSION      19
#define E_INTERNAL_ERROR       20
#define E_OVERLOADED           21
#define E_SHUTTING_DOWN        22
#define E_TIMEOUT              23

/* ------------------------------------------------------------ Arena */
#define AR_CUR     0
#define AR_END     8
#define AR_CHUNKS  16
#define AR_TOTAL   24
#define AR_LIMIT   32      /* 0 = unlimited; else RESOURCE_LIMIT when exceeded */
#define ARENA_SIZE 40

/* ------------------------------------------------------------ Buf (malloc-backed byte buffer) */
#define BUF_DATA 0
#define BUF_LEN  8
#define BUF_CAP  16
#define BUF_SIZE 24

/* ------------------------------------------------------------ Vec (arena-backed u64 vector) */
#define VEC_DATA  0
#define VEC_LEN   8
#define VEC_CAP   16
#define VEC_ARENA 24
#define VEC_SIZE  32

/* ------------------------------------------------------------ pstr
 * Length-prefixed string: u64 len, then len bytes, then a NUL byte. */
#define PSTR_LEN  0
#define PSTR_DATA 8

/* ------------------------------------------------------------ JSON DOM node (32 bytes) */
#define J_NULL   0
#define J_FALSE  1
#define J_TRUE   2
#define J_NUMBER 3
#define J_STRING 4
#define J_ARRAY  5
#define J_OBJECT 6

#define JN_TYPE  0     /* u64: J_* */
#define JN_PTR   8     /* string: decoded bytes; number: raw text; array: node*[]; object: member[] */
#define JN_LEN   16    /* byte length / element count */
#define JN_FLAGS 24    /* number: bit0 = has '.', 'e' or 'E' */
#define JN_SIZE  32

/* object member (24 bytes) */
#define JM_KEY    0    /* decoded key bytes (NUL terminated) */
#define JM_KEYLEN 8
#define JM_VAL    16   /* node* */
#define JM_SIZE   24

/* ------------------------------------------------------------ Table / Column */
#define TB_NAME    0     /* pstr* */
#define TB_NCOLS   8
#define TB_NROWS   16
#define TB_COLS    24    /* Column[ncols] */
#define TB_ARENA   32    /* owning Arena* */
#define TB_LAYOUT  40    /* LAYOUT_COLUMN / LAYOUT_ROW (physical representation) */
#define TB_ROWS    48    /* row layout: row-major block of nrows * TB_ROWW bytes */
#define TB_ROWW    56    /* row layout: bytes per row tuple */
#define TB_STATS   64    /* ColStats[ncols] (computed lazily) or 0 */
#define TB_INDEXES 72    /* Vec* of Index* (malloc'd, see index.S) or 0 */
#define TB_NRG     80    /* PQCF-backed: number of row groups (0 otherwise) */
#define TB_RGS     88    /* PQCF-backed: RowGroup[nrg] */
#define TB_MAP     96    /* lazily decoded PQCF file: its mapping, or 0 */
#define TB_MAPLEN  104
#define TB_DICTMODE 112  /* DICT_* requested at load / open */
#define TB_SIZE    120

#define LAYOUT_COLUMN 0
#define LAYOUT_ROW    1

/* PQCF save encodings (save option "encoding") */
#define ENC_AUTO  0
#define ENC_PLAIN 1
#define ENC_DICT  2
#define ENC_RLE   3

/* pqcf_read modes */
#define PQ_READ       0
#define PQ_MMAP_EAGER 1
#define PQ_MMAP_LAZY  2

/* dictionary encoding of STRING columns (table_finalize) */
#define DICT_AUTO 0
#define DICT_ON   1
#define DICT_OFF  2

/* Column.  Ingestion first fills the *staging* form: COL_DATA u64[nrows]
 * and COL_NULLS u8[nrows] (1 = NULL).  table_finalize (table.S) then turns
 * it into the physical layout, after which values are read only through
 * the accessor fields:
 *   value of row i : at COL_DATA + i * COL_STRIDE: a u64 slot
 *                    (BOOL 0/1, INT i64, FLOAT f64 bits, DEC unscaled i64,
 *                    STR pstr*, DATE days, TS micros), or with COL_DICT != 0
 *                    a u32 dictionary code (STRING columns, column layout)
 *   NULL flag      : bit (i * COL_NSTRIDE + COL_NBIT) of the bitmap at
 *                    COL_NULLS (1 = NULL); COL_NULLS = 0 means no NULLs.
 * Column layout: dense vectors (stride 8 or 4, one null bitmap per column).
 * Row layout: COL_DATA points into the row tuples (stride = row width), the
 * null bits of a row follow its value slots. */
#define COL_NAME    0    /* pstr* */
#define COL_TYPE    8    /* packed type */
#define COL_DATA    16
#define COL_NULLS   24
#define COL_STRIDE  32   /* bytes from one row's value to the next */
#define COL_NSTRIDE 40   /* bits from one row's NULL flag to the next */
#define COL_NBIT    48   /* bit offset of row 0's NULL flag */
#define COL_DICT    56   /* pstr*[] dictionary or 0 */
#define COL_TABLE   64   /* owning Table* (lazily decoded columns) */
#define COL_INDEX   72   /* column number (lazily decoded columns) */
#define COL_LAZY    80   /* u8: 1 = PQCF chunks not decoded yet (col_get loads) */
#define COL_SIZE    128
#define COL_SHIFT   7

/* per-column statistics (TB_STATS) */
#define CST_NULLS    0
#define CST_DISTINCT 8
#define CST_HAS      16   /* 1 if there is a non-null value */
#define CST_MIN      24
#define CST_MAX      32
#define CST_DONE     40   /* 1 = computed */
#define CST_SIZE     48

/* PQCF row group (TB_RGS): first row, row count, then per column
 * RGC entries with the chunk's min/max (when known). */
#define RG_START 0
#define RG_N     8
#define RG_COLS  16       /* RGC[ncols] */
#define RG_SIZE  24
#define RGC_HAS  0        /* 1 = min/max known */
#define RGC_MIN  8
#define RGC_MAX  16
#define RGC_NULLS 24
#define RGC_OFF  32       /* chunk byte range, checksum and encoding */
#define RGC_LEN  40
#define RGC_CRC  48
#define RGC_ENC  56
#define RGC_SIZE 64

/* ------------------------------------------------------------ Index (index.S)
 * Each index owns an arena (freed by DROP INDEX / table drop). */
#define IX_NAME  0     /* pstr* */
#define IX_TABLE 8     /* Table* */
#define IX_COL   16    /* column index */
#define IX_KIND  24    /* IXK_HASH / IXK_BTREE */
#define IX_ARENA 32
#define IX_TYPE  40    /* packed column type */
#define IX_N     48    /* non-NULL entries */
#define IX_ROWS  56    /* BTREE: u64 row ids sorted by (value, row) */
#define IX_KEYS  64    /* BTREE: u64 values in the same order */
#define IX_NB    72    /* HASH: bucket count (power of two) */
#define IX_HEADS 80    /* HASH: i64 first row per bucket (-1 = empty) */
#define IX_NEXT  88    /* HASH: i64 next row in the chain, per row */
#define IX_SIZE  96

#define IXK_HASH  1
#define IXK_BTREE 2

/* idx_range flags */
#define RF_LO  1       /* lower bound present */
#define RF_LOI 2       /* lower bound inclusive */
#define RF_HI  4
#define RF_HII 8

/* ------------------------------------------------------------ Schema (explicit load schema) */
#define SC_NCOLS 0
#define SC_COLS  8     /* pointer to entries of 16 bytes: pstr* name, u64 packed type */
#define SCE_NAME 0
#define SCE_TYPE 8
#define SCE_SIZE 16

/* ------------------------------------------------------------ macros */
.macro FUNC name
    .globl \name
    .type \name, @function
    .p2align 4
\name:
.endm

.macro ENDF name
    .size \name, .-\name
.endm

/* Standard frame: saves rbp, rbx, r12-r15; reserves `locals` bytes at (%rsp). */
.macro ENTER locals=0
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $((((\locals) + 15) & ~15) + 8), %rsp
.endm

.macro LEAVE
    lea -40(%rbp), %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.endm

/* CR-6 stack guard: raise RESOURCE_LIMIT (stack_exhausted, util.S) when the
 * stack pointer is below the calling thread's safe limit t_stack_lo.  Used at
 * the entry of every recursive tree walker; a thread whose limit was never
 * set (t_stack_lo = 0) always passes. */
.macro STACK_CHECK
    cmp %fs:t_stack_lo@tpoff, %rsp
    jb stack_exhausted
.endm

/* raise error with a constant message: RAISE E_CODE, "text" */
.macro RAISE code, msg
    .pushsection .rodata.str1.1, "aMS", @progbits, 1
9876:
    .asciz "\msg"
    .popsection
    mov $\code, %edi
    lea 9876b(%rip), %rsi
    call pq_raise
.endm

/* lea of an inline constant C string: CSTR reg, "text" */
.macro CSTR reg, msg
    .pushsection .rodata.str1.1, "aMS", @progbits, 1
9875:
    .asciz "\msg"
    .popsection
    lea 9875b(%rip), \reg
.endm

/* append inline constant C string to buffer pointer in reg: PUTS bufreg, "text" */
.macro PUTS buf, msg
    .pushsection .rodata.str1.1, "aMS", @progbits, 1
9874:
    .asciz "\msg"
    .popsection
    mov \buf, %rdi
    lea 9874b(%rip), %rsi
    call buf_puts
.endm

#endif
