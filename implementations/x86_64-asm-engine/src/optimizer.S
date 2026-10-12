/*
 * optimizer.S - rule-based logical optimizer (option `optimize`, default
 * true; `optimize: false` is the unoptimized baseline and applies no rule).
 *
 *   optimize_logical(lp rdi, plan rsi) -> rax optimized plan root
 *
 * The optimizer only rewrites the logical plan of one query block (lplan.S);
 * it takes no physical decision.  Rules run in this order, each one a
 * function rule(lp rdi, plan rsi) -> rax new root in its own module:
 *
 *   pushdown        rule_pushdown.S   predicate pushdown into join inputs
 *   prune_columns   rule_prune.S      projection / column pruning of scans
 *   fold_constants  rule_fold.S       constant folding, predicate
 *                                     simplification
 *
 * Pushdown runs before folding so that conjuncts are placed by what the
 * query says, exactly as the physical planner places them when the
 * optimizer is off (indexes-and-planning.md section 3).
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .section .rodata
    .p2align 3
    .globl opt_rules, opt_rule_names, opt_nrules
opt_rules:
    .quad rule_pushdown, rule_prune_columns, rule_fold_constants
opt_rule_names:
    .quad rn_pushdown, rn_prune, rn_fold
opt_nrules:
    .quad 3
rn_pushdown: .asciz "pushdown"
rn_prune:    .asciz "prune_columns"
rn_fold:     .asciz "fold_constants"

    .text

/* optimize_logical(lp rdi, plan rsi) -> rax optimized plan root */
FUNC optimize_logical
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    cmpq $0, g_opt_optimize(%rip)
    je 9f
    xor %r13d, %r13d
1:  cmp opt_nrules(%rip), %r13
    jae 9f
    lea opt_rules(%rip), %rax
    mov %rbx, %rdi
    mov %r12, %rsi
    call *(%rax, %r13, 8)
    mov %rax, %rbx
    inc %r13
    jmp 1b
9:  mov %rbx, %rax
    LEAVE
ENDF optimize_logical
