/*
 * exec.S - physical execution of bound plans (materialising operators).
 *
 * The input relation of a query block is a TupleSet: one u64 row index per
 * range variable and tuple (-1 = NULL-padded by a LEFT JOIN), so base tables
 * are never copied.  Derived tables and CTEs are executed into Results and
 * converted to columnar Tables.  Operators: scan, hash join (equi key),
 * nested-loop join, filter, hash aggregation (with DISTINCT aggregates),
 * projection, DISTINCT, sort, offset/limit.
 *
 *   exec_plan(plan rdi, outer ctx rsi) -> rax Result* (RS_*)
 *   exec_query(plan, max_rows rsi (-1 = none), count_only rdx, out Buf* rcx)
 *     appends  "columns":[...],"rows":[...],"row_count":N  to the buffer.
 *   eval_subquery(node rdi, ctx rsi) -> rax, rdx   (EK_SUBQ / EK_EXISTS / EK_INSUBQ)
 *
 * Result rows are arrays of VAL_SIZE cells: the output columns followed by
 * the sort keys.  Sorting uses qsort_r over row pointers.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

/* aggregate state */
#define AS_COUNT 0
#define AS_LO    8
#define AS_HI    16
#define AS_VAL   24
#define AS_HAS   32
#define AS_SET   40    /* HashTable* of seen values (DISTINCT aggregates) */
#define AS_SIZE  48

/* execution state of one query block (arena allocated) */
#define XS_PLAN   0
#define XS_CTX    8    /* EvalCtx, EC_SIZE bytes */
#define XS_TABLES 72   /* Table*[nrv] */
#define XS_W      80   /* tuple width = max(nrv, 1) */
#define XS_TS     88   /* TupleSet* (after FROM and WHERE) */
#define XS_ROWS   96   /* Vec of rows: 96..127 */
#define XS_STOP   128  /* stop producing rows after this many (LIMIT pushdown) */
#define XS_SIZE   136

/* tuple set */
#define TS_N    0
#define TS_CAP  8
#define TS_DATA 16
#define TS_W    24
#define TS_SIZE 32

/* IN (subquery) value set */
#define IS_HT    0
#define IS_NULL  8     /* the subquery produced a NULL */
#define IS_ROWS  16    /* number of rows produced */
#define IS_TYPE  24    /* comparison type (key type of IS_HT) */
#define IS_SIZE  32

    .text

/* ================================================================ tuple sets */

/* ts_new(w rdi, cap rsi) -> rax TupleSet* */
FUNC ts_new
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    cmp $16, %r12
    jae 1f
    mov $16, %r12d
1:  mov $TS_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13
    mov %rbx, TS_W(%r13)
    mov %r12, TS_CAP(%r13)
    mov %r12, %rdi
    imul %rbx, %rdi
    shl $3, %rdi
    call tmp_alloc
    mov %rax, TS_DATA(%r13)
    mov %r13, %rax
    LEAVE
ENDF ts_new

/* ts_slot(ts rdi) -> rax pointer to a new (uninitialised) tuple; grows by doubling */
FUNC ts_slot
    ENTER 0
    mov %rdi, %rbx
    mov TS_N(%rbx), %rax
    cmp TS_CAP(%rbx), %rax
    jb 1f
    mov TS_CAP(%rbx), %r12
    add %r12, %r12
    mov %r12, %rdi
    imul TS_W(%rbx), %rdi
    shl $3, %rdi
    call tmp_alloc
    mov %rax, %r13
    mov %rax, %rdi
    mov TS_DATA(%rbx), %rsi
    mov TS_N(%rbx), %rdx
    imul TS_W(%rbx), %rdx
    shl $3, %rdx
    call memcpy
    mov %r13, TS_DATA(%rbx)
    mov %r12, TS_CAP(%rbx)
1:  mov TS_N(%rbx), %rax
    incq TS_N(%rbx)
    imul TS_W(%rbx), %rax
    shl $3, %rax
    add TS_DATA(%rbx), %rax
    LEAVE
ENDF ts_slot

/* tuple_combine(dst rdi, left rsi, right rdx, fp rcx, w r8):
 * dst = left with range variables [RLO, RHI) taken from right (or -1 when right = 0) */
FUNC tuple_combine
    ENTER 0
    mov %rdi, %rbx
    mov %rdx, %r12
    mov %rcx, %r13
    lea (,%r8,8), %rdx
    call memcpy
    mov FP_RLO(%r13), %rcx
    mov FP_RHI(%r13), %rdx
1:  cmp %rdx, %rcx
    jae 9f
    mov $-1, %rax
    test %r12, %r12
    jz 2f
    mov (%r12, %rcx, 8), %rax
2:  mov %rax, (%rbx, %rcx, 8)
    inc %rcx
    jmp 1b
9:  LEAVE
ENDF tuple_combine

/* check_join_rows(ts rdi): RESOURCE_LIMIT beyond --max-join-rows */
FUNC check_join_rows
    mov TS_N(%rdi), %rax
    cmp g_max_join_rows(%rip), %rax
    ja 1f
    ret
1:  sub $8, %rsp
    RAISE E_RESOURCE_LIMIT, "join produces more rows than --max-join-rows"
ENDF check_join_rows

/* ================================================================ FROM */

/* exec_from(xs rdi, fp rsi) -> rax TupleSet* */
FUNC exec_from
    ENTER 80
    mov %rdi, %rbx
    mov %rsi, %r12
    cmpq $FK_JOIN, FP_KIND(%r12)
    je 10f
    /* ---- scan of one range variable */
    mov FP_RV(%r12), %r13
    mov XS_TABLES(%rbx), %rax
    mov (%rax, %r13, 8), %rax
    mov TB_NROWS(%rax), %r14        /* n */
    mov XS_W(%rbx), %rdi
    mov %r14, %rsi
    call ts_new
    mov %rax, %r15
    mov %r14, TS_N(%r15)
    mov TS_DATA(%r15), %rdi
    mov $0xff, %esi
    mov %r14, %rdx
    imul XS_W(%rbx), %rdx
    shl $3, %rdx
    call memset
    mov TS_DATA(%r15), %rax
    lea (%rax, %r13, 8), %rax
    mov XS_W(%rbx), %rcx
    shl $3, %rcx
    xor %edx, %edx
1:  cmp %r14, %rdx
    jae 2f
    mov %rdx, (%rax)
    add %rcx, %rax
    inc %rdx
    jmp 1b
2:  mov %r15, %rax
    LEAVE

10: /* ---- join */
    mov FP_LEFT(%r12), %rsi
    mov %rbx, %rdi
    call exec_from
    mov %rax, 0(%rsp)               /* L */
    mov FP_RIGHT(%r12), %rsi
    mov %rbx, %rdi
    call exec_from
    mov %rax, 8(%rsp)               /* R */
    mov XS_W(%rbx), %rdi
    mov 0(%rsp), %rax
    mov TS_N(%rax), %rsi
    call ts_new
    mov %rax, %r13                  /* out */
    cmpq $0, FP_LKEY(%r12)
    jne 30f

    /* ---- nested loop join */
    xor %r14d, %r14d                /* i */
11: mov 0(%rsp), %rax
    cmp TS_N(%rax), %r14
    jae 90f
    movq $0, 16(%rsp)               /* matched */
    xor %r15d, %r15d                /* j */
12: mov 8(%rsp), %rax
    cmp TS_N(%rax), %r15
    jae 16f
    test $1023, %r15
    jnz 13f
    call check_deadline
13: mov %r13, %rdi
    call ts_slot
    mov %rax, 24(%rsp)              /* slot */
    mov %rax, %rdi
    mov 0(%rsp), %rax
    mov XS_W(%rbx), %r8
    mov %r14, %rsi
    imul %r8, %rsi
    shl $3, %rsi
    add TS_DATA(%rax), %rsi
    mov 8(%rsp), %rax
    mov %r15, %rdx
    imul %r8, %rdx
    shl $3, %rdx
    add TS_DATA(%rax), %rdx
    mov %r12, %rcx
    call tuple_combine
    mov FP_ON(%r12), %rdi
    test %rdi, %rdi
    jz 15f
    mov 24(%rsp), %rax
    mov %rax, XS_CTX+EC_TUPLE(%rbx)
    lea XS_CTX(%rbx), %rsi
    call eval
    test %edx, %edx
    jnz 14f
    test $1, %eax
    jnz 15f
14: decq TS_N(%r13)                 /* drop the candidate */
    jmp 151f
15: movq $1, 16(%rsp)
    mov %r13, %rdi
    call check_join_rows
151: inc %r15
    jmp 12b
16: call ts_left_pad
    inc %r14
    jmp 11b

30: /* ---- hash join: build on the right input */
    mov FP_RKEY(%r12), %rax
    lea N_TYPE(%rax), %rsi
    mov $1, %edi
    call ht_new
    mov %rax, 32(%rsp)              /* ht */
    mov 8(%rsp), %rax
    mov TS_N(%rax), %rdi
    lea 8(,%rdi,8), %rdi
    call tmp_alloc
    mov %rax, 40(%rsp)              /* next[] */
    xor %r15d, %r15d
31: mov 8(%rsp), %rax
    cmp TS_N(%rax), %r15
    jae 35f
    mov 40(%rsp), %rcx
    movq $-1, (%rcx, %r15, 8)
    mov XS_W(%rbx), %rcx
    imul %r15, %rcx
    shl $3, %rcx
    add TS_DATA(%rax), %rcx
    mov %rcx, XS_CTX+EC_TUPLE(%rbx)
    mov FP_RKEY(%r12), %rdi
    lea XS_CTX(%rbx), %rsi
    call eval
    test %edx, %edx
    jnz 34f                         /* NULL keys never match */
    mov %rax, 48(%rsp)
    mov $VAL_SIZE, %edi
    call tmp_zalloc
    mov 48(%rsp), %rcx
    mov %rcx, VAL_P(%rax)
    mov 32(%rsp), %rdi
    mov %rax, %rsi
    mov $1, %edx
    call ht_lookup
    test %edx, %edx
    jz 33f
    movq $-1, EN_D0(%rax)
33: mov EN_D0(%rax), %rcx
    mov 40(%rsp), %rdx
    mov %rcx, (%rdx, %r15, 8)
    mov %r15, EN_D0(%rax)
34: inc %r15
    jmp 31b
35: /* probe with the left input */
    xor %r14d, %r14d
36: mov 0(%rsp), %rax
    cmp TS_N(%rax), %r14
    jae 90f
    test $1023, %r14
    jnz 37f
    call check_deadline
37: movq $0, 16(%rsp)               /* matched */
    mov 0(%rsp), %rax
    mov XS_W(%rbx), %rcx
    imul %r14, %rcx
    shl $3, %rcx
    add TS_DATA(%rax), %rcx
    mov %rcx, XS_CTX+EC_TUPLE(%rbx)
    mov FP_LKEY(%r12), %rdi
    lea XS_CTX(%rbx), %rsi
    call eval
    test %edx, %edx
    jnz 46f
    mov %rax, 48(%rsp)              /* probe cell at 48..63 */
    movq $0, 56(%rsp)
    mov 32(%rsp), %rdi
    lea 48(%rsp), %rsi
    xor %edx, %edx
    call ht_lookup
    test %rax, %rax
    jz 46f
    mov EN_D0(%rax), %r15           /* chain of right tuples */
40: cmp $-1, %r15
    je 46f
    mov %r13, %rdi
    call ts_slot
    mov %rax, 24(%rsp)
    mov %rax, %rdi
    mov 0(%rsp), %rax
    mov XS_W(%rbx), %r8
    mov %r14, %rsi
    imul %r8, %rsi
    shl $3, %rsi
    add TS_DATA(%rax), %rsi
    mov 8(%rsp), %rax
    mov %r15, %rdx
    imul %r8, %rdx
    shl $3, %rdx
    add TS_DATA(%rax), %rdx
    mov %r12, %rcx
    call tuple_combine
    mov 24(%rsp), %rax
    mov %rax, XS_CTX+EC_TUPLE(%rbx)
    mov FP_ON(%r12), %rdi
    lea XS_CTX(%rbx), %rsi
    call eval
    test %edx, %edx
    jnz 41f
    test $1, %eax
    jnz 42f
41: decq TS_N(%r13)
    jmp 43f
42: movq $1, 16(%rsp)
    mov %r13, %rdi
    call check_join_rows
43: mov 40(%rsp), %rax
    mov (%rax, %r15, 8), %r15
    jmp 40b
46: call ts_left_pad
    inc %r14
    jmp 36b

90: mov %r13, %rax
    LEAVE

/* ts_left_pad: local helper sharing exec_from's frame (rbx xs, r12 fp,
 * r13 out, r14 left index, 0(%rsp)+8 = L, 16(%rsp)+8 = matched):
 * emits the NULL-padded left tuple of an unmatched row of a LEFT JOIN */
ts_left_pad:
    cmpq $JT_LEFT, FP_JTYPE(%r12)
    jne 9f
    cmpq $0, 24(%rsp)
    jne 9f
    sub $8, %rsp
    mov %r13, %rdi
    call ts_slot
    mov %rax, %rdi
    mov 16(%rsp), %rax              /* L (frame shifted by call + sub) */
    mov XS_W(%rbx), %r8
    mov %r14, %rsi
    imul %r8, %rsi
    shl $3, %rsi
    add TS_DATA(%rax), %rsi
    xor %edx, %edx
    mov %r12, %rcx
    call tuple_combine
    mov %r13, %rdi
    call check_join_rows
    add $8, %rsp
9:  ret
ENDF exec_from

/* row_passes(plan rdi, ctx rsi) -> eax 1 if the WHERE predicate is TRUE (or absent) */
FUNC row_passes
    push %rbx
    mov QP_WHERE(%rdi), %rdi
    mov $1, %ebx
    test %rdi, %rdi
    jz 1f
    call eval
    xor %ebx, %ebx
    test %edx, %edx
    jnz 1f
    mov %eax, %ebx
    and $1, %ebx
1:  mov %ebx, %eax
    pop %rbx
    ret
ENDF row_passes

/* build_row(plan rdi, ctx rsi) -> rax row (cells: outputs then sort keys) */
FUNC build_row
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov QP_NOUT(%rbx), %rdi
    add QP_NKEYS(%rbx), %rdi
    shl $4, %rdi
    call tmp_alloc
    mov %rax, %r13
    xor %r14d, %r14d
1:  cmp QP_NOUT(%rbx), %r14
    jae 2f
    imul $OC_SIZE, %r14, %rax
    add QP_OUT(%rbx), %rax
    mov OC_EXPR(%rax), %rdi
    mov %r12, %rsi
    call eval
    mov %r14, %rcx
    shl $4, %rcx
    mov %rax, VAL_P(%r13, %rcx)
    mov %rdx, VAL_NULL(%r13, %rcx)
    inc %r14
    jmp 1b
2:  xor %r15d, %r15d
3:  cmp QP_NKEYS(%rbx), %r15
    jae 9f
    imul $SK_SIZE, %r15, %rcx
    add QP_KEYS(%rbx), %rcx
    mov SK_OUT(%rcx), %rax
    cmp $-1, %rax
    je 4f
    shl $4, %rax                    /* copy the output cell */
    mov VAL_P(%r13, %rax), %rdx
    mov VAL_NULL(%r13, %rax), %rax
    jmp 5f
4:  mov SK_EXPR(%rcx), %rdi
    mov %r12, %rsi
    call eval
    xchg %rax, %rdx
5:  mov QP_NOUT(%rbx), %rcx
    add %r15, %rcx
    shl $4, %rcx
    mov %rdx, VAL_P(%r13, %rcx)
    mov %rax, VAL_NULL(%r13, %rcx)
    inc %r15
    jmp 3b
9:  mov %r13, %rax
    LEAVE
ENDF build_row

/* row_cmp(pa rdi, pb rsi, plan rdx) -> eax  (qsort_r comparator) */
FUNC row_cmp
    ENTER 0
    mov (%rdi), %rbx                /* row a */
    mov (%rsi), %r12                /* row b */
    mov %rdx, %r13
    xor %r14d, %r14d
1:  cmp QP_NKEYS(%r13), %r14
    jae 8f
    imul $SK_SIZE, %r14, %r15
    add QP_KEYS(%r13), %r15
    mov QP_NOUT(%r13), %rcx
    add %r14, %rcx
    shl $4, %rcx
    mov VAL_NULL(%rbx, %rcx), %rax
    mov VAL_NULL(%r12, %rcx), %rdx
    test %rax, %rax
    jz 3f
    test %rdx, %rdx
    jnz 6f                          /* both NULL: equal */
    mov $-1, %eax                   /* a NULL */
    cmpq $0, SK_NFIRST(%r15)
    jne 9f
    mov $1, %eax
    jmp 9f
3:  test %rdx, %rdx
    jz 4f
    mov $1, %eax                    /* b NULL */
    cmpq $0, SK_NFIRST(%r15)
    jne 9f
    mov $-1, %eax
    jmp 9f
4:  mov SK_TYPE(%r15), %rdi
    mov VAL_P(%rbx, %rcx), %rsi
    mov VAL_P(%r12, %rcx), %rdx
    call value_cmp
    test %eax, %eax
    jz 6f
    cmpq $0, SK_DESC(%r15)
    je 9f
    neg %eax
    jmp 9f
6:  inc %r14
    jmp 1b
8:  xor %eax, %eax
9:  LEAVE
ENDF row_cmp

/* agg_update(plan rdi, ctx rsi, states rdx): feeds the current row to every aggregate */
FUNC agg_update
    ENTER 48
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    xor %r14d, %r14d
1:  cmp QP_NAGGS(%rbx), %r14
    jae 9f
    mov QP_AGGS(%rbx), %rax
    mov (%rax, %r14, 8), %r15       /* agg node */
    imul $AS_SIZE, %r14, %rax
    add %r13, %rax
    mov %rax, 0(%rsp)               /* state */
    cmpl $AGG_COUNT_STAR, N_OP(%r15)
    jne 2f
    incq AS_COUNT(%rax)
    jmp 8f
2:  mov N_A(%r15), %rdi
    mov %r12, %rsi
    call eval
    test %edx, %edx
    jnz 8f
    mov %rax, 8(%rsp)               /* value */
    testl $NF_DISTINCT, N_FLAGS(%r15)
    jz 25f
    /* DISTINCT: only values not seen before in this group */
    mov 0(%rsp), %rcx
    cmpq $0, AS_SET(%rcx)
    jne 21f
    mov N_A(%r15), %rsi
    lea N_TYPE(%rsi), %rsi
    mov $1, %edi
    call ht_new
    mov 0(%rsp), %rcx
    mov %rax, AS_SET(%rcx)
21: mov 8(%rsp), %rax
    mov %rax, 16(%rsp)              /* probe cell 16..31 */
    movq $0, 24(%rsp)
    mov 0(%rsp), %rcx
    mov AS_SET(%rcx), %rdi
    lea 16(%rsp), %rsi
    xor %edx, %edx
    call ht_lookup
    test %rax, %rax
    jnz 8f
    mov $VAL_SIZE, %edi
    call tmp_zalloc
    mov 8(%rsp), %rcx
    mov %rcx, VAL_P(%rax)
    mov 0(%rsp), %rcx
    mov AS_SET(%rcx), %rdi
    mov %rax, %rsi
    mov $1, %edx
    call ht_lookup
    mov 8(%rsp), %rax
25: mov 0(%rsp), %rcx
    incq AS_COUNT(%rcx)
    mov N_OP(%r15), %edx
    cmp $AGG_COUNT, %edx
    je 8f
    cmp $AGG_MIN, %edx
    jae 5f
    /* SUM / AVG */
    mov N_A(%r15), %rdx
    movzbl N_TYPE(%rdx), %edx
    cmp $T_FLOAT, %edx
    jne 3f
    movq %rax, %xmm0
    addsd AS_VAL(%rcx), %xmm0
    movsd %xmm0, AS_VAL(%rcx)
    jmp 8f
3:  cqo                             /* 128-bit integer sum */
    add %rax, AS_LO(%rcx)
    adc %rdx, AS_HI(%rcx)
    jmp 8f
5:  /* MIN / MAX */
    cmpq $0, AS_HAS(%rcx)
    je 7f
    mov N_A(%r15), %rdx
    mov N_TYPE(%rdx), %edi
    mov %rax, %rsi
    mov AS_VAL(%rcx), %rdx
    call value_cmp
    mov 0(%rsp), %rcx
    cmpl $AGG_MIN, N_OP(%r15)
    jne 6f
    cmp $0, %eax
    jge 8f
    jmp 61f
6:  cmp $0, %eax
    jle 8f
61: mov 8(%rsp), %rax
7:  mov %rax, AS_VAL(%rcx)
    movq $1, AS_HAS(%rcx)
8:  inc %r14
    jmp 1b
9:  LEAVE
ENDF agg_update

/* agg_finish(plan rdi, states rsi) -> rax value cells (VAL_SIZE per aggregate) */
FUNC agg_finish
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r13
    mov QP_NAGGS(%rbx), %rdi
    shl $4, %rdi
    call tmp_zalloc
    mov %rax, %r12
    xor %r14d, %r14d
1:  cmp QP_NAGGS(%rbx), %r14
    jae 99f
    mov QP_AGGS(%rbx), %rax
    mov (%rax, %r14, 8), %r15
    imul $AS_SIZE, %r14, %rcx
    add %r13, %rcx                  /* state */
    mov %r14, %r8
    shl $4, %r8
    add %r12, %r8                   /* out cell */
    mov N_OP(%r15), %edx
    cmp $AGG_COUNT, %edx
    ja 2f
    mov AS_COUNT(%rcx), %rax        /* COUNT(*), COUNT(x) */
    mov %rax, VAL_P(%r8)
    jmp 98f
2:  cmpq $0, AS_COUNT(%rcx)
    je 97f                          /* no input: NULL */
    mov N_A(%r15), %rax
    mov N_TYPE(%rax), %r9d          /* argument type */
    movzbl %r9b, %r10d
    cmp $AGG_SUM, %edx
    je 3f
    cmp $AGG_AVG, %edx
    je 5f
    /* MIN / MAX */
    cmpq $0, AS_HAS(%rcx)
    je 97f
    mov AS_VAL(%rcx), %rax
    mov %rax, VAL_P(%r8)
    jmp 98f
3:  /* SUM */
    cmp $T_FLOAT, %r10d
    jne 4f
    movsd AS_VAL(%rcx), %xmm0
    mov %r8, 0(%rsp)
    call check_finite
    mov 0(%rsp), %r8
    movsd %xmm0, VAL_P(%r8)
    jmp 98f
4:  mov AS_LO(%rcx), %rax
    mov AS_HI(%rcx), %rdx
    cmp $T_DEC, %r10d
    jne 41f
    mov %r8, 0(%rsp)
    call chk_dec128
    mov 0(%rsp), %r8
    mov %rax, VAL_P(%r8)
    jmp 98f
41: mov %rax, %rsi                  /* INT: must fit int64 */
    sar $63, %rsi
    cmp %rsi, %rdx
    jne raise_overflow
    mov %rax, VAL_P(%r8)
    jmp 98f
5:  /* AVG */
    mov %r8, 0(%rsp)
    mov %rcx, 8(%rsp)
    cmp $T_FLOAT, %r10d
    jne 6f
    movsd AS_VAL(%rcx), %xmm0
    jmp 7f
6:  mov AS_LO(%rcx), %rdi
    mov AS_HI(%rcx), %rsi
    call i128_to_double
    mov N_A(%r15), %rax
    movzbl N_TYPE(%rax), %ecx
    cmp $T_DEC, %ecx
    jne 7f
    mov N_TYPE(%rax), %ecx
    shr $16, %ecx
    and $0xff, %ecx
    lea pow10_u64(%rip), %rax
    cvtsi2sdq (%rax, %rcx, 8), %xmm1
    divsd %xmm1, %xmm0
7:  call check_finite                /* FLOAT64 sum overflow */
    mov 8(%rsp), %rcx
    cvtsi2sdq AS_COUNT(%rcx), %xmm1
    divsd %xmm1, %xmm0
    mov 0(%rsp), %r8
    movsd %xmm0, VAL_P(%r8)
    jmp 98f
97: movq $1, VAL_NULL(%r8)
98: inc %r14
    jmp 1b
99: mov %r12, %rax
    LEAVE
ENDF agg_finish

/* ================================================================ query block */

/* xs_tuple(xs rdi, i rsi) -> rax pointer to tuple i of XS_TS */
FUNC xs_tuple
    mov XS_TS(%rdi), %rax
    imul TS_W(%rax), %rsi
    shl $3, %rsi
    mov TS_DATA(%rax), %rax
    add %rsi, %rax
    ret
ENDF xs_tuple

/* emit_group(xs rdi, rep tuple rsi, states rdx): HAVING, then the output row */
FUNC emit_group
    ENTER 0
    mov %rdi, %rbx
    mov XS_PLAN(%rbx), %r12
    mov %rsi, XS_CTX+EC_TUPLE(%rbx)
    mov %r12, %rdi
    mov %rdx, %rsi
    call agg_finish
    mov %rax, XS_CTX+EC_AGGV(%rbx)
    mov QP_HAVING(%r12), %rdi
    test %rdi, %rdi
    jz 1f
    lea XS_CTX(%rbx), %rsi
    call eval
    test %edx, %edx
    jnz 9f
    test $1, %eax
    jz 9f
1:  mov %r12, %rdi
    lea XS_CTX(%rbx), %rsi
    call build_row
    lea XS_ROWS(%rbx), %rdi
    mov %rax, %rsi
    call vec_push
9:  LEAVE
ENDF emit_group

/* exec_aggregate(xs rdi): grouping (hash) and aggregation, one row per group */
FUNC exec_aggregate
    ENTER 48
    mov %rdi, %rbx
    mov XS_PLAN(%rbx), %r12
    mov XS_TS(%rbx), %r13
    cmpq $0, QP_NGROUP(%r12)
    jne 10f
    /* ---- single group */
    mov QP_NAGGS(%r12), %rdi
    imul $AS_SIZE, %rdi, %rdi
    add $8, %rdi
    call tmp_zalloc
    mov %rax, %r15                  /* states */
    xor %r14d, %r14d
1:  cmp TS_N(%r13), %r14
    jae 3f
    test $1023, %r14
    jnz 2f
    call check_deadline
2:  mov %rbx, %rdi
    mov %r14, %rsi
    call xs_tuple
    mov %rax, XS_CTX+EC_TUPLE(%rbx)
    mov %r12, %rdi
    lea XS_CTX(%rbx), %rsi
    mov %r15, %rdx
    call agg_update
    inc %r14
    jmp 1b
3:  /* representative tuple: the first one, or all NULL on empty input */
    cmpq $0, TS_N(%r13)
    je 4f
    mov TS_DATA(%r13), %rsi
    jmp 5f
4:  mov XS_W(%rbx), %rdi
    shl $3, %rdi
    call tmp_alloc
    mov %rax, 0(%rsp)
    mov %rax, %rdi
    mov $0xff, %esi
    mov XS_W(%rbx), %rdx
    shl $3, %rdx
    call memset
    mov 0(%rsp), %rsi
5:  mov %rbx, %rdi
    mov %r15, %rdx
    call emit_group
    LEAVE

10: /* ---- GROUP BY: hash on the key cells */
    mov QP_NGROUP(%r12), %rdi
    shl $3, %rdi
    call tmp_alloc
    mov %rax, 0(%rsp)               /* key types */
    xor %ecx, %ecx
11: cmp QP_NGROUP(%r12), %rcx
    jae 12f
    mov QP_GROUP(%r12), %rdx
    mov (%rdx, %rcx, 8), %rdx
    mov N_TYPE(%rdx), %edx
    mov 0(%rsp), %rsi
    mov %rdx, (%rsi, %rcx, 8)
    inc %rcx
    jmp 11b
12: mov QP_NGROUP(%r12), %rdi
    mov 0(%rsp), %rsi
    call ht_new
    mov %rax, 8(%rsp)               /* ht */
    mov QP_NGROUP(%r12), %rdi
    shl $4, %rdi
    call tmp_alloc
    mov %rax, 16(%rsp)              /* scratch key */
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, 24(%rsp)              /* groups (entries) in first-seen order */
    xor %r14d, %r14d
13: cmp TS_N(%r13), %r14
    jae 20f
    test $1023, %r14
    jnz 14f
    call check_deadline
14: mov %rbx, %rdi
    mov %r14, %rsi
    call xs_tuple
    mov %rax, XS_CTX+EC_TUPLE(%rbx)
    mov %rax, 32(%rsp)
    xor %r15d, %r15d
15: cmp QP_NGROUP(%r12), %r15
    jae 16f
    mov QP_GROUP(%r12), %rax
    mov (%rax, %r15, 8), %rdi
    lea XS_CTX(%rbx), %rsi
    call eval
    mov %r15, %rcx
    shl $4, %rcx
    add 16(%rsp), %rcx
    mov %rax, VAL_P(%rcx)
    mov %rdx, VAL_NULL(%rcx)
    inc %r15
    jmp 15b
16: mov 8(%rsp), %rdi
    mov 16(%rsp), %rsi
    xor %edx, %edx
    call ht_lookup
    test %rax, %rax
    jnz 17f
    mov QP_NGROUP(%r12), %rdi       /* new group: persistent key copy */
    shl $4, %rdi
    call tmp_alloc
    mov %rax, 40(%rsp)
    mov %rax, %rdi
    mov 16(%rsp), %rsi
    mov QP_NGROUP(%r12), %rdx
    shl $4, %rdx
    call memcpy
    mov 8(%rsp), %rdi
    mov 40(%rsp), %rsi
    mov $1, %edx
    call ht_lookup
    mov %rax, 40(%rsp)
    mov 32(%rsp), %rcx
    mov %rcx, EN_D1(%rax)           /* representative tuple */
    mov QP_NAGGS(%r12), %rdi
    imul $AS_SIZE, %rdi, %rdi
    add $8, %rdi
    call tmp_zalloc
    mov 40(%rsp), %rcx
    mov %rax, EN_D0(%rcx)           /* aggregate states */
    mov 24(%rsp), %rdi
    mov %rcx, %rsi
    call vec_push
    mov 40(%rsp), %rax
17: mov EN_D0(%rax), %rdx
    mov %r12, %rdi
    lea XS_CTX(%rbx), %rsi
    call agg_update
    inc %r14
    jmp 13b
20: xor %r14d, %r14d
21: mov 24(%rsp), %rax
    cmp VEC_LEN(%rax), %r14
    jae 29f
    mov VEC_DATA(%rax), %rax
    mov (%rax, %r14, 8), %rax
    mov EN_D1(%rax), %rsi
    mov EN_D0(%rax), %rdx
    mov %rbx, %rdi
    call emit_group
    inc %r14
    jmp 21b
29: LEAVE
ENDF exec_aggregate

/* distinct_rows(xs rdi): removes duplicate output rows (NULLs equal), keeps first */
FUNC distinct_rows
    ENTER 16
    mov %rdi, %rbx
    mov XS_PLAN(%rbx), %r12
    mov QP_NOUT(%r12), %rdi
    shl $3, %rdi
    add $8, %rdi
    call tmp_alloc
    mov %rax, %r13                  /* types */
    xor %ecx, %ecx
1:  cmp QP_NOUT(%r12), %rcx
    jae 2f
    imul $OC_SIZE, %rcx, %rdx
    add QP_OUT(%r12), %rdx
    mov OC_TYPE(%rdx), %rdx
    mov %rdx, (%r13, %rcx, 8)
    inc %rcx
    jmp 1b
2:  mov QP_NOUT(%r12), %rdi
    mov %r13, %rsi
    call ht_new
    mov %rax, %r13
    xor %r14d, %r14d                /* read */
    xor %r15d, %r15d                /* write */
3:  cmp VEC_LEN+XS_ROWS(%rbx), %r14
    jae 9f
    mov VEC_DATA+XS_ROWS(%rbx), %rax
    mov (%rax, %r14, 8), %rsi
    mov %rsi, 0(%rsp)
    mov %r13, %rdi
    mov $1, %edx
    call ht_lookup
    test %edx, %edx
    jz 4f
    mov VEC_DATA+XS_ROWS(%rbx), %rax
    mov 0(%rsp), %rcx
    mov %rcx, (%rax, %r15, 8)
    inc %r15
4:  inc %r14
    jmp 3b
9:  mov %r15, VEC_LEN+XS_ROWS(%rbx)
    LEAVE
ENDF distinct_rows

/* result_to_table(result rdi, rv rsi) -> rax columnar Table* (derived tables, CTEs) */
FUNC result_to_table
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov $TB_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13
    mov RV_NAME(%r12), %rax
    mov %rax, TB_NAME(%r13)
    mov RV_NCOLS(%r12), %rax
    mov %rax, TB_NCOLS(%r13)
    mov RS_NROWS(%rbx), %rax
    mov %rax, TB_NROWS(%r13)
    mov RV_NCOLS(%r12), %rdi
    shl $5, %rdi
    add $8, %rdi
    call tmp_zalloc
    mov %rax, TB_COLS(%r13)
    xor %r14d, %r14d                /* column */
1:  cmp RV_NCOLS(%r12), %r14
    jae 9f
    mov %r14, %r15
    shl $5, %r15
    add TB_COLS(%r13), %r15         /* Column* */
    mov %r14, %rax
    shl $4, %rax
    add RV_COLS(%r12), %rax
    mov RVC_NAME(%rax), %rcx
    mov %rcx, COL_NAME(%r15)
    mov RVC_TYPE(%rax), %rcx
    mov %rcx, COL_TYPE(%r15)
    mov RS_NROWS(%rbx), %rdi
    lea 8(,%rdi,8), %rdi
    call tmp_alloc
    mov %rax, COL_DATA(%r15)
    mov RS_NROWS(%rbx), %rdi
    add $8, %rdi
    call tmp_alloc
    mov %rax, COL_NULLS(%r15)
    mov COL_DATA(%r15), %r8
    mov COL_NULLS(%r15), %r9
    mov RS_ROWS(%rbx), %r10
    mov %r14, %r11
    shl $4, %r11
    xor %ecx, %ecx
2:  cmp RS_NROWS(%rbx), %rcx
    jae 3f
    mov (%r10, %rcx, 8), %rax       /* row */
    mov VAL_P(%rax, %r11), %rdx
    mov %rdx, (%r8, %rcx, 8)
    mov VAL_NULL(%rax, %r11), %rdx
    mov %dl, (%r9, %rcx)
    inc %rcx
    jmp 2b
3:  inc %r14
    jmp 1b
9:  mov %r13, %rax
    LEAVE
ENDF result_to_table

/* exec_plan(plan rdi, outer ctx rsi) -> rax Result* */
FUNC exec_plan
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r14
    cmpq $0, QP_CORR(%rbx)
    jne 1f
    mov QP_CACHE(%rbx), %rax
    test %rax, %rax
    jz 1f
    LEAVE
1:  mov $XS_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r12                  /* xs */
    mov %rbx, XS_PLAN(%r12)
    mov %r14, XS_CTX+EC_OUTER(%r12)
    mov QP_NRV(%rbx), %rax
    mov $1, %ecx
    test %rax, %rax
    cmovnz %rax, %rcx
    mov %rcx, XS_W(%r12)
    lea 8(,%rax,8), %rdi
    call tmp_zalloc
    mov %rax, XS_TABLES(%r12)
    mov %rax, XS_CTX+EC_TABLES(%r12)
    /* ---- range variables: base tables, or materialised derived tables / CTEs */
    xor %r13d, %r13d
2:  cmp QP_NRV(%rbx), %r13
    jae 4f
    mov QP_RVS(%rbx), %rax
    mov (%rax, %r13, 8), %r15       /* rv */
    mov RV_TABLE(%r15), %rax
    test %rax, %rax
    jnz 3f
    mov RV_PLAN(%r15), %rdi
    lea XS_CTX(%r12), %rsi
    call exec_plan
    mov %rax, %rdi
    mov %r15, %rsi
    call result_to_table
3:  mov XS_TABLES(%r12), %rcx
    mov %rax, (%rcx, %r13, 8)
    inc %r13
    jmp 2b
4:  /* ---- FROM */
    mov QP_FROM(%rbx), %rsi
    test %rsi, %rsi
    jz 5f
    mov %r12, %rdi
    call exec_from
    mov %rax, XS_TS(%r12)
    jmp 6f
5:  mov $1, %edi                    /* no FROM: one empty tuple */
    mov $1, %esi
    call ts_new
    mov %rax, XS_TS(%r12)
    mov %rax, %rdi
    call ts_slot
    movq $-1, (%rax)
6:  /* ---- WHERE: filter tuples in place */
    cmpq $0, QP_WHERE(%rbx)
    je 8f
    mov XS_TS(%r12), %r15
    xor %r13d, %r13d                /* read */
    xor %r14d, %r14d                /* write */
7:  cmp TS_N(%r15), %r13
    jae 79f
    test $1023, %r13
    jnz 71f
    call check_deadline
71: mov %r12, %rdi
    mov %r13, %rsi
    call xs_tuple
    mov %rax, 0(%rsp)
    mov %rax, XS_CTX+EC_TUPLE(%r12)
    mov QP_WHERE(%rbx), %rdi
    lea XS_CTX(%r12), %rsi
    call eval
    test %edx, %edx
    jnz 78f
    test $1, %eax
    jz 78f
    cmp %r13, %r14
    je 77f
    mov %r12, %rdi
    mov %r14, %rsi
    call xs_tuple
    mov %rax, %rdi
    mov 0(%rsp), %rsi
    mov XS_W(%r12), %rdx
    shl $3, %rdx
    call memcpy
77: inc %r14
78: inc %r13
    jmp 7b
79: mov %r14, TS_N(%r15)
8:  /* ---- rows */
    lea XS_ROWS(%r12), %rdi
    mov g_arena(%rip), %rsi
    call vec_init
    cmpq $0, QP_AGG(%rbx)
    je 81f
    mov %r12, %rdi
    call exec_aggregate
    jmp 85f
81: /* projection; stop early when unsorted, not DISTINCT and limited */
    mov $0x7fffffffffffffff, %rax
    mov %rax, XS_STOP(%r12)
    cmpq $0, QP_NKEYS(%rbx)
    jne 82f
    cmpq $0, QP_DISTINCT(%rbx)
    jne 82f
    mov QP_LIMIT(%rbx), %rax
    test %rax, %rax
    js 82f
    add QP_OFFSET(%rbx), %rax
    jo 82f
    mov %rax, XS_STOP(%r12)
82: xor %r13d, %r13d
    mov XS_TS(%r12), %r15
83: cmp TS_N(%r15), %r13
    jae 85f
    mov VEC_LEN+XS_ROWS(%r12), %rax
    cmp XS_STOP(%r12), %rax
    jae 85f
    test $1023, %r13
    jnz 84f
    call check_deadline
84: mov %r12, %rdi
    mov %r13, %rsi
    call xs_tuple
    mov %rax, XS_CTX+EC_TUPLE(%r12)
    mov %rbx, %rdi
    lea XS_CTX(%r12), %rsi
    call build_row
    lea XS_ROWS(%r12), %rdi
    mov %rax, %rsi
    call vec_push
    inc %r13
    jmp 83b
85: /* ---- DISTINCT */
    cmpq $0, QP_DISTINCT(%rbx)
    je 86f
    mov %r12, %rdi
    call distinct_rows
86: /* ---- sort */
    cmpq $0, QP_NKEYS(%rbx)
    je 87f
    mov VEC_LEN+XS_ROWS(%r12), %rsi
    cmp $1, %rsi
    jbe 87f
    mov VEC_DATA+XS_ROWS(%r12), %rdi
    mov $8, %edx
    lea row_cmp(%rip), %rcx
    mov %rbx, %r8
    call qsort_r
87: /* ---- offset / limit */
    mov VEC_LEN+XS_ROWS(%r12), %rax /* n */
    mov QP_OFFSET(%rbx), %r13
    cmp %rax, %r13
    cmova %rax, %r13                /* start */
    mov %rax, %r14                  /* end */
    mov QP_LIMIT(%rbx), %rdx
    test %rdx, %rdx
    js 88f
    add %r13, %rdx
    jo 88f
    cmp %rax, %rdx
    jae 88f
    mov %rdx, %r14
88: mov $RS_SIZE, %edi
    call tmp_zalloc
    mov QP_NOUT(%rbx), %rcx
    mov %rcx, RS_NCOLS(%rax)
    sub %r13, %r14
    mov %r14, RS_NROWS(%rax)
    mov VEC_DATA+XS_ROWS(%r12), %rcx
    lea (%rcx, %r13, 8), %rcx
    mov %rcx, RS_ROWS(%rax)
    mov %rbx, RS_PLAN(%rax)
    cmpq $0, QP_CORR(%rbx)
    jne 89f
    mov %rax, QP_CACHE(%rbx)
89: LEAVE
ENDF exec_plan

/* ================================================================ subqueries in expressions */

/* eval_subquery(node rdi, ctx rsi) -> rax payload, rdx null */
FUNC eval_subquery
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov N_KIND(%rbx), %eax
    cmp $EK_INSUBQ, %eax
    je 20f
    cmp $EK_EXISTS, %eax
    je 10f
    /* ---- scalar subquery */
    testl $NF_CACHED, N_FLAGS(%rbx)
    jz 1f
    mov N_V3(%rbx), %rcx
    mov VAL_P(%rcx), %rax
    mov VAL_NULL(%rcx), %rdx
    LEAVE
1:  mov N_V2(%rbx), %rdi
    mov %r12, %rsi
    call exec_plan
    mov RS_NROWS(%rax), %rcx
    cmp $1, %rcx
    ja 8f
    mov %rax, %r13
    mov $VAL_SIZE, %edi
    call tmp_zalloc
    movq $1, VAL_NULL(%rax)
    cmpq $0, RS_NROWS(%r13)
    je 2f
    mov RS_ROWS(%r13), %rcx
    mov (%rcx), %rcx                /* row 0 */
    mov VAL_P(%rcx), %rdx
    mov %rdx, VAL_P(%rax)
    mov VAL_NULL(%rcx), %rdx
    mov %rdx, VAL_NULL(%rax)
2:  testl $NF_CORR, N_FLAGS(%rbx)
    jnz 3f
    mov %rax, N_V3(%rbx)
    orl $NF_CACHED, N_FLAGS(%rbx)
3:  mov VAL_NULL(%rax), %rdx
    mov VAL_P(%rax), %rax
    LEAVE
8:  RAISE E_SUBQUERY_CARDINALITY, "scalar subquery returned more than one row"

10: /* ---- EXISTS */
    testl $NF_CACHED, N_FLAGS(%rbx)
    jz 11f
    mov N_V3(%rbx), %rax
    xor %edx, %edx
    LEAVE
11: mov N_V2(%rbx), %rdi
    mov %r12, %rsi
    call exec_plan
    xor %ecx, %ecx
    cmpq $0, RS_NROWS(%rax)
    setne %cl
    mov %rcx, %rax
    testl $NF_CORR, N_FLAGS(%rbx)
    jnz 12f
    mov %rax, N_V3(%rbx)
    orl $NF_CACHED, N_FLAGS(%rbx)
12: xor %edx, %edx
    LEAVE

20: /* ---- x [NOT] IN (subquery) */
    testl $NF_CACHED, N_FLAGS(%rbx)
    jz 21f
    mov N_V3(%rbx), %r13
    jmp 30f
21: mov N_V2(%rbx), %rdi
    mov %r12, %rsi
    call exec_plan
    mov %rax, %r14                  /* result */
    mov $IS_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13                  /* set */
    mov RS_NROWS(%r14), %rax
    mov %rax, IS_ROWS(%r13)
    mov RS_PLAN(%r14), %rax
    mov QP_OUT(%rax), %rax
    mov OC_TYPE(%rax), %rax
    mov %rax, 0(%rsp)               /* subquery column type */
    mov N_A(%rbx), %rcx
    mov N_TYPE(%rcx), %ecx          /* comparison type: x's (already promoted) type */
    cmp $T_NULL, %cl
    jne 22f
    mov %eax, %ecx
22: mov %rcx, IS_TYPE(%r13)
    lea IS_TYPE(%r13), %rsi
    mov $1, %edi
    call ht_new
    mov %rax, IS_HT(%r13)
    xor %r15d, %r15d
23: cmp RS_NROWS(%r14), %r15
    jae 29f
    mov RS_ROWS(%r14), %rax
    mov (%rax, %r15, 8), %rax       /* row */
    cmpq $0, VAL_NULL(%rax)
    je 24f
    movq $1, IS_NULL(%r13)
    jmp 28f
24: mov VAL_P(%rax), %rdx
    mov 0(%rsp), %rdi
    mov IS_TYPE(%r13), %rsi
    cmp %edi, %esi
    je 25f
    call cast_value
    mov %rax, %rdx
25: mov %rdx, 8(%rsp)
    mov $VAL_SIZE, %edi
    call tmp_zalloc
    mov 8(%rsp), %rcx
    mov %rcx, VAL_P(%rax)
    mov IS_HT(%r13), %rdi
    mov %rax, %rsi
    mov $1, %edx
    call ht_lookup
28: inc %r15
    jmp 23b
29: testl $NF_CORR, N_FLAGS(%rbx)
    jnz 30f
    mov %r13, N_V3(%rbx)
    orl $NF_CACHED, N_FLAGS(%rbx)
30: /* r13 = set: evaluate x and probe */
    xor %r14d, %r14d                /* result: FALSE */
    cmpq $0, IS_ROWS(%r13)
    je 38f                          /* empty set: FALSE even for NULL x */
    mov N_A(%rbx), %rdi
    mov %r12, %rsi
    call eval
    test %edx, %edx
    jnz 37f
    mov %rax, 16(%rsp)
    movq $0, 24(%rsp)
    mov IS_HT(%r13), %rdi
    lea 16(%rsp), %rsi
    xor %edx, %edx
    call ht_lookup
    mov $1, %r14d
    test %rax, %rax
    jnz 38f
    xor %r14d, %r14d
    cmpq $0, IS_NULL(%r13)
    je 38f
37: xor %eax, %eax                  /* NULL */
    mov $1, %edx
    LEAVE
38: mov %r14, %rax
    xor N_OP(%rbx), %eax            /* NOT IN */
    and $1, %eax
    xor %edx, %edx
    LEAVE
ENDF eval_subquery

/* ================================================================ top level */

/* exec_query(plan, max_rows, count_only, out) */
FUNC exec_query
    ENTER 32
    mov %rdi, %rbx                  /* plan */
    mov %rsi, 0(%rsp)               /* max rows */
    mov %rdx, 8(%rsp)               /* count only */
    mov %rcx, %r15                  /* out */
    xor %esi, %esi
    call exec_plan
    mov %rax, %r12                  /* result */
    mov RS_NROWS(%r12), %r14
    mov 0(%rsp), %rax
    test %rax, %rax
    js 12f
    cmp %rax, %r14
    jbe 12f
    RAISE E_RESOURCE_LIMIT, "result exceeds max_rows"
12: /* ---- serialize */
    PUTS %r15, "\"columns\":["
    xor %r13d, %r13d
13: cmp QP_NOUT(%rbx), %r13
    jae 15f
    test %r13, %r13
    jz 14f
    mov %r15, %rdi
    mov $',', %esi
    call buf_putc
14: PUTS %r15, "{\"name\":"
    imul $OC_SIZE, %r13, %rax
    add QP_OUT(%rbx), %rax
    mov OC_NAME(%rax), %rsi
    mov %r15, %rdi
    call buf_put_json_pstr
    PUTS %r15, ",\"type\":\""
    imul $OC_SIZE, %r13, %rax
    add QP_OUT(%rbx), %rax
    mov OC_TYPE(%rax), %rsi
    mov %r15, %rdi
    call fmt_type
    PUTS %r15, "\"}"
    inc %r13
    jmp 13b
15: PUTS %r15, "]"
    cmpq $0, 8(%rsp)
    jne 20f
    PUTS %r15, ",\"rows\":["
    xor %r13d, %r13d
16: cmp RS_NROWS(%r12), %r13
    jae 19f
    test %r13, %r13
    jz 17f
    mov %r15, %rdi
    mov $',', %esi
    call buf_putc
17: mov %r15, %rdi
    mov $'[', %esi
    call buf_putc
    mov RS_ROWS(%r12), %rax
    mov (%rax, %r13, 8), %rax
    mov %rax, 16(%rsp)              /* row */
    xor %r14d, %r14d
171: cmp QP_NOUT(%rbx), %r14
    jae 18f
    test %r14, %r14
    jz 172f
    mov %r15, %rdi
    mov $',', %esi
    call buf_putc
172: mov %r14, %rcx
    shl $4, %rcx
    add 16(%rsp), %rcx
    cmpq $0, VAL_NULL(%rcx)
    je 173f
    PUTS %r15, "null"
    jmp 174f
173: mov VAL_P(%rcx), %rdx
    imul $OC_SIZE, %r14, %rax
    add QP_OUT(%rbx), %rax
    mov OC_TYPE(%rax), %rsi
    mov %r15, %rdi
    call fmt_value_json
174: inc %r14
    jmp 171b
18: mov %r15, %rdi
    mov $']', %esi
    call buf_putc
    inc %r13
    jmp 16b
19: PUTS %r15, "]"
20: PUTS %r15, ",\"row_count\":"
    mov RS_NROWS(%r12), %rsi
    mov %r15, %rdi
    call buf_put_u64
    LEAVE
ENDF exec_query
