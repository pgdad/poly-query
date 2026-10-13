// =============================================================================
// rule_joinorder.S — optimizer rule reorder_joins.
//
//   rule_reorder_joins(x0 LogicalNode*) -> x0 LogicalNode*
//       Join reordering for regions of >= 3 inputs connected by INNER /
//       CROSS joins (a LEFT JOIN is an input of its region; regions inside
//       its inputs are reordered on their own). Greedy left-deep order:
//       start with the input of the smallest estimated cardinality, then
//       repeatedly join the smallest input that is connected to the joined
//       set by a condition (the smallest input at all if none is). Every
//       condition of the region (ON conditions and WHERE conjuncts already
//       pushed onto its joins) is attached to the lowest join that covers its
//       range variables. Tuples keep one slot per range variable, so the join
//       order never changes the result.
//
// Estimates come from the table statistics (access.S scan_estimate: the
// selectivity of the scan predicate); the rule takes no access-path
// decision. Two-input joins are left alone (the physical planner picks the
// hash join build side).
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .text

// =============================================================================
// rule_reorder_joins(x0 LogicalNode* or 0) -> x0 LogicalNode*
// Finds the FROM trees (the inputs below Filter / Project / Aggregate) of
// the query level and its UNION ALL branches.
//   x19 node, x20 index
// =============================================================================
FUNC rule_reorder_joins
    GUARD_TICK                          // CR-6: recursive
    cbz  x0, 9f
    ldr  w9, [x0, #LN_OP]
    cmp  w9, #LO_JOIN
    b.eq jo_order                       // a FROM tree (tail call)
    ENTER 2
    mov  x19, x0
    ldr  x0, [x19, #LN_LEFT]
    bl   rule_reorder_joins
    str  x0, [x19, #LN_LEFT]
    mov  x20, #0
1:  ldr  x9, [x19, #LN_NKIDS]
    cmp  x20, x9
    b.hs 2f
    ldr  x9, [x19, #LN_KIDS]
    ldr  x0, [x9, x20, lsl #3]
    bl   rule_reorder_joins
    ldr  x9, [x19, #LN_KIDS]
    str  x0, [x9, x20, lsl #3]
    add  x20, x20, #1
    b    1b
2:  mov  x0, x19
    LEAVE 2
9:  ret
ENDF rule_reorder_joins

// =============================================================================
// jo_order(x0 FROM tree) -> x0 root (the same node or a new one)
//   x19 node; [sp] inputs Vec, [sp+32] conditions Vec
// =============================================================================
LFUNC jo_order
    GUARD_TICK                          // CR-6: recursive
    ENTER 2
    sub  sp, sp, #64
    mov  x19, x0
    ldr  w9, [x19, #LN_OP]
    cmp  w9, #LO_JOIN
    b.ne 8f
    ldr  w9, [x19, #LN_JT]
    cmp  w9, #JT_LEFT
    b.ne 1f
    ldr  x0, [x19, #LN_LEFT]            // LEFT JOIN: inside the inputs
    bl   jo_order
    str  x0, [x19, #LN_LEFT]
    ldr  x0, [x19, #LN_RIGHT]
    bl   jo_order
    str  x0, [x19, #LN_RIGHT]
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
    b.lo 8f                             // two inputs: nothing to reorder
    mov  x0, sp
    add  x1, sp, #32
    ldr  x2, [x19, #LN_BQ]
    bl   jo_build
    b    9f
8:  mov  x0, x19
9:  add  sp, sp, #64
    LEAVE 2
ENDF jo_order

// jo_collect(x0 node, x1 inputs Vec*, x2 conditions Vec*): inputs and
// conditions of the inner-join region below node
//   x19 node, x20 inputs, x21 conditions
LFUNC jo_collect
    GUARD_TICK                          // CR-6: recursive
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  w9, [x19, #LN_OP]
    cmp  w9, #LO_JOIN
    b.ne 1f
    ldr  w9, [x19, #LN_JT]
    cmp  w9, #JT_LEFT
    b.eq 1f
    mov  x0, x21
    ldr  x1, [x19, #LN_PRED]
    bl   split_conj
    ldr  x0, [x19, #LN_LEFT]
    mov  x1, x20
    mov  x2, x21
    bl   jo_collect
    ldr  x0, [x19, #LN_RIGHT]
    mov  x1, x20
    mov  x2, x21
    bl   jo_collect
    LEAVE 3
1:  mov  x0, x19                        // an input (reordered inside)
    bl   jo_order
    mov  x1, x0
    mov  x0, x20
    bl   pvec_push
    LEAVE 3
ENDF jo_collect

// jo_estimate(x0 input) -> x0 estimated rows: the statistics estimate of a
// scan with its predicate, a large constant for other inputs (LEFT JOIN
// subtrees)   (x19 node)
LFUNC jo_estimate
    ldr  w9, [x0, #LN_OP]
    cmp  w9, #LO_SUBQUERY
    b.hi 1f
    ldr  x1, [x0, #LN_RV]
    ldr  x2, [x0, #LN_PRED]
    ldr  x0, [x0, #LN_BQ]
    b    scan_estimate
1:  mov  x0, #(1 << 40)
    ret
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
    ldr  x0, [x23, #LN_MASK]
    bl   .Ljb_pick
    mov  w9, #1
    strb w9, [x22, x0]
    ldr  x9, [x20, x0, lsl #3]
    str  x9, [sp, #8]
    mov  w0, #LO_JOIN
    mov  x1, x28
    mov  x2, x23
    bl   ln_new
    mov  w9, #JT_CROSS
    str  w9, [x0, #LN_JT]
    ldr  x9, [sp, #8]
    str  x9, [x0, #LN_RIGHT]
    ldr  x10, [x9, #LN_MASK]
    ldr  x11, [x23, #LN_MASK]
    orr  x10, x10, x11
    str  x10, [x0, #LN_MASK]
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
    ldr  x14, [x13, #LN_MASK]
    add  x11, x11, #1
    bics xzr, x10, x14
    b.ne 71b
    mov  x0, x13
8:  str  x0, [sp, #8]
    ldr  x0, [x0, #LN_PRED]
    ldr  x9, [x27, #16]
    ldr  x1, [x9, x25, lsl #3]
    bl   and_append
    ldr  x9, [sp, #8]
    str  x0, [x9, #LN_PRED]
    mov  w10, #JT_INNER
    str  w10, [x9, #LN_JT]
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
    ldr  x13, [x13, #LN_MASK]
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

    NOTE_GNU_STACK
