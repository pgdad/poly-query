/*
 * functions.S - scalar functions (functions.md §1) and the special expression
 * forms CASE, [NOT] BETWEEN, [NOT] IN (list) and [NOT] LIKE (semantics.md
 * §11-13): type checking at bind time and evaluation.
 *
 * Binding (called by the binder; B is the binder state, passed through to
 * bind_expr untouched):
 *   bind_scalar_func(B rdi, node rsi) -> rax bound node
 *       EK_FUNC whose name is not an aggregate.  Sets N_OP = F_*, N_TYPE and
 *       inserts implicit casts so that evaluation sees uniform types.
 *       Bound extras: N_V2 = ROUND's constant n / DATE_TRUNC, DATE_DIFF unit
 *       code (0 = NULL unit); N_V3 = 1 when ROUND's n is NULL.
 *   bind_special(B rdi, node rsi) -> rax bound node
 *       EK_CASE / EK_BETWEEN / EK_INLIST / EK_LIKE.
 *
 * Evaluation (rax payload, rdx null flag; ctx is passed through to eval):
 *   eval_scalar_func(node rdi, ctx rsi)
 *   eval_special(node rdi, ctx rsi)
 *
 * Shared helpers:
 *   expr_is_const(node rdi) -> eax 1 if the value cannot depend on a row
 *   common_type(t1 edi, t2 esi) -> eax result type of CASE/COALESCE branches
 *   check_comparable(t1 edi, t2 esi): TYPE_ERROR unless comparable
 *   cmp_mixed(ta edi, a rsi, tb edx, b rcx) -> eax -1/0/1 comparing two
 *       non-NULL values of comparable (possibly different) types, applying the
 *       numeric / DATE->TIMESTAMP promotions of types.md §2 at run time.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

#define US_PER_SEC  1000000
#define US_PER_MIN  60000000
#define US_PER_HOUR 3600000000
#define US_PER_DAY  86400000000

/* accepted argument kinds: bit k = kind k (the NULL type is always accepted) */
#define M_INT ((1 << T_INT))
#define M_NUM ((1 << T_INT) | (1 << T_FLOAT) | (1 << T_DEC))
#define M_STR ((1 << T_STR))
#define M_DT  ((1 << T_DATE) | (1 << T_TS))
#define M_TS  ((1 << T_TS))

/* DATE_TRUNC / DATE_DIFF unit codes (index in unit_names + 1) */
#define UNIT_YEAR   1
#define UNIT_MONTH  2
#define UNIT_DAY    3
#define UNIT_HOUR   4
#define UNIT_MINUTE 5

#define VARIADIC 255

    .section .rodata
/* function names (case-insensitive) and, in fn_info, per name:
 * F_* id, minimum and maximum argument count */
fn_names:
    .asciz "PQ_SLEEP"
    .asciz "ABS"
    .asciz "ROUND"
    .asciz "FLOOR"
    .asciz "CEIL"
    .asciz "CEILING"
    .asciz "SQRT"
    .asciz "POWER"
    .asciz "MOD"
    .asciz "LENGTH"
    .asciz "UPPER"
    .asciz "LOWER"
    .asciz "SUBSTR"
    .asciz "SUBSTRING"
    .asciz "TRIM"
    .asciz "LTRIM"
    .asciz "RTRIM"
    .asciz "REPLACE"
    .asciz "CONCAT"
    .asciz "COALESCE"
    .asciz "NULLIF"
    .asciz "YEAR"
    .asciz "MONTH"
    .asciz "DAY"
    .asciz "HOUR"
    .asciz "MINUTE"
    .asciz "SECOND"
    .asciz "DATE_TRUNC"
    .asciz "DATE_DIFF"
    .byte 0
fn_info:
    .byte F_PQ_SLEEP, 1, 1
    .byte F_ABS, 1, 1
    .byte F_ROUND, 1, 2
    .byte F_FLOOR, 1, 1
    .byte F_CEIL, 1, 1
    .byte F_CEIL, 1, 1
    .byte F_SQRT, 1, 1
    .byte F_POWER, 2, 2
    .byte F_MOD, 2, 2
    .byte F_LENGTH, 1, 1
    .byte F_UPPER, 1, 1
    .byte F_LOWER, 1, 1
    .byte F_SUBSTR, 2, 3
    .byte F_SUBSTR, 2, 3
    .byte F_TRIM, 1, 1
    .byte F_LTRIM, 1, 1
    .byte F_RTRIM, 1, 1
    .byte F_REPLACE, 3, 3
    .byte F_CONCAT, 1, VARIADIC
    .byte F_COALESCE, 1, VARIADIC
    .byte F_NULLIF, 2, 2
    .byte F_YEAR, 1, 1
    .byte F_MONTH, 1, 1
    .byte F_DAY, 1, 1
    .byte F_HOUR, 1, 1
    .byte F_MINUTE, 1, 1
    .byte F_SECOND, 1, 1
    .byte F_DATE_TRUNC, 2, 2
    .byte F_DATE_DIFF, 3, 3

unit_names:
    .asciz "year"
    .asciz "month"
    .asciz "day"
    .asciz "hour"
    .asciz "minute"
    .byte 0

    .p2align 3
f64_ten:    .double 10.0
    .text

/* ================================================================ small helpers */

/* name_lookup(ptr rdi, len rsi, list rdx) -> eax index of the name in a
 * NUL-separated list (ASCII case-insensitive), or -1 */
FUNC name_lookup
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    xor %r14d, %r14d
1:  cmpb $0, (%r13)
    je 8f
    mov %rbx, %rdi
    mov %r12, %rsi
    mov %r13, %rdx
    call cstr_ieq
    test %eax, %eax
    jnz 9f
    mov %r13, %rdi
    call strlen
    lea 1(%r13, %rax), %r13
    inc %r14d
    jmp 1b
8:  mov $-1, %r14d
9:  mov %r14d, %eax
    LEAVE
ENDF name_lookup

FUNC fn_type_error
    sub $8, %rsp
    RAISE E_TYPE_ERROR, "argument types are incompatible"
ENDF fn_type_error

/* floordiv(a rdi, b rsi > 0) -> rax floor(a / b), rdx a mod b in [0, b) */
FUNC floordiv
    mov %rdi, %rax
    cqo
    idiv %rsi
    test %rdx, %rdx
    jns 1f
    dec %rax
    add %rsi, %rdx
1:  ret
ENDF floordiv

/* expr_is_const(node rdi) -> eax 1 if the expression is constant: no column
 * references, aggregates or subqueries anywhere in it */
FUNC expr_is_const
    STACK_CHECK
    ENTER 0
    mov %rdi, %rbx
    mov N_KIND(%rbx), %eax
    cmp $EK_COL, %eax
    je 8f
    cmp $EK_OUTER, %eax
    je 8f
    cmp $EK_AGG, %eax
    je 8f
    cmp $EK_SUBQ, %eax
    je 8f
    cmp $EK_INSUBQ, %eax
    je 8f
    cmp $EK_EXISTS, %eax
    je 8f
    mov %rbx, %rdi
    call expr_nchild
    mov %rax, %r12
    xor %r13d, %r13d
1:  cmp %r12, %r13
    jae 7f
    mov %rbx, %rdi
    mov %r13, %rsi
    call expr_child_ptr
    mov (%rax), %rdi
    test %rdi, %rdi
    jz 2f
    call expr_is_const
    test %eax, %eax
    jz 8f
2:  inc %r13
    jmp 1b
7:  mov $1, %eax
    LEAVE
8:  xor %eax, %eax
    LEAVE
ENDF expr_is_const

/* ================================================================ type rules */

/* common_type(t1 edi, t2 esi) -> eax: result type of two CASE/COALESCE
 * branches.  The NULL type yields the other type; identical types stay;
 * numeric kinds promote (INT < DECIMAL < FLOAT64; DECIMALs and INT/DECIMAL
 * mixes become DECIMAL(18, max scale)); anything else is a TYPE_ERROR. */
FUNC common_type
    movzbl %dil, %eax
    movzbl %sil, %ecx
    test %ecx, %ecx
    jz 1f
    test %eax, %eax
    jz 2f
    cmp %esi, %edi
    je 1f
    mov $M_NUM, %edx
    bt %eax, %edx
    jnc fn_type_error
    bt %ecx, %edx
    jnc fn_type_error
    cmp $T_FLOAT, %eax
    je 3f
    cmp $T_FLOAT, %ecx
    je 3f
    push %rbx                       /* DECIMAL(W, max(s1, s2)); INT has s = 0 */
    push %r12
    push %r13
    mov %edi, %ebx
    mov %esi, %r12d
    call dec_is_wide
    mov %eax, %r13d
    mov %r12d, %edi
    call dec_is_wide
    or %eax, %r13d                  /* W = 38 if a decimal is wide */
    mov %ebx, %eax
    shr $16, %eax
    movzbl %al, %eax
    mov %r12d, %ecx
    shr $16, %ecx
    movzbl %cl, %ecx
    cmp %ecx, %eax
    cmovb %ecx, %eax
    shl $16, %eax
    or $MKDEC(18, 0), %eax
    test %r13d, %r13d
    jz 4f
    or $MKDEC(38, 0), %eax          /* 18 | 38 = 54: set p explicitly */
    and $0xff00ff, %eax
    or $MKDEC(38, 0), %eax
4:  pop %r13
    pop %r12
    pop %rbx
    ret
1:  mov %edi, %eax
    ret
2:  mov %esi, %eax
    ret
3:  mov $T_FLOAT, %eax
    ret
ENDF common_type

/* check_comparable(t1 edi, t2 esi): NULL type, identical kinds, two numeric
 * kinds, or DATE with TIMESTAMP are comparable; otherwise TYPE_ERROR */
FUNC check_comparable
    movzbl %dil, %eax
    movzbl %sil, %ecx
    test %eax, %eax
    jz 1f
    test %ecx, %ecx
    jz 1f
    cmp %ecx, %eax
    je 1f
    mov $M_NUM, %edx
    bt %eax, %edx
    jnc 2f
    bt %ecx, %edx
    jc 1f
    jmp fn_type_error
2:  mov $M_DT, %edx
    bt %eax, %edx
    jnc fn_type_error
    bt %ecx, %edx
    jnc fn_type_error
1:  ret
ENDF check_comparable

/* to_double(type edi, payload rsi) -> xmm0 (INT, DECIMAL or FLOAT64 value) */
FUNC to_double
    movzbl %dil, %eax
    cmp $T_FLOAT, %eax
    je 2f
    cmp $T_DEC, %eax
    je 1f
    cvtsi2sd %rsi, %xmm0
    ret
1:  mov %edi, %eax
    shr $8, %eax
    cmp $18, %al
    ja 3f
    shr $16, %edi
    movzbl %dil, %eax
    mov %rsi, %rdi
    mov %eax, %esi
    jmp dec_to_float
3:  shr $16, %edi                   /* wide */
    movzbl %dil, %edx
    mov 8(%rsi), %rax
    mov (%rsi), %rdi
    mov %rax, %rsi
    jmp dec128_to_double
2:  movq %rsi, %xmm0
    ret
ENDF to_double

/* cmp_mixed(ta edi, a rsi, tb edx, b rcx) -> eax -1/0/1 */
FUNC cmp_mixed
    ENTER 16
    mov %edi, %ebx                  /* ta */
    mov %rsi, %r12                  /* a */
    mov %edx, %r13d                 /* tb */
    mov %rcx, %r14                  /* b */
    movzbl %bl, %r8d
    movzbl %r13b, %r9d
    cmp $T_FLOAT, %r8d
    je cm_float
    cmp $T_FLOAT, %r9d
    je cm_float
    cmp $T_DEC, %r8d
    je cm_dec
    cmp $T_DEC, %r9d
    je cm_dec
    cmp %r8d, %r9d
    je 2f
    /* DATE vs TIMESTAMP: the DATE side becomes midnight of that day */
    mov $US_PER_DAY, %rax
    cmp $T_DATE, %r8d
    jne 1f
    imul %rax, %r12
    jmp 2f
1:  imul %rax, %r14
    mov %ebx, %r13d                 /* both TIMESTAMP now */
2:  mov %ebx, %edi
    mov %r12, %rsi
    mov %r14, %rdx
    call value_cmp
    LEAVE
cm_dec:                             /* DECIMAL vs DECIMAL/INT (INT has scale 0) */
    mov %ebx, %edi
    mov %r12, %rsi
    mov %r13d, %edx
    mov %r14, %rcx
    call dec_cmp_any
    LEAVE
    xor %esi, %esi
    cmp $T_DEC, %r8d
    jne 1f
    mov %ebx, %esi
    shr $16, %esi
    movzbl %sil, %esi
1:  xor %ecx, %ecx
    cmp $T_DEC, %r9d
    jne 2f
    mov %r13d, %ecx
    shr $16, %ecx
    movzbl %cl, %ecx
2:  mov %r12, %rdi
    mov %r14, %rdx
    call dec_cmp
    LEAVE
cm_float:
    mov %r13d, %edi
    mov %r14, %rsi
    call to_double
    movsd %xmm0, 0(%rsp)
    mov %ebx, %edi
    mov %r12, %rsi
    call to_double
    movsd 0(%rsp), %xmm1
    xor %eax, %eax
    ucomisd %xmm1, %xmm0
    je 9f
    mov $-1, %eax
    jb 9f
    mov $1, %eax
9:  LEAVE
ENDF cmp_mixed

/* ================================================================ binding helpers */

/* arg_check(node rdi, i esi, mask edx) -> eax packed type of argument i;
 * TYPE_ERROR unless its kind is in mask or the NULL type */
FUNC arg_check
    mov N_A(%rdi), %rax
    mov (%rax, %rsi, 8), %rax
    mov N_TYPE(%rax), %eax
    movzbl %al, %ecx
    test %ecx, %ecx
    jz 1f
    bt %ecx, %edx
    jnc fn_type_error
1:  ret
ENDF arg_check

/* slot_cast(slot rdi, type esi): wraps the expression stored at slot in an
 * implicit CAST to type unless it already has that type or the NULL type */
FUNC slot_cast
    push %rbx
    mov %rdi, %rbx
    mov (%rbx), %rdi
    movzbl N_TYPE(%rdi), %eax
    test %eax, %eax
    jz 1f
    cmp N_TYPE(%rdi), %esi
    je 1f
    call wrap_cast
    mov %rax, (%rbx)
1:  pop %rbx
    ret
ENDF slot_cast

/* arg_cast(node rdi, i esi, type edx): slot_cast on argument i */
FUNC arg_cast
    mov N_A(%rdi), %rax
    lea (%rax, %rsi, 8), %rdi
    mov %edx, %esi
    jmp slot_cast
ENDF arg_cast

/* const_arg(node rdi, i esi) -> rax payload, rdx null flag of argument i,
 * which must be a constant expression (else SEMANTIC_ERROR); it is evaluated
 * now with an empty context */
FUNC const_arg
    ENTER EC_SIZE
    mov N_A(%rdi), %rax
    mov (%rax, %rsi, 8), %rbx
    mov %rbx, %rdi
    call expr_is_const
    test %eax, %eax
    jz 1f
    lea 0(%rsp), %rdi
    xor %esi, %esi
    mov $EC_SIZE, %edx
    call memset
    mov %rbx, %rdi
    lea 0(%rsp), %rsi
    call eval
    LEAVE
1:  RAISE E_SEMANTIC_ERROR, "function argument must be a constant"
ENDF const_arg

/* bind_unit(node rdi) -> eax unit code of the constant STRING argument 0
 * (0 when it is NULL); INVALID_ARGUMENT for an unknown unit */
FUNC bind_unit
    ENTER 0
    mov %rdi, %rbx
    xor %esi, %esi
    call const_arg
    mov %rax, %r12
    mov %rdx, %r13
    mov %rbx, %rdi
    xor %esi, %esi
    mov $M_STR, %edx
    call arg_check
    xor %eax, %eax
    test %r13, %r13
    jnz 9f
    lea PSTR_DATA(%r12), %rdi
    mov PSTR_LEN(%r12), %rsi
    lea unit_names(%rip), %rdx
    call name_lookup
    cmp $-1, %eax
    je 8f
    inc %eax
9:  LEAVE
8:  RAISE E_INVALID_ARGUMENT, "unknown date/time unit"
ENDF bind_unit

/* ================================================================ bind_scalar_func */

.macro ARGCHK i, mask
    mov %r12, %rdi
    mov $\i, %esi
    mov $(\mask), %edx
    call arg_check
.endm

.macro ARGCAST i, type
    mov %r12, %rdi
    mov $\i, %esi
    mov $(\type), %edx
    call arg_cast
.endm

/* bind_scalar_func(B rdi, node rsi) -> rax
 * registers: rbx B, r12 node; 0(%rsp) argument count */
FUNC bind_scalar_func
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov N_B(%r12), %rax
    lea PSTR_DATA(%rax), %rdi
    mov PSTR_LEN(%rax), %rsi
    lea fn_names(%rip), %rdx
    call name_lookup
    cmp $-1, %eax
    je bsf_unknown
    test %eax, %eax                 /* index 0: PQ_SLEEP, test builds only */
    jnz 1f
    cmpq $0, g_test_functions(%rip)
    je bsf_unknown
1:  lea (%rax, %rax, 2), %rax
    lea fn_info(%rip), %rcx
    add %rax, %rcx
    movzbl (%rcx), %r13d            /* F_* */
    movzbl 1(%rcx), %r14d           /* min args */
    movzbl 2(%rcx), %r15d           /* max args */
    testl $(NF_STAR | NF_DISTINCT), N_FLAGS(%r12)
    jnz bsf_arity
    xor %eax, %eax
    cmpq $0, N_A(%r12)
    je 2f
    mov N_V1(%r12), %rax
2:  mov %rax, 0(%rsp)
    cmp %r14, %rax
    jb bsf_arity
    cmp $VARIADIC, %r15d
    je 3f
    cmp %r15, %rax
    ja bsf_arity
3:  mov %r13d, N_OP(%r12)
    movq $0, N_V2(%r12)
    movq $0, N_V3(%r12)
    /* bind the arguments (bind_expr may replace a node) */
    xor %r14d, %r14d
4:  cmp 0(%rsp), %r14
    jae 5f
    mov N_A(%r12), %rax
    mov (%rax, %r14, 8), %rsi
    mov %rbx, %rdi
    call bind_expr
    mov N_A(%r12), %rcx
    mov %rax, (%rcx, %r14, 8)
    inc %r14
    jmp 4b
5:  /* per-function typing */
    mov %r13d, %eax
    lea bsf_jt(%rip), %rcx
    movslq -4(%rcx, %rax, 4), %rax
    add %rcx, %rax
    jmp *%rax

    .p2align 2
bsf_jt:                             /* indexed by F_* - 1 */
    .long bt_sleep - bsf_jt
    .long bt_abs - bsf_jt
    .long bt_round - bsf_jt
    .long bt_floor - bsf_jt
    .long bt_floor - bsf_jt         /* CEIL */
    .long bt_sqrt - bsf_jt
    .long bt_power - bsf_jt
    .long bt_mod - bsf_jt
    .long bt_length - bsf_jt
    .long bt_str_str - bsf_jt       /* UPPER */
    .long bt_str_str - bsf_jt       /* LOWER */
    .long bt_substr - bsf_jt
    .long bt_str_str - bsf_jt       /* TRIM */
    .long bt_str_str - bsf_jt       /* LTRIM */
    .long bt_str_str - bsf_jt       /* RTRIM */
    .long bt_replace - bsf_jt
    .long bt_concat - bsf_jt
    .long bt_coalesce - bsf_jt
    .long bt_nullif - bsf_jt
    .long bt_ymd - bsf_jt           /* YEAR */
    .long bt_ymd - bsf_jt           /* MONTH */
    .long bt_ymd - bsf_jt           /* DAY */
    .long bt_hms - bsf_jt           /* HOUR */
    .long bt_hms - bsf_jt           /* MINUTE */
    .long bt_hms - bsf_jt           /* SECOND */
    .long bt_date_trunc - bsf_jt
    .long bt_date_diff - bsf_jt

bsf_set_int:
    movl $T_INT, N_TYPE(%r12)
bsf_done:
    mov %r12, %rax
    LEAVE

bt_sleep:                           /* PQ_SLEEP(INT64) -> INT64 */
    ARGCHK 0, M_INT
    jmp bsf_set_int

bt_abs:                             /* numeric -> same type */
    ARGCHK 0, M_NUM
    movzbl %al, %ecx
    test %ecx, %ecx
    jnz 1f
    mov $T_INT, %eax                /* ABS(NULL) */
1:  mov %eax, N_TYPE(%r12)
    jmp bsf_done

bt_round:                           /* ROUND(x [, n constant INT64]) */
    ARGCHK 0, M_NUM
    mov %eax, %r13d
    cmpq $2, 0(%rsp)
    jne 1f
    mov %r12, %rdi
    mov $1, %esi
    call const_arg
    mov %rax, N_V2(%r12)
    mov %rdx, N_V3(%r12)
    test %rdx, %rdx
    jz 0f
    movq $0, N_V2(%r12)
0:  ARGCHK 1, M_INT
1:  movzbl %r13b, %ecx
    test %ecx, %ecx
    jz bsf_set_int
    cmp $T_DEC, %ecx
    je 2f
    mov %r13d, N_TYPE(%r12)         /* INT64 -> INT64, FLOAT64 -> FLOAT64 */
    jmp bsf_done
2:  /* DECIMAL(p,s) -> DECIMAL(18, max(0, min(n, s))) */
    mov %r13d, %eax
    shr $16, %eax
    movzbl %al, %eax
    mov N_V2(%r12), %rcx
    cmp %rax, %rcx
    jge 3f
    mov %rcx, %rax
    test %rax, %rax
    jns 3f
    xor %eax, %eax
3:  shl $16, %eax
    or $MKDEC(18, 0), %eax
    mov %eax, 8(%rsp)
    mov %r13d, %edi
    call dec_is_wide
    test %eax, %eax
    mov 8(%rsp), %eax
    jz 4f
    and $0xff00ff, %eax             /* wide argument: DECIMAL(38, ...) */
    or $MKDEC(38, 0), %eax
4:  mov %eax, N_TYPE(%r12)
    jmp bsf_done

bt_floor:                           /* FLOOR / CEIL: DECIMAL(p,s) -> DECIMAL(18,0) */
    ARGCHK 0, M_NUM
    movzbl %al, %ecx
    test %ecx, %ecx
    jz bsf_set_int
    cmp $T_DEC, %ecx
    jne 1f
    mov %eax, %edi
    call dec_is_wide
    test %eax, %eax
    mov $MKDEC(18, 0), %eax
    jz 1f
    mov $MKDEC(38, 0), %eax
1:  mov %eax, N_TYPE(%r12)
    jmp bsf_done

bt_sqrt:                            /* numeric -> FLOAT64 */
    ARGCHK 0, M_NUM
    ARGCAST 0, T_FLOAT
    movl $T_FLOAT, N_TYPE(%r12)
    jmp bsf_done

bt_power:                           /* numeric, numeric -> FLOAT64 */
    ARGCHK 0, M_NUM
    ARGCHK 1, M_NUM
    ARGCAST 0, T_FLOAT
    ARGCAST 1, T_FLOAT
    movl $T_FLOAT, N_TYPE(%r12)
    jmp bsf_done

bt_mod:                             /* INT64, INT64 -> INT64 */
    ARGCHK 0, M_INT
    ARGCHK 1, M_INT
    jmp bsf_set_int

bt_length:                          /* STRING -> INT64 */
    ARGCHK 0, M_STR
    jmp bsf_set_int

bt_str_str:                         /* STRING -> STRING */
    ARGCHK 0, M_STR
bsf_set_str:
    movl $T_STR, N_TYPE(%r12)
    jmp bsf_done

bt_substr:                          /* STRING, INT64 [, INT64] -> STRING */
    ARGCHK 0, M_STR
    ARGCHK 1, M_INT
    cmpq $3, 0(%rsp)
    jne bsf_set_str
    ARGCHK 2, M_INT
    jmp bsf_set_str

bt_replace:                         /* STRING x 3 -> STRING */
    ARGCHK 0, M_STR
    ARGCHK 1, M_STR
    ARGCHK 2, M_STR
    jmp bsf_set_str

bt_concat:                          /* any types except FLOAT64 -> STRING */
    xor %r14d, %r14d
1:  cmp 0(%rsp), %r14
    jae bsf_set_str
    mov %r12, %rdi
    mov %r14d, %esi
    mov $(0xff & ~(1 << T_FLOAT)), %edx
    call arg_check
    inc %r14
    jmp 1b

bt_coalesce:                        /* common type of all arguments */
    xor %r13d, %r13d                /* T_NULL */
    xor %r14d, %r14d
1:  cmp 0(%rsp), %r14
    jae 2f
    mov N_A(%r12), %rax
    mov (%rax, %r14, 8), %rax
    mov N_TYPE(%rax), %esi
    mov %r13d, %edi
    call common_type
    mov %eax, %r13d
    inc %r14
    jmp 1b
2:  xor %r14d, %r14d
3:  cmp 0(%rsp), %r14
    jae 4f
    mov %r12, %rdi
    mov %r14d, %esi
    mov %r13d, %edx
    call arg_cast
    inc %r14
    jmp 3b
4:  mov %r13d, N_TYPE(%r12)
    jmp bsf_done

bt_nullif:                          /* comparable; result has the type of a */
    mov N_A(%r12), %rax
    mov (%rax), %rcx
    mov N_TYPE(%rcx), %r13d
    mov 8(%rax), %rcx
    mov N_TYPE(%rcx), %esi
    mov %r13d, %edi
    call check_comparable
    mov %r13d, N_TYPE(%r12)
    jmp bsf_done

bt_ymd:                             /* DATE or TIMESTAMP -> INT64 */
    ARGCHK 0, M_DT
    jmp bsf_set_int

bt_hms:                             /* TIMESTAMP -> INT64 */
    ARGCHK 0, M_TS
    jmp bsf_set_int

bt_date_trunc:                      /* (unit, DATE|TIMESTAMP) -> TIMESTAMP */
    mov %r12, %rdi
    call bind_unit
    mov %rax, N_V2(%r12)
    ARGCHK 1, M_DT
    ARGCAST 1, T_TS
    movl $T_TS, N_TYPE(%r12)
    jmp bsf_done

bt_date_diff:                       /* ('day', DATE|TS, DATE|TS) -> INT64 */
    mov %r12, %rdi
    call bind_unit
    mov %rax, N_V2(%r12)
    test %eax, %eax
    jz 1f
    cmp $UNIT_DAY, %eax
    jne bsf_bad_unit
1:  ARGCHK 1, M_DT
    ARGCHK 2, M_DT
    ARGCAST 1, T_DATE               /* only the date parts count */
    ARGCAST 2, T_DATE
    jmp bsf_set_int

bsf_bad_unit:
    RAISE E_INVALID_ARGUMENT, "DATE_DIFF supports only the 'day' unit"
bsf_unknown:
    mov N_B(%r12), %rdx
    add $PSTR_DATA, %rdx
    mov $E_SEMANTIC_ERROR, %edi
    CSTR %rsi, "unknown function '%s'"
    call pq_raisef
bsf_arity:
    RAISE E_SEMANTIC_ERROR, "wrong number of arguments"
ENDF bind_scalar_func

/* ================================================================ bind_special */

/* bind_special(B rdi, node rsi) -> rax: CASE / BETWEEN / IN list / LIKE */
FUNC bind_special
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    /* bind every child slot in place */
    mov %r12, %rdi
    call expr_nchild
    mov %rax, %r13
    xor %r14d, %r14d
1:  cmp %r13, %r14
    jae 2f
    mov %r12, %rdi
    mov %r14, %rsi
    call expr_child_ptr
    mov %rax, %r15
    mov (%r15), %rsi
    test %rsi, %rsi
    jz 11f
    mov %rbx, %rdi
    call bind_expr
    mov %rax, (%r15)
11: inc %r14
    jmp 1b
2:  movl $T_BOOL, N_TYPE(%r12)
    mov N_KIND(%r12), %eax
    cmp $EK_CASE, %eax
    je bsp_case
    cmp $EK_BETWEEN, %eax
    je bsp_between
    cmp $EK_INLIST, %eax
    je bsp_inlist
    cmp $EK_LIKE, %eax
    je bsp_like
    RAISE E_INTERNAL_ERROR, "bind_special: unexpected node"
bsp_done:
    mov %r12, %rax
    LEAVE

bsp_between:                        /* x >= low AND x <= high */
    mov N_A(%r12), %rax
    mov N_TYPE(%rax), %r13d
    mov N_B(%r12), %rax
    mov N_TYPE(%rax), %esi
    mov %r13d, %edi
    call check_comparable
    mov N_V1(%r12), %rax
    mov N_TYPE(%rax), %esi
    mov %r13d, %edi
    call check_comparable
    jmp bsp_done

bsp_inlist:                         /* x = item for every item */
    mov N_A(%r12), %rax
    mov N_TYPE(%rax), %r13d
    xor %r14d, %r14d
1:  cmp N_V1(%r12), %r14
    jae bsp_done
    mov N_B(%r12), %rax
    mov (%rax, %r14, 8), %rax
    mov N_TYPE(%rax), %esi
    mov %r13d, %edi
    call check_comparable
    inc %r14
    jmp 1b

bsp_like:                           /* STRING LIKE STRING */
    mov N_A(%r12), %rax
    movzbl N_TYPE(%rax), %ecx
    test %ecx, %ecx
    jz 1f
    cmp $T_STR, %ecx
    jne 9f
1:  mov N_B(%r12), %rax
    movzbl N_TYPE(%rax), %ecx
    test %ecx, %ecx
    jz bsp_done
    cmp $T_STR, %ecx
    je bsp_done
9:  call fn_type_error

bsp_case:
    mov N_V1(%r12), %r14            /* WHEN pairs */
    /* conditions: simple CASE compares x = v, searched CASE needs BOOLEAN */
    xor %r15d, %r15d
1:  cmp %r14, %r15
    jae 3f
    mov N_B(%r12), %rax
    mov %r15, %rcx
    shl $4, %rcx
    mov (%rax, %rcx), %rax          /* WHEN expression */
    mov N_TYPE(%rax), %esi
    mov N_A(%r12), %rcx
    test %rcx, %rcx
    jz 2f
    mov N_TYPE(%rcx), %edi
    call check_comparable
    jmp 21f
2:  movzbl %sil, %eax
    test %eax, %eax
    jz 21f
    cmp $T_BOOL, %eax
    je 21f
    RAISE E_TYPE_ERROR, "CASE WHEN condition must be BOOLEAN"
21: inc %r15
    jmp 1b
3:  /* result type: fold the THEN branches and ELSE */
    xor %r13d, %r13d                /* T_NULL */
    xor %r15d, %r15d
4:  cmp %r14, %r15
    jae 5f
    mov N_B(%r12), %rax
    mov %r15, %rcx
    shl $4, %rcx
    mov 8(%rax, %rcx), %rax         /* THEN expression */
    mov N_TYPE(%rax), %esi
    mov %r13d, %edi
    call common_type
    mov %eax, %r13d
    inc %r15
    jmp 4b
5:  mov N_V2(%r12), %rax
    test %rax, %rax
    jz 6f
    mov N_TYPE(%rax), %esi
    mov %r13d, %edi
    call common_type
    mov %eax, %r13d
6:  /* cast the branches to the result type */
    xor %r15d, %r15d
7:  cmp %r14, %r15
    jae 8f
    mov N_B(%r12), %rax
    mov %r15, %rcx
    shl $4, %rcx
    lea 8(%rax, %rcx), %rdi
    mov %r13d, %esi
    call slot_cast
    inc %r15
    jmp 7b
8:  cmpq $0, N_V2(%r12)
    je 9f
    lea N_V2(%r12), %rdi
    mov %r13d, %esi
    call slot_cast
9:  mov %r13d, N_TYPE(%r12)
    jmp bsp_done
ENDF bind_special

/* ================================================================ numeric kernels */

/* round_int(x rdi, n rsi) -> rax: ROUND of an INT64 to n digits (n < 0 rounds
 * to tens, hundreds, ... half away from zero) */
FUNC round_int
    mov %rdi, %rax
    test %rsi, %rsi
    jns 9f                          /* n >= 0: identity */
    neg %rsi                        /* k = -n */
    js 7f                           /* n = INT64_MIN */
    cmp $20, %rsi
    jae 7f                          /* |x| < 0.5 * 10^20 */
    mov %rdi, %r8
    sar $63, %r8                    /* sign mask */
    mov %rdi, %r9
    xor %r8, %r9
    sub %r8, %r9                    /* |x| as unsigned */
    cmp $19, %rsi
    je 5f
    lea pow10_u64(%rip), %rcx
    mov (%rcx, %rsi, 8), %rcx       /* p = 10^k */
    mov %r9, %rax
    xor %edx, %edx
    div %rcx                        /* q, r */
    mov %rcx, %r10
    sub %rdx, %r10
    cmp %r10, %rdx                  /* r >= p - r: round up */
    jb 1f
    inc %rax
1:  mul %rcx                        /* q * p */
    jc raise_overflow
    test %r8, %r8
    jnz 2f
    test %rax, %rax
    js raise_overflow
    ret
2:  movabs $0x8000000000000000, %r10
    cmp %r10, %rax
    ja raise_overflow
    neg %rax
    ret
5:  /* k = 19: the result is 0 or +-10^19 (out of range) */
    movabs $5000000000000000000, %r10
    cmp %r10, %r9
    jae raise_overflow
7:  xor %eax, %eax
9:  ret
ENDF round_int

/* round_dec(v rdi, s esi, n rdx) -> rax: ROUND of DECIMAL(p,s) unscaled v to
 * n digits; the result has scale max(0, min(n, s)) */
FUNC round_dec
    push %rbx
    mov %rdx, %rbx                  /* n */
    mov %esi, %eax                  /* s */
    cmp %rax, %rbx
    jge 8f                          /* n >= s: unchanged */
    cmp $-18, %rbx
    jl 7f
    mov %rax, %rcx
    sub %rbx, %rcx                  /* k = s - n digits dropped */
    cmp $18, %rcx
    jg 7f                           /* |v| < 10^18 rounds to 0 */
    mov %ecx, %esi
    xor %edx, %edx
    call dec_rescale                /* round(v / 10^k), half away from zero */
    test %rbx, %rbx
    jns 9f
    neg %rbx                        /* n < 0: back to scale 0 */
    lea pow10_u64(%rip), %rcx
    imul (%rcx, %rbx, 8), %rax
    jo raise_overflow
    mov %rax, %rbx
    mov %rax, %rdi
    mov $18, %esi
    call dec_fits
    test %eax, %eax
    jz raise_overflow
    mov %rbx, %rax
    jmp 9f
7:  xor %eax, %eax
    jmp 9f
8:  mov %rdi, %rax
9:  pop %rbx
    ret
ENDF round_dec

/* is_finite_rax: ZF=0 when the f64 bits in rax are finite (clobbers rcx) */
.macro FINITE_TEST reg
    mov \reg, %rcx
    shr $52, %rcx
    and $0x7ff, %ecx
    cmp $0x7ff, %ecx
.endm

/* round_float(x xmm0, n rdi) -> xmm0: round half away from zero to n digits */
FUNC round_float
    ENTER 16
    movsd %xmm0, 0(%rsp)            /* x */
    mov %rdi, %rbx
    test %rbx, %rbx
    js 5f
    cmp $400, %rbx
    jg 9f                           /* far below the precision of a double */
    cvtsi2sd %rbx, %xmm1
    movsd f64_ten(%rip), %xmm0
    call pow
    movsd %xmm0, 8(%rsp)            /* f = 10^n */
    mulsd 0(%rsp), %xmm0
    movq %xmm0, %rax
    FINITE_TEST %rax
    je 9f                           /* x * f overflows: x has no such digits */
    call round
    divsd 8(%rsp), %xmm0
    LEAVE
5:  neg %rbx
    js 6f
    cmp $400, %rbx
    jg 6f
    cvtsi2sd %rbx, %xmm1
    movsd f64_ten(%rip), %xmm0
    call pow
    movsd %xmm0, 8(%rsp)            /* f = 10^-n */
    movq %xmm0, %rax
    FINITE_TEST %rax
    je 6f
    movsd 0(%rsp), %xmm0
    divsd 8(%rsp), %xmm0
    call round
    mulsd 8(%rsp), %xmm0
    call check_finite
    LEAVE
6:  xorpd %xmm0, %xmm0
    LEAVE
9:  movsd 0(%rsp), %xmm0
    LEAVE
ENDF round_float

/* ================================================================ LIKE */

/* like_match(s pstr rdi, p pstr rsi) -> eax 1 if s matches pattern p.
 * '%' = any sequence, '_' = one code point, other bytes literal.  Greedy scan
 * that backtracks only to the most recent '%' (O(len(s) * len(p))). */
FUNC like_match
    push %rbx
    lea PSTR_DATA(%rdi), %r8        /* subject */
    mov PSTR_LEN(%rdi), %r9
    lea PSTR_DATA(%rsi), %r10       /* pattern */
    mov PSTR_LEN(%rsi), %r11
    xor %ecx, %ecx                  /* si */
    xor %edx, %edx                  /* pi */
    mov $-1, %rax                   /* pattern index after the last '%' */
    xor %edi, %edi                  /* subject index that '%' resumes from */
1:  cmp %r9, %rcx
    jae 6f
    cmp %r11, %rdx
    jae 4f
    movzbl (%r10, %rdx), %ebx
    cmp $'%', %bl
    jne 2f
    inc %rdx
    mov %rdx, %rax
    mov %rcx, %rdi
    jmp 1b
2:  cmp $'_', %bl
    jne 3f
    inc %rdx
    inc %rcx                        /* skip one code point */
21: cmp %r9, %rcx
    jae 1b
    movzbl (%r8, %rcx), %esi
    and $0xc0, %esi
    cmp $0x80, %esi
    jne 1b
    inc %rcx
    jmp 21b
3:  cmp (%r8, %rcx), %bl
    jne 4f
    inc %rcx
    inc %rdx
    jmp 1b
4:  /* mismatch: let the last '%' absorb one more code point */
    cmp $-1, %rax
    je 8f
    mov %rax, %rdx
    inc %rdi
41: cmp %r9, %rdi
    jae 42f
    movzbl (%r8, %rdi), %esi
    and $0xc0, %esi
    cmp $0x80, %esi
    jne 42f
    inc %rdi
    jmp 41b
42: mov %rdi, %rcx
    jmp 1b
6:  /* subject consumed: the rest of the pattern must be '%' only */
    cmp %r11, %rdx
    jae 7f
    cmpb $'%', (%r10, %rdx)
    jne 8f
    inc %rdx
    jmp 6b
7:  mov $1, %eax
    pop %rbx
    ret
8:  xor %eax, %eax
    pop %rbx
    ret
ENDF like_match

/* ================================================================ eval_scalar_func */

/* skip one UTF-8 code point: idx += 1, then past continuation bytes */
.macro CP_NEXT idx, len, data, tmp, tmp32
    inc \idx
1001:
    cmp \len, \idx
    jae 1002f
    movzbl (\data, \idx), \tmp32
    and $0xc0, \tmp32
    cmp $0x80, \tmp32
    jne 1002f
    inc \idx
    jmp 1001b
1002:
.endm

/* packed type of argument i of the node in rbx -> reg32 (clobbers rax) */
.macro ARGTYPE i, reg32
    mov N_A(%rbx), %rax
    mov (8 * \i)(%rax), %rax
    mov N_TYPE(%rax), \reg32
.endm

/* eval_scalar_func(node rdi, ctx rsi) -> rax payload, rdx null flag
 * registers: rbx node, r12 ctx; strict functions get their (non-NULL)
 * arguments in r13, r14, r15 */
FUNC eval_scalar_func
    STACK_CHECK
    ENTER 48
    mov %rdi, %rbx
    mov %rsi, %r12
    mov N_OP(%rbx), %eax
    cmp $F_CONCAT, %eax
    je ef_concat
    cmp $F_COALESCE, %eax
    je ef_coalesce
    cmp $F_NULLIF, %eax
    je ef_nullif
    /* strict functions: evaluate the arguments left to right; NULL => NULL */
    xor %r13d, %r13d
1:  cmp N_V1(%rbx), %r13
    jae 2f
    mov N_A(%rbx), %rax
    mov (%rax, %r13, 8), %rdi
    mov %r12, %rsi
    call eval
    test %rdx, %rdx
    jnz ef_null
    mov %rax, (%rsp, %r13, 8)
    inc %r13
    jmp 1b
2:  mov 0(%rsp), %r13
    mov 8(%rsp), %r14
    mov 16(%rsp), %r15
    mov N_OP(%rbx), %eax
    lea ef_jt(%rip), %rcx
    movslq -4(%rcx, %rax, 4), %rax
    add %rcx, %rax
    jmp *%rax

    .p2align 2
ef_jt:                              /* indexed by F_* - 1 */
    .long ef_sleep - ef_jt
    .long ef_abs - ef_jt
    .long ef_round - ef_jt
    .long ef_floor - ef_jt
    .long ef_ceil - ef_jt
    .long ef_sqrt - ef_jt
    .long ef_power - ef_jt
    .long ef_mod - ef_jt
    .long ef_length - ef_jt
    .long ef_upper - ef_jt
    .long ef_lower - ef_jt
    .long ef_substr - ef_jt
    .long ef_trim - ef_jt
    .long ef_ltrim - ef_jt
    .long ef_rtrim - ef_jt
    .long ef_replace - ef_jt
    .long ef_internal - ef_jt       /* CONCAT: not strict */
    .long ef_internal - ef_jt       /* COALESCE */
    .long ef_internal - ef_jt       /* NULLIF */
    .long ef_year - ef_jt
    .long ef_month - ef_jt
    .long ef_day - ef_jt
    .long ef_hour - ef_jt
    .long ef_minute - ef_jt
    .long ef_second - ef_jt
    .long ef_date_trunc - ef_jt
    .long ef_date_diff - ef_jt

ef_null:
    xor %eax, %eax
    mov $1, %edx
    LEAVE
ef_ret:                             /* non-NULL value in rax */
    xor %edx, %edx
    LEAVE
ef_internal:
    RAISE E_INTERNAL_ERROR, "bad scalar function id"
ef_invalid:
    RAISE E_INVALID_ARGUMENT, "invalid function argument"

/* ---------------------------------------------------------------- PQ_SLEEP */
ef_sleep:                           /* sleeps in 10 ms slices, checking the deadline */
    mov %r13, %r14                  /* remaining ms */
1:  test %r14, %r14
    jle 3f
    mov %r14, %rcx
    cmp $10, %rcx
    jbe 2f
    mov $10, %ecx
2:  sub %rcx, %r14
    imul $1000000, %rcx, %rcx
    movq $0, 0(%rsp)                /* struct timespec */
    mov %rcx, 8(%rsp)
    lea 0(%rsp), %rdi
    xor %esi, %esi
    call nanosleep
    call check_deadline
    jmp 1b
3:  mov %r13, %rax
    jmp ef_ret

/* ---------------------------------------------------------------- numeric */
ef_abs:
    mov %r13, %rax
    movzbl N_TYPE(%rbx), %ecx
    cmp $T_FLOAT, %ecx
    jne 1f
    btr $63, %rax
    jmp ef_ret
1:  mov N_TYPE(%rbx), %edi
    call dec_is_wide
    test %eax, %eax
    jnz 2f
    mov %r13, %rax
    test %rax, %rax                 /* INT64 / DECIMAL */
    jns ef_ret
    neg %rax
    jo raise_overflow
    jmp ef_ret
2:  mov %r13, %rax                  /* wide: |v| < 10^p cannot overflow */
    mov 8(%r13), %rsi
    test %rsi, %rsi
    jns ef_ret
    mov (%r13), %rdi
    neg %rdi
    adc $0, %rsi
    neg %rsi
    call dec_box
    jmp ef_ret

ef_round:
    cmpq $0, N_V3(%rbx)             /* ROUND(x, NULL) */
    jne ef_null
    ARGTYPE 0, %ecx
    movzbl %cl, %eax
    cmp $T_INT, %eax
    jne 1f
    mov %r13, %rdi
    mov N_V2(%rbx), %rsi
    call round_int
    jmp ef_ret
1:  cmp $T_DEC, %eax
    jne 2f
    mov %ecx, %edi
    call dec_is_wide
    mov %eax, 0(%rsp)
    ARGTYPE 0, %ecx
    mov %r13, %rdi
    shr $16, %ecx
    movzbl %cl, %esi
    mov N_V2(%rbx), %rdx
    cmpl $0, 0(%rsp)
    jnz 3f
    call round_dec
    jmp ef_ret
3:  call round_dec128
    jmp ef_ret
2:  movq %r13, %xmm0
    mov N_V2(%rbx), %rdi
    call round_float
    movq %xmm0, %rax
    jmp ef_ret

ef_floor:
    xor %r15d, %r15d
    jmp 1f
ef_ceil:
    mov $1, %r15d
1:  ARGTYPE 0, %ecx
    movzbl %cl, %eax
    cmp $T_FLOAT, %eax
    je 3f
    cmp $T_DEC, %eax
    mov %r13, %rax
    jne ef_ret                      /* INT64: unchanged */
    mov %ecx, 0(%rsp)
    mov %ecx, %edi
    call dec_is_wide
    mov 0(%rsp), %ecx
    test %eax, %eax
    jz 6f
    mov %r13, %rdi                  /* wide: DECIMAL(38,0) */
    shr $16, %ecx
    movzbl %cl, %esi
    mov %r15d, %edx
    call floor_dec128
    jmp ef_ret
6:  mov %r13, %rax
    /* DECIMAL(p,s) -> DECIMAL(18,0) */
    shr $16, %ecx
    movzbl %cl, %ecx
    lea pow10_u64(%rip), %rax
    mov (%rax, %rcx, 8), %rcx
    mov %r13, %rax
    cqo
    idiv %rcx                       /* truncates toward zero */
    test %r15d, %r15d
    jnz 2f
    test %rdx, %rdx
    jns ef_ret
    dec %rax
    jmp ef_ret
2:  test %rdx, %rdx
    jle ef_ret
    inc %rax
    jmp ef_ret
3:  movq %r13, %xmm0
    test %r15d, %r15d
    jnz 4f
    call floor
    jmp 5f
4:  call ceil
5:  movq %xmm0, %rax
    jmp ef_ret

ef_sqrt:
    movq %r13, %xmm0
    xorpd %xmm1, %xmm1
    ucomisd %xmm1, %xmm0
    jb 1f
    sqrtsd %xmm0, %xmm0
    movq %xmm0, %rax
    jmp ef_ret
1:  RAISE E_INVALID_ARGUMENT, "SQRT of a negative number"

ef_power:
    movq %r13, %xmm0                /* x */
    movq %r14, %xmm1                /* y */
    xorpd %xmm2, %xmm2
    ucomisd %xmm2, %xmm0
    jne 1f
    ucomisd %xmm2, %xmm1
    jb raise_divzero                /* 0 ^ negative */
1:  ucomisd %xmm2, %xmm0
    jae 2f
    movapd %xmm1, %xmm0             /* negative base: y must be integral */
    call floor
    movq %r14, %xmm1
    ucomisd %xmm1, %xmm0
    jne 3f
2:  movq %r13, %xmm0
    movq %r14, %xmm1
    call pow
    call check_finite
    movq %xmm0, %rax
    jmp ef_ret
3:  RAISE E_INVALID_ARGUMENT, "POWER of a negative base with a non-integral exponent"

ef_mod:                             /* same as a % b */
    test %r14, %r14
    jz raise_divzero
    xor %eax, %eax
    cmp $-1, %r14
    je ef_ret
    mov %r13, %rax
    cqo
    idiv %r14
    mov %rdx, %rax
    jmp ef_ret

/* ---------------------------------------------------------------- strings */
ef_length:                          /* code points = bytes that are not 10xxxxxx */
    mov PSTR_LEN(%r13), %rcx
    lea PSTR_DATA(%r13), %rsi
    xor %eax, %eax
1:  test %rcx, %rcx
    jz ef_ret
    movzbl (%rsi), %edx
    and $0xc0, %edx
    cmp $0x80, %edx
    je 2f
    inc %rax
2:  inc %rsi
    dec %rcx
    jmp 1b

/* UPPER / LOWER: ASCII letters are case-mapped, everything else is copied.
 * A word (maximal run of ASCII letters/digits and non-ASCII code points)
 * that contains non-ASCII characters is copied unchanged, so mixed words such
 * as 'Ünï' keep their spelling (functions.pqt expects UPPER('abc Ünï') =
 * 'ABC Ünï').  r14 = first letter of the range to flip, r15 = result. */
ef_upper:
    mov $'a', %r14d
    jmp 1f
ef_lower:
    mov $'A', %r14d
1:  mov PSTR_LEN(%r13), %rdi
    add $9, %rdi
    call tmp_alloc
    mov %rax, %r15
    mov PSTR_LEN(%r13), %rcx
    mov %rcx, PSTR_LEN(%r15)
    movb $0, PSTR_DATA(%r15, %rcx)
    xor %edx, %edx                  /* i */
2:  cmp %rcx, %rdx
    jae 6f
    /* r8 = end of the word starting at i, r9 = 1 if it must stay unchanged */
    mov %rdx, %r8
    xor %r9d, %r9d
21: cmp %rcx, %r8
    jae 23f
    movzbl PSTR_DATA(%r13, %r8), %eax
    cmp $0x80, %eax
    jb 22f
    mov $1, %r9d                    /* non-ASCII byte */
    inc %r8
    jmp 21b
22: mov %eax, %esi
    sub $'0', %esi
    cmp $9, %esi
    jbe 221f
    mov %eax, %esi
    or $0x20, %esi
    sub $'a', %esi
    cmp $25, %esi
    ja 23f
221: inc %r8
    jmp 21b
23: cmp %rdx, %r8
    jne 3f
    inc %r8                         /* a single non-word byte */
3:  cmp %r8, %rdx                   /* copy [i, r8) */
    jae 2b
    movzbl PSTR_DATA(%r13, %rdx), %eax
    test %r9d, %r9d
    jnz 4f
    mov %eax, %esi
    sub %r14d, %esi
    cmp $25, %esi
    ja 4f
    xor $0x20, %eax                 /* ASCII case flip */
4:  mov %al, PSTR_DATA(%r15, %rdx)
    inc %rdx
    jmp 3b
6:  mov %r15, %rax
    jmp ef_ret

ef_substr:                          /* r13 s, r14 start, r15 len (if given) */
    movabs $0x7fffffffffffffff, %r9 /* end position (exclusive) */
    cmpq $3, N_V1(%rbx)
    jne 1f
    test %r15, %r15
    js 9f
    mov %r14, %r9
    add %r15, %r9
    jno 1f
    movabs $0x7fffffffffffffff, %r9
1:  mov %r14, %r8                   /* first position: max(start, 1) */
    cmp $1, %r8
    jge 2f
    mov $1, %r8d
2:  lea PSTR_DATA(%r13), %rsi
    mov PSTR_LEN(%r13), %r10
    xor %ecx, %ecx                  /* byte index */
    mov $1, %edx                    /* code point position at rcx */
3:  cmp %r8, %rdx
    jge 4f
    cmp %r10, %rcx
    jae 4f
    CP_NEXT %rcx, %r10, %rsi, %rax, %eax
    inc %rdx
    jmp 3b
4:  mov %rcx, %r11                  /* start byte */
5:  cmp %r9, %rdx
    jge 6f
    cmp %r10, %rcx
    jae 6f
    CP_NEXT %rcx, %r10, %rsi, %rax, %eax
    inc %rdx
    jmp 5b
6:  lea (%rsi, %r11), %rdi
    mov %rcx, %rsi
    sub %r11, %rsi
    call pstr_tmp
    jmp ef_ret
9:  RAISE E_INVALID_ARGUMENT, "SUBSTR length must not be negative"

ef_trim:                            /* r14 = strip leading, r15 = strip trailing */
    mov $1, %r14d
    mov $1, %r15d
    jmp 1f
ef_ltrim:
    mov $1, %r14d
    xor %r15d, %r15d
    jmp 1f
ef_rtrim:
    xor %r14d, %r14d
    mov $1, %r15d
1:  lea PSTR_DATA(%r13), %rdi
    mov PSTR_LEN(%r13), %rsi
    test %r14d, %r14d
    jz 3f
2:  test %rsi, %rsi
    jz 3f
    cmpb $' ', (%rdi)
    jne 3f
    inc %rdi
    dec %rsi
    jmp 2b
3:  test %r15d, %r15d
    jz 5f
4:  test %rsi, %rsi
    jz 5f
    cmpb $' ', -1(%rdi, %rsi)
    jne 5f
    dec %rsi
    jmp 4b
5:  call pstr_tmp
    jmp ef_ret

/* REPLACE(s r13, from r14, to r15); locals: 0 result, 8 output length so far,
 * 16 scan position in s, 24 match count / match pointer, 32 result length */
ef_replace:
    mov %r13, %rax
    cmpq $0, PSTR_LEN(%r14)
    je ef_ret                       /* from = '' */
    movq $0, 24(%rsp)
    movq $0, 16(%rsp)
1:  call rp_find                    /* pass 1: count matches */
    test %rax, %rax
    jz 2f
    incq 24(%rsp)
    sub %r13, %rax
    sub $PSTR_DATA, %rax
    add PSTR_LEN(%r14), %rax
    mov %rax, 16(%rsp)
    jmp 1b
2:  mov PSTR_LEN(%r15), %rax        /* len + count * (len(to) - len(from)) */
    sub PSTR_LEN(%r14), %rax
    imul 24(%rsp), %rax
    add PSTR_LEN(%r13), %rax
    mov %rax, 32(%rsp)
    lea 9(%rax), %rdi
    call tmp_alloc
    mov %rax, 0(%rsp)
    mov 32(%rsp), %rcx
    mov %rcx, PSTR_LEN(%rax)
    movb $0, PSTR_DATA(%rax, %rcx)
    movq $0, 8(%rsp)
    movq $0, 16(%rsp)
3:  call rp_find                    /* pass 2: copy */
    test %rax, %rax
    jz 4f
    mov %rax, 24(%rsp)
    lea PSTR_DATA(%r13), %rsi       /* s[pos .. match) */
    add 16(%rsp), %rsi
    mov %rax, %rdx
    sub %rsi, %rdx
    call rp_put
    lea PSTR_DATA(%r15), %rsi       /* replacement */
    mov PSTR_LEN(%r15), %rdx
    call rp_put
    mov 24(%rsp), %rax
    sub %r13, %rax
    sub $PSTR_DATA, %rax
    add PSTR_LEN(%r14), %rax
    mov %rax, 16(%rsp)
    jmp 3b
4:  lea PSTR_DATA(%r13), %rsi       /* tail */
    add 16(%rsp), %rsi
    mov PSTR_LEN(%r13), %rdx
    sub 16(%rsp), %rdx
    call rp_put
    mov 0(%rsp), %rax
    jmp ef_ret

/* ---------------------------------------------------------------- CONCAT */
ef_concat:                          /* r15 piece array, r14 total length */
    mov N_V1(%rbx), %rdi
    shl $3, %rdi
    call tmp_alloc
    mov %rax, %r15
    xor %r13d, %r13d
    xor %r14d, %r14d
1:  cmp N_V1(%rbx), %r13
    jae 3f
    mov N_A(%rbx), %rax
    mov (%rax, %r13, 8), %rdi
    mov %r12, %rsi
    call eval
    movq $0, (%r15, %r13, 8)
    test %rdx, %rdx
    jnz 2f                          /* NULL arguments are skipped */
    mov N_A(%rbx), %rcx
    mov (%rcx, %r13, 8), %rcx
    mov N_TYPE(%rcx), %edi
    movzbl %dil, %ecx
    cmp $T_STR, %ecx
    je 11f
    mov %rax, %rsi                  /* canonical text form (CAST to STRING) */
    call fmt_to_pstr
11: mov %rax, (%r15, %r13, 8)
    add PSTR_LEN(%rax), %r14
2:  inc %r13
    jmp 1b
3:  lea 9(%r14), %rdi
    call tmp_alloc
    mov %rax, 0(%rsp)
    mov %r14, PSTR_LEN(%rax)
    movb $0, PSTR_DATA(%rax, %r14)
    lea PSTR_DATA(%rax), %r14       /* output cursor */
    xor %r13d, %r13d
4:  cmp N_V1(%rbx), %r13
    jae 6f
    mov (%r15, %r13, 8), %rsi
    test %rsi, %rsi
    jz 5f
    mov PSTR_LEN(%rsi), %rdx
    mov %rdx, 8(%rsp)
    add $PSTR_DATA, %rsi
    mov %r14, %rdi
    call memcpy
    add 8(%rsp), %r14
5:  inc %r13
    jmp 4b
6:  mov 0(%rsp), %rax
    jmp ef_ret

/* ---------------------------------------------------------------- COALESCE / NULLIF */
ef_coalesce:
    xor %r13d, %r13d
1:  cmp N_V1(%rbx), %r13
    jae ef_null
    mov N_A(%rbx), %rax
    mov (%rax, %r13, 8), %rdi
    mov %r12, %rsi
    call eval
    test %rdx, %rdx
    jz ef_ret
    inc %r13
    jmp 1b

ef_nullif:                          /* NULL if a = b is TRUE, else a */
    mov N_A(%rbx), %rax
    mov (%rax), %rdi
    mov %r12, %rsi
    call eval
    test %rdx, %rdx
    jnz ef_null
    mov %rax, %r13
    mov N_A(%rbx), %rax
    mov 8(%rax), %rdi
    mov %r12, %rsi
    call eval
    test %rdx, %rdx
    jnz 1f
    mov %rax, %r14
    ARGTYPE 1, %r15d
    ARGTYPE 0, %edi
    mov %r13, %rsi
    mov %r15d, %edx
    mov %r14, %rcx
    call cmp_mixed
    test %eax, %eax
    jz ef_null
1:  mov %r13, %rax
    jmp ef_ret

/* ---------------------------------------------------------------- dates */
ef_year:
    xor %r14d, %r14d
    jmp 1f
ef_month:
    mov $1, %r14d
    jmp 1f
ef_day:
    mov $2, %r14d
1:  mov %r13, %rdi                  /* days */
    ARGTYPE 0, %ecx
    movzbl %cl, %ecx
    cmp $T_TS, %ecx
    jne 2f
    mov $US_PER_DAY, %rsi
    call floordiv
    mov %rax, %rdi
2:  call civil_from_days            /* rax y, rdx m, rcx d */
    cmp $1, %r14d
    cmove %rdx, %rax
    cmp $2, %r14d
    cmove %rcx, %rax
    jmp ef_ret

ef_hour:
    mov $US_PER_HOUR, %r14
    jmp 1f
ef_minute:
    mov $US_PER_MIN, %r14
    jmp 1f
ef_second:
    mov $US_PER_SEC, %r14
1:  mov %r13, %rdi
    mov $US_PER_DAY, %rsi
    call floordiv                   /* rdx = microseconds into the day */
    mov %rdx, %rax
    xor %edx, %edx
    div %r14
    xor %edx, %edx                  /* field = (us / unit) mod 60 (hours < 24) */
    mov $60, %ecx
    div %rcx
    mov %rdx, %rax
    jmp ef_ret

ef_date_trunc:                      /* r14 TIMESTAMP */
    mov N_V2(%rbx), %r15            /* unit */
    test %r15, %r15
    jz ef_null
    mov $US_PER_HOUR, %rsi
    cmp $UNIT_HOUR, %r15
    je 2f
    mov $US_PER_MIN, %rsi
    cmp $UNIT_MINUTE, %r15
    je 2f
    mov $US_PER_DAY, %rsi
    cmp $UNIT_DAY, %r15
    je 2f
    mov %r14, %rdi                  /* year / month: via the civil date */
    call floordiv
    mov %rax, %rdi
    call civil_from_days
    mov %eax, %edi
    mov %edx, %esi
    cmp $UNIT_YEAR, %r15
    jne 1f
    mov $1, %esi
1:  mov $1, %edx
    call days_from_civil
    mov $US_PER_DAY, %rcx
    imul %rcx, %rax
    jmp ef_ret
2:  mov %rsi, %r13                  /* floor to a multiple of the unit */
    mov %r14, %rdi
    call floordiv
    imul %r13, %rax
    jmp ef_ret

ef_date_diff:                       /* both arguments are DATEs (days) */
    mov %r15, %rax
    sub %r14, %rax
    jmp ef_ret
ENDF eval_scalar_func

/* rp_find(): REPLACE helper running on eval_scalar_func's frame (its locals
 * are at 8(%rsp) here): rax = memmem(s + pos, len - pos, from) or 0 */
rp_find:
    sub $8, %rsp
    lea PSTR_DATA(%r13), %rdi
    add 32(%rsp), %rdi              /* frame 16(%rsp): pos */
    mov PSTR_LEN(%r13), %rsi
    sub 32(%rsp), %rsi
    lea PSTR_DATA(%r14), %rdx
    mov PSTR_LEN(%r14), %rcx
    call memmem
    add $8, %rsp
    ret

/* rp_put(src rsi, n rdx): REPLACE helper appending n bytes to the result */
rp_put:
    sub $8, %rsp
    mov 16(%rsp), %rdi              /* frame 0(%rsp): result */
    add $PSTR_DATA, %rdi
    add 24(%rsp), %rdi              /* frame 8(%rsp): output length */
    add %rdx, 24(%rsp)
    call memcpy
    add $8, %rsp
    ret

/* ================================================================ eval_special */

/* eval_special(node rdi, ctx rsi) -> rax payload, rdx null flag
 * registers: rbx node, r12 ctx */
FUNC eval_special
    STACK_CHECK
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov N_KIND(%rbx), %eax
    cmp $EK_CASE, %eax
    je es_case
    cmp $EK_BETWEEN, %eax
    je es_between
    cmp $EK_INLIST, %eax
    je es_inlist
    cmp $EK_LIKE, %eax
    je es_like
    RAISE E_INTERNAL_ERROR, "eval_special: unexpected node"

es_null:
    xor %eax, %eax
    mov $1, %edx
    LEAVE
es_false:
    xor %eax, %eax
es_bool:                            /* eax 0/1, negated for NOT forms */
    xor N_OP(%rbx), %eax
    and $1, %eax
    xor %edx, %edx
    LEAVE
es_true:
    mov $1, %eax
    jmp es_bool

/* eval child slot: ES_EVAL field -> rax, rdx */
.macro ES_EVAL field
    mov \field(%rbx), %rdi
    mov %r12, %rsi
    call eval
.endm

es_like:
    ES_EVAL N_A
    test %rdx, %rdx
    jnz es_null
    mov %rax, %r13
    ES_EVAL N_B
    test %rdx, %rdx
    jnz es_null
    mov %r13, %rdi
    mov %rax, %rsi
    call like_match
    jmp es_bool

/* x BETWEEN low AND high = x >= low AND x <= high (three-valued) */
es_between:
    ES_EVAL N_A
    test %rdx, %rdx
    jnz es_null
    mov %rax, %r13                  /* x */
    xor %r14d, %r14d                /* 1 = some comparison was NULL */
    ES_EVAL N_B
    test %rdx, %rdx
    jz 1f
    mov $1, %r14d
    jmp 2f
1:  mov %rax, %rcx
    mov N_A(%rbx), %rax
    mov N_TYPE(%rax), %edi
    mov %r13, %rsi
    mov N_B(%rbx), %rax
    mov N_TYPE(%rax), %edx
    call cmp_mixed
    test %eax, %eax
    js es_false                     /* x < low */
2:  ES_EVAL N_V1
    test %rdx, %rdx
    jz 3f
    mov $1, %r14d
    jmp 4f
3:  mov %rax, %rcx
    mov N_A(%rbx), %rax
    mov N_TYPE(%rax), %edi
    mov %r13, %rsi
    mov N_V1(%rbx), %rax
    mov N_TYPE(%rax), %edx
    call cmp_mixed
    test %eax, %eax
    jg es_false                     /* x > high */
4:  test %r14d, %r14d
    jnz es_null
    jmp es_true

/* x IN (e1, ..): TRUE if some ei = x; else NULL if x or some ei is NULL */
es_inlist:
    ES_EVAL N_A
    test %rdx, %rdx
    jnz es_null
    mov %rax, %r13                  /* x */
    xor %r14d, %r14d                /* item index */
    xor %r15d, %r15d                /* NULL item seen */
1:  cmp N_V1(%rbx), %r14
    jae 3f
    mov N_B(%rbx), %rax
    mov (%rax, %r14, 8), %rdi
    mov %r12, %rsi
    call eval
    test %rdx, %rdx
    jz 2f
    mov $1, %r15d
    jmp 21f
2:  mov %rax, %rcx
    mov N_B(%rbx), %rax
    mov (%rax, %r14, 8), %rax
    mov N_TYPE(%rax), %edx
    mov N_A(%rbx), %rax
    mov N_TYPE(%rax), %edi
    mov %r13, %rsi
    call cmp_mixed
    test %eax, %eax
    jz es_true
21: inc %r14
    jmp 1b
3:  test %r15d, %r15d
    jnz es_null
    jmp es_false

/* CASE: r13/r14 operand value/null flag (simple CASE), r15 pair index */
es_case:
    cmpq $0, N_A(%rbx)
    je 1f
    ES_EVAL N_A
    mov %rax, %r13
    mov %rdx, %r14
1:  xor %r15d, %r15d
2:  cmp N_V1(%rbx), %r15
    jae 6f
    mov N_B(%rbx), %rax
    mov %r15, %rcx
    shl $4, %rcx
    mov (%rax, %rcx), %rdi          /* WHEN expression */
    mov %r12, %rsi
    call eval
    test %rdx, %rdx
    jnz 5f                          /* NULL is not TRUE / never equal */
    cmpq $0, N_A(%rbx)
    jne 3f
    test %rax, %rax                 /* searched CASE: condition TRUE? */
    jnz 4f
    jmp 5f
3:  test %r14, %r14                 /* simple CASE: operand = value? */
    jnz 5f
    mov %rax, %rcx
    mov N_B(%rbx), %rax
    mov %r15, %rdx
    shl $4, %rdx
    mov (%rax, %rdx), %rax
    mov N_TYPE(%rax), %edx
    mov N_A(%rbx), %rax
    mov N_TYPE(%rax), %edi
    mov %r13, %rsi
    call cmp_mixed
    test %eax, %eax
    jnz 5f
4:  mov N_B(%rbx), %rax             /* matched: THEN expression */
    mov %r15, %rcx
    shl $4, %rcx
    mov 8(%rax, %rcx), %rdi
    mov %r12, %rsi
    call eval
    LEAVE
5:  inc %r15
    jmp 2b
6:  cmpq $0, N_V2(%rbx)
    je es_null
    ES_EVAL N_V2
    LEAVE
ENDF eval_special
