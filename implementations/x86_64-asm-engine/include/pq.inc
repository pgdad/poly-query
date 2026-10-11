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
#define TB_NAME  0     /* pstr* */
#define TB_NCOLS 8
#define TB_NROWS 16
#define TB_COLS  24    /* Column[ncols] */
#define TB_ARENA 32    /* owning Arena* */
#define TB_SIZE  48

/* column values: one u64 slot per row
 *   BOOL 0/1, INT i64, FLOAT f64 bits, DEC unscaled i64, STR pstr*,
 *   DATE i64 days since 1970-01-01, TS i64 microseconds since epoch.
 * null rows: nulls[i] = 1 and data[i] = 0 */
#define COL_NAME  0    /* pstr* */
#define COL_TYPE  8    /* packed type */
#define COL_DATA  16   /* u64[nrows] */
#define COL_NULLS 24   /* u8[nrows], 1 = NULL */
#define COL_SIZE  32

/* ------------------------------------------------------------ Schema (explicit load schema) */
#define SC_NCOLS 0
#define SC_COLS  8     /* entries of 16 bytes: pstr* name, u64 packed type */
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
