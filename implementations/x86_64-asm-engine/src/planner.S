/*
 * planner.S - physical planning of a bound query block
 * (indexes-and-planning.md §3):
 *
 *   1. predicate pushdown: WHERE conjuncts that reference a single range
 *      variable (not on the NULL-padded side of a LEFT JOIN) move to that
 *      variable's scan (FP_FILTER) and are evaluated before any join;
 *   2. index selection: `col = c`, `col IN (c, ..)`, and range conjuncts
 *      (<, <=, >, >=, BETWEEN; bounds on one column are intersected) on an
 *      indexed column of a base table become an IndexScan when the
 *      estimated selectivity is <= 10% (equality: 1/distinct per value;
 *      ranges: linear interpolation between the column's min and max for
 *      numeric / temporal types, 1/3 otherwise).  Equality lookups whose
 *      estimate is at most SMALL_LOOKUP rows also use the index (tiny tables);
 *   3. row-group skipping: for PQCF-backed tables, row groups whose chunk
 *      min/max exclude such a conjunct are marked in FP_RGSKIP;
 *   4. cardinality estimates (FP_EST) and the hash-join build side: inner
 *      joins build on the smaller input, LEFT joins on the right input.
 *
 * The pushed conjuncts are always re-evaluated on every candidate row, so an
 * index or row-group skip only has to be conservative.  Column pruning is
 * inherent to the executor: scans produce row ids and only referenced
 * columns (RV_USED, shown by EXPLAIN) are ever read.
 *
 *   plan_block(plan rdi)          called by the binder for every query block
 *   g_opt_optimize, g_opt_indexes per-query options (protocol.S sets them)
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

#define SMALL_LOOKUP 16

/* planner state */
#define PS_PLAN  0
#define PS_NULL  8     /* u8[nrv]: 1 = NULL-padded side of a LEFT JOIN */
#define PS_PUSH  16    /* node*[nrv]: pushed conjuncts per range variable */
#define PS_RESID 24    /* residual WHERE */
#define PS_SIZE  32

/* per-column constraint info of one scan */
#define CI_HASEQ 0     /* 1 = equality / IN list recorded */
#define CI_EQN   8
#define CI_EQV   16    /* u64 values[CI_EQN] (column representation) */
#define CI_FLAGS 24    /* RF_* of the intersected range */
#define CI_LO    32
#define CI_HI    40
#define CI_SIZE  48

    .data
    .p2align 3
    .globl g_opt_optimize, g_opt_indexes
g_opt_optimize: .quad 1
g_opt_indexes:  .quad 1

    .section .rodata
    .p2align 3
f_tenth: .double 0.1
f_third: .double 0.3333333333333333
f_one:   .double 1.0
f_small: .double 16.0
f_huge:  .double 9.0e18

    .text

/* mk_and(a rdi, b rsi) -> rax AND node (b appended after a) */
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

/* mark_nullable(fp rdi, flags rsi, inherited edx) */
FUNC mark_nullable
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %edx, %r13d
    cmpq $FK_JOIN, FP_KIND(%rbx)
    je 1f
    test %r13d, %r13d
    jz 9f
    mov FP_RV(%rbx), %rax
    movb $1, (%r12, %rax)
    jmp 9f
1:  mov FP_LEFT(%rbx), %rdi
    mov %r12, %rsi
    mov %r13d, %edx
    call mark_nullable
    cmpq $JT_LEFT, FP_JTYPE(%rbx)
    jne 2f
    mov $1, %r13d
2:  mov FP_RIGHT(%rbx), %rdi
    mov %r12, %rsi
    mov %r13d, %edx
    call mark_nullable
9:  LEAVE
ENDF mark_nullable

/* push_conj(ps rdi, expr rsi): distributes the conjuncts of expr */
FUNC push_conj
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    cmpl $EK_BINARY, N_KIND(%r12)
    jne 1f
    cmpl $B_AND, N_OP(%r12)
    jne 1f
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    call push_conj
    mov %rbx, %rdi
    mov N_B(%r12), %rsi
    call push_conj
    LEAVE
1:  mov %r12, %rdi
    call conj_rv
    test %rax, %rax
    js 5f
    mov PS_NULL(%rbx), %rcx
    cmpb $0, (%rcx, %rax)
    jne 5f
    mov PS_PUSH(%rbx), %rcx
    lea (%rcx, %rax, 8), %r13
    mov (%r13), %rdi
    mov %r12, %rsi
    call mk_and
    mov %rax, (%r13)
    LEAVE
5:  mov PS_RESID(%rbx), %rdi
    mov %r12, %rsi
    call mk_and
    mov %rax, PS_RESID(%rbx)
    LEAVE
ENDF push_conj

/* ================================================================ constants */

/* simple_const(node rdi) -> eax 1 for a literal, possibly under casts and
 * unary operators (the only constants evaluated at planning time) */
FUNC simple_const
    xor %eax, %eax
1:  test %rdi, %rdi
    jz 9f
    mov N_KIND(%rdi), %ecx
    cmp $EK_LIT, %ecx
    je 8f
    cmp $EK_CAST, %ecx
    je 2f
    cmp $EK_UNARY, %ecx
    jne 9f
2:  mov N_A(%rdi), %rdi
    jmp 1b
8:  mov $1, %eax
9:  ret
ENDF simple_const

/* try_eval_const(node rdi) -> rax payload, rdx NULL flag, ecx 1 = ok,
 * 0 = evaluation raised an error (the error is discarded) */
FUNC try_eval_const
    ENTER 288
    mov %rdi, %rbx
    mov g_jmpbuf(%rip), %rax
    mov %rax, 0(%rsp)               /* outer handler */
    lea 16(%rsp), %rdi              /* zeroed EvalCtx at 16..79 */
    xor %esi, %esi
    mov $EC_SIZE, %edx
    call memset
    lea 80(%rsp), %rdi              /* jmp_buf at 80.. */
    mov %rdi, g_jmpbuf(%rip)
    call _setjmp
    test %eax, %eax
    jnz 8f
    mov %rbx, %rdi
    lea 16(%rsp), %rsi
    call eval
    mov 0(%rsp), %rcx
    mov %rcx, g_jmpbuf(%rip)
    mov $1, %ecx
    LEAVE
8:  mov 0(%rsp), %rcx
    mov %rcx, g_jmpbuf(%rip)
    xor %eax, %eax
    xor %edx, %edx
    xor %ecx, %ecx
    LEAVE
ENDF try_eval_const

/* conv_exact(src type rdi, value rsi, dst type rdx) -> rax value, edx 1 = ok
 * (exact representation of the value in the column's type, or failure) */
FUNC conv_exact
    movzbl %dil, %r8d               /* source kind */
    movzbl %dl, %r9d                /* target kind */
    mov %rdi, %r10
    shr $16, %r10
    and $0xff, %r10d                /* source scale */
    mov %rdx, %r11
    shr $16, %r11
    and $0xff, %r11d                /* target scale */
    mov %rsi, %rax
    cmp %r8d, %r9d
    jne 2f
    cmp $T_DEC, %r8d
    je 5f
    jmp 8f
2:  cmp $T_INT, %r8d
    jne 4f
    cmp $T_DEC, %r9d
    jne 3f
    xor %r10d, %r10d                /* INT -> DEC: from scale 0 */
    jmp 5f
3:  cmp $T_FLOAT, %r9d
    jne 9f
    mov $1, %rcx                    /* INT -> FLOAT: exact up to 2^53 */
    shl $53, %rcx
    mov %rsi, %rdx
    neg %rdx
    cmovs %rsi, %rdx
    cmp %rcx, %rdx
    ja 9f
    cvtsi2sd %rsi, %xmm0
    movq %xmm0, %rax
    jmp 8f
4:  cmp $T_DATE, %r8d               /* DATE -> TS: midnight */
    jne 9f
    cmp $T_TS, %r9d
    jne 9f
    mov $86400000000, %rcx
    imul %rcx, %rax
    jo 9f
    jmp 8f
5:  /* rescale from scale r10 to scale r11 exactly */
    cmp %r10d, %r11d
    je 8f
    jb 7f
    mov %r11d, %ecx
    sub %r10d, %ecx
6:  imul $10, %rax, %rax
    jo 9f
    dec %ecx
    jnz 6b
    jmp 8f
7:  mov %r10d, %ecx
    sub %r11d, %ecx
    lea pow10_u64(%rip), %rdx
    mov (%rdx, %rcx, 8), %rcx
    cqo
    idiv %rcx
    test %rdx, %rdx
    jnz 9f
8:  mov $1, %edx
    ret
9:  xor %edx, %edx
    ret
ENDF conv_exact

/* const_val(node rdi, col type rsi) -> rax value, edx 0 = usable,
 * 1 = NULL, 2 = not usable */
FUNC const_val
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    call simple_const
    test %eax, %eax
    jz 9f
    mov %rbx, %rdi
    call try_eval_const
    test %ecx, %ecx
    jz 9f
    test %edx, %edx
    jnz 7f
    mov N_TYPE(%rbx), %edi
    mov %rax, %rsi
    mov %r12, %rdx
    call conv_exact
    test %edx, %edx
    jz 9f
    xor %edx, %edx
    LEAVE
7:  mov $1, %edx
    LEAVE
9:  mov $2, %edx
    LEAVE
ENDF const_val

/* ================================================================ scan analysis */

/* ci_for(scan rdi = node, ci array rsi, col node rdx) -> rax CI* */
#define SC_TABLE 0     /* scan analysis context (on plan_scan's frame) */
#define SC_CI    8
#define SC_RV    16

/* ci_bound(ci rdi, type rsi, value rdx, lower ecx): intersect the range */
FUNC ci_bound
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %ecx, %r14d                 /* bit0 lower, bit1 inclusive */
    test $1, %r14d
    jz 5f
    /* lower bound */
    testq $RF_LO, CI_FLAGS(%rbx)
    jz 2f
    mov %r12, %rdi
    mov %r13, %rsi
    mov CI_LO(%rbx), %rdx
    call value_cmp
    test %eax, %eax
    js 9f                           /* looser */
    jnz 2f
    test $2, %r14d                  /* equal: exclusive wins */
    jnz 9f
    andq $~RF_LOI, CI_FLAGS(%rbx)
    jmp 9f
2:  mov %r13, CI_LO(%rbx)
    andq $~RF_LOI, CI_FLAGS(%rbx)
    orq $RF_LO, CI_FLAGS(%rbx)
    test $2, %r14d
    jz 9f
    orq $RF_LOI, CI_FLAGS(%rbx)
    jmp 9f
5:  /* upper bound */
    testq $RF_HI, CI_FLAGS(%rbx)
    jz 6f
    mov %r12, %rdi
    mov %r13, %rsi
    mov CI_HI(%rbx), %rdx
    call value_cmp
    test %eax, %eax
    jg 9f
    jnz 6f
    test $2, %r14d
    jnz 9f
    andq $~RF_HII, CI_FLAGS(%rbx)
    jmp 9f
6:  mov %r13, CI_HI(%rbx)
    andq $~RF_HII, CI_FLAGS(%rbx)
    orq $RF_HI, CI_FLAGS(%rbx)
    test $2, %r14d
    jz 9f
    orq $RF_HII, CI_FLAGS(%rbx)
9:  LEAVE
ENDF ci_bound

/* analyze_conj(sc rdi, expr rsi): records usable constraints */
FUNC analyze_conj
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov N_KIND(%r12), %eax
    cmp $EK_BINARY, %eax
    je 10f
    cmp $EK_INLIST, %eax
    je 30f
    cmp $EK_BETWEEN, %eax
    je 40f
    LEAVE

10: mov N_OP(%r12), %r15d
    cmp $B_AND, %r15d
    jne 11f
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    call analyze_conj
    mov %rbx, %rdi
    mov N_B(%r12), %rsi
    call analyze_conj
    LEAVE
11: cmp $B_EQ, %r15d
    jb 99f
    cmp $B_GE, %r15d
    ja 99f
    cmp $B_NE, %r15d
    je 99f
    mov N_A(%r12), %r13             /* column side */
    mov N_B(%r12), %r14             /* constant side */
    cmpl $EK_COL, N_KIND(%r13)
    je 12f
    xchg %r13, %r14
    cmpl $EK_COL, N_KIND(%r13)
    jne 99f
    /* mirror the operator: c < col  <=>  col > c */
    cmp $B_EQ, %r15d
    je 12f
    mov $B_LT+B_GT, %eax
    cmp $B_LT, %r15d
    je 111f
    cmp $B_GT, %r15d
    je 111f
    mov $B_LE+B_GE, %eax
111: sub %r15d, %eax
    mov %eax, %r15d
12: mov N_V1(%r13), %rax
    shl $COL_SHIFT, %rax
    mov SC_TABLE(%rbx), %rcx
    add TB_COLS(%rcx), %rax
    mov COL_TYPE(%rax), %rax
    mov %rax, 0(%rsp)               /* column type */
    mov %r14, %rdi
    mov %rax, %rsi
    call const_val
    test %edx, %edx
    jnz 99f
    mov %rax, 8(%rsp)               /* value */
    imul $CI_SIZE, N_V1(%r13), %rax
    add SC_CI(%rbx), %rax
    mov %rax, %r14                  /* CI* */
    cmp $B_EQ, %r15d
    jne 13f
    cmpq $0, CI_HASEQ(%r14)
    jne 99f
    mov $8, %edi
    call tmp_alloc
    mov 8(%rsp), %rcx
    mov %rcx, (%rax)
    mov %rax, CI_EQV(%r14)
    movq $1, CI_EQN(%r14)
    movq $1, CI_HASEQ(%r14)
    LEAVE
13: xor %ecx, %ecx                  /* bit0 lower, bit1 inclusive */
    cmp $B_GT, %r15d
    jb 14f
    or $1, %ecx
14: cmp $B_LE, %r15d
    je 15f
    cmp $B_GE, %r15d
    jne 16f
15: or $2, %ecx
16: mov %r14, %rdi
    mov 0(%rsp), %rsi
    mov 8(%rsp), %rdx
    call ci_bound
    LEAVE

30: /* col IN (constants) */
    cmpl $0, N_OP(%r12)
    jne 99f
    mov N_A(%r12), %r13
    cmpl $EK_COL, N_KIND(%r13)
    jne 99f
    mov N_V1(%r13), %rax
    shl $COL_SHIFT, %rax
    mov SC_TABLE(%rbx), %rcx
    add TB_COLS(%rcx), %rax
    mov COL_TYPE(%rax), %rax
    mov %rax, 0(%rsp)
    mov N_V1(%r12), %rdi
    lea 8(, %rdi, 8), %rdi
    call tmp_alloc
    mov %rax, 8(%rsp)               /* values */
    movq $0, 16(%rsp)               /* count */
    xor %r15d, %r15d
31: cmp N_V1(%r12), %r15
    jae 33f
    mov N_B(%r12), %rax
    mov (%rax, %r15, 8), %rdi
    mov 0(%rsp), %rsi
    call const_val
    cmp $1, %edx
    je 32f                          /* NULL items never match */
    test %edx, %edx
    jnz 99f
    mov 8(%rsp), %rcx
    mov 16(%rsp), %rdx
    mov %rax, (%rcx, %rdx, 8)
    incq 16(%rsp)
32: inc %r15
    jmp 31b
33: imul $CI_SIZE, N_V1(%r13), %rax
    add SC_CI(%rbx), %rax
    cmpq $0, CI_HASEQ(%rax)
    jne 99f
    movq $1, CI_HASEQ(%rax)
    mov 8(%rsp), %rcx
    mov %rcx, CI_EQV(%rax)
    mov 16(%rsp), %rcx
    mov %rcx, CI_EQN(%rax)
    LEAVE

40: /* col BETWEEN lo AND hi */
    cmpl $0, N_OP(%r12)
    jne 99f
    mov N_A(%r12), %r13
    cmpl $EK_COL, N_KIND(%r13)
    jne 99f
    mov N_V1(%r13), %rax
    shl $COL_SHIFT, %rax
    mov SC_TABLE(%rbx), %rcx
    add TB_COLS(%rcx), %rax
    mov COL_TYPE(%rax), %rax
    mov %rax, 0(%rsp)
    mov N_B(%r12), %rdi
    mov %rax, %rsi
    call const_val
    test %edx, %edx
    jnz 99f
    mov %rax, 8(%rsp)
    mov N_V1(%r12), %rdi
    mov 0(%rsp), %rsi
    call const_val
    test %edx, %edx
    jnz 99f
    mov %rax, 16(%rsp)
    imul $CI_SIZE, N_V1(%r13), %r14
    add SC_CI(%rbx), %r14
    mov %r14, %rdi
    mov 0(%rsp), %rsi
    mov 8(%rsp), %rdx
    mov $3, %ecx
    call ci_bound
    mov %r14, %rdi
    mov 0(%rsp), %rsi
    mov 16(%rsp), %rdx
    mov $2, %ecx
    call ci_bound
99: LEAVE
ENDF analyze_conj

/* to_num(type rdi, value rsi) -> xmm0 (order-preserving numeric image of an
 * INT / DEC unscaled / FLOAT / DATE / TS value) */
FUNC to_num
    movzbl %dil, %eax
    cmp $T_FLOAT, %eax
    jne 1f
    movq %rsi, %xmm0
    ret
1:  cvtsi2sd %rsi, %xmm0
    ret
ENDF to_num

/* range_sel(ci rdi, type rsi, stats rdx) -> xmm0 selectivity of the range */
FUNC range_sel
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    xorpd %xmm0, %xmm0
    cmpq $0, CST_HAS(%r13)
    je 9f
    movzbl %r12b, %eax
    cmp $T_INT, %eax
    je 1f
    cmp $T_FLOAT, %eax
    je 1f
    cmp $T_DEC, %eax
    je 1f
    cmp $T_DATE, %eax
    je 1f
    cmp $T_TS, %eax
    je 1f
    movsd f_third(%rip), %xmm0      /* non-numeric: 1/3 */
    jmp 9f
1:  mov %r12, %rdi
    mov CST_MIN(%r13), %rsi
    call to_num
    movsd %xmm0, 0(%rsp)            /* min */
    mov %r12, %rdi
    mov CST_MAX(%r13), %rsi
    call to_num
    movsd %xmm0, 8(%rsp)            /* max */
    movsd 0(%rsp), %xmm2            /* lo */
    testq $RF_LO, CI_FLAGS(%rbx)
    jz 2f
    mov %r12, %rdi
    mov CI_LO(%rbx), %rsi
    call to_num
    movapd %xmm0, %xmm2
    maxsd 0(%rsp), %xmm2
2:  movsd %xmm2, 0(%rsp)            /* effective lo (>= min) */
    movsd 8(%rsp), %xmm3            /* hi */
    testq $RF_HI, CI_FLAGS(%rbx)
    jz 3f
    mov %r12, %rdi
    mov CI_HI(%rbx), %rsi
    call to_num
    movapd %xmm0, %xmm3
    minsd 8(%rsp), %xmm3
3:  movsd 0(%rsp), %xmm2
    xorpd %xmm0, %xmm0
    ucomisd %xmm2, %xmm3            /* hi < lo: empty */
    jb 9f
    mov %r12, %rdi
    mov CST_MIN(%r13), %rsi
    call to_num
    movapd %xmm0, %xmm4
    mov %r12, %rdi
    mov CST_MAX(%r13), %rsi
    call to_num
    movapd %xmm0, %xmm5
    subsd %xmm4, %xmm5              /* max - min */
    movsd f_one(%rip), %xmm0
    xorpd %xmm1, %xmm1
    ucomisd %xmm1, %xmm5
    jbe 9f                          /* single value inside the range */
    movsd 0(%rsp), %xmm2
    subsd %xmm2, %xmm3
    divsd %xmm5, %xmm3
    minsd f_one(%rip), %xmm3
    movapd %xmm3, %xmm0
9:  LEAVE
ENDF range_sel

/* ci_excludes(ci rdi, type rsi, min rdx, max rcx) -> eax 1 if no value in
 * [min, max] can satisfy the recorded constraints */
FUNC ci_excludes
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    cmpq $0, CI_HASEQ(%rbx)
    je 5f
    xor %r15d, %r15d                /* every value outside [min, max]? */
1:  cmp CI_EQN(%rbx), %r15
    jae 8f
    mov CI_EQV(%rbx), %rax
    mov (%rax, %r15, 8), %rsi
    mov %rsi, 0(%rsp)
    mov %r12, %rdi
    mov %r13, %rdx
    call value_cmp
    test %eax, %eax
    js 2f
    mov %r12, %rdi
    mov 0(%rsp), %rsi
    mov %r14, %rdx
    call value_cmp
    test %eax, %eax
    jle 5f                          /* inside: cannot exclude by equality */
2:  inc %r15
    jmp 1b
5:  testq $RF_LO, CI_FLAGS(%rbx)
    jz 6f
    mov %r12, %rdi                  /* max < lo, or max = lo exclusive */
    mov %r14, %rsi
    mov CI_LO(%rbx), %rdx
    call value_cmp
    test %eax, %eax
    js 8f
    jnz 6f
    testq $RF_LOI, CI_FLAGS(%rbx)
    jz 8f
6:  testq $RF_HI, CI_FLAGS(%rbx)
    jz 7f
    mov %r12, %rdi                  /* min > hi, or min = hi exclusive */
    mov %r13, %rsi
    mov CI_HI(%rbx), %rdx
    call value_cmp
    test %eax, %eax
    jg 8f
    jnz 7f
    testq $RF_HII, CI_FLAGS(%rbx)
    jz 8f
7:  xor %eax, %eax
    LEAVE
8:  mov $1, %eax
    LEAVE
ENDF ci_excludes

/* plan_scan(ps rdi, fp rsi) -> rax estimated rows */
FUNC plan_scan
    ENTER 128
    mov %rdi, %rbx
    mov %rsi, %r12
    mov FP_RV(%r12), %rax
    mov %rax, SC_RV(%rsp)
    mov PS_PUSH(%rbx), %rcx
    mov (%rcx, %rax, 8), %rcx
    mov %rcx, FP_FILTER(%r12)
    mov PS_PLAN(%rbx), %rdx
    mov QP_RVS(%rdx), %rdx
    mov (%rdx, %rax, 8), %rdx
    mov RV_TABLE(%rdx), %r13        /* base table or 0 */
    mov %r13, SC_TABLE(%rsp)
    mov $1000, %eax                 /* derived table: unknown size */
    test %r13, %r13
    jz 95f
    mov TB_NROWS(%r13), %rax
    test %rcx, %rcx
    jz 95f
    /* ---- constraints per column */
    mov TB_NCOLS(%r13), %rdi
    imul $CI_SIZE, %rdi
    add $8, %rdi
    call tmp_zalloc
    mov %rax, SC_CI(%rsp)
    lea 0(%rsp), %rdi
    mov FP_FILTER(%r12), %rsi
    call analyze_conj
    /* ---- selectivities; best overall (estimate) and best index */
    movsd f_huge(%rip), %xmm0
    movsd %xmm0, 32(%rsp)           /* best selectivity of any constraint */
    movsd %xmm0, 40(%rsp)           /* best index selectivity */
    movq $0, 48(%rsp)               /* best index */
    movq $0, 56(%rsp)               /* its mode */
    xor %r14d, %r14d                /* column */
10: cmp TB_NCOLS(%r13), %r14
    jae 30f
    imul $CI_SIZE, %r14, %r15
    add SC_CI(%rsp), %r15           /* CI* */
    cmpq $0, CI_HASEQ(%r15)
    jne 11f
    cmpq $0, CI_FLAGS(%r15)
    je 29f
11: mov %r13, %rdi
    mov %r14, %rsi
    call table_col_stats
    mov %rax, 64(%rsp)              /* ColStats* */
    mov %r14, %rax
    shl $COL_SHIFT, %rax
    add TB_COLS(%r13), %rax
    mov COL_TYPE(%rax), %rax
    mov %rax, 72(%rsp)              /* type */
    movsd f_huge(%rip), %xmm0
    movsd %xmm0, 80(%rsp)           /* equality selectivity */
    movsd %xmm0, 88(%rsp)           /* range selectivity */
    cmpq $0, CI_HASEQ(%r15)
    je 12f
    mov 64(%rsp), %rax
    mov CST_DISTINCT(%rax), %rax
    mov $1, %ecx
    test %rax, %rax
    cmovz %rcx, %rax
    cvtsi2sdq CI_EQN(%r15), %xmm0
    cvtsi2sd %rax, %xmm1
    divsd %xmm1, %xmm0
    movsd %xmm0, 80(%rsp)
12: cmpq $0, CI_FLAGS(%r15)
    je 13f
    mov %r15, %rdi
    mov 72(%rsp), %rsi
    mov 64(%rsp), %rdx
    call range_sel
    movsd %xmm0, 88(%rsp)
13: movsd 80(%rsp), %xmm0
    minsd 88(%rsp), %xmm0
    minsd 32(%rsp), %xmm0
    movsd %xmm0, 32(%rsp)
    /* indexes on this column */
    cmpq $0, g_opt_indexes(%rip)
    je 29f
    mov TB_INDEXES(%r13), %rax
    test %rax, %rax
    jz 29f
    movq $0, 96(%rsp)
20: mov TB_INDEXES(%r13), %rax
    mov 96(%rsp), %rcx
    cmp VEC_LEN(%rax), %rcx
    jae 29f
    mov VEC_DATA(%rax), %rax
    mov (%rax, %rcx, 8), %rdi       /* Index* */
    cmp IX_COL(%rdi), %r14
    jne 28f
    cmpq $0, CI_HASEQ(%r15)
    je 22f
    movsd 80(%rsp), %xmm0           /* equality lookup */
    ucomisd 40(%rsp), %xmm0
    jae 22f
    movsd %xmm0, 40(%rsp)
    mov %rdi, 48(%rsp)
    movq $IM_EQ, 56(%rsp)
    mov %r15, 104(%rsp)             /* CI of the choice */
22: cmpq $IXK_BTREE, IX_KIND(%rdi)
    jne 28f
    cmpq $0, CI_FLAGS(%r15)
    je 28f
    movsd 88(%rsp), %xmm0           /* range lookup */
    ucomisd 40(%rsp), %xmm0
    jae 28f
    movsd %xmm0, 40(%rsp)
    mov %rdi, 48(%rsp)
    movq $IM_RANGE, 56(%rsp)
    mov %r15, 104(%rsp)
28: incq 96(%rsp)
    jmp 20b
29: inc %r14
    jmp 10b
30: /* ---- index choice */
    mov 48(%rsp), %rdi
    test %rdi, %rdi
    jz 40f
    movsd 40(%rsp), %xmm0
    ucomisd f_tenth(%rip), %xmm0
    jbe 31f
    cmpq $IM_EQ, 56(%rsp)
    jne 40f
    cvtsi2sdq TB_NROWS(%r13), %xmm1
    mulsd %xmm0, %xmm1
    ucomisd f_small(%rip), %xmm1
    ja 40f
31: mov %rdi, FP_INDEX(%r12)
    mov 56(%rsp), %rax
    mov %rax, FP_IMODE(%r12)
    mov 104(%rsp), %rcx
    cmp $IM_EQ, %rax
    jne 32f
    mov CI_EQV(%rcx), %rax
    mov %rax, FP_IVALS(%r12)
    mov CI_EQN(%rcx), %rax
    mov %rax, FP_INV(%r12)
    jmp 40f
32: mov CI_LO(%rcx), %rax
    mov %rax, FP_IVALS(%r12)
    mov CI_HI(%rcx), %rax
    mov %rax, FP_INV(%r12)
    mov CI_FLAGS(%rcx), %rax
    mov %rax, FP_IFLAGS(%r12)
40: /* ---- row-group skipping (PQCF-backed tables) */
    cmpq $0, TB_NRG(%r13)
    je 50f
    mov TB_NRG(%r13), %rdi
    add $8, %rdi
    call tmp_zalloc
    mov %rax, FP_RGSKIP(%r12)
    movq $0, 96(%rsp)               /* row group */
41: mov 96(%rsp), %rax
    cmp TB_NRG(%r13), %rax
    jae 50f
    imul $RG_SIZE, %rax, %rax
    add TB_RGS(%r13), %rax
    mov %rax, 112(%rsp)             /* RowGroup* */
    xor %r14d, %r14d
42: cmp TB_NCOLS(%r13), %r14
    jae 49f
    imul $CI_SIZE, %r14, %r15
    add SC_CI(%rsp), %r15
    cmpq $0, CI_HASEQ(%r15)
    jne 43f
    cmpq $0, CI_FLAGS(%r15)
    je 48f
43: mov 112(%rsp), %rax
    mov RG_COLS(%rax), %rax
    imul $RGC_SIZE, %r14, %rcx
    add %rcx, %rax                  /* RGC* */
    mov 112(%rsp), %rcx
    mov RG_N(%rcx), %rcx
    cmp RGC_NULLS(%rax), %rcx       /* all NULL: no row can qualify */
    je 47f
    cmpq $0, RGC_HAS(%rax)
    je 48f
    mov RGC_MIN(%rax), %rdx
    mov RGC_MAX(%rax), %rcx
    mov %r14, %rsi
    shl $COL_SHIFT, %rsi
    add TB_COLS(%r13), %rsi
    mov COL_TYPE(%rsi), %rsi
    mov %r15, %rdi
    call ci_excludes
    test %eax, %eax
    jz 48f
47: mov FP_RGSKIP(%r12), %rax
    mov 96(%rsp), %rcx
    movb $1, (%rax, %rcx)
    incq FP_NSKIP(%r12)
    jmp 49f
48: inc %r14
    jmp 42b
49: incq 96(%rsp)
    jmp 41b
50: /* ---- estimate: best constraint, or 1/3 when nothing is analyzable */
    movsd 32(%rsp), %xmm1
    minsd f_one(%rip), %xmm1
    ucomisd f_huge(%rip), %xmm1
    jb 51f
    movsd f_third(%rip), %xmm1
51: cvtsi2sdq TB_NROWS(%r13), %xmm0
    mulsd %xmm1, %xmm0
    cvttsd2si %xmm0, %rax
95: mov %rax, FP_EST(%r12)
    LEAVE
ENDF plan_scan

/* plan_fp(ps rdi, fp rsi) -> rax estimated rows */
FUNC plan_fp
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    cmpq $FK_JOIN, FP_KIND(%r12)
    je 1f
    call plan_scan
    LEAVE
1:  mov FP_LEFT(%r12), %rsi
    call plan_fp
    mov %rax, %r13                  /* left estimate */
    mov %rbx, %rdi
    mov FP_RIGHT(%r12), %rsi
    call plan_fp
    mov %rax, %r14                  /* right estimate */
    cmpq $0, FP_LKEY(%r12)
    je 2f
    mov %r13, %rax                  /* equi join: max of the inputs */
    cmp %r14, %rax
    cmovb %r14, %rax
    cmpq $JT_INNER, FP_JTYPE(%r12)
    jne 3f
    cmp %r14, %r13                  /* build on the smaller input */
    jae 3f
    movq $1, FP_BUILDL(%r12)
    jmp 3f
2:  mov %r13, %rax                  /* product (saturating) */
    mul %r14
    jno 3f
    mov $0x3fffffffffffffff, %rax
3:  mov %rax, FP_EST(%r12)
    LEAVE
ENDF plan_fp

/* plan_block(plan rdi) */
FUNC plan_block
    ENTER 16
    mov %rdi, %rbx
    cmpq $0, QP_FROM(%rbx)
    je 9f
    mov $PS_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r12
    mov %rbx, PS_PLAN(%r12)
    mov QP_NRV(%rbx), %rdi
    add $8, %rdi
    call tmp_zalloc
    mov %rax, PS_NULL(%r12)
    mov QP_NRV(%rbx), %rdi
    lea 8(, %rdi, 8), %rdi
    call tmp_zalloc
    mov %rax, PS_PUSH(%r12)
    mov QP_FROM(%rbx), %rdi
    mov PS_NULL(%r12), %rsi
    xor %edx, %edx
    call mark_nullable
    cmpq $0, g_opt_optimize(%rip)
    je 5f
    mov QP_WHERE(%rbx), %rsi
    test %rsi, %rsi
    jz 5f
    mov %r12, %rdi
    call push_conj
    mov PS_RESID(%r12), %rax
    mov %rax, QP_WHERE(%rbx)
5:  mov %r12, %rdi
    mov QP_FROM(%rbx), %rsi
    call plan_fp
9:  LEAVE
ENDF plan_block
