/*
 * rule_pushdown.S - optimizer rule "pushdown": predicate pushdown on the
 * logical plan.
 *
 *   rule_pushdown(lp rdi, plan rsi) -> rax plan root
 *
 * A Filter whose input is a FROM tree (Join, Scan or SubqueryScan) is split
 * into its conjuncts.  A conjunct that references exactly one range
 * variable - not on the NULL-padded side of a LEFT JOIN, without aggregates
 * or correlated subqueries - moves into the join inputs, into a Filter
 * directly above that variable's Scan (LFF_PUSHED; conjuncts in their
 * original order).  The remaining conjuncts stay in a Filter above the FROM
 * tree (LFF_RESIDUAL), which disappears when nothing remains.  Filters
 * elsewhere (HAVING above an Aggregate) are not moved: WHERE filters are
 * built below the projection, and nested query blocks (derived tables,
 * CTEs) are separate plans whose Filter stays above the SubqueryScan.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

/* pushdown state of one Filter */
#define PD_NULL  0     /* u8[nrv]: 1 = NULL-padded side of a LEFT JOIN */
#define PD_TREE  8     /* slot holding the FROM tree below the Filter */
#define PD_RESID 16    /* conjuncts that stay */
#define PD_SIZE  24

    .text

/* is_from_tree(node rdi) -> eax 1 for Join / Scan / SubqueryScan */
FUNC is_from_tree
    xor %eax, %eax
    test %rdi, %rdi
    jz 9f
    mov LP_KIND(%rdi), %rcx
    cmp $LK_JOIN, %rcx
    je 1f
    cmp $LK_SCAN, %rcx
    je 1f
    cmp $LK_SUBQUERY, %rcx
    jne 9f
1:  mov $1, %eax
9:  ret
ENDF is_from_tree

/* scan_slot(slot rdi, rv rsi) -> rax slot holding the Scan of range
 * variable rv (or the pushed Filter directly above it), 0 if not found */
FUNC scan_slot
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov (%rbx), %r13
    xor %eax, %eax
    test %r13, %r13
    jz 9f
    mov LP_KIND(%r13), %rcx
    cmp $LK_FILTER, %rcx
    jne 1f
    mov LP_IN(%r13), %r13           /* pushed filter: look at its scan */
    mov LP_KIND(%r13), %rcx
1:  cmp $LK_JOIN, %rcx
    je 2f
    cmp %r12, LP_A(%r13)
    jne 9f
    mov %rbx, %rax
    jmp 9f
2:  lea LP_IN(%r13), %rdi
    mov %r12, %rsi
    call scan_slot
    test %rax, %rax
    jnz 9f
    lea LP_IN2(%r13), %rdi
    mov %r12, %rsi
    call scan_slot
9:  LEAVE
ENDF scan_slot

/* push_conjunct(pd rdi, expr rsi): moves one conjunct (AND chains are
 * split) to its scan, or keeps it in PD_RESID */
FUNC push_conjunct
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    cmpl $EK_BINARY, N_KIND(%r12)
    jne 1f
    cmpl $B_AND, N_OP(%r12)
    jne 1f
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    call push_conjunct
    mov %rbx, %rdi
    mov N_B(%r12), %rsi
    call push_conjunct
    LEAVE
1:  mov %r12, %rdi
    call conj_rv
    test %rax, %rax
    js 5f
    mov PD_NULL(%rbx), %rcx
    cmpb $0, (%rcx, %rax)
    jne 5f
    mov PD_TREE(%rbx), %rdi
    mov %rax, %rsi
    call scan_slot
    test %rax, %rax
    jz 5f
    mov %rax, %r13                  /* slot of the scan */
    mov (%r13), %r14
    cmpq $LK_FILTER, LP_KIND(%r14)
    jne 2f
    mov LP_A(%r14), %rdi            /* append to the pushed filter */
    mov %r12, %rsi
    call mk_and
    mov %rax, LP_A(%r14)
    LEAVE
2:  mov $LK_FILTER, %edi
    call lp_new
    mov %r14, LP_IN(%rax)
    mov %r12, LP_A(%rax)
    movq $LFF_PUSHED, LP_B(%rax)
    mov %rax, (%r13)
    LEAVE
5:  mov PD_RESID(%rbx), %rdi
    mov %r12, %rsi
    call mk_and
    mov %rax, PD_RESID(%rbx)
    LEAVE
ENDF push_conjunct

/* push_filter(slot rdi, plan rsi): pushes the Filter in *slot (its input
 * is a FROM tree) */
FUNC push_filter
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov (%rbx), %r13                /* the Filter */
    lea LP_IN(%r13), %rax
    mov %rax, PD_TREE(%rsp)
    movq $0, PD_RESID(%rsp)
    mov QP_NRV(%r12), %rdi
    add $8, %rdi
    call tmp_zalloc
    mov %rax, PD_NULL(%rsp)
    mov LP_IN(%r13), %rdi
    mov %rax, %rsi
    xor %edx, %edx
    call lp_mark_nullable
    lea 0(%rsp), %rdi
    mov LP_A(%r13), %rsi
    call push_conjunct
    mov PD_RESID(%rsp), %rax
    test %rax, %rax
    jz 1f
    mov %rax, LP_A(%r13)
    movq $LFF_RESIDUAL, LP_B(%r13)
    LEAVE
1:  mov LP_IN(%r13), %rax           /* everything moved: drop the filter */
    mov %rax, (%rbx)
    LEAVE
ENDF push_filter

/* push_node(slot rdi, plan rsi): applies the rule to *slot and below */
FUNC push_node
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov (%rbx), %r13
    test %r13, %r13
    jz 9f
    cmpq $LK_FILTER, LP_KIND(%r13)
    jne 1f
    testq $LFF_PUSHED | LFF_RESIDUAL, LP_B(%r13)
    jnz 1f                          /* already placed */
    mov LP_IN(%r13), %rdi
    call is_from_tree
    test %eax, %eax
    jz 1f
    mov %rbx, %rdi
    mov %r12, %rsi
    call push_filter
    jmp 9f                          /* the FROM tree below holds no filters */
1:  mov (%rbx), %r13
    lea LP_IN(%r13), %rdi
    mov %r12, %rsi
    call push_node
    lea LP_IN2(%r13), %rdi
    mov %r12, %rsi
    call push_node
9:  LEAVE
ENDF push_node

/* rule_pushdown(lp rdi, plan rsi) -> rax plan root */
FUNC rule_pushdown
    ENTER 16
    mov %rdi, 0(%rsp)
    lea 0(%rsp), %rdi
    call push_node
    mov 0(%rsp), %rax
    LEAVE
ENDF rule_pushdown
