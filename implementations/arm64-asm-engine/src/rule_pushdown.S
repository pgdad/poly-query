// =============================================================================
// rule_pushdown.S — optimizer rules for predicate pushdown.
//
//   rule_push_filters(x0 LogicalNode*) -> x0 LogicalNode*
//       the conjuncts of a Filter directly above a FROM tree move to the
//       lowest scan or join that produces every range variable they
//       reference: a conjunct over one range variable becomes part of that
//       Scan's predicate, a conjunct over both sides of a join part of the
//       join condition (a CROSS join becomes INNER). Nothing moves into or
//       through the NULL-padded (right) side of a LEFT JOIN or onto a LEFT
//       JOIN's condition. Conjuncts without columns of the query level stay
//       in the Filter; an empty Filter disappears.
//   rule_push_join_conditions(x0 LogicalNode*) -> x0 LogicalNode*
//       (pre-order, so conjuncts moved down from a join are seen by the joins
//       below it) a join condition's conjuncts over one input move into that
//       input the same way — for a LEFT JOIN only into the right input,
//       which is filtered before it is padded. Conjuncts over both inputs
//       stay: the physical planner turns equalities into join keys.
//
// Range variables are tracked as bitmasks (expr_rvmask, LN_MASK); a
// correlated subquery counts as referencing every range variable, so its
// conjunct is evaluated where the whole tuple is available.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .text

// =============================================================================
// rule_push_filters(x0 LogicalNode* or 0) -> x0 LogicalNode*
//   x19 node, x20 conjunct index, x21 input, x22 conjunct, x23 kept,
//   [sp] conjunct Vec (n, cap, data)
// =============================================================================
FUNC rule_push_filters
    STACK_GUARD                         // CR-6: recursive
    cbz  x0, 9f
    ENTER 4
    sub  sp, sp, #32
    mov  x19, x0
    ldr  x0, [x19, #LN_LEFT]            // inputs first (no-ops below FROM)
    bl   rule_push_filters
    str  x0, [x19, #LN_LEFT]
    mov  x20, #0                        // UNION ALL branches
1:  ldr  x9, [x19, #LN_NKIDS]
    cmp  x20, x9
    b.hs 2f
    ldr  x9, [x19, #LN_KIDS]
    ldr  x0, [x9, x20, lsl #3]
    bl   rule_push_filters
    ldr  x9, [x19, #LN_KIDS]
    str  x0, [x9, x20, lsl #3]
    add  x20, x20, #1
    b    1b
2:  ldr  w9, [x19, #LN_OP]
    cmp  w9, #LO_FILTER
    b.ne .Lpf_ret
    ldr  x21, [x19, #LN_LEFT]
    ldr  w9, [x21, #LN_OP]
    cmp  w9, #LO_SUBQUERY               // above Scan / SubqueryScan / Join
    b.ls 3f
    cmp  w9, #LO_JOIN
    b.ne .Lpf_ret
3:  stp  xzr, xzr, [sp]
    str  xzr, [sp, #16]
    mov  x0, sp
    ldr  x1, [x19, #LN_PRED]
    bl   split_conj
    mov  x23, #0
    mov  x20, #0
4:  ldr  x9, [sp]
    cmp  x20, x9
    b.hs 6f
    ldr  x9, [sp, #16]
    ldr  x22, [x9, x20, lsl #3]
    mov  x0, x22
    bl   expr_rvmask
    cbz  x0, 5f                         // constant / outer only: keep
    mov  x2, x0
    mov  x0, x21
    mov  x1, x22
    bl   lp_push
    cbnz w0, 51f
5:  mov  x0, x23
    mov  x1, x22
    bl   and_append
    mov  x23, x0
51: add  x20, x20, #1
    b    4b
6:  str  x23, [x19, #LN_PRED]
    cbnz x23, .Lpf_ret
    mov  x19, x21                       // empty Filter: its input
.Lpf_ret:
    mov  x0, x19
    add  sp, sp, #32
    LEAVE 4
9:  ret
ENDF rule_push_filters

// =============================================================================
// rule_push_join_conditions(x0 LogicalNode* or 0) -> x0 LogicalNode*
//   x19 node, x20 conjunct index, x21 conjunct, x22 its mask, x23 kept,
//   x24 left mask, x25 right mask, [sp] conjunct Vec
// =============================================================================
FUNC rule_push_join_conditions
    STACK_GUARD                         // CR-6: recursive
    cbz  x0, 9f
    ENTER 5
    sub  sp, sp, #32
    mov  x19, x0
    ldr  w9, [x19, #LN_OP]
    cmp  w9, #LO_JOIN
    b.ne .Lpj_inputs
    ldr  x9, [x19, #LN_LEFT]
    ldr  x24, [x9, #LN_MASK]
    ldr  x9, [x19, #LN_RIGHT]
    ldr  x25, [x9, #LN_MASK]
    stp  xzr, xzr, [sp]
    str  xzr, [sp, #16]
    mov  x0, sp
    ldr  x1, [x19, #LN_PRED]
    bl   split_conj
    mov  x23, #0
    mov  x20, #0
1:  ldr  x9, [sp]
    cmp  x20, x9
    b.hs 5f
    ldr  x9, [sp, #16]
    ldr  x21, [x9, x20, lsl #3]
    mov  x0, x21
    bl   expr_rvmask
    mov  x22, x0
    cbz  x22, 4f                        // no column of this level: keep
    bics xzr, x22, x25                  // within the right input
    b.ne 2f                             // (valid for INNER and LEFT joins)
    ldr  x0, [x19, #LN_RIGHT]
    b    3f
2:  ldr  w9, [x19, #LN_JT]
    cmp  w9, #JT_LEFT
    b.eq 4f
    bics xzr, x22, x24                  // within the left input (not LEFT)
    b.ne 4f
    ldr  x0, [x19, #LN_LEFT]
3:  mov  x1, x21
    mov  x2, x22
    bl   lp_push
    cbnz w0, 41f
4:  mov  x0, x23
    mov  x1, x21
    bl   and_append
    mov  x23, x0
41: add  x20, x20, #1
    b    1b
5:  str  x23, [x19, #LN_PRED]
    cbz  x23, .Lpj_inputs
    ldr  w9, [x19, #LN_JT]              // a CROSS join with a condition
    cmp  w9, #JT_CROSS
    b.ne .Lpj_inputs
    mov  w9, #JT_INNER
    str  w9, [x19, #LN_JT]
.Lpj_inputs:
    ldr  x0, [x19, #LN_LEFT]
    bl   rule_push_join_conditions
    str  x0, [x19, #LN_LEFT]
    ldr  x0, [x19, #LN_RIGHT]
    bl   rule_push_join_conditions
    str  x0, [x19, #LN_RIGHT]
    mov  x20, #0                        // UNION ALL branches
6:  ldr  x9, [x19, #LN_NKIDS]
    cmp  x20, x9
    b.hs 7f
    ldr  x9, [x19, #LN_KIDS]
    ldr  x0, [x9, x20, lsl #3]
    bl   rule_push_join_conditions
    ldr  x9, [x19, #LN_KIDS]
    str  x0, [x9, x20, lsl #3]
    add  x20, x20, #1
    b    6b
7:  mov  x0, x19
    add  sp, sp, #32
    LEAVE 5
9:  ret
ENDF rule_push_join_conditions

// =============================================================================
// lp_push(x0 LogicalNode* Scan / SubqueryScan / Join, x1 conjunct,
//         x2 rv mask) -> w0 1 if the conjunct was absorbed by the subtree
//   x19 node, x20 conjunct, x21 mask
// =============================================================================
LFUNC lp_push
    STACK_GUARD                         // CR-6: recursive
    ENTER 2
    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    ldr  w9, [x19, #LN_OP]
    cmp  w9, #LO_SUBQUERY
    b.hi 1f
    ldr  x0, [x19, #LN_PRED]            // scan predicate
    mov  x1, x20
    bl   and_append
    str  x0, [x19, #LN_PRED]
    b    .Llp_yes
1:  ldr  x0, [x19, #LN_LEFT]
    ldr  x9, [x0, #LN_MASK]
    bics xzr, x21, x9                   // within the left input?
    b.ne 2f
    mov  x1, x20
    mov  x2, x21
    bl   lp_push
    LEAVE 2
2:  ldr  w9, [x19, #LN_JT]
    cmp  w9, #JT_LEFT
    b.eq .Llp_no                        // never into / onto a LEFT JOIN
    ldr  x0, [x19, #LN_RIGHT]
    ldr  x9, [x0, #LN_MASK]
    bics xzr, x21, x9                   // within the right input?
    b.ne 3f
    mov  x1, x20
    mov  x2, x21
    bl   lp_push
    LEAVE 2
3:  ldr  x0, [x19, #LN_PRED]            // spans both: join condition
    mov  x1, x20
    bl   and_append
    str  x0, [x19, #LN_PRED]
    mov  w9, #JT_INNER                  // CROSS + condition = INNER
    str  w9, [x19, #LN_JT]
.Llp_yes:
    mov  w0, #1
    LEAVE 2
.Llp_no:
    mov  w0, #0
    LEAVE 2
ENDF lp_push

    NOTE_GNU_STACK
