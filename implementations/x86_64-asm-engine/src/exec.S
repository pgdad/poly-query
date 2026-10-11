/*
 * exec.S - query execution: scan -> filter -> (aggregate) -> project ->
 * sort -> offset/limit, then JSON serialization of the result.
 *
 *   exec_query(plan rdi, max_rows rsi (-1 = none), count_only rdx, out Buf* rcx)
 *     appends  "columns":[...],"rows":[...],"row_count":N  to the buffer.
 *
 * Rows are materialised as arrays of VAL_SIZE cells: the output columns
 * followed by the sort keys.  Sorting uses qsort_r over row pointers.
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
#define AS_SIZE  48

/* executor frame (locals at rsp) */
#define X_PLAN    0
#define X_MAXROWS 8
#define X_COUNTO  16
#define X_OUT     24
#define X_CTX     32   /* EC_SIZE bytes: 32..95 */
#define X_ROWS    96   /* Vec: 96..127 */
#define X_NROWS   128  /* rows to scan */
#define X_STOP    136  /* stop after this many produced rows */
#define X_STATES  144
#define X_NCELLS  152
#define X_START   160
#define X_END     168
#define X_ROWIDX  176  /* current row index (EC_TUPLE target) */
#define X_TABPTR  184  /* Table* (EC_TABLES target) */
#define X_LOCALS  192

    .text

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
    ENTER 16
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
    mov 0(%rsp), %rcx
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
    mov %rax, 8(%rsp)
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

/* exec_query(plan, max_rows, count_only, out) */
FUNC exec_query
    ENTER X_LOCALS
    mov %rdi, X_PLAN(%rsp)
    mov %rsi, X_MAXROWS(%rsp)
    mov %rdx, X_COUNTO(%rsp)
    mov %rcx, X_OUT(%rsp)
    mov %rdi, %rbx                  /* plan */
    lea X_CTX(%rsp), %r12           /* ctx */
    mov QP_TABLE(%rbx), %rax
    mov %rax, X_TABPTR(%rsp)
    lea X_TABPTR(%rsp), %rax
    mov %rax, EC_TABLES(%r12)
    movq $0, X_ROWIDX(%rsp)
    lea X_ROWIDX(%rsp), %rax
    mov %rax, EC_TUPLE(%r12)
    movq $0, EC_AGGV(%r12)
    movq $0, EC_OUTER(%r12)
    lea X_ROWS(%rsp), %rdi
    mov g_arena(%rip), %rsi
    call vec_init
    /* rows to scan */
    movq $1, X_NROWS(%rsp)
    mov QP_TABLE(%rbx), %rax
    test %rax, %rax
    jz 1f
    mov TB_NROWS(%rax), %rax
    mov %rax, X_NROWS(%rsp)
1:  /* early stop when unsorted and limited */
    mov $0x7fffffffffffffff, %rax
    mov %rax, X_STOP(%rsp)
    cmpq $0, QP_NKEYS(%rbx)
    jne 2f
    cmpq $0, QP_AGG(%rbx)
    jne 2f
    mov QP_LIMIT(%rbx), %rax
    test %rax, %rax
    js 2f
    add QP_OFFSET(%rbx), %rax
    jo 2f
    mov %rax, X_STOP(%rsp)
2:  cmpq $0, QP_AGG(%rbx)
    je 3f
    mov QP_NAGGS(%rbx), %rdi
    imul $AS_SIZE, %rdi, %rdi
    call tmp_zalloc
    mov %rax, X_STATES(%rsp)
3:  /* ---- scan */
    xor %r13d, %r13d
4:  cmp X_NROWS(%rsp), %r13
    jae 8f
    mov VEC_LEN+X_ROWS(%rsp), %rax
    cmp X_STOP(%rsp), %rax
    jae 8f
    test $1023, %r13
    jnz 5f
    call check_deadline
5:  mov %r13, X_ROWIDX(%rsp)
    mov %rbx, %rdi
    mov %r12, %rsi
    call row_passes
    test %eax, %eax
    jz 7f
    cmpq $0, QP_AGG(%rbx)
    je 6f
    mov %rbx, %rdi
    mov %r12, %rsi
    mov X_STATES(%rsp), %rdx
    call agg_update
    jmp 7f
6:  mov %rbx, %rdi
    mov %r12, %rsi
    call build_row
    lea X_ROWS(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
7:  inc %r13
    jmp 4b
8:  /* ---- aggregation result row */
    cmpq $0, QP_AGG(%rbx)
    je 9f
    mov %rbx, %rdi
    mov X_STATES(%rsp), %rsi
    call agg_finish
    mov %rax, EC_AGGV(%r12)
    mov %rbx, %rdi
    mov %r12, %rsi
    call build_row
    lea X_ROWS(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
9:  /* ---- sort */
    cmpq $0, QP_NKEYS(%rbx)
    je 10f
    mov VEC_LEN+X_ROWS(%rsp), %rsi
    cmp $1, %rsi
    jbe 10f
    mov VEC_DATA+X_ROWS(%rsp), %rdi
    mov $8, %edx
    lea row_cmp(%rip), %rcx
    mov %rbx, %r8
    call qsort_r
10: /* ---- offset / limit */
    mov VEC_LEN+X_ROWS(%rsp), %rax  /* n */
    mov QP_OFFSET(%rbx), %rcx
    cmp %rax, %rcx
    cmova %rax, %rcx
    mov %rcx, X_START(%rsp)
    mov %rax, X_END(%rsp)
    mov QP_LIMIT(%rbx), %rdx
    test %rdx, %rdx
    js 11f
    add %rcx, %rdx
    jo 11f
    cmp %rax, %rdx
    jae 11f
    mov %rdx, X_END(%rsp)
11: mov X_END(%rsp), %r14
    sub X_START(%rsp), %r14         /* result row count */
    mov X_MAXROWS(%rsp), %rax
    test %rax, %rax
    js 12f
    cmp %rax, %r14
    jbe 12f
    RAISE E_RESOURCE_LIMIT, "result exceeds max_rows"
12: /* ---- serialize */
    mov X_OUT(%rsp), %r15
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
    cmpq $0, X_COUNTO(%rsp)
    jne 20f
    PUTS %r15, ",\"rows\":["
    mov X_START(%rsp), %r13
16: cmp X_END(%rsp), %r13
    jae 19f
    cmp X_START(%rsp), %r13
    je 17f
    mov %r15, %rdi
    mov $',', %esi
    call buf_putc
17: mov %r15, %rdi
    mov $'[', %esi
    call buf_putc
    mov VEC_DATA+X_ROWS(%rsp), %rax
    mov (%rax, %r13, 8), %r12       /* row */
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
    cmpq $0, VAL_NULL(%r12, %rcx)
    je 173f
    PUTS %r15, "null"
    jmp 174f
173: mov VAL_P(%r12, %rcx), %rdx
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
    mov X_END(%rsp), %rsi
    sub X_START(%rsp), %rsi
    mov %r15, %rdi
    call buf_put_u64
    LEAVE
ENDF exec_query
