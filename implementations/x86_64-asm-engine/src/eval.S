/*
 * eval.S - expression evaluation over bound expression trees.
 *
 *   eval(node rdi, ctx rsi) -> rax payload, rdx null flag (0/1)
 *   cast_value(src_type rdi, dst_type rsi, payload rdx) -> rax payload
 *   value_cmp(type rdi, a rsi, b rdx) -> eax -1/0/1 (non-null values of one type)
 *   dec_cmp(a rdi, sa esi, b rdx, sb ecx) -> eax -1/0/1 (INT64 / narrow DECIMAL)
 *
 * Wide decimals (p > 18, boxed i128, see dec128.S) are dispatched to
 * dec128.S on the type: comparisons (num_cmp), + - * (dec_arith), unary
 * minus and the CAST conversions.  Narrow decimals keep the i64 code.
 *
 * Runtime errors (overflow, division by zero, conversion) are raised.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .section .rodata
    .p2align 3
pstr_true:  .quad 4
            .asciz "true"
    .p2align 3
pstr_false: .quad 5
            .asciz "false"
    .p2align 3
dec_max:    .quad 999999999999999999
f64_two64:  .quad 0x43f0000000000000          /* 2^64 */
    .text

/* ================================================================ helpers */

FUNC raise_overflow
    sub $8, %rsp
    RAISE E_NUMERIC_OVERFLOW, "numeric overflow"
ENDF raise_overflow

FUNC raise_divzero
    sub $8, %rsp
    RAISE E_DIVISION_BY_ZERO, "division by zero"
ENDF raise_divzero

/* chk_dec128(lo rax, hi rdx) -> rax; raises unless the value fits 18 digits.
 * clobbers rcx */
FUNC chk_dec128
    mov %rax, %rcx
    sar $63, %rcx
    cmp %rcx, %rdx
    jne raise_overflow
    mov %rax, %rcx
    test %rcx, %rcx
    jns 1f
    neg %rcx
1:  cmp dec_max(%rip), %rcx
    ja raise_overflow
    ret
ENDF chk_dec128

/* scale128(v rdi, k esi) -> rdx:rax = v * 10^k (signed 128-bit), k in 0..18 */
FUNC scale128
    mov %rdi, %rax
    lea pow10_u64(%rip), %rcx
    mov (%rcx, %rsi, 8), %rcx
    imul %rcx
    ret
ENDF scale128

/* dec_cmp(a rdi, sa esi, b rdx, sb ecx) -> eax -1/0/1 */
FUNC dec_cmp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    mov %rdx, %r12                  /* b */
    mov %ecx, %r13d                 /* sb */
    mov %esi, %r14d                 /* sa */
    /* target scale = max */
    mov %r14d, %r15d
    cmp %r13d, %r15d
    cmovb %r13d, %r15d
    mov %r15d, %esi
    sub %r14d, %esi
    call scale128                   /* a */
    mov %rax, %rbx
    mov %rdx, %r14
    mov %r12, %rdi
    mov %r15d, %esi
    sub %r13d, %esi
    call scale128                   /* b in rdx:rax */
    /* compare r14:rbx with rdx:rax */
    cmp %rdx, %r14
    jl 2f
    jg 3f
    cmp %rax, %rbx
    jb 2f
    ja 3f
    xor %eax, %eax
    jmp 9f
2:  mov $-1, %eax
    jmp 9f
3:  mov $1, %eax
9:  pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    ret
ENDF dec_cmp

/* value_cmp(type rdi, a rsi, b rdx) -> eax -1/0/1 */
FUNC value_cmp
    movzbl %dil, %eax
    cmp $T_FLOAT, %eax
    je 3f
    cmp $T_STR, %eax
    je 4f
    cmp $T_DEC, %eax
    je 5f
    /* BOOL, INT, DATE, TS (and same-scale DEC): signed integers */
1:  xor %eax, %eax
    cmp %rdx, %rsi
    je 2f
    mov $-1, %eax
    jl 2f
    mov $1, %eax
2:  ret
3:  movq %rsi, %xmm0
    movq %rdx, %xmm1
    xor %eax, %eax
    ucomisd %xmm1, %xmm0
    je 2b
    mov $-1, %eax
    jb 2b
    mov $1, %eax
    ret
4:  mov %rsi, %rdi
    mov %rdx, %rsi
    jmp pstr_cmp
5:  mov %edi, %eax                  /* DECIMAL: narrow ones are i64 */
    shr $8, %eax
    cmp $18, %al
    jbe 1b
    mov 8(%rsi), %rax               /* wide: i128 boxes, one scale */
    cmp 8(%rdx), %rax
    jl 6f
    jg 7f
    mov (%rsi), %rax
    cmp (%rdx), %rax
    jb 6f
    ja 7f
    xor %eax, %eax
    ret
6:  mov $-1, %eax
    ret
7:  mov $1, %eax
    ret
ENDF value_cmp

/* cmp_values(ta edi, tb esi, a r13, b r14) -> eax -1/0/1: the comparison
 * of a bound binary comparison node.  Operand kinds are equal except
 * INT64 / DECIMAL mixes, which (like decimals of different precision or
 * scale) compare their exact values (decimal38.md section 4).  Internal:
 * takes the values in r13 / r14 (eval's registers). */
cmp_values:
    movzbl %dil, %eax
    movzbl %sil, %ecx
    cmp $T_DEC, %eax
    je 1f
    cmp $T_DEC, %ecx
    je 1f
    mov %r13, %rsi                  /* same kind */
    mov %r14, %rdx
    jmp value_cmp
1:  mov %esi, %edx                  /* INT64 / DECIMAL: exact */
    mov %r13, %rsi
    mov %r14, %rcx
    jmp dec_cmp_any

/* i128_to_double(lo rdi, hi rsi) -> xmm0 */
FUNC i128_to_double
    mov %rdi, %rax
    sar $63, %rax
    cmp %rax, %rsi
    jne 1f
    cvtsi2sd %rdi, %xmm0
    ret
1:  cvtsi2sd %rsi, %xmm0            /* hi * 2^64 */
    mulsd f64_two64(%rip), %xmm0
    test %rdi, %rdi                 /* + unsigned lo */
    js 2f
    cvtsi2sd %rdi, %xmm1
    addsd %xmm1, %xmm0
    ret
2:  mov %rdi, %rax
    shr $1, %rax
    and $1, %edi
    or %rdi, %rax
    cvtsi2sd %rax, %xmm1
    addsd %xmm1, %xmm1
    addsd %xmm1, %xmm0
    ret
ENDF i128_to_double

/* check_finite(xmm0): raises NUMERIC_OVERFLOW for inf/nan */
FUNC check_finite
    movq %xmm0, %rax
    shr $52, %rax
    and $0x7ff, %eax
    cmp $0x7ff, %eax
    je raise_overflow
    ret
ENDF check_finite

/* ================================================================ eval */

FUNC eval
    STACK_CHECK
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov N_KIND(%rbx), %eax
    cmp $EK_COL, %eax
    je ev_col
    cmp $EK_LIT, %eax
    je ev_lit
    cmp $EK_BINARY, %eax
    je ev_binary
    cmp $EK_UNARY, %eax
    je ev_unary
    cmp $EK_CAST, %eax
    je ev_cast
    cmp $EK_ISNULL, %eax
    je ev_isnull
    cmp $EK_AGG, %eax
    je ev_agg
    cmp $EK_FUNC, %eax
    je ev_func
    cmp $EK_OUTER, %eax
    je ev_outer
    cmp $EK_SUBQ, %eax
    jb 1f
    cmp $EK_EXISTS, %eax
    ja 1f
    mov %rbx, %rdi                  /* subqueries: exec.S */
    mov %r12, %rsi
    call eval_subquery
    LEAVE
1:  cmp $EK_CASE, %eax              /* functions.S hook */
    jb 2f
    cmp $EK_LIKE, %eax
    ja 2f
    mov %rbx, %rdi
    mov %r12, %rsi
    call eval_special
    LEAVE
2:  RAISE E_INTERNAL_ERROR, "cannot evaluate expression node"

ev_ret_null:
    xor %eax, %eax
    mov $1, %edx
    LEAVE
ev_ret:                             /* value in rax */
    xor %edx, %edx
    LEAVE

ev_lit:
    mov N_V1(%rbx), %rax
    mov N_FLAGS(%rbx), %edx
    and $NF_NULL, %edx
    LEAVE

ev_col:
    mov N_V2(%rbx), %rax            /* range variable */
    mov EC_TUPLE(%r12), %rsi
    mov (%rsi, %rax, 8), %rsi       /* row index */
    cmp $-1, %rsi
    je ev_ret_null
    mov EC_TABLES(%r12), %rcx
    mov (%rcx, %rax, 8), %rcx
    mov TB_COLS(%rcx), %rdi
    mov N_V1(%rbx), %rdx
    shl $COL_SHIFT, %rdx
    add %rdx, %rdi                  /* Column* */
    call col_get
    LEAVE

ev_outer:                           /* correlated column: V3 contexts up */
    mov N_V3(%rbx), %rcx
1:  mov EC_OUTER(%r12), %r12
    dec %rcx
    jnz 1b
    jmp ev_col

ev_agg:
    mov EC_AGGV(%r12), %rcx
    mov N_V2(%rbx), %rdx
    shl $4, %rdx
    mov VAL_P(%rcx, %rdx), %rax
    mov VAL_NULL(%rcx, %rdx), %rdx
    LEAVE

ev_isnull:
    mov N_A(%rbx), %rdi
    mov %r12, %rsi
    call eval
    mov %edx, %eax
    xor N_OP(%rbx), %eax            /* IS NOT NULL inverts */
    and $1, %eax
    jmp ev_ret

ev_cast:
    mov N_A(%rbx), %rdi
    mov %r12, %rsi
    call eval
    test %edx, %edx
    jnz ev_ret_null
    mov %rax, %rdx
    mov N_A(%rbx), %rdi
    mov N_TYPE(%rdi), %edi
    mov N_V1(%rbx), %rsi
    call cast_value
    jmp ev_ret

ev_unary:
    mov N_A(%rbx), %rdi
    mov %r12, %rsi
    call eval
    test %edx, %edx
    jnz ev_ret_null
    mov %rax, %r13
    mov N_OP(%rbx), %ecx
    cmp $U_NOT, %ecx
    jne 1f
    xor $1, %eax
    jmp ev_ret
1:  cmp $U_POS, %ecx
    je ev_ret
    movzbl N_TYPE(%rbx), %ecx
    cmp $T_FLOAT, %ecx
    je 2f
    mov N_TYPE(%rbx), %edi
    call dec_is_wide
    test %eax, %eax
    jnz 3f
    mov %r13, %rax
    neg %rax
    jo raise_overflow
    jmp ev_ret
2:  btc $63, %rax
    jmp ev_ret
3:  mov (%r13), %rdi                /* wide: -v never overflows */
    mov 8(%r13), %rsi
    neg %rdi
    adc $0, %rsi
    neg %rsi
    call dec_box
    jmp ev_ret

ev_func:                            /* functions.S hook */
    mov %rbx, %rdi
    mov %r12, %rsi
    call eval_scalar_func
    LEAVE

/* ---------------------------------------------------------------- binary */
ev_binary:
    mov N_OP(%rbx), %ecx
    cmp $B_AND, %ecx
    je ev_and
    cmp $B_OR, %ecx
    je ev_or
    mov N_A(%rbx), %rdi
    mov %r12, %rsi
    call eval
    test %edx, %edx
    jnz ev_ret_null
    mov %rax, %r13                  /* a */
    mov N_B(%rbx), %rdi
    mov %r12, %rsi
    call eval
    test %edx, %edx
    jnz ev_ret_null
    mov %rax, %r14                  /* b */
    mov N_OP(%rbx), %ecx
    cmp $B_EQ, %ecx
    jae ev_compare
    cmp $B_CONCAT, %ecx
    je ev_concat
    movzbl N_TYPE(%rbx), %eax
    cmp $T_INT, %eax
    je ev_int_arith
    cmp $T_FLOAT, %eax
    je ev_float_arith
    cmp $T_DEC, %eax
    je ev_dec_arith
    RAISE E_INTERNAL_ERROR, "bad arithmetic type"

ev_and:
    mov N_A(%rbx), %rdi
    mov %r12, %rsi
    call eval
    test %edx, %edx
    jnz 1f
    test %rax, %rax
    jz ev_ret                       /* FALSE AND x = FALSE */
1:  mov %edx, %r13d                 /* left null? */
    mov N_B(%rbx), %rdi
    mov %r12, %rsi
    call eval
    test %edx, %edx
    jnz 2f
    test %rax, %rax
    jz ev_ret                       /* x AND FALSE = FALSE */
    test %r13d, %r13d
    jnz ev_ret_null
    mov $1, %eax
    jmp ev_ret
2:  jmp ev_ret_null

ev_or:
    mov N_A(%rbx), %rdi
    mov %r12, %rsi
    call eval
    test %edx, %edx
    jnz 1f
    test %rax, %rax
    jnz ev_ret                      /* TRUE OR x = TRUE */
1:  mov %edx, %r13d
    mov N_B(%rbx), %rdi
    mov %r12, %rsi
    call eval
    test %edx, %edx
    jnz 2f
    test %rax, %rax
    jnz ev_ret
    test %r13d, %r13d
    jnz ev_ret_null
    xor %eax, %eax
    jmp ev_ret
2:  jmp ev_ret_null

ev_compare:
    mov N_A(%rbx), %rax
    mov N_TYPE(%rax), %edi          /* left type */
    mov N_B(%rbx), %rax
    mov N_TYPE(%rax), %esi          /* right type */
    call cmp_values
2:  mov N_OP(%rbx), %ecx
    xor %edx, %edx
    cmp $B_EQ, %ecx
    jne 3f
    test %eax, %eax
    sete %dl
    jmp 9f
3:  cmp $B_NE, %ecx
    jne 4f
    test %eax, %eax
    setne %dl
    jmp 9f
4:  cmp $B_LT, %ecx
    jne 5f
    cmp $0, %eax
    setl %dl
    jmp 9f
5:  cmp $B_LE, %ecx
    jne 6f
    cmp $0, %eax
    setle %dl
    jmp 9f
6:  cmp $B_GT, %ecx
    jne 7f
    cmp $0, %eax
    setg %dl
    jmp 9f
7:  cmp $0, %eax
    setge %dl
9:  mov %edx, %eax
    jmp ev_ret

ev_concat:
    mov (%r13), %rdi
    add (%r14), %rdi
    mov %rdi, %r15
    add $9, %rdi
    call tmp_alloc
    mov %rax, 0(%rsp)
    mov %r15, (%rax)
    lea 8(%rax), %rdi
    lea 8(%r13), %rsi
    mov (%r13), %rdx
    call memcpy
    mov 0(%rsp), %rdi
    add $8, %rdi
    add (%r13), %rdi
    lea 8(%r14), %rsi
    mov (%r14), %rdx
    call memcpy
    mov 0(%rsp), %rax
    movb $0, 8(%rax, %r15)
    jmp ev_ret

ev_int_arith:
    mov N_OP(%rbx), %ecx
    mov %r13, %rax
    cmp $B_ADD, %ecx
    jne 1f
    add %r14, %rax
    jo raise_overflow
    jmp ev_ret
1:  cmp $B_SUB, %ecx
    jne 2f
    sub %r14, %rax
    jo raise_overflow
    jmp ev_ret
2:  cmp $B_MUL, %ecx
    jne 3f
    imul %r14, %rax
    jo raise_overflow
    jmp ev_ret
3:  /* / and % */
    test %r14, %r14
    jz raise_divzero
    cmp $-1, %r14
    jne 5f
    cmp $B_MOD, %ecx
    jne 4f
    xor %eax, %eax                  /* x % -1 = 0 */
    jmp ev_ret
4:  neg %rax                        /* x / -1 */
    jo raise_overflow
    jmp ev_ret
5:  cqo
    idiv %r14
    cmp $B_MOD, %ecx
    jne ev_ret
    mov %rdx, %rax
    jmp ev_ret

ev_float_arith:
    movq %r13, %xmm0
    movq %r14, %xmm1
    mov N_OP(%rbx), %ecx
    cmp $B_ADD, %ecx
    jne 1f
    addsd %xmm1, %xmm0
    jmp 8f
1:  cmp $B_SUB, %ecx
    jne 2f
    subsd %xmm1, %xmm0
    jmp 8f
2:  cmp $B_MUL, %ecx
    jne 3f
    mulsd %xmm1, %xmm0
    jmp 8f
3:  xorpd %xmm2, %xmm2
    ucomisd %xmm2, %xmm1
    je raise_divzero
    divsd %xmm1, %xmm0
8:  call check_finite
    movq %xmm0, %rax
    jmp ev_ret

ev_dec_arith:
    mov N_TYPE(%rbx), %edi
    call dec_is_wide
    test %eax, %eax
    jz 0f
    mov N_OP(%rbx), %edi            /* wide result: dec128.S */
    mov N_A(%rbx), %rax
    mov N_TYPE(%rax), %esi
    mov %r13, %rdx
    mov N_B(%rbx), %rax
    mov N_TYPE(%rax), %ecx
    mov %r14, %r8
    mov N_TYPE(%rbx), %r9d
    call dec_arith
    jmp ev_ret
0:  mov N_A(%rbx), %rax
    mov N_TYPE(%rax), %eax
    shr $16, %eax
    and $0xff, %eax
    mov %eax, 0(%rsp)               /* sa */
    mov N_B(%rbx), %rax
    mov N_TYPE(%rax), %eax
    shr $16, %eax
    and $0xff, %eax
    mov %eax, 4(%rsp)               /* sb */
    cmpl $B_MUL, N_OP(%rbx)
    jne 1f
    mov %r13, %rax
    imul %r14
    call chk_dec128
    jmp ev_ret
1:  /* + / - : align to the result scale */
    mov N_TYPE(%rbx), %r15d
    shr $16, %r15d
    and $0xff, %r15d                /* result scale */
    mov %r13, %rdi
    mov %r15d, %esi
    sub 0(%rsp), %esi
    call scale128
    mov %rax, %r13
    mov %rdx, 8(%rsp)               /* a hi */
    mov %r14, %rdi
    mov %r15d, %esi
    sub 4(%rsp), %esi
    call scale128                   /* b: rdx:rax */
    cmpl $B_ADD, N_OP(%rbx)
    jne 2f
    add %r13, %rax
    adc 8(%rsp), %rdx
    call chk_dec128
    jmp ev_ret
2:  mov %rax, %rcx                  /* a - b */
    mov %rdx, %rsi
    mov %r13, %rax
    mov 8(%rsp), %rdx
    sub %rcx, %rax
    sbb %rsi, %rdx
    call chk_dec128
    jmp ev_ret
ENDF eval

/* ================================================================ CAST */

/* scratch buffer for formatting values to text (one per thread: parallel
 * workers evaluate CASTs concurrently; pool workers keep theirs) */
    .section .tbss, "awT", @nobits
    .p2align 3
cast_buf: .zero BUF_SIZE
    .text


/* fmt_to_pstr(type rdi, payload rsi) -> rax pstr in request arena (text form) */
FUNC fmt_to_pstr
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %fs:0, %rdi
    lea cast_buf@tpoff(%rdi), %rdi
    movq $0, BUF_LEN(%rdi)
    mov %rbx, %rsi
    mov %r12, %rdx
    call fmt_value_text
    mov %fs:0, %rax
    lea cast_buf@tpoff(%rax), %rax
    mov BUF_DATA(%rax), %rdi
    mov BUF_LEN(%rax), %rsi
    test %rdi, %rdi
    jnz 1f
    mov %rax, %rdi                  /* empty text: any valid pointer */
1:  call pstr_tmp
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF fmt_to_pstr

cast_conv_error:
    RAISE E_CONVERSION_ERROR, "invalid value for CAST"

/* cast_value(src rdi, dst rsi, payload rdx) -> rax */
FUNC cast_value
    ENTER 16
    mov %rdi, %rbx                  /* src type */
    mov %rsi, %r12                  /* dst type */
    mov %rdx, %r13                  /* payload */
    movzbl %bl, %eax
    movzbl %r12b, %ecx
    cmp $T_STR, %ecx
    je cv_to_str
    cmp $T_DEC, %ecx
    je cv_to_dec
    cmp $T_STR, %eax
    je cv_from_str
    cmp %eax, %ecx
    je cv_same
    cmp $T_BOOL, %ecx
    je cv_to_bool
    cmp $T_INT, %ecx
    je cv_to_int
    cmp $T_FLOAT, %ecx
    je cv_to_float
    cmp $T_TS, %ecx
    je cv_to_ts
    cmp $T_DATE, %ecx
    je cv_to_date
cv_same:
    mov %r13, %rax
    LEAVE

cv_to_str:
    cmp $T_STR, %eax
    je cv_same
    mov %rbx, %rdi
    mov %r13, %rsi
    call fmt_to_pstr
    LEAVE

cv_to_bool:                         /* INT -> BOOL */
    xor %eax, %eax
    test %r13, %r13
    setnz %al
    LEAVE

cv_to_int:
    cmp $T_BOOL, %eax
    je cv_same
    cmp $T_DEC, %eax
    je 1f
    /* FLOAT -> INT */
    movq %r13, %xmm0
    call float_to_int64
    test %edx, %edx
    jnz raise_overflow
    LEAVE
1:  /* DEC -> INT: truncate toward zero */
    mov %ebx, %edi
    call dec_is_wide
    test %eax, %eax
    jz 2f
    mov (%r13), %rdi
    mov 8(%r13), %rsi
    mov %rbx, %rdx
    shr $16, %rdx
    movzbl %dl, %edx
    call dec128_to_int
    test %edx, %edx
    jnz raise_overflow
    LEAVE
2:  mov %rbx, %rcx
    shr $16, %rcx
    and $0xff, %ecx
    lea pow10_u64(%rip), %rdx
    mov (%rdx, %rcx, 8), %rcx
    mov %r13, %rax
    cqo
    idiv %rcx
    LEAVE

cv_to_float:
    cmp $T_INT, %eax
    jne 1f
    cvtsi2sd %r13, %xmm0
    movq %xmm0, %rax
    LEAVE
1:  mov %ebx, %edi                  /* DEC -> FLOAT */
    call dec_is_wide
    test %eax, %eax
    jnz 2f
    mov %r13, %rdi
    mov %rbx, %rsi
    shr $16, %rsi
    and $0xff, %esi
    call dec_to_float
    movq %xmm0, %rax
    LEAVE
2:  mov (%r13), %rdi                /* wide: nearest FLOAT64 */
    mov 8(%r13), %rsi
    mov %rbx, %rdx
    shr $16, %rdx
    movzbl %dl, %edx
    call dec128_to_double
    movq %xmm0, %rax
    LEAVE

cv_to_dec:
    mov %r12, %r14
    shr $8, %r14
    and $0xff, %r14d                /* target precision */
    mov %r12, %r15
    shr $16, %r15
    and $0xff, %r15d                /* target scale */
    cmp $18, %r14d
    ja cv_to_wide
    cmp $T_DEC, %eax
    jne 0f
    mov %ebx, %edi                  /* wide -> narrow */
    call dec_is_wide
    test %eax, %eax
    jnz cv_to_wide
    movzbl %bl, %eax
0:  cmp $T_STR, %eax
    je cv_str_to_dec
    cmp $T_FLOAT, %eax
    je 3f
    cmp $T_INT, %eax
    jne 1f
    mov %r13, %rdi                  /* INT -> DEC: exact */
    mov %r15d, %esi
    call scale128
    call chk_dec128
    jmp 2f
1:  mov %r13, %rdi                  /* DEC -> DEC: rescale with rounding */
    mov %rbx, %rsi
    shr $16, %rsi
    and $0xff, %esi
    mov %r15d, %edx
    call dec_rescale
    test %edx, %edx
    jnz raise_overflow
2:  mov %rax, %r13
    mov %rax, %rdi
    mov %r14d, %esi
    call dec_fits
    test %eax, %eax
    jz raise_overflow
    mov %r13, %rax
    LEAVE
3:  movq %r13, %xmm0                /* FLOAT -> DEC */
    mov %r14d, %edi
    mov %r15d, %esi
    call float_to_dec
    test %edx, %edx
    jnz raise_overflow
    LEAVE
cv_str_to_dec:
    lea 8(%r13), %rdi
    mov (%r13), %rsi
    call text_trim
    mov %rax, %rdi
    mov %rdx, %rsi
    mov %r14d, %edx
    mov %r15d, %ecx
    mov $1, %r8d
    call text_parse_decimal
    cmp $1, %edx
    je cast_conv_error
    test %edx, %edx
    jnz raise_overflow
    LEAVE

/* conversions with a wide decimal source or target */
cv_to_wide:
    movzbl %bl, %eax
    cmp $T_STR, %eax
    je 3f
    cmp $T_FLOAT, %eax
    je 4f
    mov %ebx, %edi                  /* INT64 / DECIMAL: exact rescale */
    mov %r13, %rsi
    call num_load
    mov %rax, %rdi
    mov %rdx, %rsi
    mov %ecx, %edx
    mov %r15d, %ecx
    mov %r14d, %r8d
    call dec_rescale128
    test %ecx, %ecx
    jnz raise_overflow
1:  mov %rax, %rdi
    mov %rdx, %rsi
    mov %r12d, %edx
    call dec_put
    LEAVE
3:  lea 8(%r13), %rdi               /* STRING: round half away from zero */
    mov (%r13), %rsi
    call text_trim
    mov %rax, %rdi
    mov %rdx, %rsi
    mov %r14d, %edx
    mov %r15d, %ecx
    mov $1, %r8d
    mov %rsp, %r9
    call dec_parse
    cmp $1, %eax
    je cast_conv_error
    test %eax, %eax
    jnz raise_overflow
2:  mov 0(%rsp), %rax
    mov 8(%rsp), %rdx
    jmp 1b
4:  movq %r13, %xmm0                /* FLOAT64: exact binary value */
    mov %r14d, %edi
    mov %r15d, %esi
    mov %rsp, %rdx
    call double_to_dec128
    test %eax, %eax
    jnz raise_overflow
    jmp 2b

cv_to_ts:                           /* DATE -> TS */
    mov $86400000000, %rax
    imul %r13, %rax
    LEAVE

cv_to_date:                         /* TS -> DATE: floor division */
    mov %r13, %rax
    mov $86400000000, %rcx
    cqo
    idiv %rcx
    test %rdx, %rdx
    jns 1f
    dec %rax
1:  LEAVE

cv_from_str:
    lea 8(%r13), %rdi
    mov (%r13), %rsi
    call text_trim
    mov %rax, %rdi
    mov %rdx, %rsi
    movzbl %r12b, %ecx
    cmp $T_BOOL, %ecx
    je 1f
    cmp $T_INT, %ecx
    je 2f
    cmp $T_FLOAT, %ecx
    je 3f
    cmp $T_DATE, %ecx
    je 4f
    cmp $T_TS, %ecx
    je 5f
    RAISE E_INTERNAL_ERROR, "bad cast"
1:  call text_parse_bool
    test %edx, %edx
    jnz cast_conv_error
    LEAVE
2:  call text_parse_int64
    cmp $1, %edx
    je cast_conv_error
    test %edx, %edx
    jnz raise_overflow
    LEAVE
3:  call text_parse_float
    cmp $1, %eax
    je cast_conv_error
    test %eax, %eax
    jnz raise_overflow
    movq %xmm0, %rax
    LEAVE
4:  call text_parse_date
    test %edx, %edx
    jnz cast_conv_error
    LEAVE
5:  mov $1, %edx
    call text_parse_timestamp
    test %edx, %edx
    jnz cast_conv_error
    LEAVE
ENDF cast_value
