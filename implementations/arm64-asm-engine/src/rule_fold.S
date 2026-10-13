// =============================================================================
// rule_fold.S — optimizer rule fold_constants.
//
//   rule_fold_constants(x0 LogicalNode*) -> x0 LogicalNode*
//       every constant subtree of every expression of the plan (binder flag
//       NF_CONST: no columns, aggregates, group keys, subqueries or PQ_SLEEP)
//       is evaluated once at planning time and the node becomes a literal.
//       The evaluation runs under its own error handler (try_eval): a
//       constant that raises (1/0, overflow, bad CAST) is left alone, so the
//       error still happens at run time exactly when the unoptimized plan
//       would raise it.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .text

FUNC rule_fold_constants
    ENTER 1
    mov  x19, x0
    ADR_L x1, fold_slot
    mov  x2, #0
    bl   lp_exprs
    mov  x0, x19
    LEAVE 1
ENDF rule_fold_constants

// fold_slot(x0 Node** slot, x1 unused): folds the expression in place
LFUNC fold_slot
    ldr  x0, [x0]
    b    fold_expr
ENDF fold_slot

// =============================================================================
// fold_expr(x0 Node*) — children first, then the node itself
//   x19 node, x20 index, x21 count
// =============================================================================
LFUNC fold_expr
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
    ENTER 2
    mov  x19, x0
    ldr  w9, [x19, #N_KIND]
    cmp  w9, #NK_LIT
    b.eq 9f
    cmp  w9, #NK_SUBQ                   // subquery plans are optimized
    b.eq 9f                             // as query levels of their own
    cmp  w9, #NK_EXISTS
    b.eq 9f
    mov  x0, x19
    bl   expr_nchildren
    mov  x21, x0
    mov  x20, #0
1:  cmp  x20, x21
    b.hs 2f
    mov  x0, x19
    mov  x1, x20
    bl   expr_child_slot
    ldr  x0, [x0]
    bl   fold_expr
    add  x20, x20, #1
    b    1b
2:  ldr  w9, [x19, #N_FLAGS]
    tbz  w9, #3, 9f                     // NF_CONST
    mov  x0, x19
    bl   opt_foldable
    cbz  w0, 9f
    mov  x0, x19
    bl   try_eval
    cbz  w2, 9f
    str  x0, [x19, #N_VAL]              // the node becomes the literal
    mov  w9, #NK_LIT
    str  w9, [x19, #N_KIND]
    mov  w9, #NF_CONST
    cbz  x1, 3f
    orr  w9, w9, #NF_NULL
3:  str  w9, [x19, #N_FLAGS]
    stp  xzr, xzr, [x19, #N_A]
    str  xzr, [x19, #N_C]
9:  LEAVE 2
ENDF fold_expr

// opt_foldable(x0 Node*) -> w0 1 if the tree only has kinds that evaluate
// without any context (literals, operators, casts, scalar functions, CASE,
// IN lists, LIKE): no columns, aggregates, group keys or subqueries
//   x19 node, x20 index, x21 count
LFUNC opt_foldable
    STACK_GUARD                         // CR-6: recursive
    DEADLINE_TICK
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
    bl   check_deadline                 // a timeout is not discarded (CR-6)
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
