// =============================================================================
// exec.S — executor for physical plans (plan.S).
//
//   exec_plan(x0 PlanNode*, x1 outer EvalCtx* or 0) -> x0 ResultSet*
//   ev_subq / ev_exists / ev_insub (x0 Node*, x1 EvalCtx*) -> x0, x1
//       evaluation of subquery expressions (called from eval.S)
//
// Operators below Aggregate / Project work on *tuple sets* (TS_*): arrays of
// tuples, one u32 row id per range variable of the query (ROW_NULL for the
// NULL-padded side of a LEFT JOIN). Column values are read through the
// EvalCtx (EC_TABLES[rv], EC_TUPLE). Derived tables and CTEs are executed
// and materialised into columnar Table records on first use (cached for the
// statement unless correlated).
//
// Upper operators work on result rows ("matrix rows" of BQ_NOUT + BQ_NEXTRA
// cells; cells are 16 bytes: payload, isnull):
//   Aggregate  sort-based grouping: key cells per tuple, qsort_r, runs of
//              equal keys form groups (NULL keys group together); DISTINCT
//              aggregates sort and de-duplicate the run's values
//   Project    one row per tuple
//   Distinct   sort on all visible cells, drop adjacent duplicates
//   Sort       qsort_r on the ORDER BY key cells
//   Limit      OFFSET then LIMIT (applied before projection when the Limit
//              sits directly on a Project)
//   UnionAll   concatenation of the branch results (ex_union)
// Join operators live in join.S.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

#define DEADLINE_MASK 4095          // check the timeout every 4096 iterations

// Scan task (ex_scan / scan_task), one per thread
#define SS_NODE    0                // PlanNode* (the scan)
#define SS_CTX     8                // EvalCtx* (own copy for worker tasks)
#define SS_TS      16               // TupleSet* result (ts_concat: offset 16)
#define SS_RANGES  24               // u64 (lo, hi) candidate row ranges
#define SS_NR      32               // u64 number of ranges
#define SS_WLO     40               // window of candidate ordinals [lo, hi)
#define SS_WHI     48
#define SS_SIZE    64

// Sort key descriptor used by the row comparator (24 bytes)
#define SK_OFF    0                 // byte offset of the cell in the row
#define SK_TYPE   8                 // u32 type
#define SK_DESC   12                // u32
#define SK_NFIRST 16                // u32
#define SK_SIZE   24

// IN-subquery value set
#define IS_N       0                // u64 number of non-NULL values (sorted)
#define IS_VALS    8                // u64* payloads
#define IS_HASNULL 16               // u64 1 if the subquery produced a NULL
#define IS_TYPE    24               // u32 type of the values
#define IS_SIZE    32

// Execution settings of the running plan (pq.inc XM_*): taken from the plan
// root (physical.S PN_XMODE / PN_XTHREADS) by exec_plan / exec_plan_stream;
// worker threads inherit them (parallel.S). Process-wide defaults (main.S).
    TDATA
    .p2align 3
    .global g_x_threads, g_x_mode
g_x_threads:    .quad 1
g_x_mode:       .word XM_VEC
    .data
    .p2align 3
    .global g_def_threads, g_par_min_rows
g_def_threads:  .quad 0             // --threads (0 until main sets it)
g_par_min_rows: .quad 16384         // smallest input share of a parallel task

    .text

// =============================================================================
// Tuple sets
// ts_new(x0 width, x1 capacity) -> x0 TupleSet*
//   x19 width, x20 capacity
// =============================================================================
FUNC ts_new
    ENTER 2
    mov  x19, x0
    cmp  x1, #16
    mov  x9, #16
    csel x20, x1, x9, hi
    mov  x0, #TS_SIZE
    bl   arena_zalloc
    str  x19, [x0, #TS_W]
    str  x20, [x0, #TS_CAP]
    mov  x19, x0
    ldr  x9, [x19, #TS_W]
    mul  x0, x9, x20
    lsl  x0, x0, #2
    add  x0, x0, #16
    bl   arena_alloc
    str  x0, [x19, #TS_DATA]
    mov  x0, x19
    LEAVE 2
ENDF ts_new

// ts_push(x0 TupleSet*, x1 u32* tuple) — appends a copy of the tuple
//   x19 ts, x20 tuple, x21 new capacity, x22 new data
FUNC ts_push
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldr  x9, [x19, #TS_N]
    ldr  x10, [x19, #TS_CAP]
    cmp  x9, x10
    b.lo 1f
    lsl  x21, x10, #1                   // grow x2
    ldr  x9, [x19, #TS_W]
    mul  x0, x9, x21
    lsl  x0, x0, #2
    add  x0, x0, #16
    bl   arena_alloc
    mov  x22, x0
    ldr  x1, [x19, #TS_DATA]
    ldr  x9, [x19, #TS_W]
    ldr  x2, [x19, #TS_N]
    mul  x2, x2, x9
    lsl  x2, x2, #2
    bl   memcpy
    str  x22, [x19, #TS_DATA]
    str  x21, [x19, #TS_CAP]
1:  ldr  x9, [x19, #TS_N]
    ldr  x10, [x19, #TS_W]
    ldr  x11, [x19, #TS_DATA]
    mul  x12, x9, x10
    add  x11, x11, x12, lsl #2          // destination
    add  x9, x9, #1
    str  x9, [x19, #TS_N]
2:  cbz  x10, 3f                        // copy w u32 row ids
    ldr  w12, [x20], #4
    str  w12, [x11], #4
    sub  x10, x10, #1
    b    2b
3:  LEAVE 3
ENDF ts_push

// ts_reserve(x0 TupleSet*, x1 count) -> x0 u32* where the next tuple goes;
// grows the set so that `count` more tuples fit (the caller writes them and
// adds count to TS_N)
//   x19 ts, x20 count, x21 new capacity, x22 new data
FUNC ts_reserve
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldr  x9, [x19, #TS_N]
    ldr  x10, [x19, #TS_CAP]
    add  x9, x9, x20
    cmp  x9, x10
    b.ls 1f
    lsl  x21, x10, #1                   // max(2 * cap, needed)
    cmp  x21, x9
    csel x21, x21, x9, hs
    ldr  x9, [x19, #TS_W]
    mul  x0, x9, x21
    lsl  x0, x0, #2
    add  x0, x0, #16
    bl   arena_alloc
    mov  x22, x0
    ldr  x1, [x19, #TS_DATA]
    ldr  x9, [x19, #TS_W]
    ldr  x2, [x19, #TS_N]
    mul  x2, x2, x9
    lsl  x2, x2, #2
    bl   memcpy
    str  x22, [x19, #TS_DATA]
    str  x21, [x19, #TS_CAP]
1:  ldr  x9, [x19, #TS_N]
    ldr  x10, [x19, #TS_W]
    ldr  x0, [x19, #TS_DATA]
    mul  x9, x9, x10
    add  x0, x0, x9, lsl #2
    LEAVE 3
ENDF ts_reserve

// ts_tuple(x0 TupleSet*, x1 index) -> x0 u32* tuple   (leaf)
FUNC ts_tuple
    ldr  x9, [x0, #TS_W]
    ldr  x10, [x0, #TS_DATA]
    mul  x9, x9, x1
    add  x0, x10, x9, lsl #2
    ret
ENDF ts_tuple

// eval_true(x0 Node*, x1 EvalCtx*) -> w0 1 iff the predicate is TRUE
FUNC eval_true
    ENTER 0
    bl   eval
    cmp  x1, #0
    ccmp x0, #0, #4, eq                 // ne iff not NULL and value != 0
    cset w0, ne
    LEAVE 0
ENDF eval_true

// =============================================================================
// exec_plan(x0 PlanNode*, x1 outer EvalCtx* or 0) -> x0 ResultSet*
// Runs one query level with a fresh evaluation context.
//   x19 root, x20 ctx
// =============================================================================
FUNC exec_plan
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 2
    mov  x19, x0
    bl   exec_settings
    mov  x0, x19
    bl   new_root_ctx
    mov  x20, x0
    mov  x0, x19
    mov  x1, x20
    bl   ex_rows
    LEAVE 2
ENDF exec_plan

// exec_settings(x0 PlanNode* root): runs with the plan's execution mode and
// threads   (leaf)
LFUNC exec_settings
    ldr  w9, [x0, #PN_XMODE]
    TLS_ADDR x10, g_x_mode
    str  w9, [x10]
    ldr  x9, [x0, #PN_XTHREADS]
    TLS_ADDR x10, g_x_threads
    str  x9, [x10]
    ret
ENDF exec_settings

// new_root_ctx(x0 PlanNode*, x1 outer EvalCtx* or 0) -> x0 EvalCtx*
//   x19 node
LFUNC new_root_ctx
    ENTER 2
    mov  x19, x0
    stp  x1, xzr, [sp, #-16]!
    mov  x0, #EC_SIZE
    bl   arena_zalloc
    mov  x20, x0
    ldr  x1, [sp], #16
    str  x1, [x20, #EC_OUTER]
    ldr  x9, [x19, #PN_BQ]
    ldr  x9, [x9, #BQ_NRV]
    lsl  x0, x9, #3
    add  x0, x0, #8
    bl   arena_zalloc
    str  x0, [x20, #EC_TABLES]
    mov  x0, x20
    LEAVE 2
ENDF new_root_ctx

// =============================================================================
// exec_plan_stream(x0 root PlanNode*, x1 sink) -> x0 ResultSet*, x1 1 if
// the rows went to the sink
// Statement execution for streamed results. When the plan ends in a
// projection (optionally under LIMIT/OFFSET) the rows are projected and
// handed to the sink in batches of EXEC_STREAM_BATCH as they are produced:
//     sink(x0 0, x1 total rows)        once, before any row
//     sink(x0 ResultSet* batch)        for every batch (cells reused)
// and the returned ResultSet only carries the total in RS_NROWS. Other plans
// (sorting, grouping, DISTINCT need all rows first) are executed normally
// (x1 = 0).
//   x19 node, x20 ctx, x21 sink, x22 bq
// =============================================================================
FUNC exec_plan_stream
    ENTER 3
    mov  x19, x0
    mov  x21, x1
    bl   exec_settings
    mov  x0, x19
    mov  x1, #0
    bl   new_root_ctx
    mov  x20, x0
    ldr  x22, [x19, #PN_BQ]
    ldr  w9, [x19, #PN_OP]
    cmp  w9, #PO_PROJECT
    b.ne 1f
    mov  x0, x19
    mov  x1, x20
    mov  x2, #0
    mov  x3, #-1
    b    3f
1:  cmp  w9, #PO_LIMIT
    b.ne 2f
    ldr  x0, [x19, #PN_LEFT]
    ldr  w9, [x0, #PN_OP]
    cmp  w9, #PO_PROJECT
    b.ne 2f
    mov  x1, x20
    ldr  x2, [x22, #BQ_OFFSET]
    ldr  x3, [x22, #BQ_LIMIT]
3:  mov  x4, x21
    bl   ex_project
    mov  x1, #1
    LEAVE 3
2:  mov  x0, x19
    mov  x1, x20
    bl   ex_rows
    mov  x1, #0
    LEAVE 3
ENDF exec_plan_stream

// =============================================================================
// ex_rows(x0 PlanNode*, x1 ctx) -> x0 ResultSet*   (upper operators)
//   x19 node, x20 ctx, x21 bq, x22 result set
// =============================================================================
LFUNC ex_rows
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldr  x21, [x19, #PN_BQ]
    ldr  w9, [x19, #PN_OP]
    cmp  w9, #PO_PROJECT
    b.eq .Lxr_project
    cmp  w9, #PO_AGGREGATE
    b.eq .Lxr_agg
    cmp  w9, #PO_LIMIT
    b.eq .Lxr_limit
    cmp  w9, #PO_SORT
    b.eq .Lxr_sort
    cmp  w9, #PO_DISTINCT
    b.eq .Lxr_distinct
    cmp  w9, #PO_UNION
    b.eq .Lxr_union
    RAISE ERR_INTERNAL, "executor: unexpected plan node"
.Lxr_project:
    mov  x0, x19
    mov  x1, x20
    mov  x2, #0
    mov  x3, #-1
    mov  x4, #0
    bl   ex_project
    LEAVE 3
.Lxr_agg:
    mov  x0, x19
    mov  x1, x20
    bl   ex_aggregate
    LEAVE 3
.Lxr_limit:
    ldr  x0, [x19, #PN_LEFT]
    ldr  w9, [x0, #PN_OP]
    cmp  w9, #PO_PROJECT
    b.ne 1f
    mov  x1, x20                        // slice before projecting
    ldr  x2, [x21, #BQ_OFFSET]
    ldr  x3, [x21, #BQ_LIMIT]
    mov  x4, #0
    bl   ex_project
    LEAVE 3
1:  cmp  w9, #PO_SORT                  // ORDER BY ... LIMIT: top-N
    b.ne 11f
    ldr  w9, [x0, #PN_TOPN]
    cbz  w9, 11f
    ldr  x0, [x0, #PN_LEFT]
    mov  x1, x20
    bl   ex_rows
    mov  x22, x0
    mov  x0, x21
    bl   order_keys
    mov  x2, x0
    ldr  x9, [x21, #BQ_LIMIT]
    ldr  x10, [x21, #BQ_OFFSET]
    adds x3, x9, x10
    csinv x3, x3, xzr, cc               // saturate
    ldr  x0, [x22, #RS_ROWS]
    ldr  x1, [x22, #RS_NROWS]
    bl   topn_rows_par
    str  x0, [x22, #RS_NROWS]
    b    12f
11: mov  x1, x20
    bl   ex_rows
    mov  x22, x0
12: ldr  x9, [x22, #RS_NROWS]
    ldr  x10, [x21, #BQ_OFFSET]
    cmp  x10, x9
    csel x10, x10, x9, lo               // start = min(offset, n)
    ldr  x11, [x22, #RS_ROWS]
    add  x11, x11, x10, lsl #3
    str  x11, [x22, #RS_ROWS]
    sub  x9, x9, x10
    ldr  x12, [x21, #BQ_LIMIT]
    tbnz x12, #63, 2f
    cmp  x12, x9
    csel x9, x12, x9, lo
2:  str  x9, [x22, #RS_NROWS]
    mov  x0, x22
    LEAVE 3
.Lxr_sort:
    ldr  x0, [x19, #PN_LEFT]
    mov  x1, x20
    bl   ex_rows
    mov  x22, x0
    mov  x0, x21
    bl   order_keys
    mov  x2, x0
    ldr  x0, [x22, #RS_ROWS]
    ldr  x1, [x22, #RS_NROWS]
    ldr  x3, [x21, #BQ_NORDER]
    bl   sort_rows_par
    mov  x0, x22
    LEAVE 3
.Lxr_distinct:
    ldr  x0, [x19, #PN_LEFT]
    mov  x1, x20
    bl   ex_rows
    mov  x1, x0
    mov  x0, x21
    TLS_ADDR x9, g_x_mode               // vectorized: hash DISTINCT
    ldr  w9, [x9]
    cmp  w9, #XM_ROW
    b.eq 1f
    bl   vdistinct
    LEAVE 3
1:  bl   distinct_rows
    LEAVE 3
.Lxr_union:
    mov  x0, x19
    mov  x1, x20
    bl   ex_union
    LEAVE 3
ENDF ex_rows

// =============================================================================
// ex_union(x0 PlanNode* UnionAll, x1 ctx) -> x0 ResultSet*
// Runs every branch plan as a nested query level (its outer context is the
// compound's ctx, matching the binder's levels) and concatenates the row
// pointers in branch order. The binder made the branch column types equal to
// the compound's, so the rows are used as they are (extra cells beyond
// BQ_NOUT are ignored).
//   x19 node, x20 ctx, x21 branch results array, x22 index, x23 total rows,
//   x24 result set, x25 destination cursor
// =============================================================================
LFUNC ex_union
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    ldr  x9, [x19, #PN_NKIDS]
    lsl  x0, x9, #3
    bl   arena_alloc
    mov  x21, x0
    mov  x22, #0
    mov  x23, #0
1:  ldr  x9, [x19, #PN_NKIDS]
    cmp  x22, x9
    b.hs 2f
    bl   check_deadline
    ldr  x9, [x19, #PN_KIDS]
    ldr  x0, [x9, x22, lsl #3]
    mov  x1, x20
    bl   exec_plan
    str  x0, [x21, x22, lsl #3]
    ldr  x9, [x0, #RS_NROWS]
    add  x23, x23, x9
    add  x22, x22, #1
    b    1b
2:  ldr  x0, [x19, #PN_BQ]
    mov  x1, x23
    bl   rs_new
    mov  x24, x0
    str  x23, [x24, #RS_NROWS]
    ldr  x25, [x24, #RS_ROWS]
    mov  x22, #0
3:  ldr  x9, [x19, #PN_NKIDS]
    cmp  x22, x9
    b.hs 4f
    ldr  x9, [x21, x22, lsl #3]
    ldr  x2, [x9, #RS_NROWS]
    ldr  x1, [x9, #RS_ROWS]
    lsl  x2, x2, #3
    mov  x0, x25
    add  x25, x25, x2
    bl   memcpy
    add  x22, x22, #1
    b    3b
4:  mov  x0, x24
    LEAVE 4
ENDF ex_union

// =============================================================================
// rs_new(x0 BoundQuery*, x1 row capacity) -> x0 ResultSet* (0 rows, row
// pointer array of the given capacity; width = BQ_NOUT + BQ_NEXTRA)
//   x19 bq, x20 capacity, x21 rs
// =============================================================================
FUNC rs_new
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x0, #RS_SIZE
    bl   arena_zalloc
    mov  x21, x0
    ldr  x9, [x19, #BQ_NOUT]
    ldr  x10, [x19, #BQ_NEXTRA]
    add  x9, x9, x10
    str  x9, [x21, #RS_WIDTH]
    lsl  x0, x20, #3
    add  x0, x0, #16
    bl   arena_alloc
    str  x0, [x21, #RS_ROWS]
    mov  x0, x21
    LEAVE 3
ENDF rs_new

// =============================================================================
// project_row(x0 BoundQuery*, x1 EvalCtx*, x2 dest cells)
// Evaluates the visible and hidden expressions of one result row.
//   x19 bq, x20 ctx, x21 dest, x22 cursor, x23 count
// =============================================================================
FUNC project_row
    ENTER 3
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
4:  LEAVE 3
ENDF project_row

// =============================================================================
// ex_project(x0 PlanNode*, x1 ctx, x2 offset, x3 limit (-1 none),
//            x4 sink or 0) -> x0 ResultSet*  one row per input tuple of the
// slice. With a sink (exec_plan_stream) the rows are produced in batches
// and passed to the sink; the result then only holds the row count.
//   x19 node, x20 ctx, x21 bq, x22 tuple set, x23 first tuple, x24 count,
//   x25 rs, x26 row bytes, x27 index, x28 cells
//   [sp] sink, [sp+8] batch cells, [sp+16] first row of the batch
// =============================================================================
LFUNC ex_project
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    cbnz x4, 0f                         // mode "row": rows pulled from the
    TLS_ADDR x9, g_x_mode               // iterator tree (volcano.S)
    ldr  w9, [x9]
    cmp  w9, #XM_ROW
    b.eq it_project
0:  ENTER 5
    sub  sp, sp, #32
    str  x4, [sp]
    mov  x19, x0
    mov  x20, x1
    ldr  x21, [x19, #PN_BQ]
    stp  x2, x3, [sp, #-16]!
    ldr  x0, [x19, #PN_LEFT]
    mov  x1, x20
    bl   ex_tuples
    mov  x22, x0
    ldp  x2, x3, [sp], #16
    ldr  x9, [x22, #TS_N]
    cmp  x2, x9
    csel x23, x2, x9, lo                // start = min(offset, n)
    sub  x24, x9, x23
    tbnz x3, #63, 1f
    cmp  x3, x24
    csel x24, x3, x24, lo
1:  ldr  x9, [sp]
    cbnz x9, .Lxp_stream
    mov  x0, x21
    mov  x1, x24
    bl   rs_new
    mov  x25, x0
    str  x24, [x25, #RS_NROWS]
    ldr  x9, [x25, #RS_WIDTH]
    lsl  x26, x9, #4
    mul  x0, x26, x24
    add  x0, x0, #16
    bl   arena_alloc
    mov  x6, x0                         // cell matrix
    mov  x0, x19                        // rows (ops.S: modes, threads)
    mov  x1, x20
    mov  x2, x22
    mov  x3, x23
    mov  x4, x24
    mov  x5, x25
    bl   project_rows
    mov  x0, x25
    add  sp, sp, #32
    LEAVE 5
.Lxp_stream:
    // announce the row count (limits, stream header), then batches
    mov  x0, #0
    mov  x1, x24
    ldr  x9, [sp]
    blr  x9
    mov  x0, x21
    mov  x1, #EXEC_STREAM_BATCH
    bl   rs_new
    mov  x25, x0
    ldr  x9, [x25, #RS_WIDTH]
    lsl  x26, x9, #4
    mov  x0, #EXEC_STREAM_BATCH
    mul  x0, x26, x0
    add  x0, x0, #16
    bl   arena_alloc
    str  x0, [sp, #8]
    mov  x28, x0
    mov  x27, #0
    str  xzr, [sp, #16]
5:  cmp  x27, x24
    b.hs 7f
    tst  x27, #DEADLINE_MASK
    b.ne 51f
    bl   check_deadline
51: mov  x0, x22
    add  x1, x23, x27
    bl   ts_tuple
    str  x0, [x20, #EC_TUPLE]
    ldr  x9, [x25, #RS_ROWS]
    ldr  x10, [sp, #16]
    sub  x10, x27, x10
    str  x28, [x9, x10, lsl #3]
    mov  x0, x21
    mov  x1, x20
    mov  x2, x28
    bl   project_row
    add  x28, x28, x26
    add  x27, x27, #1
    ldr  x10, [sp, #16]
    sub  x10, x27, x10
    cmp  x10, #EXEC_STREAM_BATCH
    b.lo 5b
6:  str  x10, [x25, #RS_NROWS]          // hand the batch over, reuse cells
    mov  x0, x25
    ldr  x9, [sp]
    blr  x9
    str  x27, [sp, #16]
    ldr  x28, [sp, #8]
    b    5b
7:  ldr  x10, [sp, #16]
    subs x10, x27, x10
    b.ne 6b                             // last partial batch
    str  x24, [x25, #RS_NROWS]
    mov  x0, x25
    add  sp, sp, #32
    LEAVE 5
ENDF ex_project

// =============================================================================
// ex_aggregate(x0 PlanNode*, x1 ctx) -> x0 ResultSet*
// Groups the input tuples (sort-based), aggregates every group, filters by
// HAVING and projects one row per surviving group.
//   x19 node, x20 ctx, x21 bq, x22 tuple set, x23 records, x24 record size,
//   x25 rs, x26 group start, x27 group end, x28 key info
// Stack: [sp] null tuple / scratch
// =============================================================================
LFUNC ex_aggregate
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    ldr  x21, [x19, #PN_BQ]
    TLS_ADDR x9, g_x_mode               // vectorized: hash aggregation
    ldr  w9, [x9]
    cmp  w9, #XM_ROW
    b.eq 0f
    mov  x0, x21
    bl   vagg_ok
    cbz  w0, 0f
    mov  x0, x19
    mov  x1, x20
    bl   vagg_aggregate
    LEAVE 5
0:
    ldr  x0, [x19, #PN_LEFT]
    mov  x1, x20
    bl   ex_tuples
    mov  x22, x0
    // key info for the comparator: [0] nkeys, then u32 types
    ldr  x9, [x21, #BQ_NGROUP]
    lsl  x0, x9, #2
    add  x0, x0, #16
    bl   arena_alloc
    mov  x28, x0
    ldr  x9, [x21, #BQ_NGROUP]
    str  x9, [x28]
    mov  x10, #0
1:  cmp  x10, x9
    b.hs 2f
    ldr  x11, [x21, #BQ_GROUP]
    ldr  x11, [x11, x10, lsl #3]
    ldr  w11, [x11, #N_TYPE]
    add  x12, x28, #8
    str  w11, [x12, x10, lsl #2]
    add  x10, x10, #1
    b    1b
2:  // records: [u64 tuple index][nkeys cells]
    lsl  x24, x9, #4
    add  x24, x24, #8
    ldr  x9, [x22, #TS_N]
    mul  x0, x9, x24
    add  x0, x0, #16
    bl   arena_alloc
    mov  x23, x0
    mov  x26, #0
3:  ldr  x9, [x22, #TS_N]
    cmp  x26, x9
    b.hs 6f
    tst  x26, #DEADLINE_MASK
    b.ne 31f
    bl   check_deadline
31: mov  x0, x22
    mov  x1, x26
    bl   ts_tuple
    str  x0, [x20, #EC_TUPLE]
    madd x27, x26, x24, x23             // record
    str  x26, [x27]
    add  x27, x27, #8
    mov  x9, #0
4:  ldr  x10, [x21, #BQ_NGROUP]
    cmp  x9, x10
    b.hs 5f
    str  x9, [sp, #-16]!
    ldr  x10, [x21, #BQ_GROUP]
    ldr  x0, [x10, x9, lsl #3]
    mov  x1, x20
    bl   eval
    stp  x0, x1, [x27], #16
    ldr  x9, [sp], #16
    add  x9, x9, #1
    b    4b
5:  add  x26, x26, #1
    b    3b
6:  // sort the records by key (only with GROUP BY)
    ldr  x9, [x21, #BQ_NGROUP]
    cbz  x9, 7f
    mov  x0, x23
    ldr  x1, [x22, #TS_N]
    mov  x2, x24
    ADR_L x3, cmp_group_rec
    mov  x4, x28
    bl   qsort_r
7:  ldr  x9, [x22, #TS_N]
    add  x1, x9, #1
    mov  x0, x21
    bl   rs_new
    mov  x25, x0
    // without GROUP BY there is exactly one group, even on empty input
    ldr  x9, [x21, #BQ_NGROUP]
    cbnz x9, 8f
    ldr  x27, [x22, #TS_N]
    mov  x26, #0
    mov  x0, x19
    mov  x1, x20
    mov  x2, x22
    mov  x3, x23
    mov  x4, x24
    mov  x5, #0
    mov  x6, x27
    mov  x7, x25
    bl   agg_group
    b    .Lxa_done
8:  mov  x26, #0                        // runs of equal keys
.Lxa_run:
    ldr  x9, [x22, #TS_N]
    cmp  x26, x9
    b.hs .Lxa_done
    add  x27, x26, #1
9:  ldr  x9, [x22, #TS_N]
    cmp  x27, x9
    b.hs 10f
    madd x0, x26, x24, x23
    madd x1, x27, x24, x23
    mov  x2, x28
    bl   cmp_group_rec
    cbnz w0, 10f
    add  x27, x27, #1
    b    9b
10: mov  x0, x19
    mov  x1, x20
    mov  x2, x22
    mov  x3, x23
    mov  x4, x24
    mov  x5, x26
    mov  x6, x27
    mov  x7, x25
    bl   agg_group
    mov  x26, x27
    b    .Lxa_run
.Lxa_done:
    mov  x0, x25
    LEAVE 5
ENDF ex_aggregate

// =============================================================================
// agg_group(x0 node, x1 ctx, x2 tuple set, x3 records, x4 record size,
//           x5 first record, x6 end record, x7 ResultSet*)
// Aggregates records [first, end) as one group; if HAVING holds, appends a
// projected row to the result set.
//   x19 node, x20 ctx, x21 bq, x22 ts, x23 records, x24 rec size,
//   x25 first, x26 end, x27 rs, x28 state
// =============================================================================
LFUNC agg_group
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    ldr  x21, [x19, #PN_BQ]
    mov  x22, x2
    mov  x23, x3
    mov  x24, x4
    mov  x25, x5
    mov  x26, x6
    stp  x7, xzr, [sp, #-16]!
    mov  x0, x21
    bl   agg_init
    mov  x28, x0
    mov  x9, x25
1:  cmp  x9, x26                        // non-DISTINCT aggregates
    b.hs 3f
    str  x9, [sp, #8]
    tst  x9, #DEADLINE_MASK
    b.ne 2f
    bl   check_deadline
2:  ldr  x9, [sp, #8]
    mul  x10, x9, x24
    ldr  x1, [x23, x10]                 // tuple index
    mov  x0, x22
    bl   ts_tuple
    str  x0, [x20, #EC_TUPLE]
    mov  x0, x21
    mov  x1, x28
    mov  x2, x20
    bl   agg_step
    ldr  x9, [sp, #8]
    add  x9, x9, #1
    b    1b
3:  mov  x0, x19                        // DISTINCT aggregates
    mov  x1, x20
    mov  x2, x22
    mov  x3, x23
    mov  x4, x24
    mov  x5, x25
    mov  x6, x26
    mov  x7, x28
    bl   agg_distinct
    mov  x0, x21
    mov  x1, x28
    bl   agg_finish
    str  x0, [x20, #EC_AGGV]
    // group context: keys of the first record, its tuple as representative
    cmp  x25, x26
    b.eq 4f
    madd x9, x25, x24, x23
    add  x10, x9, #8
    str  x10, [x20, #EC_GKEYS]
    ldr  x1, [x9]
    mov  x0, x22
    bl   ts_tuple
    str  x0, [x20, #EC_TUPLE]
    b    5f
4:  ldr  x0, [x22, #TS_W]               // empty input: all-NULL tuple
    bl   null_tuple
    str  x0, [x20, #EC_TUPLE]
    str  xzr, [x20, #EC_GKEYS]
5:  mov  x0, x19
    mov  x1, x20
    ldr  x2, [sp]
    bl   agg_emit_row
7:  add  sp, sp, #16
    LEAVE 5
ENDF agg_group

// =============================================================================
// agg_emit_row(x0 Aggregate node, x1 ctx with EC_AGGV / EC_GKEYS / EC_TUPLE
// of a finished group, x2 ResultSet*): if HAVING holds, appends the group's
// projected row
//   x19 node, x20 ctx, x21 rs
// =============================================================================
FUNC agg_emit_row
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  x0, [x19, #PN_EXPR]            // HAVING
    cbz  x0, 1f
    mov  x1, x20
    bl   eval_true
    cbz  w0, 2f
1:  ldr  x9, [x21, #RS_WIDTH]
    lsl  x0, x9, #4
    add  x0, x0, #16
    bl   arena_alloc
    ldr  x9, [x21, #RS_NROWS]
    ldr  x10, [x21, #RS_ROWS]
    str  x0, [x10, x9, lsl #3]
    add  x9, x9, #1
    str  x9, [x21, #RS_NROWS]
    mov  x2, x0
    ldr  x0, [x19, #PN_BQ]
    mov  x1, x20
    bl   project_row
2:  LEAVE 3
ENDF agg_emit_row

// null_tuple(x0 width) -> x0 u32* tuple of ROW_NULL ids
FUNC null_tuple
    ENTER 1
    mov  x19, x0
    lsl  x0, x0, #2
    add  x0, x0, #4
    bl   arena_alloc
    mov  x10, x0
    mov  w11, #ROW_NULL
1:  cbz  x19, 2f
    str  w11, [x10], #4
    sub  x19, x19, #1
    b    1b
2:  LEAVE 1
ENDF null_tuple

// =============================================================================
// agg_distinct(x0 node, x1 ctx, x2 ts, x3 records, x4 rec size, x5 first,
//              x6 end, x7 state)
// For every DISTINCT aggregate slot: collect the non-NULL argument values of
// the group, sort them, and accumulate each distinct value once.
//   x19 bq, x20 ctx, x21 slot, x22 values, x23 count, x24 aggregate node,
//   x25 index; stack: ts, records, rec size, first, end, state
// =============================================================================
LFUNC agg_distinct
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 5
    sub  sp, sp, #64
    stp  x2, x3, [sp]
    stp  x4, x5, [sp, #16]
    stp  x6, x7, [sp, #32]
    ldr  x19, [x0, #PN_BQ]
    mov  x20, x1
    mov  x21, #0
.Lad_slot:
    ldr  x9, [x19, #BQ_NAGG]
    cmp  x21, x9
    b.hs .Lad_end
    ldr  x9, [x19, #BQ_AGGS]
    ldr  x24, [x9, x21, lsl #3]
    ldr  w9, [x24, #N_FLAGS]
    tbz  w9, #1, .Lad_next              // NF_DISTINCT
    ldp  x9, x10, [sp, #24]             // first, end
    sub  x0, x10, x9
    lsl  x0, x0, #3
    add  x0, x0, #16
    bl   arena_alloc
    mov  x22, x0
    mov  x23, #0
    ldr  x25, [sp, #24]
1:  ldr  x9, [sp, #32]
    cmp  x25, x9
    b.hs 2f
    ldp  x9, x10, [sp, #8]              // records, rec size
    mul  x10, x25, x10
    ldr  x1, [x9, x10]
    ldr  x0, [sp]
    bl   ts_tuple
    str  x0, [x20, #EC_TUPLE]
    ldr  x0, [x24, #N_A]
    mov  x1, x20
    bl   eval
    cbnz x1, 11f
    str  x0, [x22, x23, lsl #3]
    add  x23, x23, #1
11: add  x25, x25, #1
    b    1b
2:  ldr  x9, [x24, #N_A]                // sort by the argument type
    add  x4, x9, #N_TYPE
    mov  x0, x22
    mov  x1, x23
    mov  x2, #8
    ADR_L x3, cmp_vals
    bl   qsort_r
    mov  x25, #0
3:  cmp  x25, x23
    b.hs .Lad_next
    cbz  x25, 4f
    sub  x9, x25, #1
    ldr  x0, [x22, x9, lsl #3]
    ldr  x1, [x22, x25, lsl #3]
    ldr  x9, [x24, #N_A]
    ldr  w2, [x9, #N_TYPE]
    mov  w3, w2
    bl   cmp_typed
    cbz  w0, 5f                         // duplicate
4:  mov  x0, x24
    ldr  x1, [sp, #40]                  // state + slot * AGG_STATE_SIZE
    mov  x9, #AGG_STATE_SIZE
    madd x1, x21, x9, x1
    ldr  x2, [x22, x25, lsl #3]
    bl   agg_accum
5:  add  x25, x25, #1
    b    3b
.Lad_next:
    add  x21, x21, #1
    b    .Lad_slot
.Lad_end:
    add  sp, sp, #64
    LEAVE 5
ENDF agg_distinct

// cmp_vals(x0 u64*, x1 u64*, x2 u32* type) -> w0   (qsort_r comparator)
LFUNC cmp_vals
    ENTER 0
    ldr  w3, [x2]
    mov  w2, w3
    ldr  x0, [x0]
    ldr  x1, [x1]
    bl   cmp_typed
    LEAVE 0
ENDF cmp_vals

// cmp_group_rec(x0 rec a, x1 rec b, x2 key info) -> w0 (NULLs equal, first)
//   x19 a cells, x20 b cells, x21 keys left, x22 type cursor
FUNC cmp_group_rec
    ENTER 3
    add  x19, x0, #8
    add  x20, x1, #8
    ldr  x21, [x2]
    add  x22, x2, #8
1:  cbz  x21, 5f
    ldr  x9, [x19, #8]
    ldr  x10, [x20, #8]
    cbz  x9, 2f
    cbnz x10, 4f                        // both NULL
    mov  w0, #-1
    b    6f
2:  cbz  x10, 3f
    mov  w0, #1
    b    6f
3:  ldr  x0, [x19]
    ldr  x1, [x20]
    ldr  w2, [x22]
    mov  w3, w2
    bl   cmp_typed
    cbnz w0, 6f
4:  add  x19, x19, #16
    add  x20, x20, #16
    add  x22, x22, #4
    sub  x21, x21, #1
    b    1b
5:  mov  w0, #0
6:  LEAVE 3
ENDF cmp_group_rec

// =============================================================================
// Sorting of result rows
// cmp_rows(x0 Row**, x1 Row**, x2 keys) -> w0   (qsort_r comparator)
// keys: [0] u64 count, then SK_SIZE descriptors.
//   x19 row a, x20 row b, x21 keys left, x22 descriptor
// =============================================================================
FUNC cmp_rows
    ENTER 3
    ldr  x19, [x0]
    ldr  x20, [x1]
    ldr  x21, [x2]
    add  x22, x2, #8
1:  cbz  x21, 8f
    ldr  x3, [x22, #SK_OFF]
    add  x4, x19, x3
    add  x5, x20, x3
    ldr  x6, [x4, #8]                   // a null?
    ldr  x7, [x5, #8]                   // b null?
    cbz  x6, 3f
    cbnz x7, 7f                         // both NULL: equal on this key
    ldr  w0, [x22, #SK_NFIRST]          // a NULL, b not
    cmp  w0, #0
    mov  w0, #1
    csneg w0, w0, w0, eq                // nfirst ? -1 : 1
    b    9f
3:  cbz  x7, 4f
    ldr  w0, [x22, #SK_NFIRST]          // b NULL, a not
    cmp  w0, #0
    mov  w0, #-1
    csneg w0, w0, w0, eq                // nfirst ? 1 : -1
    b    9f
4:  ldr  x0, [x4]
    ldr  x1, [x5]
    ldr  w2, [x22, #SK_TYPE]
    mov  w3, w2
    bl   cmp_typed
    cbz  w0, 7f
    ldr  w1, [x22, #SK_DESC]
    cbz  w1, 9f
    neg  w0, w0
    b    9f
7:  add  x22, x22, #SK_SIZE
    sub  x21, x21, #1
    b    1b
8:  mov  w0, #0
9:  LEAVE 3
ENDF cmp_rows

// cell_type(x0 BoundQuery*, x1 cell index) -> w0 type   (leaf)
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

// order_keys(x0 BoundQuery*) -> x0 key descriptors for the ORDER BY
// The ORDER BY keys are followed by every visible column (ascending, NULLs
// first) as tie-breakers: rows that are equal on the ORDER BY keys come out
// in one well-defined order whatever order the executor produced them in
// (mode, join algorithm, threads), and only identical rows compare equal.
//   x19 bq, x20 keys, x21 index, x22 count, x23 descriptor
FUNC order_keys
    ENTER 3
    mov  x19, x0
    ldr  x22, [x19, #BQ_NORDER]
    ldr  x9, [x19, #BQ_NOUT]
    add  x0, x22, x9
    mov  x10, #SK_SIZE
    mul  x0, x0, x10
    add  x0, x0, #8
    bl   arena_alloc
    mov  x20, x0
    ldr  x9, [x19, #BQ_NOUT]
    add  x9, x22, x9
    str  x9, [x20]
    mov  x21, #0
1:  cmp  x21, x22
    b.hs 2f
    ldr  x9, [x19, #BQ_ORDER]
    add  x9, x9, x21, lsl #4            // OK_SIZE = 16
    mov  x10, #SK_SIZE
    madd x23, x21, x10, x20
    add  x23, x23, #8
    ldr  x1, [x9, #OK_CELL]
    lsl  x2, x1, #4
    str  x2, [x23, #SK_OFF]
    ldr  w2, [x9, #OK_DESC]
    str  w2, [x23, #SK_DESC]
    ldr  w2, [x9, #OK_NFIRST]
    str  w2, [x23, #SK_NFIRST]
    mov  x0, x19
    bl   cell_type
    str  w0, [x23, #SK_TYPE]
    add  x21, x21, #1
    b    1b
2:  mov  x21, #0                        // tie-breakers: visible columns
3:  ldr  x9, [x19, #BQ_NOUT]
    cmp  x21, x9
    b.hs 4f
    add  x10, x22, x21
    mov  x11, #SK_SIZE
    madd x23, x10, x11, x20
    add  x23, x23, #8
    lsl  x9, x21, #4
    str  x9, [x23, #SK_OFF]
    str  wzr, [x23, #SK_DESC]
    mov  w9, #1
    str  w9, [x23, #SK_NFIRST]
    ldr  x9, [x19, #BQ_OUT]
    mov  x10, #OC_SIZE
    madd x9, x21, x10, x9
    ldr  w9, [x9, #OC_TYPE]
    str  w9, [x23, #SK_TYPE]
    add  x21, x21, #1
    b    3b
4:  mov  x0, x20
    LEAVE 3
ENDF order_keys

// sort_rows(x0 Row** rows, x1 count, x2 keys)
FUNC sort_rows
    cmp  x1, #2
    b.lo 1f
    mov  x4, x2
    mov  x2, #8
    ADR_L x3, cmp_rows
    b    qsort_r                        // tail call
1:  ret
ENDF sort_rows

// =============================================================================
// topn_rows(x0 Row** rows, x1 n, x2 keys, x3 k) -> x0 min(n, k)
// Moves the first k rows in ORDER BY order to the front, sorted: a bounded
// max-heap of k rows replaces its largest row whenever a smaller one
// arrives (O(n log k) instead of sorting all n rows).
//   x19 rows, x20 n, x21 keys, x22 k, x23 index, x24 i (sift), x25 child
// =============================================================================
FUNC topn_rows
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3
    cmp  x22, x20
    b.lo 1f
    mov  x0, x19                        // k >= n: plain sort
    mov  x1, x20
    mov  x2, x21
    bl   sort_rows
    mov  x0, x20
    LEAVE 5
1:  cbz  x22, 9f
    lsr  x23, x22, #1                   // heapify rows[0, k)
2:  cbz  x23, 3f
    sub  x23, x23, #1
    mov  x24, x23
    bl   .Ltn_sift
    b    2b
3:  mov  x23, x22
4:  cmp  x23, x20
    b.hs 6f
    tst  x23, #DEADLINE_MASK
    b.ne 41f
    bl   check_deadline
41: add  x0, x19, x23, lsl #3           // rows[j] < rows[0]?
    mov  x1, x19
    mov  x2, x21
    bl   cmp_rows
    tbz  w0, #31, 5f
    ldr  x9, [x19, x23, lsl #3]
    str  x9, [x19]
    mov  x24, #0
    bl   .Ltn_sift
5:  add  x23, x23, #1
    b    4b
6:  mov  x0, x19
    mov  x1, x22
    mov  x2, x21
    bl   sort_rows
9:  mov  x0, x22
    LEAVE 5

// local helper: sift rows[x24] down the max-heap rows[0, k)
.Ltn_sift:
    stp  x29, x30, [sp, #-16]!
1:  lsl  x25, x24, #1
    add  x25, x25, #1                   // left child
    cmp  x25, x22
    b.hs 3f
    add  x9, x25, #1
    cmp  x9, x22
    b.hs 2f
    add  x0, x19, x9, lsl #3            // right > left?
    add  x1, x19, x25, lsl #3
    mov  x2, x21
    bl   cmp_rows
    cmp  w0, #0
    b.le 2f
    add  x25, x25, #1
2:  add  x0, x19, x25, lsl #3           // child > parent: swap
    add  x1, x19, x24, lsl #3
    mov  x2, x21
    bl   cmp_rows
    cmp  w0, #0
    b.le 3f
    ldr  x9, [x19, x25, lsl #3]
    ldr  x10, [x19, x24, lsl #3]
    str  x10, [x19, x25, lsl #3]
    str  x9, [x19, x24, lsl #3]
    mov  x24, x25
    b    1b
3:  ldp  x29, x30, [sp], #16
    ret
ENDF topn_rows

// =============================================================================
// distinct_rows(x0 BoundQuery*, x1 ResultSet*) -> x0 ResultSet*
// Sorts on all visible cells (NULLs equal) and drops adjacent duplicates.
//   x19 bq, x20 rs, x21 keys, x22 read index, x23 write index, x24 rows
// =============================================================================
LFUNC distinct_rows
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldr  x22, [x19, #BQ_NOUT]
    mov  x0, #SK_SIZE
    mul  x0, x22, x0
    add  x0, x0, #8
    bl   arena_zalloc
    mov  x21, x0
    str  x22, [x21]
    mov  x23, #0
1:  cmp  x23, x22
    b.hs 2f
    mov  x9, #SK_SIZE
    madd x9, x23, x9, x21
    add  x9, x9, #8
    lsl  x10, x23, #4
    str  x10, [x9, #SK_OFF]
    mov  w10, #1
    str  w10, [x9, #SK_NFIRST]
    ldr  x10, [x19, #BQ_OUT]
    add  x10, x10, x23, lsl #5
    ldr  w10, [x10, #OC_TYPE]
    str  w10, [x9, #SK_TYPE]
    add  x23, x23, #1
    b    1b
2:  ldr  x0, [x20, #RS_ROWS]
    ldr  x1, [x20, #RS_NROWS]
    mov  x2, x21
    mov  x3, #0
    bl   sort_rows_par
    ldr  x24, [x20, #RS_ROWS]
    ldr  x9, [x20, #RS_NROWS]
    cbz  x9, 5f
    mov  x23, #1
    mov  x22, #1
3:  ldr  x9, [x20, #RS_NROWS]
    cmp  x22, x9
    b.hs 4f
    sub  x9, x23, #1
    add  x0, x24, x9, lsl #3
    add  x1, x24, x22, lsl #3
    mov  x2, x21
    bl   cmp_rows
    cbz  w0, 31f
    ldr  x9, [x24, x22, lsl #3]
    str  x9, [x24, x23, lsl #3]
    add  x23, x23, #1
31: add  x22, x22, #1
    b    3b
4:  str  x23, [x20, #RS_NROWS]
5:  mov  x0, x20
    LEAVE 3
ENDF distinct_rows

// =============================================================================
// ex_tuples(x0 PlanNode*, x1 ctx) -> x0 TupleSet*   (lower operators)
//   x19 node, x20 ctx, x21 bq
// =============================================================================
FUNC ex_tuples
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    TLS_ADDR x9, g_x_mode               // mode "row": Volcano iterators
    ldr  w9, [x9]
    cmp  w9, #XM_ROW
    b.eq it_drain                       // (volcano.S, tail call)
    ENTER 2
    ldr  w9, [x0, #PN_OP]
    cmp  w9, #PO_SCAN
    b.eq 1f
    cmp  w9, #PO_FILTER
    b.eq 2f
    cmp  w9, #PO_HASHJOIN
    b.eq 3f
    cmp  w9, #PO_NLJOIN
    b.eq 4f
    cmp  w9, #PO_MERGEJOIN
    b.eq 8f
    cmp  w9, #PO_VALUES
    b.eq 5f
    RAISE ERR_INTERNAL, "executor: unexpected tuple operator"
1:  bl   ex_scan
    LEAVE 2
2:  bl   ex_filter
    LEAVE 2
3:  bl   ex_hashjoin
    LEAVE 2
4:  bl   ex_nljoin
    LEAVE 2
8:  bl   ex_mergejoin
    LEAVE 2
5:  ldr  x9, [x0, #PN_BQ]               // one tuple (all ROW_NULL)
    ldr  x19, [x9, #BQ_NRV]
    mov  x0, x19
    mov  x1, #1
    bl   ts_new
    mov  x20, x0
    mov  x9, #1
    str  x9, [x20, #TS_N]
    ldr  x10, [x20, #TS_DATA]
    mov  w11, #ROW_NULL
6:  cbz  x19, 7f
    str  w11, [x10], #4
    sub  x19, x19, #1
    b    6b
7:  mov  x0, x20
    LEAVE 2
ENDF ex_tuples

// =============================================================================
// scan_ranges(x0 scan PlanNode*, x1 ctx) -> x0 u64* (lo, hi) ranges,
//   x1 range count, x2 total rows
// Resolves the range variable's table (materialising derived tables / CTEs,
// EC_TABLES[rv]) and lists its candidate rows as row ranges, in row order:
//   * an index lookup (PN_IDX: sorted, de-duplicated row ids, runs merged),
//   * every row group the predicates do not exclude (PQCF-backed tables
//     with min/max statistics), or
//   * the whole table.
//   x19 node, x20 ctx, x21 bq, x22 rv, x23 table, x24 ranges, x25 range
//   count, x26 total rows; [sp] RowVec (index scans), [sp+24] cursor
// =============================================================================
FUNC scan_ranges
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 5
    sub  sp, sp, #32
    mov  x19, x0
    mov  x20, x1
    ldr  x21, [x19, #PN_BQ]
    ldr  x22, [x19, #PN_RV]
    mov  x0, x21
    mov  x1, x22
    mov  x2, x20
    bl   rv_table
    mov  x23, x0
    ldr  x9, [x20, #EC_TABLES]
    str  x23, [x9, x22, lsl #3]
    mov  x25, #0
    mov  x26, #0
    ldr  x9, [x19, #PN_IDX]
    cbnz x9, .Lsr_index
    ldr  x9, [x23, #TBL_NRG]
    cbz  x9, .Lsr_full
    ldr  x9, [x19, #PN_NPREDS]
    cbnz x9, .Lsr_groups
.Lsr_full:
    mov  x0, #32
    bl   arena_alloc
    mov  x24, x0
    mov  x0, #0
    ldr  x1, [x23, #TBL_NROWS]
    bl   .Lsr_add
    b    .Lsr_done
.Lsr_groups:                            // row-group skipping
    ldr  x9, [x23, #TBL_NRG]
    lsl  x0, x9, #4
    add  x0, x0, #16
    bl   arena_alloc
    mov  x24, x0
    str  xzr, [sp, #24]
4:  ldr  x9, [sp, #24]
    ldr  x10, [x23, #TBL_NRG]
    cmp  x9, x10
    b.hs .Lsr_done
    ldr  x3, [x23, #TBL_RGS]
    add  x3, x3, x9, lsl #5             // RG_SIZE = 32
    add  x9, x9, #1
    str  x9, [sp, #24]
    str  x3, [sp, #16]
    ldr  x0, [x19, #PN_PREDS]
    ldr  x1, [x19, #PN_NPREDS]
    mov  x2, x23
    bl   rg_skippable
    cbnz x0, 4b
    ldr  x3, [sp, #16]
    ldr  x0, [x3, #RG_START]
    ldr  x1, [x3, #RG_NROWS]
    add  x1, x1, x0
    bl   .Lsr_add
    b    4b
.Lsr_index:                             // index scan: runs of row ids
    stp  xzr, xzr, [sp]
    str  xzr, [sp, #16]
    mov  x0, x19
    mov  x1, sp
    bl   index_rows
    mov  x0, sp
    bl   rowvec_sort_unique
    ldr  x9, [sp]
    lsl  x0, x9, #4
    add  x0, x0, #16
    bl   arena_alloc
    mov  x24, x0
    str  xzr, [sp, #24]
5:  ldr  x9, [sp, #24]
    ldr  x10, [sp]
    cmp  x9, x10
    b.hs .Lsr_done
    ldr  x10, [sp, #16]
    ldr  w0, [x10, x9, lsl #2]
    add  x9, x9, #1
    str  x9, [sp, #24]
    add  x1, x0, #1
    cbz  x25, 51f                       // extend the previous range?
    sub  x11, x25, #1
    add  x11, x24, x11, lsl #4
    ldr  x12, [x11, #8]
    cmp  x12, x0
    b.ne 51f
    str  x1, [x11, #8]
    add  x26, x26, #1
    b    5b
51: bl   .Lsr_add
    b    5b
.Lsr_done:
    mov  x0, x24
    mov  x1, x25
    mov  x2, x26
    add  sp, sp, #32
    LEAVE 5

// local helper sharing the frame: append range [x0, x1) (x1 > x0)
.Lsr_add:
    add  x9, x24, x25, lsl #4
    stp  x0, x1, [x9]
    add  x25, x25, #1
    sub  x9, x1, x0
    add  x26, x26, x9
    ret
ENDF scan_ranges

// =============================================================================
// ex_scan(x0 PlanNode*, x1 ctx) -> x0 TupleSet*
// The rows of scan_ranges passing the pushed-down filter, in row order (the
// complete filter is evaluated on every candidate row whatever the access
// path). The candidate rows are cut into contiguous windows, one per scan
// task (scan_task); with option threads > 1 and enough rows the tasks run
// in parallel (par_run) and their results are concatenated in order.
//   x19 node, x20 ctx, x24 ranges, x25 range count, x26 total rows,
//   x27 tasks, x28 task records; [sp] scratch
// =============================================================================
LFUNC ex_scan
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 5
    sub  sp, sp, #32
    mov  x19, x0
    mov  x20, x1
    bl   scan_ranges
    mov  x24, x0
    mov  x25, x1
    mov  x26, x2
.Lsc_tasks:
    // number of tasks: threads, at most one per g_par_min_rows rows
    mov  x27, #1
    TLS_LDR x9, g_x_threads
    cmp  x9, #1
    b.ls 6f
    LDR_G x10, g_par_min_rows
    udiv x10, x26, x10
    cmp  x10, x9
    csel x10, x10, x9, lo
    cmp  x10, #2
    b.lo 6f
    str  x10, [sp]
    ldr  x0, [x19, #PN_EXPR]
    bl   expr_par_safe
    cbz  w0, 6f
    ldr  x27, [sp]
6:  mov  x9, #SS_SIZE
    mul  x0, x9, x27
    bl   arena_zalloc
    mov  x28, x0
    add  x9, x26, x27                   // window size: ceil(total / tasks)
    sub  x9, x9, #1
    udiv x9, x9, x27
    mov  x10, #0
    mov  x11, x28
7:  cmp  x10, x27
    b.hs 8f
    str  x19, [x11, #SS_NODE]
    str  x24, [x11, #SS_RANGES]
    str  x25, [x11, #SS_NR]
    mul  x12, x10, x9
    cmp  x12, x26
    csel x12, x12, x26, lo
    str  x12, [x11, #SS_WLO]
    add  x12, x12, x9
    cmp  x12, x26
    csel x12, x12, x26, lo
    str  x12, [x11, #SS_WHI]
    str  x20, [x11, #SS_CTX]
    add  x10, x10, #1
    add  x11, x11, #SS_SIZE
    b    7b
8:  cmp  x27, #1
    b.ne 9f
    mov  x0, x28                        // one task: on this thread
    bl   scan_task
    ldr  x0, [x28, #SS_TS]
    add  sp, sp, #32
    LEAVE 5
9:  mov  x10, #0                        // tasks get their own contexts
    mov  x11, x28
91: cmp  x10, x27
    b.hs 92f
    stp  x10, x11, [sp]
    mov  x0, #EC_SIZE
    bl   arena_alloc
    ldp  x10, x11, [sp]
    ldp  x12, x13, [x20]
    stp  x12, x13, [x0]
    ldp  x12, x13, [x20, #16]
    stp  x12, x13, [x0, #16]
    ldp  x12, x13, [x20, #32]
    stp  x12, x13, [x0, #32]
    str  x0, [x11, #SS_CTX]
    add  x10, x10, #1
    add  x11, x11, #SS_SIZE
    b    91b
92: ADR_L x0, scan_task
    mov  x1, x28
    mov  x2, #SS_SIZE
    mov  x3, x27
    bl   par_run
    mov  x0, x28
    mov  x1, x27
    mov  x2, #SS_SIZE
    bl   ts_concat
    add  sp, sp, #32
    LEAVE 5

ENDF ex_scan

// =============================================================================
// ts_concat(x0 records, x1 count, x2 record stride) -> x0 TupleSet*
// Concatenates the TupleSets at offset 16 (SS_TS / XT_TS) of the records,
// in order.
//   x19 records, x20 count, x21 stride, x22 result, x23 index, x24 bytes
// =============================================================================
FUNC ts_concat
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x9, #0                         // total tuples
    mov  x10, #0
1:  cmp  x10, x20
    b.hs 2f
    madd x11, x10, x21, x19
    ldr  x11, [x11, #16]
    ldr  x12, [x11, #TS_N]
    add  x9, x9, x12
    add  x10, x10, #1
    b    1b
2:  ldr  x11, [x19, #16]
    ldr  x0, [x11, #TS_W]
    mov  x1, x9
    str  x9, [sp, #-16]!
    bl   ts_new
    ldr  x9, [sp], #16
    mov  x22, x0
    str  x9, [x22, #TS_N]
    ldr  x24, [x22, #TS_DATA]
    mov  x23, #0
3:  cmp  x23, x20
    b.hs 4f
    madd x11, x23, x21, x19
    ldr  x11, [x11, #16]
    ldr  x12, [x11, #TS_N]
    ldr  x13, [x11, #TS_W]
    mul  x2, x12, x13
    lsl  x2, x2, #2
    ldr  x1, [x11, #TS_DATA]
    mov  x0, x24
    add  x24, x24, x2
    bl   memcpy
    add  x23, x23, #1
    b    3b
4:  mov  x0, x22
    LEAVE 4
ENDF ts_concat

// =============================================================================
// scan_task(x0 ScanTask*) — scans the candidate rows of its window
// [SS_WLO, SS_WHI) (ordinals over the concatenated SS_RANGES) through the
// filter into a new TupleSet SS_TS: row at a time (mode "row") or in
// batches through the vectorized evaluator.
//   x19 task, x20 ctx, x21 node, x22 width, x23 rv, x24 filter, x25 ts,
//   x26 range index, x27 ordinal of the range start, x28 scratch
//   [sp] piece lo, [sp+8] piece hi, [sp+16] VBatch*, [sp+24] sel,
//   [sp+32] batch tuples
// =============================================================================
FUNC scan_task
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 5
    sub  sp, sp, #48
    mov  x19, x0
    ldr  x20, [x19, #SS_CTX]
    ldr  x21, [x19, #SS_NODE]
    ldr  x9, [x21, #PN_BQ]
    ldr  x22, [x9, #BQ_NRV]
    ldr  x23, [x21, #PN_RV]
    ldr  x24, [x21, #PN_EXPR]
    ldp  x9, x10, [x19, #SS_WLO]
    sub  x1, x10, x9
    cbz  x24, 1f
    lsr  x1, x1, #2                     // filtered: start smaller
1:  mov  x0, x22
    bl   ts_new
    mov  x25, x0
    str  x25, [x19, #SS_TS]
    // tuple scratch: VBATCH tuples, all ROW_NULL
    mov  x9, #VBATCH
    mul  x0, x9, x22
    lsl  x0, x0, #2
    mov  x28, x0
    bl   arena_alloc
    str  x0, [sp, #32]
    mov  w1, #0xff
    mov  x2, x28
    bl   memset
    str  xzr, [sp, #16]
    TLS_ADDR x9, g_x_mode
    ldr  w9, [x9]
    cmp  w9, #XM_ROW
    b.eq 2f
    mov  x0, x20
    mov  x1, x22
    bl   vb_new
    str  x0, [sp, #16]
    ldr  x9, [sp, #32]
    str  x9, [x0, #VB_TUP]
    mov  x0, #(VBATCH * 2)
    bl   arena_alloc
    str  x0, [sp, #24]
2:  ldr  x9, [sp, #32]
    str  x9, [x20, #EC_TUPLE]
    mov  x26, #0
    mov  x27, #0
.Lst_range:
    ldr  x9, [x19, #SS_NR]
    cmp  x26, x9
    b.hs .Lst_end
    ldr  x9, [x19, #SS_RANGES]
    add  x9, x9, x26, lsl #4
    ldp  x10, x11, [x9]                 // range [lo, hi)
    sub  x12, x11, x10                  // length
    ldp  x13, x14, [x19, #SS_WLO]
    add  x15, x27, x12                  // ordinal end of the range
    cmp  x27, x13                       // a = max(ord, wlo)
    csel x16, x27, x13, hi
    cmp  x15, x14                       // b = min(ord + len, whi)
    csel x17, x15, x14, lo
    add  x26, x26, #1
    mov  x27, x15
    cmp  x16, x17
    b.hs .Lst_range
    sub  x16, x16, x15                  // piece: lo + (a - ord), lo + (b - ord)
    sub  x17, x17, x15
    add  x16, x16, x11
    add  x17, x17, x11
    stp  x16, x17, [sp]
    ldr  x9, [sp, #16]
    cbz  x9, .Lst_rows
    bl   .Lst_batches
    b    .Lst_range
.Lst_rows:
    bl   .Lst_rowloop
    b    .Lst_range
.Lst_end:
    add  sp, sp, #48
    LEAVE 5

// local helper: row at a time over [sp, sp+8) (frame shared; the return
// address is kept on the stack, so the piece is at [sp+16])
.Lst_rowloop:
    stp  x29, x30, [sp, #-16]!
    ldr  x28, [sp, #16]
1:  ldr  x9, [sp, #24]
    cmp  x28, x9
    b.hs 4f
    tst  x28, #DEADLINE_MASK
    b.ne 2f
    bl   check_deadline
2:  ldr  x10, [sp, #(16 + 32)]
    str  w28, [x10, x23, lsl #2]
    cbz  x24, 3f
    mov  x0, x24
    mov  x1, x20
    bl   eval_true
    cbz  w0, 31f
3:  mov  x0, x25
    ldr  x1, [sp, #(16 + 32)]
    bl   ts_push
31: add  x28, x28, #1
    b    1b
4:  ldp  x29, x30, [sp], #16
    ret

// local helper: batches over the piece
.Lst_batches:
    stp  x29, x30, [sp, #-16]!
1:  ldp  x9, x10, [sp, #16]             // lo, hi
    cmp  x9, x10
    b.hs 6f
    bl   check_deadline
    ldp  x9, x10, [sp, #16]
    sub  x11, x10, x9
    mov  x12, #VBATCH
    cmp  x11, x12
    csel x28, x11, x12, lo              // batch size
    add  x10, x9, x28
    str  x10, [sp, #16]                 // next lo
    ldr  x11, [sp, #(16 + 32)]          // tuples: slot rv = row
    lsl  x13, x22, #2
    add  x11, x11, x23, lsl #2
    mov  x12, #0
2:  cmp  x12, x28
    b.hs 3f
    add  w14, w9, w12
    str  w14, [x11]
    add  x11, x11, x13
    add  x12, x12, #1
    b    2b
3:  ldr  x0, [sp, #(16 + 16)]
    str  x28, [x0, #VB_N]
    cbz  x24, 4f
    mov  x0, x24
    ldr  x1, [sp, #(16 + 16)]
    ldr  x2, [sp, #(16 + 24)]
    bl   vfilter
    mov  x28, x0
    ldr  x2, [sp, #(16 + 24)]           // selected positions
    b    5f
4:  ADR_L x2, vsel_ident                // no filter: every position
5:  str  x2, [sp, #-16]!
    mov  x0, x25
    mov  x1, x28
    bl   ts_reserve
    ldr  x2, [sp], #16
    ldr  x9, [x25, #TS_N]
    add  x9, x9, x28
    str  x9, [x25, #TS_N]
    ldr  x10, [sp, #(16 + 32)]          // copy the selected tuples
    lsl  x11, x22, #2
51: cbz  x28, 1b
    ldrh w12, [x2], #2
    mul  x12, x12, x11
    add  x12, x10, x12
    mov  x13, x22
52: ldr  w14, [x12], #4
    str  w14, [x0], #4
    subs x13, x13, #1
    b.ne 52b
    sub  x28, x28, #1
    b    51b
6:  ldp  x29, x30, [sp], #16
    ret
ENDF scan_task

// =============================================================================
// index_rows(x0 scan PlanNode* with PN_IDX, x1 RowVec*) — candidate rows of
// an index scan (unsorted, may repeat for IN lists with repeated values).
//   x19 node, x20 vec, x21 IxAccess, x22 Pred, x23 i; [sp] Range (40 bytes)
// =============================================================================
LFUNC index_rows
    ENTER 3
    sub  sp, sp, #48
    mov  x19, x0
    mov  x20, x1
    ldr  x21, [x19, #PN_IXA]
    ldr  w9, [x21, #IA_KIND]
    cmp  w9, #IAK_EQ
    b.ne .Lir_range
    ldr  x22, [x21, #IA_EQ]
    ldr  w9, [x22, #PR_NULL]
    cbnz w9, .Lir_done
    ldr  w9, [x22, #PR_OP]
    cmp  w9, #PRO_IN
    b.eq 1f
    ldr  x0, [x19, #PN_IDX]
    ldr  x1, [x22, #PR_VAL]
    ldr  w2, [x22, #PR_TYPE]
    mov  x3, x20
    bl   index_lookup_eq
    b    .Lir_done
1:  mov  x23, #0
2:  ldr  x9, [x22, #PR_N]
    cmp  x23, x9
    b.hs .Lir_done
    ldr  x0, [x19, #PN_IDX]
    ldr  x9, [x22, #PR_VAL]
    ldr  x1, [x9, x23, lsl #3]
    ldr  w2, [x22, #PR_TYPE]
    mov  x3, x20
    bl   index_lookup_eq
    add  x23, x23, #1
    b    2b
.Lir_range:
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    str  xzr, [sp, #32]
    ldr  x22, [x21, #IA_LO]             // lower bound: GE inclusive, GT not
    cbz  x22, 3f
    ldr  w9, [x22, #PR_NULL]
    cbnz w9, .Lir_done
    ldr  x9, [x22, #PR_VAL]
    ldr  w10, [x22, #PR_OP]
    cmp  w10, #OP_GE
    mov  x11, #1
    mov  x12, #2
    csel x10, x11, x12, eq
    stp  x9, x10, [sp]
    ldr  w9, [x22, #PR_TYPE]
    str  w9, [sp, #32]
3:  ldr  x22, [x21, #IA_HI]             // upper bound: LE inclusive, LT not
    cbz  x22, 4f
    ldr  w9, [x22, #PR_NULL]
    cbnz w9, .Lir_done
    ldr  x9, [x22, #PR_VAL]
    ldr  w10, [x22, #PR_OP]
    cmp  w10, #OP_LE
    mov  x11, #1
    mov  x12, #2
    csel x10, x11, x12, eq
    stp  x9, x10, [sp, #16]
    ldr  w9, [x22, #PR_TYPE]
    str  w9, [sp, #36]
4:  ldr  x0, [x19, #PN_IDX]
    mov  x1, sp
    mov  x2, x20
    bl   index_lookup_range
.Lir_done:
    add  sp, sp, #48
    LEAVE 3
ENDF index_rows

// =============================================================================
// rv_table(x0 BoundQuery*, x1 rv index, x2 ctx) -> x0 Table*
// Base tables come from the catalog binding; derived tables and CTEs are
// executed (outer context: this query for derived tables, the owning query
// for CTEs) and materialised.
//   x19 RV*, x20 ctx, x21 SubPlan*
// =============================================================================
LFUNC rv_table
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 2
    ldr  x9, [x0, #BQ_RVS]
    mov  x10, #RV_SIZE
    madd x19, x1, x10, x9
    mov  x20, x2
    ldr  w9, [x19, #RV_KIND]
    cmp  w9, #RVK_BASE
    b.ne 1f
    ldr  x0, [x19, #RV_TABLE]
    LEAVE 2
1:  ldr  x21, [x19, #RV_SUB]
    cmp  w9, #RVK_CTE
    b.ne 3f
    ldr  x21, [x21, #CD_SP]
    ldr  w9, [x19, #RV_CTEUP]
2:  cbz  w9, 3f
    ldr  x20, [x20, #EC_OUTER]
    sub  w9, w9, #1
    b    2b
3:  mov  x0, x21
    mov  x1, x20
    ldr  x2, [x19, #RV_TABLE]
    bl   materialize
    LEAVE 2
ENDF rv_table

// =============================================================================
// materialize(x0 SubPlan*, x1 outer ctx, x2 shape Table*) -> x0 Table*
// Executes the subquery and converts its rows into a columnar table.
//   x19 sp, x20 rs, x21 shape, x22 table, x23 column, x24 row, x25 Column*
// =============================================================================
LFUNC materialize
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 4
    mov  x19, x0
    mov  x21, x2
    ldr  x9, [x19, #SP_DONE]
    cbz  x9, 1f
    ldr  x0, [x19, #SP_CACHE]
    LEAVE 4
1:  ldr  x0, [x19, #SP_PLAN]
    bl   exec_plan
    mov  x20, x0
    mov  x0, #TBL_SIZE
    bl   arena_zalloc
    mov  x22, x0
    ldr  x9, [x21, #TBL_NAME]
    str  x9, [x22, #TBL_NAME]
    ldr  x9, [x21, #TBL_NCOLS]
    str  x9, [x22, #TBL_NCOLS]
    ldr  x9, [x20, #RS_NROWS]
    str  x9, [x22, #TBL_NROWS]
    ldr  x9, [x21, #TBL_NCOLS]
    lsl  x0, x9, #5
    add  x0, x0, #COL_SIZE
    bl   arena_zalloc
    str  x0, [x22, #TBL_COLS]
    mov  x23, #0
2:  ldr  x9, [x22, #TBL_NCOLS]
    cmp  x23, x9
    b.hs 5f
    ldr  x25, [x22, #TBL_COLS]
    add  x25, x25, x23, lsl #5
    ldr  x9, [x21, #TBL_COLS]
    add  x9, x9, x23, lsl #5
    ldr  x10, [x9, #COL_NAME]
    str  x10, [x25, #COL_NAME]
    ldr  w10, [x9, #COL_TYPE]
    str  w10, [x25, #COL_TYPE]
    ldr  x9, [x20, #RS_NROWS]
    lsl  x0, x9, #3
    add  x0, x0, #8
    bl   arena_alloc
    str  x0, [x25, #COL_DATA]
    ldr  x0, [x20, #RS_NROWS]           // null bitmap
    add  x0, x0, #7
    lsr  x0, x0, #3
    add  x0, x0, #8
    bl   arena_zalloc
    str  x0, [x25, #COL_NULLS]
    mov  x24, #0
3:  ldr  x9, [x20, #RS_NROWS]
    cmp  x24, x9
    b.hs 4f
    ldr  x9, [x20, #RS_ROWS]
    ldr  x9, [x9, x24, lsl #3]
    add  x9, x9, x23, lsl #4
    ldp  x10, x11, [x9]
    ldr  x12, [x25, #COL_DATA]
    str  x10, [x12, x24, lsl #3]
    cbz  x11, 31f
    ldr  x12, [x25, #COL_NULLS]
    lsr  x13, x24, #3
    ldrb w14, [x12, x13]
    and  w15, w24, #7
    mov  w16, #1
    lsl  w16, w16, w15
    orr  w14, w14, w16
    strb w14, [x12, x13]
31:
    add  x24, x24, #1
    b    3b
4:  add  x23, x23, #1
    b    2b
5:  ldr  x9, [x19, #SP_BQ]
    ldr  x9, [x9, #BQ_CORR]
    cbnz x9, 6f
    str  x22, [x19, #SP_CACHE]
    mov  x9, #1
    str  x9, [x19, #SP_DONE]
6:  mov  x0, x22
    LEAVE 4
ENDF materialize

// ex_filter: ops.S

// =============================================================================
// Subquery expressions (semantics.md §8)
// sp_rows(x0 SubPlan*, x1 ctx) -> x0 ResultSet* (cached unless correlated)
//   x19 sp
// =============================================================================
LFUNC sp_rows
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 1
    mov  x19, x0
    ldr  x9, [x19, #SP_DONE]
    cbz  x9, 1f
    ldr  x0, [x19, #SP_CACHE]
    LEAVE 1
1:  ldr  x0, [x19, #SP_PLAN]
    bl   exec_plan
    ldr  x9, [x19, #SP_BQ]
    ldr  x9, [x9, #BQ_CORR]
    cbnz x9, 2f
    str  x0, [x19, #SP_CACHE]
    mov  x9, #1
    str  x9, [x19, #SP_DONE]
2:  LEAVE 1
ENDF sp_rows

// ev_subq: scalar subquery: 0 rows => NULL, > 1 row => SUBQUERY_CARDINALITY
FUNC ev_subq
    ENTER 0
    ldr  x0, [x0, #N_C]
    bl   sp_rows
    ldr  x9, [x0, #RS_NROWS]
    cbz  x9, 1f
    cmp  x9, #1
    b.ne 2f
    ldr  x9, [x0, #RS_ROWS]
    ldr  x9, [x9]
    ldp  x0, x1, [x9]
    LEAVE 0
1:  mov  x0, #0
    mov  x1, #1
    LEAVE 0
2:  RAISE ERR_SUBQUERY_CARDINALITY, "scalar subquery returned more than one row"
ENDF ev_subq

// ev_exists: TRUE iff the subquery returns at least one row (never NULL)
FUNC ev_exists
    ENTER 0
    ldr  x0, [x0, #N_C]
    bl   sp_rows
    ldr  x9, [x0, #RS_NROWS]
    cmp  x9, #0
    cset x0, ne
    mov  x1, #0
    LEAVE 0
ENDF ev_exists

// =============================================================================
// in_set(x0 SubPlan*, x1 ctx) -> x0 InSet* — the subquery's values converted
// to SP_INTYPE and sorted (cached unless correlated).
//   x19 sp, x20 rs, x21 set, x22 index, w23 source type
// =============================================================================
LFUNC in_set
    ENTER 3
    mov  x19, x0
    ldr  x9, [x19, #SP_DONE]
    cbz  x9, 1f
    ldr  x0, [x19, #SP_CACHE]
    LEAVE 3
1:  ldr  x0, [x19, #SP_PLAN]
    bl   exec_plan
    mov  x20, x0
    mov  x0, #IS_SIZE
    bl   arena_zalloc
    mov  x21, x0
    ldr  w9, [x19, #SP_INTYPE]
    str  w9, [x21, #IS_TYPE]
    ldr  x9, [x20, #RS_NROWS]
    lsl  x0, x9, #3
    add  x0, x0, #16
    bl   arena_alloc
    str  x0, [x21, #IS_VALS]
    ldr  x9, [x19, #SP_BQ]
    ldr  x9, [x9, #BQ_OUT]
    ldr  w23, [x9, #OC_TYPE]
    mov  x22, #0
2:  ldr  x9, [x20, #RS_NROWS]
    cmp  x22, x9
    b.hs 5f
    ldr  x9, [x20, #RS_ROWS]
    ldr  x9, [x9, x22, lsl #3]
    ldp  x0, x1, [x9]
    cbz  x1, 3f
    mov  x9, #1
    str  x9, [x21, #IS_HASNULL]
    b    4f
3:  ldr  w2, [x21, #IS_TYPE]
    cmp  w2, w23
    b.eq 31f
    mov  w1, w23
    bl   cast_value
31: ldr  x9, [x21, #IS_N]
    ldr  x10, [x21, #IS_VALS]
    str  x0, [x10, x9, lsl #3]
    add  x9, x9, #1
    str  x9, [x21, #IS_N]
4:  add  x22, x22, #1
    b    2b
5:  ldr  x0, [x21, #IS_VALS]
    ldr  x1, [x21, #IS_N]
    mov  x2, #8
    ADR_L x3, cmp_vals
    add  x4, x21, #IS_TYPE
    bl   qsort_r
    ldr  x9, [x19, #SP_BQ]
    ldr  x9, [x9, #BQ_CORR]
    cbnz x9, 6f
    str  x21, [x19, #SP_CACHE]
    mov  x9, #1
    str  x9, [x19, #SP_DONE]
6:  mov  x0, x21
    LEAVE 3
ENDF in_set

// =============================================================================
// ev_insub: x [NOT] IN (subquery) with SQL three-valued semantics:
// empty set => FALSE; x NULL => NULL; found => TRUE; set has NULL => NULL.
//   x19 node, x20 ctx, x21 set, x22 x payload, x23 lo, x24 hi, w25 x type
// =============================================================================
FUNC ev_insub
    ENTER 4
    mov  x19, x0
    mov  x20, x1
    ldr  x0, [x19, #N_C]
    bl   in_set
    mov  x21, x0
    ldr  x9, [x21, #IS_N]
    ldr  x10, [x21, #IS_HASNULL]
    orr  x9, x9, x10
    cbz  x9, .Lis_false                 // empty subquery result
    ldr  x0, [x19, #N_A]
    mov  x1, x20
    bl   eval
    cbnz x1, .Lis_null
    mov  x22, x0
    ldr  x9, [x19, #N_A]
    ldr  w25, [x9, #N_TYPE]
    mov  x23, #0                        // binary search [lo, hi)
    ldr  x24, [x21, #IS_N]
1:  cmp  x23, x24
    b.hs 3f
    add  x9, x23, x24
    lsr  x9, x9, #1
    str  x9, [sp, #-16]!
    ldr  x10, [x21, #IS_VALS]
    ldr  x1, [x10, x9, lsl #3]
    mov  x0, x22
    mov  w2, w25
    ldr  w3, [x21, #IS_TYPE]
    bl   cmp_typed
    ldr  x9, [sp], #16
    cbz  w0, .Lis_true
    tbz  w0, #31, 2f
    mov  x24, x9                        // x < v: left half
    b    1b
2:  add  x23, x9, #1
    b    1b
3:  ldr  x9, [x21, #IS_HASNULL]
    cbnz x9, .Lis_null
.Lis_false:
    mov  x0, #0
    b    .Lis_ret
.Lis_true:
    mov  x0, #1
.Lis_ret:
    ldr  w9, [x19, #N_OP]               // NOT IN
    eor  x0, x0, x9
    mov  x1, #0
    LEAVE 4
.Lis_null:
    mov  x0, #0
    mov  x1, #1
    LEAVE 4
ENDF ev_insub

    .ltorg
    NOTE_GNU_STACK
