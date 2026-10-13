/*
 * lplan.S - the logical plan: relational operators independent of the
 * execution strategy (layout LP_* / LK_* in sql.inc).
 *
 *   lp_new(kind rdi) -> rax                  zeroed node
 *   lp_from_rv(rv index rdi, RangeVar* rsi) -> rax
 *                                            Scan / SubqueryScan of a range
 *                                            variable (binder, FROM clause)
 *   lp_join(type rdi, left rsi, right rdx, on rcx, rlo r8, rhi r9) -> rax
 *   lp_build(plan rdi) -> rax                logical plan of a bound block
 *   lp_print(buf rdi, lp rsi, plan rdx)      indented text form (debugging,
 *                                            unit tests); nested blocks are
 *                                            printed below their reference
 *   lp_print_expr(buf rdi, expr rsi, plan rdx)
 *
 * Helpers shared by the optimizer rules and the physical planner:
 *   mk_and(a rdi, b rsi) -> rax              a AND b (a may be 0)
 *   conj_rv(expr rdi) -> rax                 the one range variable an
 *                                            expression references, -1 none,
 *                                            -2 several / aggregate /
 *                                            correlated subquery
 *   lp_mark_nullable(from rdi, flags rsi, inherited edx)
 *                                            flags[rv] = 1 for range
 *                                            variables on the NULL-padded
 *                                            side of a LEFT JOIN
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .section .rodata
    .p2align 3
lk_names:
    .quad 0, n_scan, n_subq, n_join, n_filter, n_project, n_agg, n_sort
    .quad n_limit, n_distinct, n_union, n_values
n_scan:     .asciz "Scan"
n_subq:     .asciz "SubqueryScan"
n_join:     .asciz "Join"
n_filter:   .asciz "Filter"
n_project:  .asciz "Project"
n_agg:      .asciz "Aggregate"
n_sort:     .asciz "Sort"
n_limit:    .asciz "Limit"
n_distinct: .asciz "Distinct"
n_union:    .asciz "UnionAll"
n_values:   .asciz "Values"
    .p2align 3
jt_text:
    .quad 0, jt_inner, jt_left, jt_cross
jt_inner: .asciz "INNER"
jt_left:  .asciz "LEFT"
jt_cross: .asciz "CROSS"
    .p2align 3
binop_text:
    .quad 0, o_add, o_sub, o_mul, o_div, o_mod, o_cat, o_eq, o_ne, o_lt
    .quad o_le, o_gt, o_ge, o_and, o_or
o_add: .asciz " + "
o_sub: .asciz " - "
o_mul: .asciz " * "
o_div: .asciz " / "
o_mod: .asciz " % "
o_cat: .asciz " || "
o_eq:  .asciz " = "
o_ne:  .asciz " <> "
o_lt:  .asciz " < "
o_le:  .asciz " <= "
o_gt:  .asciz " > "
o_ge:  .asciz " >= "
o_and: .asciz " AND "
o_or:  .asciz " OR "
    .p2align 3
unop_text:
    .quad 0, u_neg, u_pos, u_not
u_neg: .asciz "-"
u_pos: .asciz "+"
u_not: .asciz "NOT "
    .p2align 3
agg_text:
    .quad 0, a_cstar, a_count, a_sum, a_avg, a_min, a_max
a_cstar: .asciz "COUNT(*"
a_count: .asciz "COUNT("
a_sum:   .asciz "SUM("
a_avg:   .asciz "AVG("
a_min:   .asciz "MIN("
a_max:   .asciz "MAX("

    .text

/* ================================================================ construction */

/* lp_new(kind rdi) -> rax zeroed node of that kind */
FUNC lp_new
    push %rbx
    mov %rdi, %rbx
    mov $LP_SIZE, %edi
    call tmp_zalloc
    mov %rbx, LP_KIND(%rax)
    pop %rbx
    ret
ENDF lp_new

/* lp_unary(kind rdi, input rsi, a rdx) -> rax node with one input */
FUNC lp_unary
    ENTER 0
    mov %rsi, %rbx
    mov %rdx, %r12
    call lp_new
    mov %rbx, LP_IN(%rax)
    mov %r12, LP_A(%rax)
    LEAVE
ENDF lp_unary

/* lp_from_rv(rv index rdi, RangeVar* rsi) -> rax Scan of a base table or
 * SubqueryScan of a derived table / CTE; every column is produced */
FUNC lp_from_rv
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov $LK_SCAN, %edi
    cmpq $0, RV_TABLE(%r12)
    jne 1f
    mov $LK_SUBQUERY, %edi
1:  call lp_new
    mov %rax, %r13
    mov %rbx, LP_A(%r13)
    mov %r12, LP_B(%r13)
    mov RV_PLAN(%r12), %rax
    mov %rax, LP_D(%r13)
    mov RV_NCOLS(%r12), %rdi
    add $8, %rdi
    call tmp_alloc
    mov %rax, LP_C(%r13)
    mov %rax, %rdi
    mov $1, %esi
    mov RV_NCOLS(%r12), %rdx
    call memset
    mov %r13, %rax
    LEAVE
ENDF lp_from_rv

/* lp_join(type rdi, left rsi, right rdx, on rcx, rlo r8, rhi r9) -> rax */
FUNC lp_join
    ENTER 32
    mov %rdi, 0(%rsp)
    mov %rsi, %rbx
    mov %rdx, %r12
    mov %rcx, %r13
    mov %r8, %r14
    mov %r9, %r15
    mov $LK_JOIN, %edi
    call lp_new
    mov %rbx, LP_IN(%rax)
    mov %r12, LP_IN2(%rax)
    mov 0(%rsp), %rcx
    mov %rcx, LP_A(%rax)
    mov %r13, LP_B(%rax)
    mov %r14, LP_C(%rax)
    mov %r15, LP_D(%rax)
    LEAVE
ENDF lp_join

/* lp_build(plan rdi) -> rax logical plan of a bound query block (also stored
 * in QP_LOGICAL) in the canonical, unoptimized shape (see sql.inc) */
FUNC lp_build
    ENTER 0
    mov %rdi, %rbx
    cmpq $0, QP_NUNION(%rbx)
    je 1f
    mov $LK_UNION, %edi
    xor %esi, %esi
    mov QP_NUNION(%rbx), %rdx
    call lp_unary
    mov QP_UNION(%rbx), %rcx
    mov %rcx, LP_B(%rax)
    mov %rax, %r12
    jmp 6f
1:  mov QP_LFROM(%rbx), %r12
    test %r12, %r12
    jnz 2f
    mov $LK_VALUES, %edi
    call lp_new
    mov %rax, %r12
2:  mov QP_WHERE(%rbx), %rdx
    test %rdx, %rdx
    jz 3f
    mov $LK_FILTER, %edi
    mov %r12, %rsi
    call lp_unary
    mov %rax, %r12
3:  cmpq $0, QP_AGG(%rbx)
    je 4f
    mov $LK_AGGREGATE, %edi
    mov %r12, %rsi
    mov QP_NGROUP(%rbx), %rdx
    call lp_unary
    mov QP_GROUP(%rbx), %rcx
    mov %rcx, LP_B(%rax)
    mov QP_NAGGS(%rbx), %rcx
    mov %rcx, LP_C(%rax)
    mov QP_AGGS(%rbx), %rcx
    mov %rcx, LP_D(%rax)
    mov %rax, %r12
    mov QP_HAVING(%rbx), %rdx
    test %rdx, %rdx
    jz 4f
    mov $LK_FILTER, %edi
    mov %r12, %rsi
    call lp_unary
    mov %rax, %r12
4:  mov $LK_PROJECT, %edi
    mov %r12, %rsi
    mov QP_NOUT(%rbx), %rdx
    call lp_unary
    mov QP_OUT(%rbx), %rcx
    mov %rcx, LP_B(%rax)
    mov %rax, %r12
    cmpq $0, QP_DISTINCT(%rbx)
    je 6f
    mov $LK_DISTINCT, %edi
    mov %r12, %rsi
    xor %edx, %edx
    call lp_unary
    mov %rax, %r12
6:  mov QP_NKEYS(%rbx), %rdx
    test %rdx, %rdx
    jz 7f
    mov $LK_SORT, %edi
    mov %r12, %rsi
    call lp_unary
    mov QP_KEYS(%rbx), %rcx
    mov %rcx, LP_B(%rax)
    mov %rax, %r12
7:  cmpq $-1, QP_LIMIT(%rbx)
    jne 8f
    cmpq $0, QP_OFFSET(%rbx)
    je 9f
8:  mov $LK_LIMIT, %edi
    mov %r12, %rsi
    mov QP_LIMIT(%rbx), %rdx
    call lp_unary
    mov QP_OFFSET(%rbx), %rcx
    mov %rcx, LP_B(%rax)
    mov %rax, %r12
9:  mov %r12, QP_LOGICAL(%rbx)
    mov %r12, %rax
    LEAVE
ENDF lp_build

/* ================================================================ predicate helpers */

/* mk_and(a rdi, b rsi) -> rax AND node (b appended after a); a may be 0 */
FUNC mk_and
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    test %rbx, %rbx
    jz 1f
    mov $N_SIZE, %edi
    call tmp_zalloc
    movl $EK_BINARY, N_KIND(%rax)
    movl $B_AND, N_OP(%rax)
    movl $T_BOOL, N_TYPE(%rax)
    mov %rbx, N_A(%rax)
    mov %r12, N_B(%rax)
    LEAVE
1:  mov %r12, %rax
    LEAVE
ENDF mk_and

/* conj_rv(expr rdi) -> rax: range variable index when the expression
 * references exactly one range variable of this block, -1 when it references
 * none (constant within the block), -2 when it references several or holds
 * an aggregate / correlated subquery */
FUNC conj_rv
    STACK_CHECK
    call deadline_tick
    ENTER 0
    mov %rdi, %rbx
    mov $-1, %r12                   /* result */
    test %rbx, %rbx
    jz 9f
    mov N_KIND(%rbx), %eax
    cmp $EK_COL, %eax
    jne 1f
    mov N_V2(%rbx), %r12
    jmp 9f
1:  cmp $EK_OUTER, %eax
    je 9f
    cmp $EK_AGG, %eax
    je 8f
    cmp $EK_SUBQ, %eax
    je 2f
    cmp $EK_EXISTS, %eax
    je 2f
    cmp $EK_INSUBQ, %eax
    jne 3f
2:  testl $NF_CORR, N_FLAGS(%rbx)
    jnz 8f
    cmp $EK_INSUBQ, %eax
    jne 9f
    mov N_A(%rbx), %rdi             /* the tested value */
    call conj_rv
    mov %rax, %r12
    jmp 9f
3:  mov %rbx, %rdi
    call expr_nchild
    mov %rax, %r14
    xor %r13d, %r13d
4:  cmp %r14, %r13
    jae 9f
    mov %rbx, %rdi
    mov %r13, %rsi
    call expr_child_ptr
    mov (%rax), %rdi
    call conj_rv
    cmp $-2, %rax
    je 8f
    cmp $-1, %rax
    je 5f
    cmp $-1, %r12
    je 41f
    cmp %rax, %r12
    jne 8f
41: mov %rax, %r12
5:  inc %r13
    jmp 4b
8:  mov $-2, %r12
9:  mov %r12, %rax
    LEAVE
ENDF conj_rv

/* lp_mark_nullable(from rdi, flags rsi, inherited edx): flags[rv] = 1 for
 * every range variable of the FROM tree on the NULL-padded side of a LEFT
 * JOIN (inherited = 1: the whole subtree is) */
FUNC lp_mark_nullable
    STACK_CHECK
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %edx, %r13d
    cmpq $LK_FILTER, LP_KIND(%rbx)
    jne 0f
    mov LP_IN(%rbx), %rdi           /* filters do not change the sides */
    call lp_mark_nullable
    jmp 9f
0:  cmpq $LK_JOIN, LP_KIND(%rbx)
    je 1f
    test %r13d, %r13d
    jz 9f
    mov LP_A(%rbx), %rax
    movb $1, (%r12, %rax)
    jmp 9f
1:  mov LP_IN(%rbx), %rdi
    mov %r12, %rsi
    mov %r13d, %edx
    call lp_mark_nullable
    cmpq $JT_LEFT, LP_A(%rbx)
    jne 2f
    mov $1, %r13d
2:  mov LP_IN2(%rbx), %rdi
    mov %r12, %rsi
    mov %r13d, %edx
    call lp_mark_nullable
9:  LEAVE
ENDF lp_mark_nullable

/* ================================================================ printing */

/* put_table(buf rdi, cstr table rsi, index rdx): writes table[index] */
FUNC put_table
    mov (%rsi, %rdx, 8), %rsi
    jmp buf_puts
ENDF put_table

/* put_list(buf rdi, node*[] rsi, n rdx, plan rcx): "e1, e2, ..." */
FUNC put_list
    STACK_CHECK
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    xor %r15d, %r15d
1:  cmp %r13, %r15
    jae 9f
    test %r15, %r15
    jz 2f
    PUTS %rbx, ", "
2:  mov %rbx, %rdi
    mov (%r12, %r15, 8), %rsi
    mov %r14, %rdx
    call lp_print_expr
    inc %r15
    jmp 1b
9:  LEAVE
ENDF put_list

/* lp_print_expr(buf rdi, expr rsi, plan rdx): SQL-like text of a bound
 * expression; columns as range_variable.column, outer references as
 * ^column, subqueries as (subquery) */
FUNC lp_print_expr
    STACK_CHECK
    call deadline_tick
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    test %r12, %r12
    jnz 0f
    PUTS %rbx, "?"
    LEAVE
0:  mov N_KIND(%r12), %eax
    cmp $EK_LIT, %eax
    je pe_lit
    cmp $EK_COL, %eax
    je pe_col
    cmp $EK_OUTER, %eax
    je pe_outer
    cmp $EK_UNARY, %eax
    je pe_unary
    cmp $EK_BINARY, %eax
    je pe_binary
    cmp $EK_ISNULL, %eax
    je pe_isnull
    cmp $EK_CAST, %eax
    je pe_cast
    cmp $EK_FUNC, %eax
    je pe_func
    cmp $EK_AGG, %eax
    je pe_agg
    cmp $EK_CASE, %eax
    je pe_case
    cmp $EK_BETWEEN, %eax
    je pe_between
    cmp $EK_INLIST, %eax
    je pe_inlist
    cmp $EK_LIKE, %eax
    je pe_like
    cmp $EK_SUBQ, %eax
    je pe_subq
    cmp $EK_EXISTS, %eax
    je pe_exists
    cmp $EK_INSUBQ, %eax
    je pe_insubq
    PUTS %rbx, "?"
    LEAVE
pe_lit:
    testl $NF_NULL, N_FLAGS(%r12)
    jz 1f
    PUTS %rbx, "NULL"
    LEAVE
1:  movzbl N_TYPE(%r12), %eax
    cmp $T_BOOL, %eax
    jne 3f
    cmpq $0, N_V1(%r12)
    je 2f
    PUTS %rbx, "TRUE"
    LEAVE
2:  PUTS %rbx, "FALSE"
    LEAVE
3:  cmp $T_STR, %eax
    jne 4f
    PUTS %rbx, "'"
    mov %rbx, %rdi
    mov N_V1(%r12), %rsi
    call buf_put_pstr
    PUTS %rbx, "'"
    LEAVE
4:  mov %rbx, %rdi
    mov N_TYPE(%r12), %esi
    mov N_V1(%r12), %rdx
    call fmt_value_text
    LEAVE
pe_col:
    mov QP_RVS(%r13), %rax
    mov N_V2(%r12), %rcx
    mov (%rax, %rcx, 8), %r14       /* RangeVar* */
    mov %rbx, %rdi
    mov RV_NAME(%r14), %rsi
    call buf_put_pstr
    PUTS %rbx, "."
    mov N_V1(%r12), %rax
    shl $4, %rax
    add RV_COLS(%r14), %rax
    mov %rbx, %rdi
    mov RVC_NAME(%rax), %rsi
    call buf_put_pstr
    LEAVE
pe_outer:
    PUTS %rbx, "^"
    mov %rbx, %rdi
    mov N_B(%r12), %rsi
    call buf_put_pstr
    LEAVE
pe_unary:
    mov %rbx, %rdi
    lea unop_text(%rip), %rsi
    mov N_OP(%r12), %edx
    call put_table
    mov N_A(%r12), %rsi
    jmp pe_child
pe_binary:
    PUTS %rbx, "("
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    mov %r13, %rdx
    call lp_print_expr
    mov %rbx, %rdi
    lea binop_text(%rip), %rsi
    mov N_OP(%r12), %edx
    call put_table
    mov %rbx, %rdi
    mov N_B(%r12), %rsi
    mov %r13, %rdx
    call lp_print_expr
    jmp pe_close
pe_isnull:
    PUTS %rbx, "("
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    mov %r13, %rdx
    call lp_print_expr
    PUTS %rbx, " IS "
    cmpl $0, N_OP(%r12)
    je 1f
    PUTS %rbx, "NOT "
1:  PUTS %rbx, "NULL)"
    LEAVE
pe_cast:
    PUTS %rbx, "CAST("
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    mov %r13, %rdx
    call lp_print_expr
    PUTS %rbx, " AS "
    mov %rbx, %rdi
    mov N_TYPE(%r12), %esi
    call fmt_type
    jmp pe_close
pe_func:
    mov %rbx, %rdi
    mov N_B(%r12), %rsi
    call buf_put_pstr
    PUTS %rbx, "("
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    mov N_V1(%r12), %rdx
    mov %r13, %rcx
    call put_list
    jmp pe_close
pe_agg:
    mov %rbx, %rdi
    lea agg_text(%rip), %rsi
    mov N_OP(%r12), %edx
    call put_table
    testl $NF_DISTINCT, N_FLAGS(%r12)
    jz 1f
    PUTS %rbx, "DISTINCT "
1:  mov N_A(%r12), %rsi
    test %rsi, %rsi
    jz pe_close
    mov %rbx, %rdi
    mov %r13, %rdx
    call lp_print_expr
    jmp pe_close
pe_case:
    PUTS %rbx, "CASE"
    mov N_A(%r12), %rsi
    test %rsi, %rsi
    jz 1f
    PUTS %rbx, " "
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    mov %r13, %rdx
    call lp_print_expr
1:  xor %r14d, %r14d                /* WHEN / THEN slots */
2:  mov N_V1(%r12), %rax
    add %rax, %rax
    cmp %rax, %r14
    jae 4f
    test $1, %r14
    jnz 3f
    PUTS %rbx, " WHEN "
    jmp 31f
3:  PUTS %rbx, " THEN "
31: mov N_B(%r12), %rax
    mov (%rax, %r14, 8), %rsi
    mov %rbx, %rdi
    mov %r13, %rdx
    call lp_print_expr
    inc %r14
    jmp 2b
4:  cmpq $0, N_V2(%r12)
    je 5f
    PUTS %rbx, " ELSE "
    mov %rbx, %rdi
    mov N_V2(%r12), %rsi
    mov %r13, %rdx
    call lp_print_expr
5:  PUTS %rbx, " END"
    LEAVE
pe_between:
    PUTS %rbx, "("
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    mov %r13, %rdx
    call lp_print_expr
    call pe_not
    PUTS %rbx, " BETWEEN "
    mov %rbx, %rdi
    mov N_B(%r12), %rsi
    mov %r13, %rdx
    call lp_print_expr
    PUTS %rbx, " AND "
    mov N_V1(%r12), %rsi
    jmp pe_child_close
pe_inlist:
    PUTS %rbx, "("
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    mov %r13, %rdx
    call lp_print_expr
    call pe_not
    PUTS %rbx, " IN ("
    mov %rbx, %rdi
    mov N_B(%r12), %rsi
    mov N_V1(%r12), %rdx
    mov %r13, %rcx
    call put_list
    PUTS %rbx, "))"
    LEAVE
pe_like:
    PUTS %rbx, "("
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    mov %r13, %rdx
    call lp_print_expr
    call pe_not
    PUTS %rbx, " LIKE "
    mov N_B(%r12), %rsi
    jmp pe_child_close
pe_subq:
    PUTS %rbx, "(subquery)"
    LEAVE
pe_exists:
    PUTS %rbx, "EXISTS(subquery)"
    LEAVE
pe_insubq:
    PUTS %rbx, "("
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    mov %r13, %rdx
    call lp_print_expr
    call pe_not
    PUTS %rbx, " IN (subquery))"
    LEAVE
pe_child_close:                     /* rsi: last operand, then ")" */
    mov %rbx, %rdi
    mov %r13, %rdx
    call lp_print_expr
pe_close:
    PUTS %rbx, ")"
    LEAVE
pe_child:                           /* rsi: operand */
    mov %rbx, %rdi
    mov %r13, %rdx
    call lp_print_expr
    LEAVE
ENDF lp_print_expr

/* pe_not: writes " NOT" when N_OP(%r12) = 1 (NOT BETWEEN / IN / LIKE);
 * called from lp_print_expr's frame: rbx = buf, r12 = node */
FUNC pe_not
    sub $8, %rsp
    cmpl $0, N_OP(%r12)
    je 1f
    PUTS %rbx, " NOT"
1:  add $8, %rsp
    ret
ENDF pe_not

/* put_cols(buf rdi, scan rsi): " [c1, c2]" - the produced columns */
FUNC put_cols
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov LP_B(%r12), %r13            /* RangeVar* */
    PUTS %rbx, " ["
    xor %r14d, %r14d
    xor %r15d, %r15d                /* printed */
1:  cmp RV_NCOLS(%r13), %r14
    jae 9f
    mov LP_C(%r12), %rax
    cmpb $0, (%rax, %r14)
    je 3f
    test %r15, %r15
    jz 2f
    PUTS %rbx, ", "
2:  mov %r14, %rax
    shl $4, %rax
    add RV_COLS(%r13), %rax
    mov %rbx, %rdi
    mov RVC_NAME(%rax), %rsi
    call buf_put_pstr
    inc %r15
3:  inc %r14
    jmp 1b
9:  PUTS %rbx, "]"
    LEAVE
ENDF put_cols

/* lp_print(buf rdi, lp rsi, plan rdx): one line per operator, inputs
 * indented below it */
FUNC lp_print
    xor %ecx, %ecx
    jmp lp_print_at
ENDF lp_print

/* lp_print_at(buf rdi, lp rsi, plan rdx, depth rcx) */
FUNC lp_print_at
    STACK_CHECK
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    test %r12, %r12
    jz 99f
    xor %r15d, %r15d                /* indentation */
1:  cmp %r14, %r15
    jae 2f
    PUTS %rbx, "  "
    inc %r15
    jmp 1b
2:  mov %rbx, %rdi
    lea lk_names(%rip), %rsi
    mov LP_KIND(%r12), %rdx
    call put_table
    mov LP_KIND(%r12), %rax
    cmp $LK_SCAN, %rax
    je pl_scan
    cmp $LK_SUBQUERY, %rax
    je pl_scan
    cmp $LK_JOIN, %rax
    je pl_join
    cmp $LK_FILTER, %rax
    je pl_filter
    cmp $LK_PROJECT, %rax
    je pl_project
    cmp $LK_AGGREGATE, %rax
    je pl_agg
    cmp $LK_SORT, %rax
    je pl_sort
    cmp $LK_LIMIT, %rax
    je pl_limit
    jmp pl_done
pl_scan:
    PUTS %rbx, " "
    mov LP_B(%r12), %r15            /* RangeVar* */
    mov RV_TABLE(%r15), %rax
    test %rax, %rax
    jz 1f
    mov %rbx, %rdi
    mov TB_NAME(%rax), %rsi
    call buf_put_pstr
    PUTS %rbx, " AS "
1:  mov %rbx, %rdi
    mov RV_NAME(%r15), %rsi
    call buf_put_pstr
    mov %rbx, %rdi
    mov %r12, %rsi
    call put_cols
    jmp pl_done
pl_join:
    PUTS %rbx, " "
    mov %rbx, %rdi
    lea jt_text(%rip), %rsi
    mov LP_A(%r12), %rdx
    call put_table
    cmpq $0, LP_B(%r12)
    je pl_done
    PUTS %rbx, " ON "
    mov LP_B(%r12), %rsi
    jmp pl_expr
pl_filter:
    PUTS %rbx, " "
    mov LP_A(%r12), %rsi
pl_expr:
    mov %rbx, %rdi
    mov %r13, %rdx
    call lp_print_expr
    jmp pl_done
pl_project:
    xor %r15d, %r15d
1:  cmp LP_A(%r12), %r15
    jae pl_done
    test %r15, %r15
    jz 2f
    PUTS %rbx, ","
2:  PUTS %rbx, " "
    imul $OC_SIZE, %r15, %rax
    add LP_B(%r12), %rax
    mov %rax, 0(%rsp)
    mov %rbx, %rdi
    mov OC_EXPR(%rax), %rsi
    mov %r13, %rdx
    call lp_print_expr
    PUTS %rbx, " AS "
    mov 0(%rsp), %rax
    mov %rbx, %rdi
    mov OC_NAME(%rax), %rsi
    call buf_put_pstr
    inc %r15
    jmp 1b
pl_agg:
    PUTS %rbx, " keys=["
    mov %rbx, %rdi
    mov LP_B(%r12), %rsi
    mov LP_A(%r12), %rdx
    mov %r13, %rcx
    call put_list
    PUTS %rbx, "] calls=["
    mov %rbx, %rdi
    mov LP_D(%r12), %rsi
    mov LP_C(%r12), %rdx
    mov %r13, %rcx
    call put_list
    PUTS %rbx, "]"
    jmp pl_done
pl_sort:
    xor %r15d, %r15d
1:  cmp LP_A(%r12), %r15
    jae pl_done
    test %r15, %r15
    jz 2f
    PUTS %rbx, ","
2:  PUTS %rbx, " "
    imul $SK_SIZE, %r15, %rax
    add LP_B(%r12), %rax
    mov %rax, 0(%rsp)
    mov SK_OUT(%rax), %rcx
    cmp $-1, %rcx
    je 3f
    PUTS %rbx, "#"                  /* output column */
    mov 0(%rsp), %rax
    mov %rbx, %rdi
    mov SK_OUT(%rax), %rsi
    call buf_put_i64
    jmp 4f
3:  mov %rbx, %rdi
    mov SK_EXPR(%rax), %rsi
    mov %r13, %rdx
    call lp_print_expr
4:  mov 0(%rsp), %rax
    cmpq $0, SK_DESC(%rax)
    je 5f
    PUTS %rbx, " DESC"
5:  inc %r15
    jmp 1b
pl_limit:
    PUTS %rbx, " "
    mov %rbx, %rdi
    mov LP_A(%r12), %rsi
    call buf_put_i64
    PUTS %rbx, " OFFSET "
    mov %rbx, %rdi
    mov LP_B(%r12), %rsi
    call buf_put_i64
pl_done:
    PUTS %rbx, "\n"
    lea 1(%r14), %r15               /* inputs one level deeper */
    mov LP_KIND(%r12), %rax
    cmp $LK_SUBQUERY, %rax
    je 5f
    cmp $LK_UNION, %rax
    je 6f
    mov %rbx, %rdi
    mov LP_IN(%r12), %rsi
    mov %r13, %rdx
    mov %r15, %rcx
    call lp_print_at
    mov %rbx, %rdi
    mov LP_IN2(%r12), %rsi
    mov %r13, %rdx
    mov %r15, %rcx
    call lp_print_at
    jmp 99f
5:  mov LP_D(%r12), %rdx            /* the derived table's own plan */
    mov %rbx, %rdi
    mov QP_LOGICAL(%rdx), %rsi
    mov %r15, %rcx
    call lp_print_at
    jmp 99f
6:  movq $0, 0(%rsp)                /* the branches' own plans */
7:  mov 0(%rsp), %rax
    cmp LP_A(%r12), %rax
    jae 99f
    mov LP_B(%r12), %rcx
    mov (%rcx, %rax, 8), %rdx
    mov %rbx, %rdi
    mov QP_LOGICAL(%rdx), %rsi
    mov %r15, %rcx
    call lp_print_at
    incq 0(%rsp)
    jmp 7b
99: LEAVE
ENDF lp_print_at
