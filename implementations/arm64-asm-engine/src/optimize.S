// =============================================================================
// optimize.S — rule-based logical optimizer.
//
//   optimize(x0 LogicalNode*) -> x0 LogicalNode*
//       applies the rules of opt_rules, in order, to the logical plan of one
//       query level (and its UNION ALL branches). With the query option
//       "optimize": false (g_opt_optimize = 0) no rule is applied.
//
// Rules (each a function LogicalNode* -> LogicalNode* that rewrites only the
// logical plan; one module each, unit-tested by tests/unit/test_optimizer.S):
//   fold_constants         rule_fold.S      literal-only expressions -> literals
//   simplify_predicates    rule_simplify.S  TRUE/FALSE in AND / OR / NOT;
//                                           conditions that became TRUE vanish
//   push_filters           rule_pushdown.S  WHERE conjuncts into scans and joins
//   reorder_joins          rule_joinorder.S greedy order of inner-join regions
//   push_join_conditions   rule_pushdown.S  single-input join conjuncts into
//                                           the join inputs
//   prune_columns          rule_prune.S     scans read only referenced columns
// The order matters: join reordering estimates its inputs with the WHERE
// conjuncts already pushed onto the scans, and re-attaches every condition to
// the lowest join covering it, which push_join_conditions then splits.
//
// Debugging: with the environment variable PQ_TRACE_PLAN set, the plan is
// printed to stderr before the first rule and after every rule.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

    .text

// =============================================================================
// optimize(x0 LogicalNode*) -> x0 LogicalNode*
//   x19 plan, x20 rule cursor, x21 trace flag, x22 trace label
// =============================================================================
FUNC optimize
    ENTER 2
    mov  x19, x0
    TLS_ADDR x9, g_opt_optimize
    ldr  w9, [x9]
    cbz  w9, 9f
    ADR_L x0, s_env
    bl   getenv
    mov  x21, x0
    ADR_L x20, opt_rules
    ADR_L x1, s_initial
    bl   .Lop_trace
1:  ldr  x9, [x20, #8]
    cbz  x9, 9f
    mov  x0, x19
    blr  x9
    mov  x19, x0
    ldr  x1, [x20]
    bl   .Lop_trace
    add  x20, x20, #16
    b    1b
9:  mov  x0, x19
    LEAVE 2

// local helper (shares the frame): if tracing, prints "-- <x1>\n" and the
// plan x19 to stderr
.Lop_trace:
    cbz  x21, 2f
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    mov  x22, x1
    stp  xzr, xzr, [sp, #16]            // Buf
    stp  xzr, xzr, [sp, #32]
    add  x0, sp, #16
    ADR_L x1, s_dashes
    bl   buf_puts
    add  x0, sp, #16
    mov  x1, x22
    bl   buf_puts
    add  x0, sp, #16
    mov  w1, #'\n'
    bl   buf_putc
    add  x0, sp, #16
    mov  x1, x19
    bl   lp_print
    ldr  x0, [sp, #16 + BUF_PTR]
    mov  x1, #1
    ldr  x2, [sp, #16 + BUF_LEN]
    GOT_LOAD x3, stderr
    bl   fwrite
    ldr  x0, [sp, #16 + BUF_PTR]
    bl   free
    ldp  x29, x30, [sp], #48
2:  ret
ENDF optimize

    .section .rodata
    .p2align 3
// Rule table: {name, function}, applied in this order; ends with {0, 0}.
opt_rules:
    .quad s_fold,     rule_fold_constants
    .quad s_simplify, rule_simplify_predicates
    .quad s_pushf,    rule_push_filters
    .quad s_reorder,  rule_reorder_joins
    .quad s_pushj,    rule_push_join_conditions
    .quad s_prune,    rule_prune_columns
    .quad 0, 0
s_fold:     .asciz "fold_constants"
s_simplify: .asciz "simplify_predicates"
s_pushf:    .asciz "push_filters"
s_reorder:  .asciz "reorder_joins"
s_pushj:    .asciz "push_join_conditions"
s_prune:    .asciz "prune_columns"
s_initial:  .asciz "logical plan"
s_dashes:   .asciz "-- "
s_env:      .asciz "PQ_TRACE_PLAN"
    .text

    NOTE_GNU_STACK
