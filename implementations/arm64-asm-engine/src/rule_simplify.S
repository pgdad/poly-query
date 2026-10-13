// =============================================================================
// rule_simplify.S — optimizer rule simplify_predicates.
//
//   rule_simplify_predicates(x0 LogicalNode*) -> x0 LogicalNode*
//       Boolean simplification of every expression (three-valued logic,
//       never changing which operands the row evaluator evaluates):
//           x AND TRUE -> x,  TRUE AND x -> x,  FALSE AND x -> FALSE,
//           x OR FALSE -> x,  FALSE OR x -> x,  TRUE OR x -> TRUE,
//           NOT NOT x -> x;
//       then a condition (Filter / Scan predicate, ON, HAVING) that is the
//       literal TRUE is dropped, and a Filter without a predicate disappears.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .text

FUNC rule_simplify_predicates
    ENTER 1
    mov  x19, x0
    ADR_L x1, simplify_slot
    mov  x2, #0
    bl   lp_exprs
    mov  x0, x19
    bl   drop_true
    LEAVE 1
ENDF rule_simplify_predicates

// simplify_slot(x0 Node** slot, x1 unused): *slot = simplify_expr(*slot)
//   x19 slot
LFUNC simplify_slot
    GUARD_TICK                          // CR-6: recursive
    ENTER 1
    mov  x19, x0
    ldr  x0, [x19]
    bl   simplify_expr
    str  x0, [x19]
    LEAVE 1
ENDF simplify_slot

// =============================================================================
// simplify_expr(x0 Node*) -> x0 rewritten Node* (children first)
//   x19 node, x20 index, x21 count
// =============================================================================
LFUNC simplify_expr
    GUARD_TICK                          // CR-6: recursive
    ENTER 2
    mov  x19, x0
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_LIT
    b.eq .Lse_ret
    cmp  w9, #NK_SUBQ                   // subquery plans are optimized
    b.eq .Lse_ret                       // as query levels of their own
    cmp  w9, #NK_EXISTS
    b.eq .Lse_ret
    mov  x0, x19
    bl   expr_nchildren
    mov  x21, x0
    mov  x20, #0
1:  cmp  x20, x21
    b.hs 2f
    mov  x0, x19
    mov  x1, x20
    bl   expr_child_slot
    mov  x1, #0
    bl   simplify_slot
    add  x20, x20, #1
    b    1b
2:  ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_UNARY
    b.eq .Lse_not
    cmp  w9, #NK_BINARY
    b.ne .Lse_ret
    ldr  w9, [x19, #N_OP]
    cmp  w9, #OP_AND
    b.eq .Lse_and
    cmp  w9, #OP_OR
    b.ne .Lse_ret
    // OR: FALSE OR x -> x, TRUE OR x -> TRUE, x OR FALSE -> x
    ldr  x0, [x19, #N_A]
    bl   lit_truth
    cmp  w0, #0
    b.eq .Lse_right
    cmp  w0, #1
    b.eq .Lse_left
    ldr  x0, [x19, #N_B]
    bl   lit_truth
    cmp  w0, #0
    b.eq .Lse_left
    b    .Lse_ret
.Lse_and:
    // AND: TRUE AND x -> x, FALSE AND x -> FALSE, x AND TRUE -> x
    ldr  x0, [x19, #N_A]
    bl   lit_truth
    cmp  w0, #1
    b.eq .Lse_right
    cmp  w0, #0
    b.eq .Lse_left
    ldr  x0, [x19, #N_B]
    bl   lit_truth
    cmp  w0, #1
    b.eq .Lse_left
    b    .Lse_ret
.Lse_not:
    ldr  w9, [x19, #N_OP]
    cmp  w9, #OP_NOT
    b.ne .Lse_ret
    ldr  x9, [x19, #N_A]                // NOT NOT x -> x
    ldr  w10, [x9, #N_KIND]
    cmp  w10, #NK_UNARY
    b.ne .Lse_ret
    ldr  w10, [x9, #N_OP]
    cmp  w10, #OP_NOT
    b.ne .Lse_ret
    ldr  x0, [x9, #N_A]
    LEAVE 2
.Lse_left:
    ldr  x0, [x19, #N_A]
    LEAVE 2
.Lse_right:
    ldr  x0, [x19, #N_B]
    LEAVE 2
.Lse_ret:
    mov  x0, x19
    LEAVE 2
ENDF simplify_expr

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
// drop_true(x0 LogicalNode* or 0) -> x0 LogicalNode*: clears predicates that
// are the literal TRUE and removes Filters left without a predicate
//   x19 node, x20 index
// =============================================================================
LFUNC drop_true
    GUARD_TICK                          // CR-6: recursive
    cbz  x0, 9f
    ENTER 2
    mov  x19, x0
    ldr  x0, [x19, #LN_PRED]
    cbz  x0, 1f
    bl   lit_truth
    cmp  w0, #1
    b.ne 1f
    str  xzr, [x19, #LN_PRED]
1:  ldr  x0, [x19, #LN_LEFT]
    bl   drop_true
    str  x0, [x19, #LN_LEFT]
    ldr  x0, [x19, #LN_RIGHT]
    bl   drop_true
    str  x0, [x19, #LN_RIGHT]
    mov  x20, #0                        // UNION ALL branches
2:  ldr  x9, [x19, #LN_NKIDS]
    cmp  x20, x9
    b.hs 3f
    ldr  x9, [x19, #LN_KIDS]
    ldr  x0, [x9, x20, lsl #3]
    bl   drop_true
    ldr  x9, [x19, #LN_KIDS]
    str  x0, [x9, x20, lsl #3]
    add  x20, x20, #1
    b    2b
3:  mov  x0, x19
    ldr  w9, [x19, #LN_OP]
    cmp  w9, #LO_FILTER
    b.ne 4f
    ldr  x9, [x19, #LN_PRED]
    cbnz x9, 4f
    ldr  x0, [x19, #LN_LEFT]            // empty Filter: its input
4:  LEAVE 2
9:  ret
ENDF drop_true

    NOTE_GNU_STACK
