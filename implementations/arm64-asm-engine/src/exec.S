// =============================================================================
// exec.S — query executor for bound single-table queries.
//
// Pipeline (semantics.md §4):
//   scan + filter   -> selection vector (u32 row ids)
//   aggregate       -> one row (if BQ_ISAGG)          | project -> matrix rows
//   sort (ORDER BY) -> row pointer permutation (qsort_r)
//   offset / limit  -> slice of the row pointer array
// A matrix row holds BQ_NOUT visible cells followed by BQ_NEXTRA hidden cells
// (ORDER BY keys); each cell is 16 bytes: payload, isnull.
// Without ORDER BY, OFFSET/LIMIT are applied to the selection before
// projection so that only the needed rows are evaluated.
// =============================================================================
#include "pq.inc"

#define DEADLINE_MASK 4095          // check the timeout every 4096 rows

// Sort key descriptor used by the comparator (24 bytes)
#define SK_OFF    0                 // byte offset of the cell in the row
#define SK_TYPE   8                 // u32 type
#define SK_DESC   12                // u32
#define SK_NFIRST 16                // u32
#define SK_SIZE   24

    .text

// project_row(x0 BoundQuery*, x1 EvalCtx*, x2 dest cells)
// Evaluates the visible and hidden expressions of one result row.
LFUNC project_row
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  x22, [x19, #BQ_OUT]
    ldr  x23, [x19, #BQ_NOUT]
1:  cbz  x23, 2f
    ldr  x0, [x22, #OC_EXPR]
    mov  x1, x20
    bl   eval
    stp  x0, x1, [x21], #16
    add  x22, x22, #OC_SIZE
    sub  x23, x23, #1
    b    1b
2:  ldr  x22, [x19, #BQ_EXTRA]
    ldr  x23, [x19, #BQ_NEXTRA]
3:  cbz  x23, 4f
    ldr  x0, [x22], #8
    mov  x1, x20
    bl   eval
    stp  x0, x1, [x21], #16
    sub  x23, x23, #1
    b    3b
4:  ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF project_row

// cmp_rows(x0 Row**, x1 Row**, x2 keys) -> w0   (qsort_r comparator)
// keys: [0] u64 count, then SK_SIZE descriptors.
LFUNC cmp_rows
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    ldr  x19, [x0]                  // row a
    ldr  x20, [x1]                  // row b
    ldr  x21, [x2]                  // key count
    add  x22, x2, #8                // descriptor
1:  cbz  x21, 8f
    ldr  x3, [x22, #SK_OFF]
    add  x4, x19, x3
    add  x5, x20, x3
    ldr  x6, [x4, #8]               // a null?
    ldr  x7, [x5, #8]               // b null?
    cbz  x6, 3f
    cbnz x7, 7f                     // both NULL: equal on this key
    ldr  w0, [x22, #SK_NFIRST]      // a NULL, b not
    cmp  w0, #0
    mov  w0, #1
    csneg w0, w0, w0, eq            // nfirst ? -1 : 1
    b    9f
3:  cbz  x7, 4f
    ldr  w0, [x22, #SK_NFIRST]      // b NULL, a not
    cmp  w0, #0
    mov  w0, #-1
    csneg w0, w0, w0, eq            // nfirst ? 1 : -1
    b    9f
4:  ldr  x0, [x4]
    ldr  x1, [x5]
    ldr  w2, [x22, #SK_TYPE]
    and  w23, w2, #T_KIND_MASK
    cmp  w23, #T_INT                // fast path for integer-like kinds
    b.eq 5f
    cmp  w23, #T_DATE
    b.eq 5f
    cmp  w23, #T_TS
    b.eq 5f
    cmp  w23, #T_DEC
    b.eq 5f
    bl   value_cmp
    b    6f
5:  cmp  x0, x1
    cset w0, gt
    csinv w0, w0, wzr, ge
6:  cbz  w0, 7f
    ldr  w1, [x22, #SK_DESC]
    cbz  w1, 9f
    neg  w0, w0
    b    9f
7:  add  x22, x22, #SK_SIZE
    sub  x21, x21, #1
    b    1b
8:  mov  w0, #0
9:  ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF cmp_rows

// cell_type(x0 BoundQuery*, x1 cell index) -> w0 type
LFUNC cell_type
    ldr  x2, [x0, #BQ_NOUT]
    cmp  x1, x2
    b.hs 1f
    ldr  x3, [x0, #BQ_OUT]
    mov  x4, #OC_SIZE
    madd x3, x1, x4, x3
    ldr  w0, [x3, #OC_TYPE]
    ret
1:  sub  x1, x1, x2
    ldr  x3, [x0, #BQ_EXTRA]
    ldr  x3, [x3, x1, lsl #3]
    ldr  w0, [x3, #N_TYPE]
    ret
ENDF cell_type

// sort_rows(x0 BoundQuery*, x1 Row** rows, x2 count)
LFUNC sort_rows
    stp  x29, x30, [sp, #-64]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    cmp  x21, #2
    b.lo 9f
    ldr  x22, [x19, #BQ_NORDER]
    mov  x0, #SK_SIZE
    mul  x0, x22, x0
    add  x0, x0, #8
    bl   arena_alloc
    mov  x23, x0
    str  x22, [x23]
    add  x24, x23, #8               // descriptor cursor
    ldr  x9, [x19, #BQ_ORDER]
    stp  x9, xzr, [sp, #-16]!
1:  cbz  x22, 2f
    ldr  x9, [sp]
    ldr  x1, [x9, #OK_CELL]
    lsl  x2, x1, #4
    str  x2, [x24, #SK_OFF]
    mov  x0, x19
    bl   cell_type
    str  w0, [x24, #SK_TYPE]
    ldr  x9, [sp]
    ldr  w1, [x9, #OK_DESC]
    str  w1, [x24, #SK_DESC]
    ldr  w1, [x9, #OK_NFIRST]
    str  w1, [x24, #SK_NFIRST]
    add  x9, x9, #OK_SIZE
    str  x9, [sp]
    add  x24, x24, #SK_SIZE
    sub  x22, x22, #1
    b    1b
2:  add  sp, sp, #16
    mov  x0, x20
    mov  x1, x21
    mov  x2, #8
    ADR_L x3, cmp_rows
    mov  x4, x23
    bl   qsort_r
9:  ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x29, x30, [sp], #64
    ret
ENDF sort_rows

// exec_query(x0 BoundQuery*) -> x0 ResultSet*
// x19 bq, x20 row width in bytes, x21 table, x22 selection, x23 nsel,
// x24 ctx pointer, x25 rows array, x26 row count, x27/x28 scratch
FUNC exec_query
    stp  x29, x30, [sp, #-128]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, x28, [sp, #80]
    add  x24, sp, #96               // EvalCtx (32 bytes)
    stp  xzr, xzr, [x24]
    stp  xzr, xzr, [x24, #16]
    mov  x19, x0
    ldr  x0, [x19, #BQ_NOUT]
    ldr  x1, [x19, #BQ_NEXTRA]
    add  x0, x0, x1
    lsl  x20, x0, #4
    ldr  x21, [x19, #BQ_TABLE]
    str  x21, [x24, #EC_TABLE]
    // ---- scan + filter
    mov  x27, #1                    // input row count (1 virtual row w/o FROM)
    cbz  x21, 1f
    ldr  x27, [x21, #TBL_NROWS]
1:  lsl  x0, x27, #2
    add  x0, x0, #16
    bl   arena_alloc
    mov  x22, x0
    mov  x23, #0
    mov  x28, #0                    // row id
2:  cmp  x28, x27
    b.hs 4f
    tst  x28, #DEADLINE_MASK
    b.ne 21f
    bl   check_deadline
21: ldr  x0, [x19, #BQ_WHERE]
    cbz  x0, 3f
    str  x28, [x24, #EC_ROW]
    mov  x1, x24
    bl   eval
    cbnz x1, 31f                    // NULL => not selected
    cbz  x0, 31f                    // FALSE
3:  str  w28, [x22, x23, lsl #2]
    add  x23, x23, #1
31: add  x28, x28, #1
    b    2b
4:  ldr  x0, [x19, #BQ_ISAGG]
    cbz  x0, 6f
    // ---- whole-table aggregation: one output row
    mov  x0, x19
    bl   agg_init
    mov  x25, x0                    // state
    mov  x28, #0
5:  cmp  x28, x23
    b.hs 51f
    tst  x28, #DEADLINE_MASK
    b.ne 52f
    bl   check_deadline
52: ldr  w0, [x22, x28, lsl #2]
    str  x0, [x24, #EC_ROW]
    mov  x0, x19
    mov  x1, x25
    mov  x2, x24
    bl   agg_step
    add  x28, x28, #1
    b    5b
51: mov  x0, x19
    mov  x1, x25
    bl   agg_finish
    str  x0, [x24, #EC_AGGV]
    str  xzr, [x24, #EC_ROW]
    mov  x0, x20
    bl   arena_alloc
    mov  x27, x0                    // row cells
    mov  x0, #16
    bl   arena_alloc
    mov  x25, x0
    str  x27, [x25]
    mov  x26, #1
    mov  x0, x19
    mov  x1, x24
    mov  x2, x27
    bl   project_row
    b    8f
6:  // ---- projection; without ORDER BY slice the selection first
    ldr  x0, [x19, #BQ_NORDER]
    cbnz x0, 61f
    ldr  x0, [x19, #BQ_OFFSET]
    cmp  x0, x23
    csel x0, x0, x23, lo            // start = min(offset, nsel)
    add  x22, x22, x0, lsl #2
    sub  x23, x23, x0
    ldr  x1, [x19, #BQ_LIMIT]
    tbnz x1, #63, 61f
    cmp  x1, x23
    csel x23, x1, x23, lo
61: mov  x26, x23
    lsl  x0, x26, #3
    add  x0, x0, #16
    bl   arena_alloc
    mov  x25, x0
    mul  x0, x26, x20
    add  x0, x0, #16
    bl   arena_alloc
    mov  x27, x0                    // matrix
    mov  x28, #0
7:  cmp  x28, x26
    b.hs 71f
    tst  x28, #DEADLINE_MASK
    b.ne 72f
    bl   check_deadline
72: ldr  w0, [x22, x28, lsl #2]
    str  x0, [x24, #EC_ROW]
    str  x27, [x25, x28, lsl #3]
    mov  x0, x19
    mov  x1, x24
    mov  x2, x27
    bl   project_row
    add  x27, x27, x20
    add  x28, x28, #1
    b    7b
71: ldr  x0, [x19, #BQ_NORDER]
    cbz  x0, 9f                     // already sliced
8:  // ---- sort, then offset / limit
    mov  x0, x19
    mov  x1, x25
    mov  x2, x26
    bl   sort_rows
    ldr  x0, [x19, #BQ_OFFSET]
    cmp  x0, x26
    csel x0, x0, x26, lo
    add  x25, x25, x0, lsl #3
    sub  x26, x26, x0
    ldr  x1, [x19, #BQ_LIMIT]
    tbnz x1, #63, 9f
    cmp  x1, x26
    csel x26, x1, x26, lo
9:  mov  x0, #RS_SIZE
    bl   arena_alloc
    lsr  x1, x20, #4
    str  x1, [x0, #RS_WIDTH]
    str  x26, [x0, #RS_NROWS]
    str  x25, [x0, #RS_ROWS]
    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x25, x26, [sp, #64]
    ldp  x27, x28, [sp, #80]
    ldp  x29, x30, [sp], #128
    ret
ENDF exec_query

    NOTE_GNU_STACK
