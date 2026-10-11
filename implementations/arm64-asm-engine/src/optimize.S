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
