// =============================================================================
// optimize.S — logical rewrites of a bound query (Phase 5, option
// "optimize", default true; plan.S calls opt_query before building the
// logical plan when it is on).
//
//   opt_query(x0 BoundQuery*)   rewrites every expression of the query level
//                               (WHERE, ON conditions, GROUP BY, aggregate
//                               arguments, HAVING, SELECT list, hidden ORDER
//                               BY expressions) in place
//
// Rewrites:
//   * constant folding: every constant subtree (binder flag NF_CONST, no
//     subquery) is evaluated once at planning time and replaced by a
//     literal. The evaluation runs under its own error handler (try_eval):
//     a constant that raises (1/0, overflow, bad CAST) is left alone, so the
//     error still happens at run time exactly when the unoptimized plan
//     would raise it.
//   * predicate simplification (three-valued logic, never changing which
//     operands the row evaluator evaluates):
//       x AND TRUE -> x,  TRUE AND x -> x,  FALSE AND x -> FALSE,
//       x OR FALSE -> x,  FALSE OR x -> x,  TRUE OR x -> TRUE,
//       NOT NOT x -> x;
//     a WHERE / HAVING / ON condition that becomes TRUE is dropped.
//
//   opt_join_order(x0 FROM tree) -> x0 root   join reordering (called by
//                               plan.S after the WHERE pushdown)
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .text

// =============================================================================
// opt_query(x0 BoundQuery*)
//   x19 bq, x20 index, x21 array
// =============================================================================
FUNC opt_query
    ENTER 3
    mov  x19, x0
    add  x0, x19, #BQ_WHERE
    bl   opt_cond_slot
    add  x0, x19, #BQ_HAVING
    bl   opt_cond_slot
    ldr  x0, [x19, #BQ_FROM]
    bl   opt_from
    ldr  x21, [x19, #BQ_GROUP]          // GROUP BY expressions
    mov  x20, #0
1:  ldr  x9, [x19, #BQ_NGROUP]
    cmp  x20, x9
    b.hs 2f
    add  x0, x21, x20, lsl #3
    bl   opt_slot
    add  x20, x20, #1
    b    1b
2:  ldr  x21, [x19, #BQ_AGGS]           // aggregate arguments
    mov  x20, #0
3:  ldr  x9, [x19, #BQ_NAGG]
    cmp  x20, x9
    b.hs 4f
    ldr  x9, [x21, x20, lsl #3]
    add  x0, x9, #N_A
    ldr  x10, [x0]
    cbz  x10, 31f                       // COUNT(*)
    bl   opt_slot
31: add  x20, x20, #1
    b    3b
4:  ldr  x21, [x19, #BQ_OUT]            // output columns
    mov  x20, #0
5:  ldr  x9, [x19, #BQ_NOUT]
    cmp  x20, x9
    b.hs 6f
    mov  x9, #OC_SIZE
    madd x0, x20, x9, x21
    add  x0, x0, #OC_EXPR
    bl   opt_slot
    add  x20, x20, #1
    b    5b
6:  ldr  x21, [x19, #BQ_EXTRA]          // hidden ORDER BY expressions
    mov  x20, #0
7:  ldr  x9, [x19, #BQ_NEXTRA]
    cmp  x20, x9
    b.hs 8f
    add  x0, x21, x20, lsl #3
    bl   opt_slot
    add  x20, x20, #1
    b    7b
8:  LEAVE 3
ENDF opt_query

// opt_from(x0 BoundFrom* or 0): ON conditions of the FROM tree
//   x19 node
LFUNC opt_from
    cbz  x0, 2f
    ENTER 1
    mov  x19, x0
    ldr  w9, [x19, #BF_KIND]
    cmp  w9, #BFK_JOIN
    b.ne 1f
    add  x0, x19, #BF_ON
    bl   opt_cond_slot
    ldr  x0, [x19, #BF_LEFT]
    bl   opt_from
    ldr  x0, [x19, #BF_RIGHT]
    bl   opt_from
1:  LEAVE 1
2:  ret
ENDF opt_from

// opt_cond_slot(x0 Node** slot of a condition, may hold 0): rewrites it and
// drops it (0) if it became the literal TRUE
//   x19 slot
LFUNC opt_cond_slot
    ldr  x9, [x0]
    cbz  x9, 2f
    ENTER 1
    mov  x19, x0
    bl   opt_slot
    ldr  x0, [x19]
    bl   lit_truth
    cmp  w0, #1
    b.ne 1f
    str  xzr, [x19]
1:  LEAVE 1
2:  ret
ENDF opt_cond_slot

// opt_slot(x0 Node** slot): *slot = opt_expr(*slot)
//   x19 slot
LFUNC opt_slot
    ENTER 1
    mov  x19, x0
    ldr  x0, [x19]
    bl   opt_expr
    str  x0, [x19]
    LEAVE 1
ENDF opt_slot

// lit_truth(x0 Node*) -> w0 1 literal TRUE, 0 literal FALSE, -1 otherwise
// (leaf)
LFUNC lit_truth
    ldr  w9, [x0, #N_KIND]
    cmp  w9, #NK_LIT
    b.ne 1f
    ldrb w9, [x0, #N_TYPE]
    cmp  w9, #T_BOOL
    b.ne 1f
    ldr  w9, [x0, #N_FLAGS]
    tbnz w9, #0, 1f                     // NF_NULL
    ldr  x9, [x0, #N_VAL]
    cmp  x9, #0
    cset w0, ne
    ret
1:  mov  w0, #-1
    ret
ENDF lit_truth

// =============================================================================
// opt_expr(x0 Node*) -> x0 rewritten Node* (children first)
//   x19 node, x20 index, x21 count, x22 truth of the left operand
// =============================================================================
LFUNC opt_expr
    ENTER 3
    mov  x19, x0
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_LIT
    b.eq .Loe_ret
    cmp  w9, #NK_SUBQ                   // subquery plans are optimized
    b.eq .Loe_ret                       // as query levels of their own
    cmp  w9, #NK_EXISTS
    b.eq .Loe_ret
    mov  x0, x19
    bl   expr_nchildren
    mov  x21, x0
    mov  x20, #0
1:  cmp  x20, x21
    b.hs 2f
    mov  x0, x19
    mov  x1, x20
    bl   expr_child_slot
    bl   opt_slot
    add  x20, x20, #1
    b    1b
2:  // constant folding
    ldr  w9, [x19, #N_FLAGS]
    tbz  w9, #3, .Loe_simplify          // NF_CONST
    mov  x0, x19
    bl   opt_foldable
    cbz  w0, .Loe_simplify
    mov  x0, x19
    bl   try_eval
    cbz  w2, .Loe_simplify
    str  x0, [x19, #N_VAL]
    mov  w9, #NK_LIT
    str  w9, [x19, #N_KIND]
    mov  w9, #NF_CONST
    cbz  x1, 3f
    orr  w9, w9, #NF_NULL
3:  str  w9, [x19, #N_FLAGS]
    stp  xzr, xzr, [x19, #N_A]
    str  xzr, [x19, #N_C]
    b    .Loe_ret
.Loe_simplify:
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_UNARY
    b.eq .Loe_not
    cmp  w9, #NK_BINARY
    b.ne .Loe_ret
    ldr  w9, [x19, #N_OP]
    cmp  w9, #OP_AND
    b.eq .Loe_and
    cmp  w9, #OP_OR
    b.ne .Loe_ret
    // OR: FALSE OR x -> x, TRUE OR x -> TRUE, x OR FALSE -> x
    ldr  x0, [x19, #N_A]
    bl   lit_truth
    cmp  w0, #0
    b.eq .Loe_right
    cmp  w0, #1
    b.eq .Loe_left
    ldr  x0, [x19, #N_B]
    bl   lit_truth
    cmp  w0, #0
    b.eq .Loe_left
    b    .Loe_ret
.Loe_and:
    // AND: TRUE AND x -> x, FALSE AND x -> FALSE, x AND TRUE -> x
    ldr  x0, [x19, #N_A]
    bl   lit_truth
    cmp  w0, #1
    b.eq .Loe_right
    cmp  w0, #0
    b.eq .Loe_left
    ldr  x0, [x19, #N_B]
    bl   lit_truth
    cmp  w0, #1
    b.eq .Loe_left
    b    .Loe_ret
.Loe_not:
    ldr  w9, [x19, #N_OP]
    cmp  w9, #OP_NOT
    b.ne .Loe_ret
    ldr  x9, [x19, #N_A]                // NOT NOT x -> x
    ldr  w10, [x9, #N_KIND]
    cmp  w10, #NK_UNARY
    b.ne .Loe_ret
    ldr  w10, [x9, #N_OP]
    cmp  w10, #OP_NOT
    b.ne .Loe_ret
    ldr  x0, [x9, #N_A]
    LEAVE 3
.Loe_left:
    ldr  x0, [x19, #N_A]
    LEAVE 3
.Loe_right:
    ldr  x0, [x19, #N_B]
    LEAVE 3
.Loe_ret:
    mov  x0, x19
    LEAVE 3
ENDF opt_expr

// =============================================================================
// opt_join_order(x0 FROM tree root) -> x0 root (the same node or a new one)
// Join reordering for regions of >= 3 inputs connected by INNER / CROSS
// joins (a LEFT JOIN is an input of its region; regions inside its inputs
// are reordered on their own). Greedy left-deep order: start with the input
// of the smallest estimated cardinality, then repeatedly join the smallest
// input that is connected to the joined set by a condition (the smallest
// input at all if none is). Every condition of the region (ON conditions and
// the WHERE conjuncts already pushed onto its joins) is attached to the
// lowest join that covers its range variables; plan.S then derives the join
// keys and pushes single-input conjuncts into the inputs as usual. Tuples
// keep one slot per range variable, so the join order never changes the
// result.
//   x19 node; [sp] inputs Vec, [sp+32] conditions Vec
// =============================================================================
FUNC opt_join_order
    ENTER 2
    sub  sp, sp, #64
    mov  x19, x0
    ldr  w9, [x19, #PN_OP]
    cmp  w9, #PO_JOIN
    b.ne 8f
    ldr  w9, [x19, #PN_JT]
    cmp  w9, #JT_LEFT
    b.ne 1f
    ldr  x0, [x19, #PN_LEFT]            // LEFT JOIN: inside the inputs
    bl   opt_join_order
    str  x0, [x19, #PN_LEFT]
    ldr  x0, [x19, #PN_RIGHT]
    bl   opt_join_order
    str  x0, [x19, #PN_RIGHT]
    b    8f
1:  stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    stp  xzr, xzr, [sp, #32]
    stp  xzr, xzr, [sp, #48]
    mov  x0, x19
    mov  x1, sp
    add  x2, sp, #32
    bl   jo_collect
    ldr  x9, [sp]
    cmp  x9, #3
    b.lo 8f                             // two inputs: build side suffices
    mov  x0, sp
    add  x1, sp, #32
    ldr  x2, [x19, #PN_BQ]
    bl   jo_build
    b    9f
8:  mov  x0, x19
9:  add  sp, sp, #64
    LEAVE 2
ENDF opt_join_order

// jo_collect(x0 node, x1 inputs Vec*, x2 conditions Vec*): inputs and
// conditions of the inner-join region below node
//   x19 node, x20 inputs, x21 conditions
LFUNC jo_collect
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  w9, [x19, #PN_OP]
    cmp  w9, #PO_JOIN
    b.ne 1f
    ldr  w9, [x19, #PN_JT]
    cmp  w9, #JT_LEFT
    b.eq 1f
    mov  x0, x21
    ldr  x1, [x19, #PN_EXPR]
    bl   split_conj
    ldr  x0, [x19, #PN_LEFT]
    mov  x1, x20
    mov  x2, x21
    bl   jo_collect
    ldr  x0, [x19, #PN_RIGHT]
    mov  x1, x20
    mov  x2, x21
    bl   jo_collect
    LEAVE 3
1:  mov  x0, x19                        // an input (reordered inside)
    bl   opt_join_order
    mov  x1, x0
    mov  x0, x20
    bl   pvec_push
    LEAVE 3
ENDF jo_collect

// jo_estimate(x0 input) -> x0 estimated rows: access-path estimate of a
// scan (the scan's access path is reset; pp_access chooses it later), a
// large constant for other inputs (LEFT JOIN subtrees)
//   x19 node
LFUNC jo_estimate
    ENTER 1
    mov  x19, x0
    ldr  w9, [x19, #PN_OP]
    cmp  w9, #PO_SCAN
    b.ne 1f
    bl   ap_scan
    str  xzr, [x19, #PN_IDX]
    str  xzr, [x19, #PN_IXA]
    str  xzr, [x19, #PN_PREDS]
    str  xzr, [x19, #PN_NPREDS]
    str  wzr, [x19, #PN_RGSKIP]
    LEAVE 1
1:  mov  x0, #(1 << 40)
    LEAVE 1
ENDF jo_estimate

// =============================================================================
// jo_build(x0 inputs Vec*, x1 conditions Vec*, x2 BoundQuery*) -> x0 root
//   x19 n inputs, x20 inputs, x21 estimates, x22 used flags, x23 current
//   tree, x24 joins built (bottom up), x25 index / best, x26 condition
//   masks, x27 conditions Vec*, x28 bq
// =============================================================================
LFUNC jo_build
    ENTER 5
    sub  sp, sp, #16
    ldr  x19, [x0]
    ldr  x20, [x0, #16]
    mov  x27, x1
    mov  x28, x2
    lsl  x0, x19, #3
    bl   arena_alloc
    mov  x21, x0
    mov  x0, x19
    bl   arena_zalloc
    mov  x22, x0
    lsl  x0, x19, #3
    bl   arena_alloc
    mov  x24, x0
    ldr  x9, [x27]
    lsl  x0, x9, #3
    add  x0, x0, #8
    bl   arena_alloc
    mov  x26, x0
    mov  x25, #0                        // condition masks
1:  ldr  x9, [x27]
    cmp  x25, x9
    b.hs 2f
    ldr  x9, [x27, #16]
    ldr  x0, [x9, x25, lsl #3]
    bl   expr_rvmask
    str  x0, [x26, x25, lsl #3]
    add  x25, x25, #1
    b    1b
2:  mov  x25, #0                        // input estimates
3:  cmp  x25, x19
    b.hs 4f
    ldr  x0, [x20, x25, lsl #3]
    bl   jo_estimate
    str  x0, [x21, x25, lsl #3]
    add  x25, x25, #1
    b    3b
4:  mov  x0, #0                         // start: the smallest input
    bl   .Ljb_pick
    mov  w9, #1
    strb w9, [x22, x0]
    ldr  x23, [x20, x0, lsl #3]
    mov  x25, #1
5:  cmp  x25, x19                       // add the others one by one
    b.hs 6f
    str  x25, [sp]
    ldr  x0, [x23, #PN_MASK]
    bl   .Ljb_pick
    mov  w9, #1
    strb w9, [x22, x0]
    ldr  x9, [x20, x0, lsl #3]
    str  x9, [sp, #8]
    mov  w0, #PO_JOIN
    mov  x1, x28
    mov  x2, x23
    bl   pn_new
    mov  w9, #JT_CROSS
    str  w9, [x0, #PN_JT]
    ldr  x9, [sp, #8]
    str  x9, [x0, #PN_RIGHT]
    ldr  x10, [x9, #PN_MASK]
    ldr  x11, [x23, #PN_MASK]
    orr  x10, x10, x11
    str  x10, [x0, #PN_MASK]
    mov  x23, x0
    ldr  x25, [sp]
    sub  x9, x25, #1
    str  x23, [x24, x9, lsl #3]
    add  x25, x25, #1
    b    5b
6:  mov  x25, #0                        // attach the conditions
7:  ldr  x9, [x27]
    cmp  x25, x9
    b.hs 9f
    ldr  x10, [x26, x25, lsl #3]        // condition mask
    mov  x0, x23                        // default: the root
    cbz  x10, 8f
    mov  x11, #0
71: sub  x12, x19, #1
    cmp  x11, x12
    b.hs 8f
    ldr  x13, [x24, x11, lsl #3]
    ldr  x14, [x13, #PN_MASK]
    add  x11, x11, #1
    bics xzr, x10, x14
    b.ne 71b
    mov  x0, x13
8:  str  x0, [sp, #8]
    ldr  x0, [x0, #PN_EXPR]
    ldr  x9, [x27, #16]
    ldr  x1, [x9, x25, lsl #3]
    bl   and_append
    ldr  x9, [sp, #8]
    str  x0, [x9, #PN_EXPR]
    mov  w10, #JT_INNER
    str  w10, [x9, #PN_JT]
    add  x25, x25, #1
    b    7b
9:  mov  x0, x23
    add  sp, sp, #16
    LEAVE 5

// local helper: x0 mask of the joined set (0: none yet) -> x0 index of the
// next input: unused, connected to the set by a condition if any is, then
// the smallest estimate (ties: FROM order). Clobbers x9-x17.
.Ljb_pick:
    mov  x9, #-1                        // best
    mov  x10, #0                        // best connected
    mov  x11, #0                        // j
1:  cmp  x11, x19
    b.hs 6f
    ldrb w12, [x22, x11]
    cbnz w12, 5f
    mov  x12, #0                        // connected?
    cbz  x0, 3f
    ldr  x13, [x20, x11, lsl #3]
    ldr  x13, [x13, #PN_MASK]
    orr  x14, x13, x0
    mov  x15, #0
2:  ldr  x16, [x27]
    cmp  x15, x16
    b.hs 3f
    ldr  x16, [x26, x15, lsl #3]
    add  x15, x15, #1
    tst  x16, x13
    b.eq 2b
    tst  x16, x0
    b.eq 2b
    bics xzr, x16, x14
    b.ne 2b
    mov  x12, #1
3:  cmn  x9, #1
    b.eq 4f
    cmp  x12, x10
    b.hi 4f
    b.lo 5f
    ldr  x13, [x21, x11, lsl #3]
    ldr  x14, [x21, x9, lsl #3]
    cmp  x13, x14
    b.hs 5f
4:  mov  x9, x11
    mov  x10, x12
5:  add  x11, x11, #1
    b    1b
6:  mov  x0, x9
    ret
ENDF jo_build

// opt_foldable(x0 Node*) -> w0 1 if the tree only has kinds that evaluate
// without any context (literals, operators, casts, scalar functions, CASE,
// IN lists, LIKE): no columns, aggregates, group keys or subqueries
//   x19 node, x20 index, x21 count
LFUNC opt_foldable
    ENTER 3
    mov  x19, x0
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_LIT
    b.eq 3f
    cmp  w9, #NK_UNARY
    b.eq 1f
    cmp  w9, #NK_BINARY
    b.eq 1f
    cmp  w9, #NK_CAST
    b.eq 1f
    cmp  w9, #NK_ISNULL
    b.eq 1f
    cmp  w9, #NK_FUNC
    b.eq 1f
    cmp  w9, #NK_CASE
    b.eq 1f
    cmp  w9, #NK_IN
    b.eq 1f
    cmp  w9, #NK_LIKE
    b.ne 4f
1:  mov  x0, x19
    bl   expr_nchildren
    mov  x21, x0
    mov  x20, #0
2:  cmp  x20, x21
    b.hs 3f
    mov  x0, x19
    mov  x1, x20
    bl   expr_child_slot
    ldr  x0, [x0]
    bl   opt_foldable
    cbz  w0, 5f
    add  x20, x20, #1
    b    2b
3:  mov  w0, #1
    LEAVE 3
4:  mov  w0, #0
5:  LEAVE 3
ENDF opt_foldable

// =============================================================================
// try_eval(x0 constant Node*) -> x0 payload, x1 isnull, w2 1 if evaluated
// (0 if the evaluation raised an error; the error is discarded)
// Runs eval under a nested error handler: the request's jump buffer is
// saved and restored around it.
//   x19 node; stack: [sp] result, [sp+16] saved g_jmpbuf (512 bytes)
// =============================================================================
LFUNC try_eval
    ENTER 1
    sub  sp, sp, #(512 + 16)
    mov  x19, x0
    add  x0, sp, #16
    TLS_ADDR x1, g_jmpbuf
    mov  x2, #512
    bl   memcpy
    TLS_ADDR x0, g_jmpbuf
    bl   setjmp
    cbnz w0, 1f
    mov  x0, #EC_SIZE
    bl   arena_zalloc
    mov  x1, x0
    mov  x0, x19
    bl   eval
    stp  x0, x1, [sp]
    bl   .Lte_restore
    ldp  x0, x1, [sp]
    mov  w2, #1
    add  sp, sp, #(512 + 16)
    LEAVE 1
1:  bl   .Lte_restore
    TLS_ADDR x9, g_err_code
    str  wzr, [x9]
    mov  x0, #0
    mov  x1, #1
    mov  w2, #0
    add  sp, sp, #(512 + 16)
    LEAVE 1
.Lte_restore:
    stp  x29, x30, [sp, #-16]!
    TLS_ADDR x0, g_jmpbuf
    add  x1, sp, #(16 + 16)
    mov  x2, #512
    bl   memcpy
    ldp  x29, x30, [sp], #16
    ret
ENDF try_eval

    NOTE_GNU_STACK
