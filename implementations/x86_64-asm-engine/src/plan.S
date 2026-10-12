/*
 * plan.S - the planning pipeline of one query block:
 *
 *   bound block (binder.S)
 *     -> logical plan        lp_build            (lplan.S)
 *     -> optimized plan      optimize_logical    (optimizer.S, rule_*.S)
 *     -> physical plan       phys_plan           (planner.S)
 *
 *   plan_block(plan rdi)     called by the binder for every query block
 *                            once it is bound (nested blocks first)
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .text

/* plan_block(plan rdi) */
FUNC plan_block
    ENTER 0
    mov %rdi, %rbx
    call lp_build
    mov %rax, %rdi
    mov %rbx, %rsi
    call optimize_logical
    mov %rax, QP_LOGICAL(%rbx)
    mov %rbx, %rdi
    mov %rax, %rsi
    call phys_plan
    LEAVE
ENDF plan_block
