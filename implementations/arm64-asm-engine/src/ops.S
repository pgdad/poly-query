// =============================================================================
// ops.S — Filter and Project operators over tuple sets, in both execution
// modes and in parallel (Phase 5).
//
//   ex_filter(x0 Filter PlanNode*, x1 ctx) -> x0 TupleSet*
//   project_rows(x0 Project PlanNode*, x1 ctx, x2 TupleSet*, x3 first
//                tuple, x4 count, x5 ResultSet* (RS_ROWS sized), x6 cells)
//       projects tuples [first, first + count) into result rows 0..count-1
//       (row i = cells + i * RS_WIDTH * 16)
//
// The input tuples are cut into contiguous windows, one per task (option
// threads, at most one task per g_par_min_rows tuples, only when every
// expression is safe for worker threads). A task works row at a time (mode
// "row": eval per tuple) or in batches of VBATCH tuples read in place from
// the tuple set (vfilter / veval per output column, results scattered into
// the row cells). Filter outputs are concatenated in task order; projection
// tasks write disjoint rows of the result. Either way the result does not
// depend on the mode or the number of threads.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define DEADLINE_MASK 4095

// Tuple-window task
#define OT_NODE     0               // PlanNode*
#define OT_CTX      8               // EvalCtx* (own copy for worker tasks)
#define OT_TS       16              // filter: output TupleSet (ts_concat)
#define OT_IN       24              // input TupleSet*
#define OT_LO       32              // window [lo, hi): filter input tuples /
#define OT_HI       40              //   projection result rows
#define OT_RS       48              // projection: ResultSet*
#define OT_CELLS    56              // projection: cells of result row 0
#define OT_FIRST    64              // projection: input tuple of row 0
#define OT_SIZE     80

    .text

// =============================================================================
// ot_split(x0 template task, x1 total, w2 parallel allowed)
//   -> x0 task records, x1 count
// Copies the template into one record per task with windows [lo, hi) that
// cover 0..total; worker tasks get their own EvalCtx copies.
//   x19 template, x20 total, x21 count, x22 records, x23 index, x24 window
// =============================================================================
LFUNC ot_split
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x21, #1
    cbz  w2, 1f
    TLS_LDR x9, g_x_threads
    cmp  x9, #1
    b.ls 1f
    LDR_G x10, g_par_min_rows
    udiv x10, x20, x10
    cmp  x10, x9
    csel x10, x10, x9, lo
    cmp  x10, #2
    b.lo 1f
    mov  x21, x10
1:  mov  x9, #OT_SIZE
    mul  x0, x9, x21
    bl   arena_alloc
    mov  x22, x0
    add  x24, x20, x21                  // ceil(total / count)
    sub  x24, x24, #1
    udiv x24, x24, x21
    mov  x23, #0
2:  cmp  x23, x21
    b.hs 4f
    mov  x9, #OT_SIZE
    madd x0, x23, x9, x22
    mov  x1, x19
    mov  x2, #OT_SIZE
    bl   memcpy
    mul  x10, x23, x24
    cmp  x10, x20
    csel x10, x10, x20, lo
    str  x10, [x0, #OT_LO]
    add  x10, x10, x24
    cmp  x10, x20
    csel x10, x10, x20, lo
    str  x10, [x0, #OT_HI]
    cmp  x21, #1
    b.eq 3f
    str  x0, [sp, #-16]!
    mov  x0, #EC_SIZE
    bl   arena_alloc
    ldr  x1, [x19, #OT_CTX]
    ldp  x12, x13, [x1]
    stp  x12, x13, [x0]
    ldp  x12, x13, [x1, #16]
    stp  x12, x13, [x0, #16]
    ldp  x12, x13, [x1, #32]
    stp  x12, x13, [x0, #32]
    mov  x1, x0
    ldr  x0, [sp], #16
    str  x1, [x0, #OT_CTX]
3:  add  x23, x23, #1
    b    2b
4:  mov  x0, x22
    mov  x1, x21
    LEAVE 5
ENDF ot_split

// ot_exec(x0 fn, x1 records, x2 count): one task on this thread, else par_run
LFUNC ot_exec
    cmp  x2, #1
    b.ne 1f
    mov  x9, x0
    mov  x0, x1
    br   x9                             // tail call fn(record)
1:  mov  x3, x2
    mov  x2, #OT_SIZE
    b    par_run
ENDF ot_exec

// =============================================================================
// ex_filter(x0 node, x1 ctx) -> x0 TupleSet*
//   x19 node, x20 ctx, x21 records, x22 count; [sp] template
// =============================================================================
FUNC ex_filter
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 3
    sub  sp, sp, #OT_SIZE
    mov  x19, x0
    mov  x20, x1
    ldr  x0, [x19, #PN_LEFT]
    bl   ex_tuples
    str  x0, [sp, #OT_IN]
    str  x19, [sp, #OT_NODE]
    str  x20, [sp, #OT_CTX]
    ldr  x0, [x19, #PN_EXPR]
    bl   expr_par_safe
    mov  w2, w0
    mov  x0, sp
    ldr  x9, [sp, #OT_IN]
    ldr  x1, [x9, #TS_N]
    bl   ot_split
    mov  x21, x0
    mov  x22, x1
    ADR_L x0, filter_task
    mov  x1, x21
    mov  x2, x22
    bl   ot_exec
    ldr  x0, [x21, #OT_TS]
    cmp  x22, #1
    b.eq 1f
    mov  x0, x21
    mov  x1, x22
    mov  x2, #OT_SIZE
    bl   ts_concat
1:  add  sp, sp, #OT_SIZE
    LEAVE 3
ENDF ex_filter

// =============================================================================
// filter_task(x0 task): input tuples [lo, hi) through PN_EXPR into OT_TS
//   x19 task, x20 ctx, x21 input, x22 out, x23 index, x24 predicate,
//   x25 vb, x26 selection, x27 batch size
// =============================================================================
FUNC filter_task
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 5
    mov  x19, x0
    ldr  x20, [x19, #OT_CTX]
    ldr  x21, [x19, #OT_IN]
    ldr  x9, [x19, #OT_NODE]
    ldr  x24, [x9, #PN_EXPR]
    ldr  x0, [x21, #TS_W]
    ldp  x9, x10, [x19, #OT_LO]
    sub  x1, x10, x9
    lsr  x1, x1, #1
    bl   ts_new
    mov  x22, x0
    str  x22, [x19, #OT_TS]
    ldr  x23, [x19, #OT_LO]
    TLS_ADDR x9, g_x_mode
    ldr  w9, [x9]
    cmp  w9, #XM_ROW
    b.ne .Lft_vec
1:  ldr  x9, [x19, #OT_HI]              // row at a time
    cmp  x23, x9
    b.hs .Lft_end
    tst  x23, #DEADLINE_MASK
    b.ne 2f
    bl   check_deadline
2:  mov  x0, x21
    mov  x1, x23
    bl   ts_tuple
    str  x0, [x20, #EC_TUPLE]
    mov  x0, x24
    mov  x1, x20
    bl   eval_true
    cbz  w0, 3f
    mov  x0, x22
    ldr  x1, [x20, #EC_TUPLE]
    bl   ts_push
3:  add  x23, x23, #1
    b    1b
.Lft_vec:
    mov  x0, x20
    ldr  x1, [x21, #TS_W]
    bl   vb_new
    mov  x25, x0
    mov  x0, #(VBATCH * 2)
    bl   arena_alloc
    mov  x26, x0
4:  ldr  x9, [x19, #OT_HI]
    cmp  x23, x9
    b.hs .Lft_end
    bl   check_deadline
    ldr  x9, [x19, #OT_HI]
    sub  x27, x9, x23
    mov  x10, #VBATCH
    cmp  x27, x10
    csel x27, x27, x10, lo
    mov  x0, x21
    mov  x1, x23
    bl   ts_tuple
    str  x0, [x25, #VB_TUP]
    str  x27, [x25, #VB_N]
    mov  x0, x24
    mov  x1, x25
    mov  x2, x26
    bl   vfilter
    mov  x28, x0                        // selected count
    mov  x0, x22
    mov  x1, x28
    bl   ts_reserve
    ldr  x9, [x22, #TS_N]
    add  x9, x9, x28
    str  x9, [x22, #TS_N]
    ldr  x10, [x25, #VB_TUP]            // copy the selected tuples
    ldr  x11, [x21, #TS_W]
    lsl  x12, x11, #2
    mov  x13, #0
5:  cmp  x13, x28
    b.hs 7f
    ldrh w14, [x26, x13, lsl #1]
    madd x14, x14, x12, x10
    mov  x15, x11
    cbz  x15, 61f                       // zero-width tuples (no FROM)
6:  ldr  w16, [x14], #4
    str  w16, [x0], #4
    subs x15, x15, #1
    b.ne 6b
61: add  x13, x13, #1
    b    5b
7:  add  x23, x23, x27
    b    4b
.Lft_end:
    LEAVE 5
ENDF filter_task

// =============================================================================
// project_rows(x0 node, x1 ctx, x2 ts, x3 first, x4 count, x5 rs, x6 cells)
//   x19 records, x20 count, x21 bq; [sp] template
// =============================================================================
FUNC project_rows
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 3
    sub  sp, sp, #OT_SIZE
    str  x0, [sp, #OT_NODE]
    str  x1, [sp, #OT_CTX]
    str  x2, [sp, #OT_IN]
    str  x3, [sp, #OT_FIRST]
    str  x5, [sp, #OT_RS]
    str  x6, [sp, #OT_CELLS]
    mov  x20, x4
    ldr  x21, [x0, #PN_BQ]
    mov  x0, x21
    bl   bq_out_par_safe
    mov  w2, w0
    mov  x0, sp
    mov  x1, x20
    bl   ot_split
    mov  x19, x0
    mov  x20, x1
    ADR_L x0, project_task
    mov  x1, x19
    mov  x2, x20
    bl   ot_exec
    add  sp, sp, #OT_SIZE
    LEAVE 3
ENDF project_rows

// bq_out_par_safe(x0 BoundQuery*) -> w0 1 if every output / hidden
// expression is safe for worker threads
//   x19 bq, x20 index
FUNC bq_out_par_safe
    ENTER 2
    mov  x19, x0
    mov  x20, #0
1:  ldr  x9, [x19, #BQ_NOUT]
    cmp  x20, x9
    b.hs 2f
    ldr  x9, [x19, #BQ_OUT]
    mov  x10, #OC_SIZE
    madd x9, x20, x10, x9
    ldr  x0, [x9, #OC_EXPR]
    bl   expr_par_safe
    cbz  w0, 9f
    add  x20, x20, #1
    b    1b
2:  mov  x20, #0
3:  ldr  x9, [x19, #BQ_NEXTRA]
    cmp  x20, x9
    b.hs 4f
    ldr  x9, [x19, #BQ_EXTRA]
    ldr  x0, [x9, x20, lsl #3]
    bl   expr_par_safe
    cbz  w0, 9f
    add  x20, x20, #1
    b    3b
4:  mov  w0, #1
9:  LEAVE 2
ENDF bq_out_par_safe

// =============================================================================
// project_task(x0 task): result rows [lo, hi)
//   x19 task, x20 ctx, x21 bq, x22 row bytes, x23 row index, x24 vb,
//   x25 vector, x26 batch size, x27 column, x28 expression
// =============================================================================
FUNC project_task
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 5
    mov  x19, x0
    ldr  x20, [x19, #OT_CTX]
    ldr  x9, [x19, #OT_NODE]
    ldr  x21, [x9, #PN_BQ]
    ldr  x9, [x19, #OT_RS]
    ldr  x22, [x9, #RS_WIDTH]
    lsl  x22, x22, #4
    ldr  x23, [x19, #OT_LO]             // row pointers of the window
    ldr  x10, [x19, #OT_HI]
    ldr  x11, [x9, #RS_ROWS]
    ldr  x12, [x19, #OT_CELLS]
1:  cmp  x23, x10
    b.hs 2f
    madd x13, x23, x22, x12
    str  x13, [x11, x23, lsl #3]
    add  x23, x23, #1
    b    1b
2:  ldr  x23, [x19, #OT_LO]
    TLS_ADDR x9, g_x_mode
    ldr  w9, [x9]
    cmp  w9, #XM_ROW
    b.ne .Lpt_vec
3:  ldr  x9, [x19, #OT_HI]              // row at a time
    cmp  x23, x9
    b.hs .Lpt_end
    tst  x23, #DEADLINE_MASK
    b.ne 4f
    bl   check_deadline
4:  ldr  x0, [x19, #OT_IN]
    ldr  x1, [x19, #OT_FIRST]
    add  x1, x1, x23
    bl   ts_tuple
    str  x0, [x20, #EC_TUPLE]
    mov  x0, x21
    mov  x1, x20
    ldr  x2, [x19, #OT_CELLS]
    madd x2, x23, x22, x2
    bl   project_row
    add  x23, x23, #1
    b    3b
.Lpt_vec:
    mov  x0, x20
    ldr  x1, [x19, #OT_IN]
    ldr  x1, [x1, #TS_W]
    bl   vb_new
    mov  x24, x0
    bl   vpool_get
    mov  x25, x0
5:  ldr  x9, [x19, #OT_HI]
    cmp  x23, x9
    b.hs .Lpt_end
    bl   check_deadline
    ldr  x9, [x19, #OT_HI]
    sub  x26, x9, x23
    mov  x10, #VBATCH
    cmp  x26, x10
    csel x26, x26, x10, lo
    ldr  x0, [x19, #OT_IN]
    ldr  x1, [x19, #OT_FIRST]
    add  x1, x1, x23
    bl   ts_tuple
    str  x0, [x24, #VB_TUP]
    str  x26, [x24, #VB_N]
    mov  x27, #0                        // column (visible, then hidden)
6:  ldr  x9, [x21, #BQ_NOUT]
    cmp  x27, x9
    b.hs 61f
    ldr  x10, [x21, #BQ_OUT]
    mov  x11, #OC_SIZE
    madd x10, x27, x11, x10
    ldr  x28, [x10, #OC_EXPR]
    b    62f
61: ldr  x10, [x21, #BQ_NEXTRA]
    add  x10, x10, x9
    cmp  x27, x10
    b.hs 8f
    ldr  x10, [x21, #BQ_EXTRA]
    sub  x11, x27, x9
    ldr  x28, [x10, x11, lsl #3]
62: mov  x0, x28
    mov  x1, x24
    ADR_L x2, vsel_ident
    mov  x3, x26
    mov  x4, x25
    bl   veval
    ldr  x10, [x19, #OT_CELLS]          // scatter into the rows
    madd x10, x23, x22, x10
    add  x10, x10, x27, lsl #4          // cell of the first row
    add  x11, x25, #VEC_NULLS
    mov  x12, #0
7:  cmp  x12, x26
    b.hs 71f
    ldr  x13, [x25, x12, lsl #3]
    ldrb w14, [x11, x12]
    stp  x13, x14, [x10]
    add  x10, x10, x22
    add  x12, x12, #1
    b    7b
71: add  x27, x27, #1
    b    6b
8:  add  x23, x23, x26
    b    5b
.Lpt_end:
    LEAVE 5
ENDF project_task

    NOTE_GNU_STACK
