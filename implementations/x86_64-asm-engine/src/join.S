/*
 * join.S - sort-merge join (option join: "merge").
 *
 *   exec_merge_join(xs rdi, fp rsi, L rdx, R rcx, out r8)
 *
 * Both inputs are reduced to (key, tuple index) entries (NULL keys never
 * match and are dropped), sorted by (key, index) and merged: every left
 * entry learns the range of right entries with an equal key.  The output is
 * then emitted in left input order with the matching right tuples in right
 * input order - exactly the order of the nested-loop and hash joins - and
 * the full ON condition is re-checked on every candidate pair.  Unmatched
 * left tuples of a LEFT JOIN are NULL-padded.
 */
#include "pq.inc"
#include "sql.inc"
#include "exec.inc"

    .section .note.GNU-stack, "", @progbits

/* sort entry */
#define ME_KEY 0
#define ME_IDX 8
#define ME_SIZE 16


    .text

/* me_cmp(a rdi, b rsi, type* rdx) -> eax: qsort_r comparator on (key, idx) */
FUNC me_cmp
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %rbx
    mov %rsi, %r12
    mov (%rdx), %edi
    mov ME_KEY(%rbx), %rsi
    mov ME_KEY(%r12), %rdx
    call value_cmp
    test %eax, %eax
    jnz 9f
    mov ME_IDX(%rbx), %rcx
    cmp ME_IDX(%r12), %rcx
    seta %al
    setb %cl
    sub %cl, %al
    movsbl %al, %eax
9:  add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF me_cmp

/* me_cmp_int(a rdi, b rsi) -> eax: me_cmp for 64-bit integer-like keys
 * (BOOLEAN, INT64, DATE, TIMESTAMP, DECIMAL of one scale) */
FUNC me_cmp_int
    mov ME_KEY(%rdi), %rax
    cmp ME_KEY(%rsi), %rax
    jl 1f
    jg 2f
    mov ME_IDX(%rdi), %rax
    cmp ME_IDX(%rsi), %rax
    jb 1f
    ja 2f
    xor %eax, %eax
    ret
1:  mov $-1, %eax
    ret
2:  mov $1, %eax
    ret
ENDF me_cmp_int

/* radix_entries(entries rdi, n rsi) -> rax sorted entries (the input
 * array or a new one): stable LSD radix sort of ME entries
 * by their signed 64-bit key (8 passes of 8 bits; passes in which every
 * key has the same digit are skipped).  The entries are in index order, so
 * the result is ordered by (key, index). */
FUNC radix_entries
    ENTER 2048 + 32
    mov %rdi, %rbx                  /* source */
    mov %rsi, %r12                  /* n */
    mov %r12, %rdi
    shl $4, %rdi
    call tmp_alloc
    mov %rax, %r13                  /* destination */
    xor %r14d, %r14d                /* shift */
1:  cmp $64, %r14
    jae 8f
    lea 32(%rsp), %rdi              /* histogram: 256 counters */
    xor %eax, %eax
    mov $256, %ecx
    rep stosq
    mov %r14, %rcx
    mov $0x8000000000000000, %r8    /* signed order */
    xor %edx, %edx
2:  cmp %r12, %rdx
    jae 3f
    mov %rdx, %rax
    shl $4, %rax
    mov ME_KEY(%rbx, %rax), %rax
    xor %r8, %rax
    shr %cl, %rax
    movzbl %al, %eax
    incq 32(%rsp, %rax, 8)
    inc %rdx
    jmp 2b
3:  xor %eax, %eax                  /* one digit only: skip the pass */
    xor %edx, %edx                  /* prefix sums */
4:  cmp $256, %eax
    jae 5f
    mov 32(%rsp, %rax, 8), %r9
    cmp %r12, %r9
    je 7f
    mov %rdx, 32(%rsp, %rax, 8)
    add %r9, %rdx
    inc %eax
    jmp 4b
5:  xor %edx, %edx                  /* scatter */
6:  cmp %r12, %rdx
    jae 61f
    mov %rdx, %rax
    shl $4, %rax
    mov ME_KEY(%rbx, %rax), %r10
    mov ME_IDX(%rbx, %rax), %r11
    mov %r10, %rax
    xor %r8, %rax
    shr %cl, %rax
    movzbl %al, %eax
    mov 32(%rsp, %rax, 8), %r9
    incq 32(%rsp, %rax, 8)
    shl $4, %r9
    mov %r10, ME_KEY(%r13, %r9)
    mov %r11, ME_IDX(%r13, %r9)
    inc %rdx
    jmp 6b
61: xchg %rbx, %r13
7:  add $8, %r14
    jmp 1b
8:  mov %rbx, %rax                  /* the array holding the result */
    LEAVE
ENDF radix_entries

/* join_entries(xs rdi, ts rsi, key expr rdx) -> rax sorted ME entries,
 * rdx count (tuples whose key is NULL are left out) */
FUNC join_entries
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov TS_N(%r12), %rdi
    shl $4, %rdi
    add $16, %rdi
    call tmp_alloc
    mov %rax, %r14                  /* entries */
    xor %r15d, %r15d                /* count */
    movq $0, 0(%rsp)                /* tuple index */
    mov %rbx, %rdi                  /* batch modes: vector key evaluation */
    call pexec_enabled
    test %eax, %eax
    jz 1f
    mov %rbx, %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    mov %r14, %rcx
    call pexec_join_keys
    mov %rax, %r15
    jmp 4f
1:  mov 0(%rsp), %rcx
    cmp TS_N(%r12), %rcx
    jae 4f
    test $1023, %rcx
    jnz 2f
    call check_deadline
    mov 0(%rsp), %rcx
2:  imul XS_W(%rbx), %rcx
    shl $3, %rcx
    add TS_DATA(%r12), %rcx
    mov %rcx, XS_CTX+EC_TUPLE(%rbx)
    mov %r13, %rdi
    lea XS_CTX(%rbx), %rsi
    call eval
    test %edx, %edx
    jnz 3f
    mov %r15, %rcx
    shl $4, %rcx
    mov %rax, ME_KEY(%r14, %rcx)
    mov 0(%rsp), %rax
    mov %rax, ME_IDX(%r14, %rcx)
    inc %r15
3:  incq 0(%rsp)
    jmp 1b
4:  cmp $1, %r15
    jbe 5f
    mov N_TYPE(%r13), %eax
    mov %rax, 8(%rsp)
    mov %r14, %rdi
    mov %r15, %rsi
    mov $ME_SIZE, %edx
    lea me_cmp(%rip), %rcx
    movzbl %al, %eax
    cmp $T_FLOAT, %eax
    je 41f
    cmp $T_STR, %eax
    je 41f
    call radix_entries              /* integer-like keys: radix sort */
    mov %rax, %r14
    jmp 5f
41: lea 8(%rsp), %r8
    call qsort_r
5:  mov %r14, %rax
    mov %r15, %rdx
    LEAVE
ENDF join_entries

/* exec_merge_join(xs rdi, fp rsi, L rdx, R rcx, out r8) */
FUNC exec_merge_join
    ENTER 112
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %r8, %r13
    mov %rdx, 0(%rsp)               /* L */
    mov %rcx, 8(%rsp)               /* R */
    mov %rbx, %rdi
    mov 0(%rsp), %rsi
    mov FP_LKEY(%r12), %rdx
    call join_entries
    mov %rax, 16(%rsp)              /* left entries */
    mov %rdx, 24(%rsp)
    mov %rbx, %rdi
    mov 8(%rsp), %rsi
    mov FP_RKEY(%r12), %rdx
    call join_entries
    mov %rax, 32(%rsp)              /* right entries */
    mov %rdx, 40(%rsp)
    /* ranges[left tuple] = [lo, hi) of right entries with an equal key */
    mov 0(%rsp), %rax
    mov TS_N(%rax), %rdi
    shl $4, %rdi
    add $16, %rdi
    call tmp_zalloc
    mov %rax, 48(%rsp)
    mov FP_LKEY(%r12), %rax
    mov N_TYPE(%rax), %eax
    mov %rax, 56(%rsp)              /* key type */
    movq $0, 88(%rsp)               /* 1: ON is just the key equality */
    mov FP_ON(%r12), %rax
    cmpl $EK_BINARY, N_KIND(%rax)
    jne 9f
    cmpl $B_EQ, N_OP(%rax)
    jne 9f
    mov N_A(%rax), %rcx
    mov N_B(%rax), %rdx
    cmp FP_LKEY(%r12), %rcx
    jne 8f
    cmp FP_RKEY(%r12), %rdx
    jne 9f
    movq $1, 88(%rsp)
    jmp 9f
8:  cmp FP_RKEY(%r12), %rcx
    jne 9f
    cmp FP_LKEY(%r12), %rdx
    jne 9f
    movq $1, 88(%rsp)
9:
    xor %r14d, %r14d                /* left position */
    xor %r15d, %r15d                /* right position */
10: cmp 24(%rsp), %r14
    jae 20f
    cmp 40(%rsp), %r15
    jae 20f
    mov 56(%rsp), %rdi
    mov %r14, %rax
    shl $4, %rax
    add 16(%rsp), %rax
    mov ME_KEY(%rax), %rsi
    mov %r15, %rax
    shl $4, %rax
    add 32(%rsp), %rax
    mov ME_KEY(%rax), %rdx
    call value_cmp
    test %eax, %eax
    jz 12f
    js 11f
    inc %r15                        /* left key > right key */
    jmp 10b
11: inc %r14                        /* left key < right key */
    jmp 10b
12: /* equal keys: the right run [r15, hi) */
    mov %r15, 64(%rsp)
13: inc %r15
    cmp 40(%rsp), %r15
    jae 14f
    mov 56(%rsp), %rdi
    mov 64(%rsp), %rax
    shl $4, %rax
    add 32(%rsp), %rax
    mov ME_KEY(%rax), %rsi
    mov %r15, %rax
    shl $4, %rax
    add 32(%rsp), %rax
    mov ME_KEY(%rax), %rdx
    call value_cmp
    test %eax, %eax
    jz 13b
14: /* every left entry of the run gets the range */
    mov %r14, %rax
    shl $4, %rax
    add 16(%rsp), %rax
    mov ME_KEY(%rax), %rax
    mov %rax, 72(%rsp)              /* run key */
15: mov %r14, %rax
    shl $4, %rax
    add 16(%rsp), %rax
    mov ME_IDX(%rax), %rcx
    shl $4, %rcx
    add 48(%rsp), %rcx
    mov 64(%rsp), %rdx
    mov %rdx, 0(%rcx)
    mov %r15, 8(%rcx)
    inc %r14
    cmp 24(%rsp), %r14
    jae 20f
    mov 56(%rsp), %rdi
    mov 72(%rsp), %rsi
    mov %r14, %rax
    shl $4, %rax
    add 16(%rsp), %rax
    mov ME_KEY(%rax), %rdx
    call value_cmp
    test %eax, %eax
    jz 15b
    jmp 10b

20: /* emit in left input order */
    xor %r14d, %r14d                /* left tuple */
21: mov 0(%rsp), %rax
    cmp TS_N(%rax), %r14
    jae 90f
    test $1023, %r14
    jnz 22f
    call check_deadline
22: movq $0, 80(%rsp)               /* matched */
    mov %r14, %rax
    shl $4, %rax
    add 48(%rsp), %rax
    mov 0(%rax), %r15               /* range position */
    mov 8(%rax), %rax
    mov %rax, 64(%rsp)              /* range end */
23: cmp 64(%rsp), %r15
    jae 28f
    mov %r13, %rdi
    call ts_slot
    mov %rax, 72(%rsp)
    mov %rax, %rdi
    mov XS_W(%rbx), %r8
    mov 0(%rsp), %rax
    mov %r14, %rsi
    imul %r8, %rsi
    shl $3, %rsi
    add TS_DATA(%rax), %rsi
    mov %r15, %rax
    shl $4, %rax
    add 32(%rsp), %rax
    mov ME_IDX(%rax), %rdx
    imul %r8, %rdx
    shl $3, %rdx
    mov 8(%rsp), %rax
    add TS_DATA(%rax), %rdx
    mov %r12, %rcx
    call tuple_combine
    cmpq $0, 88(%rsp)
    jne 25f                         /* keys equal: ON holds */
    mov 72(%rsp), %rax
    mov %rax, XS_CTX+EC_TUPLE(%rbx)
    mov FP_ON(%r12), %rdi
    lea XS_CTX(%rbx), %rsi
    call eval
    test %edx, %edx
    jnz 24f
    test $1, %eax
    jnz 25f
24: decq TS_N(%r13)                 /* drop the candidate */
    jmp 26f
25: movq $1, 80(%rsp)
    mov %r13, %rdi
    call check_join_rows
26: inc %r15
    jmp 23b
28: cmpq $JT_LEFT, FP_JTYPE(%r12)
    jne 29f
    cmpq $0, 80(%rsp)
    jne 29f
    mov %r13, %rdi                  /* NULL-padded left tuple */
    call ts_slot
    mov %rax, %rdi
    mov XS_W(%rbx), %r8
    mov 0(%rsp), %rax
    mov %r14, %rsi
    imul %r8, %rsi
    shl $3, %rsi
    add TS_DATA(%rax), %rsi
    xor %edx, %edx
    mov %r12, %rcx
    call tuple_combine
    mov %r13, %rdi
    call check_join_rows
29: inc %r14
    jmp 21b
90: LEAVE
ENDF exec_merge_join
