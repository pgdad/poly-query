/*
 * vec.S - vectorized execution (mode "vectorized"): expressions are
 * evaluated a batch (up to VB tuples) at a time into column vectors.
 *
 * A vector is VB u64 values followed by VB NULL bytes (1 = NULL).  Vectors
 * live on a per-thread scratch stack (vs_*) that every kernel releases when
 * its batch is done; values that must outlive the batch (strings produced by
 * functions) are allocated in the request / worker arena as usual.
 *
 *   veval(node rdi, batch rsi, active rdx) -> rax vector
 *
 * `active` is 0 (all rows) or a byte mask (1 = the row engine would
 * evaluate this expression for the row).  Expressions are only *required*
 * to be correct on active rows, and anything that can raise an error
 * (overflow, division by zero, casts, functions) is only computed on active
 * rows: the right operand of AND / OR is active only where the left one did
 * not decide the result, and the right operand of every other binary
 * operator only where the left one is not NULL - exactly the evaluation
 * order of eval() - so every mode raises the same errors.
 *
 * Fast paths: column references (gathers from both physical layouts,
 * dictionary decoding), literals, constant subtrees (evaluated once per
 * batch), comparisons (AVX2 for 64-bit integer types), integer / float /
 * decimal arithmetic, AND / OR / NOT, IS [NOT] NULL and CAST.  Other nodes
 * (functions, CASE, LIKE, IN, subqueries, ...) are evaluated tuple by tuple
 * with eval() on the active rows.
 *
 * Kernels (called by pexec.S through its k_* dispatchers):
 *   vk_filter, vk_project, vk_group_keys, vk_agg_single, vk_agg_groups
 */
#include "pq.inc"
#include "sql.inc"
#include "exec.inc"

    .section .note.GNU-stack, "", @progbits

#define VS_BYTES (8 * 1024 * 1024)  /* scratch stack per thread */

/* batch */
#define BT_CTX  0                   /* worker EvalCtx* */
#define BT_TUP  8                   /* tuples */
#define BT_N    16
#define BT_TW   24                  /* tuple bytes */
#define BT_SIZE 32

    .section .tbss, "awT", @nobits
    .p2align 3
t_vs_raw: .zero 8
t_vs_cur: .zero 8
t_vs_end: .zero 8

    .section .rodata
    .p2align 5
ones_b: .fill 32, 1, 1

    .text

/* vbin_wide(node rdi) -> eax 1 if the binary node or an operand has a wide
 * DECIMAL type (evaluated tuple by tuple with eval) */
FUNC vbin_wide
    push %rbx
    mov %rdi, %rbx
    mov N_TYPE(%rbx), %edi
    call dec_is_wide
    test %eax, %eax
    jnz 9f
    mov N_A(%rbx), %rdi
    mov N_TYPE(%rdi), %edi
    call dec_is_wide
    test %eax, %eax
    jnz 9f
    mov N_B(%rbx), %rdi
    mov N_TYPE(%rdi), %edi
    call dec_is_wide
9:  pop %rbx
    ret
ENDF vbin_wide

/* ================================================================ scratch */

/* vs_mark() -> rax current top (initialises the stack on first use) */
FUNC vs_mark
    mov %fs:t_vs_cur@tpoff, %rax
    test %rax, %rax
    jz 1f
    ret
1:  sub $8, %rsp
    mov $VS_BYTES + 64, %edi
    call xmalloc
    mov %rax, %fs:t_vs_raw@tpoff
    add $63, %rax
    and $-64, %rax
    mov %rax, %fs:t_vs_cur@tpoff
    lea VS_BYTES(%rax), %rcx
    mov %rcx, %fs:t_vs_end@tpoff
    add $8, %rsp
    ret
ENDF vs_mark

/* vs_release(mark rdi) */
FUNC vs_release
    mov %rdi, %fs:t_vs_cur@tpoff
    ret
ENDF vs_release

/* vs_alloc(size rdi) -> rax 64-byte aligned scratch (arena when full) */
FUNC vs_alloc
    add $63, %rdi
    and $-64, %rdi
    mov %fs:t_vs_cur@tpoff, %rax
    test %rax, %rax
    jz 2f
    lea (%rax, %rdi), %rcx
    cmp %fs:t_vs_end@tpoff, %rcx
    ja 3f
    mov %rcx, %fs:t_vs_cur@tpoff
    ret
2:  push %rdi
    call vs_mark
    pop %rdi
    jmp vs_alloc
3:  jmp tmp_alloc
ENDF vs_alloc

/* vs_thread_exit(): frees the calling worker thread's scratch stack */
FUNC vs_thread_exit
    sub $8, %rsp
    mov %fs:t_vs_raw@tpoff, %rdi
    call free
    movq $0, %fs:t_vs_raw@tpoff
    movq $0, %fs:t_vs_cur@tpoff
    movq $0, %fs:t_vs_end@tpoff
    add $8, %rsp
    ret
ENDF vs_thread_exit

/* vnew() -> rax a vector */
FUNC vnew
    mov $VSIZE, %edi
    jmp vs_alloc
ENDF vnew

/* vbytes() -> rax a VB-byte mask */
FUNC vbytes
    mov $VB, %edi
    jmp vs_alloc
ENDF vbytes

/* vskip(dst rdi, active rsi|0, n1 rdx, n2 rcx|0, n r8):
 * dst[i] = !active[i] | n1[i] | n2[i]  (AVX2, 32 rows per step) */
FUNC vskip
    vmovdqa ones_b(%rip), %ymm6
    xor %eax, %eax
1:  cmp %r8, %rax
    jae 9f
    vmovdqu (%rdx, %rax), %ymm0
    test %rcx, %rcx
    jz 2f
    vpor (%rcx, %rax), %ymm0, %ymm0
2:  test %rsi, %rsi
    jz 3f
    vpxor (%rsi, %rax), %ymm6, %ymm1
    vpor %ymm1, %ymm0, %ymm0
3:  vmovdqu %ymm0, (%rdi, %rax)
    add $32, %rax
    jmp 1b
9:  vzeroupper
    ret
ENDF vskip

/* vnot(dst rdi, src rsi, n rdx): dst[i] = src[i] ^ 1 */
FUNC vnot
    vmovdqa ones_b(%rip), %ymm6
    xor %eax, %eax
1:  cmp %rdx, %rax
    jae 9f
    vpxor (%rsi, %rax), %ymm6, %ymm0
    vmovdqu %ymm0, (%rdi, %rax)
    add $32, %rax
    jmp 1b
9:  vzeroupper
    ret
ENDF vnot

/* ================================================================ analysis */

/* expr_batch_const(node rdi) -> eax 1 if the value does not depend on the
 * tuple: no column / outer / aggregate references, no subqueries and no
 * PQ_SLEEP (which must run once per row) */
FUNC expr_batch_const
    ENTER 0
    mov $1, %eax
    test %rdi, %rdi
    jz 9f
    mov %rdi, %rbx
    mov N_KIND(%rbx), %ecx
    xor %eax, %eax
    cmp $EK_COL, %ecx
    je 9f
    cmp $EK_OUTER, %ecx
    je 9f
    cmp $EK_AGG, %ecx
    je 9f
    cmp $EK_SUBQ, %ecx
    je 9f
    cmp $EK_INSUBQ, %ecx
    je 9f
    cmp $EK_EXISTS, %ecx
    je 9f
    cmp $EK_FUNC, %ecx
    jne 1f
    cmpl $F_PQ_SLEEP, N_OP(%rbx)
    je 9f
1:  mov %rbx, %rdi
    call expr_nchild
    mov %rax, %r12
    xor %r13d, %r13d
2:  cmp %r12, %r13
    jae 8f
    mov %rbx, %rdi
    mov %r13, %rsi
    call expr_child_ptr
    mov (%rax), %rdi
    call expr_batch_const
    test %eax, %eax
    jz 9f
    inc %r13
    jmp 2b
8:  mov $1, %eax
9:  LEAVE
ENDF expr_batch_const

/* ================================================================ veval */

FUNC veval
    ENTER 96
    mov %rdi, %rbx                  /* node */
    mov %rsi, %r12                  /* batch */
    mov %rdx, %r13                  /* active mask or 0 */
    mov N_KIND(%rbx), %eax
    cmp $EK_COL, %eax
    je v_col
    cmp $EK_LIT, %eax
    je v_lit
    mov %rbx, %rdi
    call expr_batch_const
    test %eax, %eax
    jnz v_const
    mov N_KIND(%rbx), %eax
    cmp $EK_BINARY, %eax
    je v_binary
    cmp $EK_UNARY, %eax
    je v_unary
    cmp $EK_ISNULL, %eax
    je v_isnull
    cmp $EK_CAST, %eax
    je v_cast
    jmp v_fallback

v_done:                             /* result vector in r15 */
    mov %r15, %rax
    LEAVE

/* ---------------------------------------------------------------- literal */
v_lit:
    call vnew
    mov %rax, %r15
    mov %rax, %rdi
    mov N_V1(%rbx), %rax
    mov BT_N(%r12), %rcx
    rep stosq
    lea VNULL(%r15), %rdi
    mov N_FLAGS(%rbx), %esi
    and $NF_NULL, %esi
    mov BT_N(%r12), %rdx
    call memset
    jmp v_done

/* ---------------------------------------------------------------- constant:
 * evaluated once if any row is active (the row engine would evaluate it
 * for that row and raise the same error, if any) */
v_const:
    call vnew
    mov %rax, %r15
    test %r13, %r13
    jz 1f
    mov %r13, %rdi
    mov $1, %esi
    mov BT_N(%r12), %rdx
    call memchr
    test %rax, %rax
    jnz 1f
    lea VNULL(%r15), %rdi           /* no active row */
    mov $1, %esi
    mov BT_N(%r12), %rdx
    call memset
    jmp v_done
1:  mov %rbx, %rdi
    mov BT_CTX(%r12), %rsi
    call eval
    mov %rdx, 0(%rsp)
    mov %r15, %rdi
    mov BT_N(%r12), %rcx
    rep stosq
    lea VNULL(%r15), %rdi
    mov 0(%rsp), %esi
    mov BT_N(%r12), %rdx
    call memset
    jmp v_done

/* ---------------------------------------------------------------- column */
v_col:
    call vnew
    mov %rax, %r15
    mov N_V2(%rbx), %rcx            /* range variable */
    mov BT_CTX(%r12), %rax
    mov EC_TABLES(%rax), %rax
    mov (%rax, %rcx, 8), %rax
    mov TB_COLS(%rax), %rdi
    mov N_V1(%rbx), %rax
    shl $COL_SHIFT, %rax
    add %rax, %rdi                  /* Column* */
    mov %rdi, 0(%rsp)
    cmpb $0, COL_LAZY(%rdi)
    je 1f
    call pqcf_load_col              /* first access (serial execution only) */
1:  mov 0(%rsp), %r14               /* Column* */
    mov BT_TUP(%r12), %rsi
    mov N_V2(%rbx), %rcx
    lea (%rsi, %rcx, 8), %rsi       /* &tuple[0][rv] */
    mov BT_TW(%r12), %r9            /* tuple stride */
    mov COL_DATA(%r14), %r8
    mov COL_STRIDE(%r14), %r10
    mov COL_DICT(%r14), %r11
    mov BT_N(%r12), %rdx
    xor %ecx, %ecx                  /* i */
    cmpq $0, COL_NULLS(%r14)
    jne 20f
    test %r11, %r11
    jnz 10f
    /* plain values, no NULL bitmap */
2:  cmp %rdx, %rcx
    jae 30f
    mov (%rsi), %rax                /* row */
    add %r9, %rsi
    cmp $-1, %rax
    je 3f
    imul %r10, %rax
    mov (%r8, %rax), %rax
    mov %rax, (%r15, %rcx, 8)
    movb $0, VNULL(%r15, %rcx)
    inc %rcx
    jmp 2b
3:  movq $0, (%r15, %rcx, 8)
    movb $1, VNULL(%r15, %rcx)
    inc %rcx
    jmp 2b
10: /* dictionary codes, no NULL bitmap */
    cmp %rdx, %rcx
    jae 30f
    mov (%rsi), %rax
    add %r9, %rsi
    cmp $-1, %rax
    je 11f
    imul %r10, %rax
    mov (%r8, %rax), %eax
    mov (%r11, %rax, 8), %rax
    mov %rax, (%r15, %rcx, 8)
    movb $0, VNULL(%r15, %rcx)
    inc %rcx
    jmp 10b
11: movq $0, (%r15, %rcx, 8)
    movb $1, VNULL(%r15, %rcx)
    inc %rcx
    jmp 10b
20: /* NULL bitmap (and maybe a dictionary) */
    mov COL_NSTRIDE(%r14), %r13     /* (node and mask are no longer needed) */
    mov COL_NBIT(%r14), %rbx
    mov COL_NULLS(%r14), %rdi
21: cmp %rdx, %rcx
    jae 30f
    mov (%rsi), %rax                /* row */
    add %r9, %rsi
    cmp $-1, %rax
    je 24f
    push %rax
    imul %r13, %rax                 /* NULL bit: row * nstride + nbit */
    add %rbx, %rax
    bt %rax, (%rdi)
    pop %rax
    jc 24f
    imul %r10, %rax
    test %r11, %r11
    jnz 22f
    mov (%r8, %rax), %rax
    jmp 23f
22: mov (%r8, %rax), %eax
    mov (%r11, %rax, 8), %rax
23: mov %rax, (%r15, %rcx, 8)
    movb $0, VNULL(%r15, %rcx)
    inc %rcx
    jmp 21b
24: movq $0, (%r15, %rcx, 8)
    movb $1, VNULL(%r15, %rcx)
    inc %rcx
    jmp 21b
30: jmp v_done

/* ---------------------------------------------------------------- fallback:
 * eval() tuple by tuple on the active rows */
v_fallback:
    call vnew
    mov %rax, %r15
    mov BT_CTX(%r12), %rax
    mov EC_TUPLE(%rax), %rax
    mov %rax, 0(%rsp)               /* saved ctx tuple */
    xor %r14d, %r14d
1:  cmp BT_N(%r12), %r14
    jae 9f
    test %r13, %r13
    jz 2f
    cmpb $0, (%r13, %r14)
    jne 2f
    movq $0, (%r15, %r14, 8)
    movb $1, VNULL(%r15, %r14)
    jmp 3f
2:  mov %r14, %rax
    imul BT_TW(%r12), %rax
    add BT_TUP(%r12), %rax
    mov BT_CTX(%r12), %rsi
    mov %rax, EC_TUPLE(%rsi)
    mov %rbx, %rdi
    call eval
    mov %rax, (%r15, %r14, 8)
    mov %dl, VNULL(%r15, %r14)
3:  inc %r14
    jmp 1b
9:  mov BT_CTX(%r12), %rsi
    mov 0(%rsp), %rax
    mov %rax, EC_TUPLE(%rsi)
    jmp v_done

/* ---------------------------------------------------------------- IS NULL */
v_isnull:
    mov N_A(%rbx), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call veval
    mov %rax, %r14
    call vnew
    mov %rax, %r15
    mov N_OP(%rbx), %edx
    and $1, %edx
    xor %ecx, %ecx
1:  cmp BT_N(%r12), %rcx
    jae 2f
    movzbl VNULL(%r14, %rcx), %eax
    xor %edx, %eax
    mov %rax, (%r15, %rcx, 8)
    movb $0, VNULL(%r15, %rcx)
    inc %rcx
    jmp 1b
2:  jmp v_done

/* ---------------------------------------------------------------- unary */
v_unary:
    mov N_TYPE(%rbx), %edi          /* -wide: tuple at a time */
    call dec_is_wide
    test %eax, %eax
    jnz v_fallback
    mov N_A(%rbx), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call veval
    mov %rax, %r14                  /* operand */
    mov N_OP(%rbx), %eax
    cmp $U_POS, %eax
    jne 1f
    mov %r14, %r15
    jmp v_done
1:  call vnew
    mov %rax, %r15
    lea VNULL(%r15), %rdi           /* NULL = operand NULL or inactive */
    mov %r13, %rsi
    lea VNULL(%r14), %rdx
    xor %ecx, %ecx
    mov BT_N(%r12), %r8
    call vskip
    mov BT_N(%r12), %rdx
    xor %ecx, %ecx
    cmpl $U_NOT, N_OP(%rbx)
    jne 3f
2:  cmp %rdx, %rcx                  /* NOT */
    jae 9f
    mov (%r14, %rcx, 8), %rax
    xor $1, %rax
    mov %rax, (%r15, %rcx, 8)
    inc %rcx
    jmp 2b
3:  movzbl N_TYPE(%rbx), %eax
    cmp $T_FLOAT, %eax
    jne 5f
4:  cmp %rdx, %rcx                  /* -FLOAT */
    jae 9f
    mov (%r14, %rcx, 8), %rax
    btc $63, %rax
    mov %rax, (%r15, %rcx, 8)
    inc %rcx
    jmp 4b
5:  cmp %rdx, %rcx                  /* -INT / -DECIMAL: overflow on MIN */
    jae 9f
    cmpb $0, VNULL(%r15, %rcx)
    jne 6f
    mov (%r14, %rcx, 8), %rax
    neg %rax
    jo 7f
    mov %rax, (%r15, %rcx, 8)
6:  inc %rcx
    jmp 5b
7:  call raise_overflow
9:  jmp v_done

/* ---------------------------------------------------------------- CAST */
v_cast:
    mov N_A(%rbx), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call veval
    mov %rax, %r14
    call vnew
    mov %rax, %r15
    lea VNULL(%r15), %rdi
    mov %r13, %rsi
    lea VNULL(%r14), %rdx
    xor %ecx, %ecx
    mov BT_N(%r12), %r8
    call vskip
    xor %r13d, %r13d                /* i */
1:  cmp BT_N(%r12), %r13
    jae 9f
    cmpb $0, VNULL(%r15, %r13)
    jne 2f
    mov N_A(%rbx), %rdi
    mov N_TYPE(%rdi), %edi
    mov N_V1(%rbx), %rsi
    mov (%r14, %r13, 8), %rdx
    call cast_value
    mov %rax, (%r15, %r13, 8)
2:  inc %r13
    jmp 1b
9:  jmp v_done

/* ---------------------------------------------------------------- binary */
v_binary:
    mov N_OP(%rbx), %eax
    cmp $B_AND, %eax
    je v_logic
    cmp $B_OR, %eax
    je v_logic
    cmp $B_CONCAT, %eax
    je v_fallback
    mov %rbx, %rdi                  /* wide DECIMALs: tuple at a time */
    call vbin_wide
    test %eax, %eax
    jnz v_fallback
    mov N_OP(%rbx), %eax
    cmp $B_EQ, %eax
    jae 1f
    movzbl N_TYPE(%rbx), %ecx       /* arithmetic: INT, FLOAT, DECIMAL (+ - *) */
    cmp $T_INT, %ecx
    je 1f
    cmp $T_FLOAT, %ecx
    je 1f
    cmp $T_DEC, %ecx
    jne v_fallback
    cmp $B_MUL, %eax
    ja v_fallback
1:  /* left operand on the active rows, right one where the left is not NULL */
    mov N_A(%rbx), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call veval
    mov %rax, 0(%rsp)               /* a */
    call vbytes
    mov %rax, 16(%rsp)              /* active for b */
    mov %rax, %rdi
    mov %r13, %rsi
    mov 0(%rsp), %rdx
    add $VNULL, %rdx
    xor %ecx, %ecx
    mov BT_N(%r12), %r8
    call vskip
    mov 16(%rsp), %rdi
    mov %rdi, %rsi
    mov BT_N(%r12), %rdx
    call vnot
    mov N_B(%rbx), %rdi
    mov %r12, %rsi
    mov 16(%rsp), %rdx
    call veval
    mov %rax, 8(%rsp)               /* b */
    call vnew
    mov %rax, %r15
    lea VNULL(%r15), %rdi           /* result NULL = skipped */
    mov 16(%rsp), %rsi
    mov 8(%rsp), %rdx
    add $VNULL, %rdx
    xor %ecx, %ecx
    mov BT_N(%r12), %r8
    call vskip
    mov 0(%rsp), %r13               /* a */
    mov 8(%rsp), %r14               /* b */
    mov N_OP(%rbx), %eax
    cmp $B_EQ, %eax
    jae v_compare
    movzbl N_TYPE(%rbx), %ecx
    cmp $T_INT, %ecx
    je v_iarith
    cmp $T_FLOAT, %ecx
    je v_farith
    jmp v_darith

/* comparisons: per-row -1/0/1 in the result, then mapped by the operator */
v_compare:
    mov N_A(%rbx), %rax
    mov N_TYPE(%rax), %eax
    movzbl %al, %ecx
    mov N_B(%rbx), %rdx             /* INT64 vs DECIMAL: dec_cmp (exact) */
    movzbl N_TYPE(%rdx), %edx
    cmp %ecx, %edx
    je 0f
    cmp $T_DEC, %ecx
    je 40f
    cmp $T_DEC, %edx
    je 40f
0:  cmp $T_FLOAT, %ecx
    je 20f
    cmp $T_STR, %ecx
    je 30f
    cmp $T_DEC, %ecx
    jne 1f
    mov N_B(%rbx), %rdx             /* DECIMAL: same scale compares as integers */
    mov N_TYPE(%rdx), %edx
    xor %eax, %edx
    test $0xff0000, %edx
    jnz 40f
1:  /* 64-bit signed integers: AVX2, 4 rows per step */
    mov N_OP(%rbx), %eax
    mov BT_N(%r12), %rdx
    xor %ecx, %ecx
    vpcmpeqq %ymm7, %ymm7, %ymm7    /* all ones */
2:  cmp %rdx, %rcx
    jae 8f
    vmovdqu (%r13, %rcx, 8), %ymm0  /* a */
    vmovdqu (%r14, %rcx, 8), %ymm1  /* b */
    cmp $B_EQ, %eax
    jne 3f
    vpcmpeqq %ymm1, %ymm0, %ymm2
    jmp 7f
3:  cmp $B_NE, %eax
    jne 4f
    vpcmpeqq %ymm1, %ymm0, %ymm2
    vpxor %ymm7, %ymm2, %ymm2
    jmp 7f
4:  cmp $B_LT, %eax
    jne 5f
    vpcmpgtq %ymm0, %ymm1, %ymm2    /* b > a */
    jmp 7f
5:  cmp $B_LE, %eax
    jne 6f
    vpcmpgtq %ymm1, %ymm0, %ymm2    /* !(a > b) */
    vpxor %ymm7, %ymm2, %ymm2
    jmp 7f
6:  cmp $B_GT, %eax
    jne 61f
    vpcmpgtq %ymm1, %ymm0, %ymm2    /* a > b */
    jmp 7f
61: vpcmpgtq %ymm0, %ymm1, %ymm2    /* GE: !(b > a) */
    vpxor %ymm7, %ymm2, %ymm2
7:  vpsrlq $63, %ymm2, %ymm2
    vmovdqu %ymm2, (%r15, %rcx, 8)
    add $4, %rcx
    jmp 2b
8:  vzeroupper
    jmp v_done

20: /* FLOAT64 (value_cmp semantics) */
    xor %ecx, %ecx
21: cmp BT_N(%r12), %rcx
    jae 50f
    movsd (%r13, %rcx, 8), %xmm0
    ucomisd (%r14, %rcx, 8), %xmm0
    mov $0, %eax
    je 22f
    mov $-1, %eax
    jb 22f
    mov $1, %eax
22: movslq %eax, %rax
    mov %rax, (%r15, %rcx, 8)
    inc %rcx
    jmp 21b

30: /* STRING */
    xor %r13d, %r13d
    mov 0(%rsp), %r14
31: cmp BT_N(%r12), %r13
    jae 50f
    cmpb $0, VNULL(%r15, %r13)
    jne 32f
    mov (%r14, %r13, 8), %rdi
    mov 8(%rsp), %rsi
    mov (%rsi, %r13, 8), %rsi
    call pstr_cmp
    movslq %eax, %rax
    mov %rax, (%r15, %r13, 8)
32: inc %r13
    jmp 31b

40: /* DECIMAL with different scales */
    xor %r13d, %r13d
    mov 0(%rsp), %r14
41: cmp BT_N(%r12), %r13
    jae 50f
    cmpb $0, VNULL(%r15, %r13)
    jne 42f
    mov N_A(%rbx), %rax
    mov N_TYPE(%rax), %esi
    shr $16, %esi
    and $0xff, %esi
    mov N_B(%rbx), %rax
    mov N_TYPE(%rax), %ecx
    shr $16, %ecx
    and $0xff, %ecx
    mov (%r14, %r13, 8), %rdi
    mov 8(%rsp), %rdx
    mov (%rdx, %r13, 8), %rdx
    call dec_cmp
    movslq %eax, %rax
    mov %rax, (%r15, %r13, 8)
42: inc %r13
    jmp 41b

50: /* map -1/0/1 to the operator's truth value */
    mov N_OP(%rbx), %esi
    xor %ecx, %ecx
51: cmp BT_N(%r12), %rcx
    jae 59f
    mov (%r15, %rcx, 8), %rax
    xor %edx, %edx
    cmp $0, %rax
    cmp $B_EQ, %esi
    jne 52f
    test %rax, %rax
    sete %dl
    jmp 58f
52: cmp $B_NE, %esi
    jne 53f
    test %rax, %rax
    setne %dl
    jmp 58f
53: cmp $B_LT, %esi
    jne 54f
    test %rax, %rax
    sets %dl
    jmp 58f
54: cmp $B_LE, %esi
    jne 55f
    cmp $0, %rax
    setle %dl
    jmp 58f
55: cmp $B_GT, %esi
    jne 56f
    cmp $0, %rax
    setg %dl
    jmp 58f
56: test %rax, %rax
    setns %dl
58: mov %rdx, (%r15, %rcx, 8)
    inc %rcx
    jmp 51b
59: jmp v_done

/* INT64 arithmetic (eval's ev_int_arith, per non-skipped row) */
v_iarith:
    mov N_OP(%rbx), %esi
    xor %ecx, %ecx
1:  cmp BT_N(%r12), %rcx
    jae 9f
    cmpb $0, VNULL(%r15, %rcx)
    jne 8f
    mov (%r13, %rcx, 8), %rax
    mov (%r14, %rcx, 8), %rdi
    cmp $B_ADD, %esi
    jne 2f
    add %rdi, %rax
    jo 90f
    jmp 7f
2:  cmp $B_SUB, %esi
    jne 3f
    sub %rdi, %rax
    jo 90f
    jmp 7f
3:  cmp $B_MUL, %esi
    jne 4f
    imul %rdi, %rax
    jo 90f
    jmp 7f
4:  test %rdi, %rdi                 /* / and % */
    jz 91f
    cmp $-1, %rdi
    jne 6f
    cmp $B_MOD, %esi
    jne 5f
    xor %eax, %eax
    jmp 7f
5:  neg %rax
    jo 90f
    jmp 7f
6:  mov %rcx, %r8
    cqo
    idiv %rdi
    mov %r8, %rcx
    cmp $B_MOD, %esi
    jne 7f
    mov %rdx, %rax
7:  mov %rax, (%r15, %rcx, 8)
8:  inc %rcx
    jmp 1b
9:  jmp v_done
90: call raise_overflow
91: call raise_divzero

/* FLOAT64 arithmetic (ev_float_arith) */
v_farith:
    mov N_OP(%rbx), %esi
    xor %ecx, %ecx
    xorpd %xmm2, %xmm2
1:  cmp BT_N(%r12), %rcx
    jae 9f
    cmpb $0, VNULL(%r15, %rcx)
    jne 8f
    movsd (%r13, %rcx, 8), %xmm0
    movsd (%r14, %rcx, 8), %xmm1
    cmp $B_ADD, %esi
    jne 2f
    addsd %xmm1, %xmm0
    jmp 6f
2:  cmp $B_SUB, %esi
    jne 3f
    subsd %xmm1, %xmm0
    jmp 6f
3:  cmp $B_MUL, %esi
    jne 4f
    mulsd %xmm1, %xmm0
    jmp 6f
4:  ucomisd %xmm2, %xmm1
    je 91f
    divsd %xmm1, %xmm0
6:  movq %xmm0, %rax                /* check_finite */
    shr $52, %rax
    and $0x7ff, %eax
    cmp $0x7ff, %eax
    je 90f
    movsd %xmm0, (%r15, %rcx, 8)
8:  inc %rcx
    jmp 1b
9:  jmp v_done
90: call raise_overflow
91: call raise_divzero

/* DECIMAL + - * (ev_dec_arith): operands scaled to the result scale */
v_darith:
    mov N_A(%rbx), %rax
    mov N_TYPE(%rax), %eax
    shr $16, %eax
    and $0xff, %eax                 /* sa */
    mov N_B(%rbx), %rcx
    mov N_TYPE(%rcx), %ecx
    shr $16, %ecx
    and $0xff, %ecx                 /* sb */
    mov N_TYPE(%rbx), %edx
    shr $16, %edx
    and $0xff, %edx                 /* result scale */
    lea pow10_u64(%rip), %rsi
    mov %edx, %edi
    sub %eax, %edi
    mov (%rsi, %rdi, 8), %rdi
    mov %rdi, 24(%rsp)              /* factor a */
    sub %ecx, %edx
    mov (%rsi, %rdx, 8), %rdx
    mov %rdx, 32(%rsp)              /* factor b */
    mov N_OP(%rbx), %esi
    xor %ecx, %ecx
1:  cmp BT_N(%r12), %rcx
    jae 9f
    cmpb $0, VNULL(%r15, %rcx)
    jne 8f
    mov %rcx, 40(%rsp)
    cmp $B_MUL, %esi
    jne 2f
    mov (%r13, %rcx, 8), %rax
    imulq (%r14, %rcx, 8)
    jmp 5f
2:  mov (%r13, %rcx, 8), %rax       /* a * fa */
    imulq 24(%rsp)
    mov %rax, %r8
    mov %rdx, %r9
    mov (%r14, %rcx, 8), %rax       /* b * fb */
    imulq 32(%rsp)
    cmp $B_ADD, %esi
    jne 3f
    add %r8, %rax
    adc %r9, %rdx
    jmp 5f
3:  sub %rax, %r8
    sbb %rdx, %r9
    mov %r8, %rax
    mov %r9, %rdx
5:  call chk_dec128                 /* clobbers rcx */
    mov 40(%rsp), %rcx
    mov %rax, (%r15, %rcx, 8)
8:  inc %rcx
    jmp 1b
9:  jmp v_done

/* AND / OR (Kleene logic, ev_and / ev_or evaluation order) */
v_logic:
    mov N_A(%rbx), %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call veval
    mov %rax, %r14                  /* a */
    call vbytes
    mov %rax, 16(%rsp)              /* rows where b is evaluated */
    mov N_OP(%rbx), %esi            /* decisive a value: FALSE for AND, TRUE for OR */
    xor %edi, %edi
    cmp $B_OR, %esi
    sete %dil
    xor %ecx, %ecx
1:  cmp BT_N(%r12), %rcx
    jae 3f
    mov $1, %eax
    test %r13, %r13
    jz 2f
    movzbl (%r13, %rcx), %eax
2:  xor %edx, %edx                  /* decided = !null && (a & 1) == decisive */
    cmpb $0, VNULL(%r14, %rcx)
    jne 21f
    mov (%r14, %rcx, 8), %r8
    and $1, %r8d
    cmp %edi, %r8d
    sete %dl
21: xor $1, %edx
    and %edx, %eax
    mov 16(%rsp), %r8
    mov %al, (%r8, %rcx)
    inc %rcx
    jmp 1b
3:  mov N_B(%rbx), %rdi
    mov %r12, %rsi
    mov 16(%rsp), %rdx
    call veval
    mov %rax, 8(%rsp)               /* b */
    call vnew
    mov %rax, %r15
    mov 8(%rsp), %r9
    mov N_OP(%rbx), %esi
    xor %edi, %edi
    cmp $B_OR, %esi
    sete %dil                       /* decisive value d */
    xor %ecx, %ecx
4:  cmp BT_N(%r12), %rcx
    jae 9f
    movzbl VNULL(%r14, %rcx), %r10d /* an */
    movzbl VNULL(%r9, %rcx), %r11d  /* bn */
    mov (%r14, %rcx, 8), %rax
    and $1, %eax
    cmp %edi, %eax
    sete %al
    mov %r10d, %edx
    xor $1, %edx
    and %edx, %eax                  /* a decides */
    mov (%r9, %rcx, 8), %rdx
    and $1, %edx
    cmp %edi, %edx
    sete %dl
    mov %r11d, %r8d
    xor $1, %r8d
    and %r8d, %edx                  /* b decides */
    or %edx, %eax                   /* decided -> value d, not NULL */
    jz 5f
    mov %rdi, (%r15, %rcx, 8)
    movb $0, VNULL(%r15, %rcx)
    jmp 6f
5:  or %r11d, %r10d                 /* undecided: NULL if either is NULL */
    mov %r10b, VNULL(%r15, %rcx)
    mov %edi, %eax
    xor $1, %eax
    mov %rax, (%r15, %rcx, 8)
6:  inc %rcx
    jmp 4b
9:  jmp v_done
ENDF veval

/* ================================================================ kernels */

/* vk_filter(ctx rdi, pred rsi, tuples rdx, n rcx, W r8) -> rax kept */
FUNC vk_filter
    ENTER 48
    mov %rdi, 0+BT_CTX(%rsp)
    mov %rdx, 0+BT_TUP(%rsp)
    mov %rcx, 0+BT_N(%rsp)
    shl $3, %r8
    mov %r8, 0+BT_TW(%rsp)
    mov %rsi, %rbx
    call vs_mark
    mov %rax, 32(%rsp)
    mov %rbx, %rdi
    lea 0(%rsp), %rsi
    xor %edx, %edx
    call veval
    mov %rax, %r12                  /* predicate vector */
    mov 0+BT_TUP(%rsp), %r13
    mov 0+BT_TW(%rsp), %r14
    xor %ecx, %ecx                  /* read */
    xor %r15d, %r15d                /* write */
1:  cmp 0+BT_N(%rsp), %rcx
    jae 9f
    cmpb $0, VNULL(%r12, %rcx)
    jne 3f
    testb $1, (%r12, %rcx, 8)
    jz 3f
    cmp %rcx, %r15
    je 2f
    mov %rcx, %rsi
    imul %r14, %rsi
    add %r13, %rsi
    mov %r15, %rdi
    imul %r14, %rdi
    add %r13, %rdi
    mov %rcx, %r8
    mov %r14, %rcx
    shr $3, %rcx
    rep movsq
    mov %r8, %rcx
2:  inc %r15
3:  inc %rcx
    jmp 1b
9:  mov 32(%rsp), %rdi
    call vs_release
    mov %r15, %rax
    LEAVE
ENDF vk_filter

/* vk_project(ctx rdi, plan rsi, tuples rdx, n rcx, W r8, rows Vec* r9) */
FUNC vk_project
    ENTER 80
    mov %rdi, 0+BT_CTX(%rsp)
    mov %rdx, 0+BT_TUP(%rsp)
    mov %rcx, 0+BT_N(%rsp)
    shl $3, %r8
    mov %r8, 0+BT_TW(%rsp)
    mov %rsi, %rbx                  /* plan */
    mov %r9, 32(%rsp)               /* rows */
    mov QP_NOUT(%rbx), %r12
    add QP_NKEYS(%rbx), %r12
    shl $4, %r12                    /* row bytes */
    mov %r12, %rdi
    imul %rcx, %rdi
    add $16, %rdi
    call tmp_alloc
    mov %rax, %r13                  /* row cells of the batch */
    xor %r14d, %r14d                /* output column */
1:  cmp QP_NOUT(%rbx), %r14
    jae 3f
    call vs_mark
    mov %rax, 40(%rsp)
    imul $OC_SIZE, %r14, %rax
    add QP_OUT(%rbx), %rax
    mov OC_EXPR(%rax), %rdi
    lea 0(%rsp), %rsi
    xor %edx, %edx
    call veval
    mov %r14, %rdi
    shl $4, %rdi
    add %r13, %rdi                  /* cell of row 0 */
    xor %ecx, %ecx
2:  cmp 0+BT_N(%rsp), %rcx
    jae 21f
    mov (%rax, %rcx, 8), %rdx
    mov %rdx, VAL_P(%rdi)
    movzbl VNULL(%rax, %rcx), %edx
    mov %rdx, VAL_NULL(%rdi)
    add %r12, %rdi
    inc %rcx
    jmp 2b
21: mov 40(%rsp), %rdi
    call vs_release
    inc %r14
    jmp 1b
3:  xor %r15d, %r15d                /* sort keys */
4:  cmp QP_NKEYS(%rbx), %r15
    jae 7f
    imul $SK_SIZE, %r15, %rax
    add QP_KEYS(%rbx), %rax
    mov QP_NOUT(%rbx), %rdi
    add %r15, %rdi
    shl $4, %rdi
    add %r13, %rdi                  /* key cell of row 0 */
    mov SK_OUT(%rax), %rsi
    cmp $-1, %rsi
    je 5f
    shl $4, %rsi                    /* copy of an output cell */
    add %r13, %rsi
    xor %ecx, %ecx
41: cmp 0+BT_N(%rsp), %rcx
    jae 6f
    mov VAL_P(%rsi), %rdx
    mov %rdx, VAL_P(%rdi)
    mov VAL_NULL(%rsi), %rdx
    mov %rdx, VAL_NULL(%rdi)
    add %r12, %rsi
    add %r12, %rdi
    inc %rcx
    jmp 41b
5:  mov %rdi, 48(%rsp)
    mov SK_EXPR(%rax), %r14
    call vs_mark
    mov %rax, 40(%rsp)
    mov %r14, %rdi
    lea 0(%rsp), %rsi
    xor %edx, %edx
    call veval
    mov 48(%rsp), %rdi
    xor %ecx, %ecx
51: cmp 0+BT_N(%rsp), %rcx
    jae 52f
    mov (%rax, %rcx, 8), %rdx
    mov %rdx, VAL_P(%rdi)
    movzbl VNULL(%rax, %rcx), %edx
    mov %rdx, VAL_NULL(%rdi)
    add %r12, %rdi
    inc %rcx
    jmp 51b
52: mov 40(%rsp), %rdi
    call vs_release
6:  inc %r15
    jmp 4b
7:  xor %r14d, %r14d                /* hand the rows over */
8:  cmp 0+BT_N(%rsp), %r14
    jae 9f
    mov 32(%rsp), %rdi
    mov %r14, %rsi
    imul %r12, %rsi
    add %r13, %rsi
    call vec_push
    inc %r14
    jmp 8b
9:  LEAVE
ENDF vk_project

/* vk_group_keys(ctx rdi, plan rsi, tuples rdx, n rcx, W r8, keys r9) */
FUNC vk_group_keys
    ENTER 64
    mov %rdi, 0+BT_CTX(%rsp)
    mov %rdx, 0+BT_TUP(%rsp)
    mov %rcx, 0+BT_N(%rsp)
    shl $3, %r8
    mov %r8, 0+BT_TW(%rsp)
    mov %rsi, %rbx
    mov %r9, %r13                   /* keys */
    mov QP_NGROUP(%rbx), %r12
    shl $4, %r12                    /* key bytes per tuple */
    xor %r14d, %r14d
1:  cmp QP_NGROUP(%rbx), %r14
    jae 9f
    call vs_mark
    mov %rax, 32(%rsp)
    mov QP_GROUP(%rbx), %rax
    mov (%rax, %r14, 8), %rdi
    lea 0(%rsp), %rsi
    xor %edx, %edx
    call veval
    mov %r14, %rdi
    shl $4, %rdi
    add %r13, %rdi
    xor %ecx, %ecx
2:  cmp 0+BT_N(%rsp), %rcx
    jae 3f
    movzbl VNULL(%rax, %rcx), %edx
    mov %rdx, VAL_NULL(%rdi)
    mov (%rax, %rcx, 8), %rsi
    neg %rdx                        /* NULL cells: payload 0 */
    not %rdx
    and %rdx, %rsi
    mov %rsi, VAL_P(%rdi)
    add %r12, %rdi
    inc %rcx
    jmp 2b
3:  mov 32(%rsp), %rdi
    call vs_release
    inc %r14
    jmp 1b
9:  LEAVE
ENDF vk_group_keys

/* has_distinct(plan rdi) -> eax 1 if an aggregate is DISTINCT
 * (clobbers only rax and r10: the kernels' arguments stay intact) */
FUNC has_distinct
    xor %r10d, %r10d
1:  cmp QP_NAGGS(%rdi), %r10
    jae 8f
    mov QP_AGGS(%rdi), %rax
    mov (%rax, %r10, 8), %rax
    inc %r10
    testl $NF_DISTINCT, N_FLAGS(%rax)
    jz 1b
    mov $1, %eax
    ret
8:  xor %eax, %eax
    ret
ENDF has_distinct

/* vagg_update(agg node rdi, vector rsi, n rdx, states rcx, stride r8,
 * offset r9): feeds the vector's non-NULL values to the aggregate states
 * at states + offset (stride 0: one state for the batch) or at
 * states[i] + offset (stride 8: a state pointer per row, see
 * vk_agg_groups).  The aggregate and type dispatch happens once per batch;
 * COUNT, SUM / AVG and MIN / MAX of integer-like types (and SUM of FLOAT64,
 * in row order) run in specialised loops, MIN / MAX of FLOAT64 and STRING
 * through value_cmp. */
FUNC vagg_update
    ENTER 48
    mov %rdi, %rbx                  /* agg */
    mov %rsi, %r12                  /* vector */
    mov %rdx, %r13                  /* n */
    mov %rcx, %r14                  /* states */
    mov %r9, %r15                   /* offset */
    mov %r8, 0(%rsp)                /* stride */
    mov N_A(%rbx), %rax
    mov N_TYPE(%rax), %eax
    mov %rax, 24(%rsp)              /* argument type */
    movzbl %al, %eax
    mov N_OP(%rbx), %ecx
    cmp $AGG_COUNT, %ecx
    je 10f
    cmp $AGG_MIN, %ecx
    jae 40f
    cmp $T_FLOAT, %eax
    je 30f
    mov 24(%rsp), %edi
    call dec_is_wide
    test %eax, %eax
    jnz 28f
    /* ---- SUM / AVG of INT64 / DECIMAL: 128-bit sums */
    cmpq $0, 0(%rsp)
    jne 25f
    lea (%r14, %r15), %rdi          /* one state: accumulate in registers */
    mov AS_LO(%rdi), %r8
    mov AS_HI(%rdi), %r9
    mov AS_COUNT(%rdi), %r10
    xor %ecx, %ecx
21: cmp %r13, %rcx
    jae 22f
    cmpb $0, VNULL(%r12, %rcx)
    jne 23f
    mov (%r12, %rcx, 8), %rax
    cqo
    add %rax, %r8
    adc %rdx, %r9
    inc %r10
23: inc %rcx
    jmp 21b
22: mov %r8, AS_LO(%rdi)
    mov %r9, AS_HI(%rdi)
    mov %r10, AS_COUNT(%rdi)
    jmp 99f
25: xor %ecx, %ecx                  /* a state per row */
26: cmp %r13, %rcx
    jae 99f
    cmpb $0, VNULL(%r12, %rcx)
    jne 27f
    mov (%r14, %rcx, 8), %rdi
    add %r15, %rdi
    mov (%r12, %rcx, 8), %rax
    cqo
    add %rax, AS_LO(%rdi)
    adc %rdx, AS_HI(%rdi)
    incq AS_COUNT(%rdi)
27: inc %rcx
    jmp 26b

28: /* ---- SUM / AVG of wide DECIMAL: 192-bit sums of the boxed values */
    xor %ecx, %ecx
281: cmp %r13, %rcx
    jae 99f
    cmpb $0, VNULL(%r12, %rcx)
    jne 283f
    mov %r14, %rdi
    cmpq $0, 0(%rsp)
    je 282f
    mov (%r14, %rcx, 8), %rdi
282: add %r15, %rdi                 /* state */
    incq AS_COUNT(%rdi)
    add $AS_LO, %rdi
    mov (%r12, %rcx, 8), %rax
    mov (%rax), %rsi
    mov 8(%rax), %rdx
    mov %rcx, 16(%rsp)
    call sum192_add
    mov 16(%rsp), %rcx
283: inc %rcx
    jmp 281b

10: /* ---- COUNT(x) */
    xor %ecx, %ecx
    xor %r8d, %r8d
11: cmp %r13, %rcx
    jae 13f
    cmpb $0, VNULL(%r12, %rcx)
    jne 12f
    inc %r8
    cmpq $0, 0(%rsp)
    je 12f
    mov (%r14, %rcx, 8), %rdi
    incq AS_COUNT(%rdi, %r15)
12: inc %rcx
    jmp 11b
13: cmpq $0, 0(%rsp)
    jne 99f
    add %r8, AS_COUNT(%r14, %r15)
    jmp 99f

30: /* ---- SUM / AVG of FLOAT64 (in row order) */
    xor %ecx, %ecx
    cmpq $0, 0(%rsp)
    jne 35f
    lea (%r14, %r15), %rdi
    movsd AS_VAL(%rdi), %xmm0
    mov AS_COUNT(%rdi), %r10
31: cmp %r13, %rcx
    jae 32f
    cmpb $0, VNULL(%r12, %rcx)
    jne 33f
    addsd (%r12, %rcx, 8), %xmm0
    inc %r10
33: inc %rcx
    jmp 31b
32: movsd %xmm0, AS_VAL(%rdi)
    mov %r10, AS_COUNT(%rdi)
    jmp 99f
35: cmp %r13, %rcx
    jae 99f
    cmpb $0, VNULL(%r12, %rcx)
    jne 36f
    mov (%r14, %rcx, 8), %rdi
    add %r15, %rdi
    movsd AS_VAL(%rdi), %xmm0
    addsd (%r12, %rcx, 8), %xmm0
    movsd %xmm0, AS_VAL(%rdi)
    incq AS_COUNT(%rdi)
36: inc %rcx
    jmp 35b

40: /* ---- MIN / MAX */
    cmp $T_FLOAT, %eax
    je 60f
    cmp $T_STR, %eax
    je 60f
    mov 24(%rsp), %edi
    call dec_is_wide
    test %eax, %eax
    jnz 60f                         /* wide DECIMAL: boxed, value_cmp */
    xor %ecx, %ecx                  /* integer-like: signed compare */
    mov N_OP(%rbx), %r11d
41: cmp %r13, %rcx
    jae 99f
    cmpb $0, VNULL(%r12, %rcx)
    jne 48f
    mov %r14, %rdi
    cmpq $0, 0(%rsp)
    je 42f
    mov (%r14, %rcx, 8), %rdi
42: add %r15, %rdi                  /* state */
    incq AS_COUNT(%rdi)
    mov (%r12, %rcx, 8), %rax
    cmpq $0, AS_HAS(%rdi)
    je 46f
    cmp $AGG_MIN, %r11d
    jne 44f
    cmp AS_VAL(%rdi), %rax
    jge 48f
    jmp 47f
44: cmp AS_VAL(%rdi), %rax
    jle 48f
    jmp 47f
46: movq $1, AS_HAS(%rdi)
47: mov %rax, AS_VAL(%rdi)
48: inc %rcx
    jmp 41b

60: /* FLOAT64 / STRING: value_cmp */
    xor %ecx, %ecx
61: cmp %r13, %rcx
    jae 99f
    cmpb $0, VNULL(%r12, %rcx)
    jne 68f
    mov %r14, %rdi
    cmpq $0, 0(%rsp)
    je 62f
    mov (%r14, %rcx, 8), %rdi
62: add %r15, %rdi
    mov %rdi, 8(%rsp)               /* state */
    mov %rcx, 16(%rsp)
    incq AS_COUNT(%rdi)
    mov (%r12, %rcx, 8), %rax
    cmpq $0, AS_HAS(%rdi)
    je 66f
    mov %rax, 32(%rsp)
    mov 24(%rsp), %rdi
    mov %rax, %rsi
    mov 8(%rsp), %rdx
    mov AS_VAL(%rdx), %rdx
    call value_cmp
    mov 16(%rsp), %rcx
    mov 8(%rsp), %rdi
    mov 32(%rsp), %rdx
    cmpl $AGG_MIN, N_OP(%rbx)
    jne 64f
    cmp $0, %eax
    jge 68f
    mov %rdx, AS_VAL(%rdi)
    jmp 68f
64: cmp $0, %eax
    jle 68f
    mov %rdx, AS_VAL(%rdi)
    jmp 68f
66: mov %rax, AS_VAL(%rdi)
    movq $1, AS_HAS(%rdi)
68: inc %rcx
    jmp 61b
99: LEAVE
ENDF vagg_update

/* vk_aggs(ctx rdi, plan rsi, tuples rdx, n rcx, W r8, states r9, stride
 * on the stack): every aggregate of the plan over the batch */
vk_aggs:
    ENTER 64
    mov %rdi, 0+BT_CTX(%rsp)
    mov %rdx, 0+BT_TUP(%rsp)
    mov %rcx, 0+BT_N(%rsp)
    shl $3, %r8
    mov %r8, 0+BT_TW(%rsp)
    mov %rsi, %rbx
    mov %r9, %r13                   /* states */
    mov 16(%rbp), %rax
    mov %rax, 40(%rsp)              /* stride */
    xor %r14d, %r14d
1:  cmp QP_NAGGS(%rbx), %r14
    jae 9f
    mov QP_AGGS(%rbx), %rax
    mov (%rax, %r14, 8), %r15       /* agg node */
    cmpl $AGG_COUNT_STAR, N_OP(%r15)
    jne 3f
    cmpq $0, 40(%rsp)               /* COUNT(*) */
    jne 2f
    imul $AS_SIZE, %r14, %rax
    mov 0+BT_N(%rsp), %rcx
    add %rcx, AS_COUNT(%r13, %rax)
    jmp 8f
2:  imul $AS_SIZE, %r14, %rax
    xor %ecx, %ecx
21: cmp 0+BT_N(%rsp), %rcx
    jae 8f
    mov (%r13, %rcx, 8), %rdx
    incq AS_COUNT(%rdx, %rax)
    inc %rcx
    jmp 21b
3:  call vs_mark
    mov %rax, 32(%rsp)
    mov N_A(%r15), %rdi
    lea 0(%rsp), %rsi
    xor %edx, %edx
    call veval
    mov %r15, %rdi
    mov %rax, %rsi
    mov 0+BT_N(%rsp), %rdx
    mov %r13, %rcx
    mov 40(%rsp), %r8
    imul $AS_SIZE, %r14, %r9
    call vagg_update
    mov 32(%rsp), %rdi
    call vs_release
8:  inc %r14
    jmp 1b
9:  LEAVE

/* vk_agg_single(ctx rdi, plan rsi, tuples rdx, n rcx, W r8, states r9) */
FUNC vk_agg_single
    xchg %rdi, %rsi
    call has_distinct
    xchg %rdi, %rsi
    test %eax, %eax
    jnz rk_agg_single               /* DISTINCT: per-tuple hash sets */
    push $0                         /* stride 0: one state set */
    call vk_aggs
    add $8, %rsp
    ret
ENDF vk_agg_single

/* vk_agg_groups(ctx rdi, plan rsi, tuples rdx, n rcx, W r8, states*[] r9) */
FUNC vk_agg_groups
    xchg %rdi, %rsi
    call has_distinct
    xchg %rdi, %rsi
    test %eax, %eax
    jnz rk_agg_groups
    push $8                         /* stride 8: a state pointer per row */
    call vk_aggs
    add $8, %rsp
    ret
ENDF vk_agg_groups

/* vk_eval1(ctx rdi, expr rsi, tuples rdx, n rcx, W r8, out vector r9) */
FUNC vk_eval1
    ENTER 64
    mov %rdi, 0+BT_CTX(%rsp)
    mov %rdx, 0+BT_TUP(%rsp)
    mov %rcx, 0+BT_N(%rsp)
    shl $3, %r8
    mov %r8, 0+BT_TW(%rsp)
    mov %rsi, %rbx
    mov %r9, %r12
    call vs_mark
    mov %rax, 32(%rsp)
    mov %rbx, %rdi
    lea 0(%rsp), %rsi
    xor %edx, %edx
    call veval
    mov %rax, %r13
    mov %r12, %rdi
    mov %r13, %rsi
    mov 0+BT_N(%rsp), %rdx
    shl $3, %rdx
    call memcpy
    lea VNULL(%r12), %rdi
    lea VNULL(%r13), %rsi
    mov 0+BT_N(%rsp), %rdx
    call memcpy
    mov 32(%rsp), %rdi
    call vs_release
    LEAVE
ENDF vk_eval1

/* vk_pred(ctx rdi, pred rsi, tuples rdx, n rcx, W r8, flags r9):
 * flags[i] = 1 if pred is TRUE for tuple i */
FUNC vk_pred
    ENTER 64
    mov %rdi, 0+BT_CTX(%rsp)
    mov %rdx, 0+BT_TUP(%rsp)
    mov %rcx, 0+BT_N(%rsp)
    shl $3, %r8
    mov %r8, 0+BT_TW(%rsp)
    mov %rsi, %rbx
    mov %r9, %r12
    call vs_mark
    mov %rax, 32(%rsp)
    mov %rbx, %rdi
    lea 0(%rsp), %rsi
    xor %edx, %edx
    call veval
    xor %ecx, %ecx
1:  cmp 0+BT_N(%rsp), %rcx
    jae 9f
    movzbl VNULL(%rax, %rcx), %edx
    xor $1, %edx
    and (%rax, %rcx, 8), %edx
    and $1, %edx
    mov %dl, (%r12, %rcx)
    inc %rcx
    jmp 1b
9:  mov 32(%rsp), %rdi
    call vs_release
    LEAVE
ENDF vk_pred
