/*
 * rule_prune.S - optimizer rule "prune_columns": projection / column
 * pruning on the logical plan.
 *
 *   rule_prune_columns(lp rdi, plan rsi) -> rax plan root
 *
 * Every Scan / SubqueryScan of the block is narrowed to the columns that
 * the operators above it reference: columns of filters, join conditions,
 * projections, grouping keys, aggregate arguments and sort keys, and
 * correlated references to the block from nested subqueries (EK_OUTER
 * nodes whose level count leads back to this block).  Columns no longer
 * produced are cleared in the Scan's output set (LP_C).
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .text

/* mark_col(scans rdi, rv rsi, col rdx): the scan of rv produces col */
FUNC mark_col
    mov (%rdi, %rsi, 8), %rax
    test %rax, %rax
    jz 9f
    mov LP_C(%rax), %rax
    movb $1, (%rax, %rdx)
9:  ret
ENDF mark_col

/* prune_expr(scans rdi, expr rsi, depth rdx): marks the columns of the
 * block (depth = number of query blocks between the expression and it) */
FUNC prune_expr
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    test %r12, %r12
    jz 9f
    mov N_KIND(%r12), %eax
    cmp $EK_COL, %eax
    jne 1f
    test %r13, %r13
    jnz 9f
    mov %rbx, %rdi
    mov N_V2(%r12), %rsi
    mov N_V1(%r12), %rdx
    call mark_col
    jmp 9f
1:  cmp $EK_OUTER, %eax
    jne 2f
    cmp N_V3(%r12), %r13
    jne 9f
    mov %rbx, %rdi
    mov N_V2(%r12), %rsi
    mov N_V1(%r12), %rdx
    call mark_col
    jmp 9f
2:  cmp $EK_SUBQ, %eax
    je 3f
    cmp $EK_EXISTS, %eax
    je 3f
    cmp $EK_INSUBQ, %eax
    jne 5f
3:  testl $NF_CORR, N_FLAGS(%r12)
    jz 5f
    mov %rbx, %rdi                  /* correlated: the nested block */
    mov N_V2(%r12), %rax
    mov QP_LOGICAL(%rax), %rsi
    lea 1(%r13), %rdx
    call prune_node
5:  mov %r12, %rdi
    call expr_nchild
    mov %rax, %r14
    xor %r15d, %r15d
6:  cmp %r14, %r15
    jae 9f
    mov %r12, %rdi
    mov %r15, %rsi
    call expr_child_ptr
    mov %rbx, %rdi
    mov (%rax), %rsi
    mov %r13, %rdx
    call prune_expr
    inc %r15
    jmp 6b
9:  LEAVE
ENDF prune_expr

/* prune_list(scans rdi, node*[] rsi, n rdx, depth rcx) */
FUNC prune_list
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    xor %r15d, %r15d
1:  cmp %r13, %r15
    jae 9f
    mov %rbx, %rdi
    mov (%r12, %r15, 8), %rsi
    mov %r14, %rdx
    call prune_expr
    inc %r15
    jmp 1b
9:  LEAVE
ENDF prune_list

/* prune_node(scans rdi, lp rsi, depth rdx): marks the columns referenced
 * by the operator, its inputs and the nested blocks below it */
FUNC prune_node
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    test %r12, %r12
    jz 9f
    mov LP_KIND(%r12), %rax
    cmp $LK_FILTER, %rax
    je 10f
    cmp $LK_JOIN, %rax
    je 20f
    cmp $LK_PROJECT, %rax
    je 30f
    cmp $LK_AGGREGATE, %rax
    je 40f
    cmp $LK_SORT, %rax
    je 50f
    cmp $LK_SUBQUERY, %rax
    je 60f
    cmp $LK_UNION, %rax
    je 70f
    jmp 80f
10: mov LP_A(%r12), %rsi            /* Filter */
    jmp 21f
20: mov LP_B(%r12), %rsi            /* Join condition */
21: mov %rbx, %rdi
    mov %r13, %rdx
    call prune_expr
    jmp 80f
30: xor %r14d, %r14d                /* Project */
31: cmp LP_A(%r12), %r14
    jae 80f
    imul $OC_SIZE, %r14, %rax
    add LP_B(%r12), %rax
    mov %rbx, %rdi
    mov OC_EXPR(%rax), %rsi
    mov %r13, %rdx
    call prune_expr
    inc %r14
    jmp 31b
40: mov %rbx, %rdi                  /* Aggregate: keys and calls */
    mov LP_B(%r12), %rsi
    mov LP_A(%r12), %rdx
    mov %r13, %rcx
    call prune_list
    mov %rbx, %rdi
    mov LP_D(%r12), %rsi
    mov LP_C(%r12), %rdx
    mov %r13, %rcx
    call prune_list
    jmp 80f
50: xor %r14d, %r14d                /* Sort: keys over the input */
51: cmp LP_A(%r12), %r14
    jae 80f
    imul $SK_SIZE, %r14, %rax
    add LP_B(%r12), %rax
    inc %r14
    cmpq $-1, SK_OUT(%rax)
    jne 51b
    mov %rbx, %rdi
    mov SK_EXPR(%rax), %rsi
    mov %r13, %rdx
    call prune_expr
    jmp 51b
60: test %r13, %r13                 /* derived table: one block further */
    jz 80f                          /* (it cannot see its own query) */
    mov LP_D(%r12), %rax
    mov %rbx, %rdi
    mov QP_LOGICAL(%rax), %rsi
    lea 1(%r13), %rdx
    call prune_node
    jmp 80f
70: xor %r14d, %r14d                /* UNION ALL branches: same level */
71: cmp LP_A(%r12), %r14
    jae 80f
    mov LP_B(%r12), %rax
    mov (%rax, %r14, 8), %rax
    mov %rbx, %rdi
    mov QP_LOGICAL(%rax), %rsi
    mov %r13, %rdx
    call prune_node
    inc %r14
    jmp 71b
80: mov %rbx, %rdi
    mov LP_IN(%r12), %rsi
    mov %r13, %rdx
    call prune_node
    mov %rbx, %rdi
    mov LP_IN2(%r12), %rsi
    mov %r13, %rdx
    call prune_node
9:  LEAVE
ENDF prune_node

/* collect_scans(lp rdi, scans rsi): scans[rv] = Scan / SubqueryScan node
 * of the block, with every column cleared */
FUNC collect_scans
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    test %rbx, %rbx
    jz 9f
    mov LP_KIND(%rbx), %rax
    cmp $LK_SCAN, %rax
    je 1f
    cmp $LK_SUBQUERY, %rax
    jne 2f
1:  mov LP_A(%rbx), %rax
    mov %rbx, (%r12, %rax, 8)
    mov LP_C(%rbx), %rdi
    xor %esi, %esi
    mov LP_B(%rbx), %rdx
    mov RV_NCOLS(%rdx), %rdx
    call memset
    jmp 9f
2:  mov LP_IN(%rbx), %rdi
    mov %r12, %rsi
    call collect_scans
    mov LP_IN2(%rbx), %rdi
    mov %r12, %rsi
    call collect_scans
9:  LEAVE
ENDF collect_scans

/* rule_prune_columns(lp rdi, plan rsi) -> rax plan root */
FUNC rule_prune_columns
    ENTER 0
    mov %rdi, %rbx
    mov QP_NRV(%rsi), %rdi
    lea 8(, %rdi, 8), %rdi
    call tmp_zalloc
    mov %rax, %r12                  /* scans[rv] */
    mov %rbx, %rdi
    mov %r12, %rsi
    call collect_scans
    mov %r12, %rdi
    mov %rbx, %rsi
    xor %edx, %edx
    call prune_node
    mov %rbx, %rax
    LEAVE
ENDF rule_prune_columns
