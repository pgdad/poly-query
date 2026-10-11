/*
 * binder.S - semantic analysis: name resolution, type checking, implicit
 * numeric promotions, aggregate validation, output naming, ORDER BY
 * resolution and constant LIMIT/OFFSET evaluation.  Produces the query plan
 * (QP_*) consumed by the executor.
 *
 *   bind_select(SelectStmt*) -> rax plan*
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

/* binder state */
#define BS_TABLE    0
#define BS_RANGE    8
#define BS_AGGS     16   /* Vec* */
#define BS_COLSEEN  24   /* column reference outside an aggregate seen */
#define BS_INAGG    32
#define BS_ALLOWAGG 40
#define BS_NOCOLS   48   /* constant context (LIMIT/OFFSET) */
#define BS_SIZE     56

    .section .rodata
/* allowed CAST targets per source kind (bit k = target kind k allowed) */
cast_matrix:
    .byte 0xFE      /* NULL  -> anything */
    .byte 0x26      /* BOOL  -> BOOL, INT, STR */
    .byte 0x3E      /* INT   -> BOOL, INT, FLOAT, DEC, STR */
    .byte 0x3C      /* FLOAT -> INT, FLOAT, DEC, STR */
    .byte 0x3C      /* DEC   -> INT, FLOAT, DEC, STR */
    .byte 0xFE      /* STR   -> anything */
    .byte 0xE0      /* DATE  -> STR, DATE, TS */
    .byte 0xE0      /* TS    -> STR, DATE, TS */

/* phase-2 scalar function names: recognised, reported as UNSUPPORTED */
phase2_funcs:
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

agg_names:
    .asciz "COUNT"
    .asciz "SUM"
    .asciz "AVG"
    .asciz "MIN"
    .asciz "MAX"
    .byte 0
agg_ids:
    .byte AGG_COUNT, AGG_SUM, AGG_AVG, AGG_MIN, AGG_MAX

    .text

/* name_index(pstr rdi, table rsi) -> eax index of pstr in a NUL-separated name list, or -1 */
FUNC name_index
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r13d, %r13d
1:  cmpb $0, (%r12)
    je 8f
    lea 8(%rbx), %rdi
    mov (%rbx), %rsi
    mov %r12, %rdx
    call cstr_ieq
    test %eax, %eax
    jnz 9f
    mov %r12, %rdi
    call strlen
    lea 1(%r12, %rax), %r12
    inc %r13d
    jmp 1b
8:  mov $-1, %r13d
9:  mov %r13d, %eax
    LEAVE
ENDF name_index

/* is_numeric(kind edi) -> eax */
FUNC is_numeric
    xor %eax, %eax
    cmp $T_INT, %edi
    je 1f
    cmp $T_FLOAT, %edi
    je 1f
    cmp $T_DEC, %edi
    jne 2f
1:  mov $1, %eax
2:  ret
ENDF is_numeric

/* wrap_cast(node rdi, type esi) -> rax new implicit CAST node */
FUNC wrap_cast
    push %rbx
    push %r12
    sub $8, %rsp
    mov %rdi, %rbx
    mov %esi, %r12d
    mov $N_SIZE, %edi
    call tmp_zalloc
    movl $EK_CAST, N_KIND(%rax)
    mov %rbx, N_A(%rax)
    mov %r12d, N_TYPE(%rax)
    mov %r12, N_V1(%rax)
    mov N_LINE(%rbx), %ecx
    mov %ecx, N_LINE(%rax)
    mov N_COL(%rbx), %ecx
    mov %ecx, N_COL(%rax)
    add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF wrap_cast

bind_type_error:
    RAISE E_TYPE_ERROR, "operand types are incompatible"

/* bind_expr(B rdi, node rsi) -> rax bound node (may be a replacement) */
FUNC bind_expr
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov N_KIND(%r12), %eax
    cmp $EK_LIT, %eax
    je be_lit
    cmp $EK_COL, %eax
    je be_col
    cmp $EK_UNARY, %eax
    je be_unary
    cmp $EK_BINARY, %eax
    je be_binary
    cmp $EK_ISNULL, %eax
    je be_isnull
    cmp $EK_CAST, %eax
    je be_cast
    cmp $EK_FUNC, %eax
    je be_func
    RAISE E_INTERNAL_ERROR, "unknown expression node"

be_done:
    mov %r12, %rax
    LEAVE

be_lit:
    testl $NF_MINLIT, N_FLAGS(%r12)
    jz be_done
    RAISE E_NUMERIC_OVERFLOW, "integer literal out of range"

/* ---------------------------------------------------------------- column */
be_col:
    cmpq $0, BS_NOCOLS(%rbx)
    jne be_col_nonconst
    mov BS_TABLE(%rbx), %r13
    test %r13, %r13
    jz be_col_unknown
    mov N_A(%r12), %rdi
    test %rdi, %rdi
    jz 1f
    mov BS_RANGE(%rbx), %rsi
    call pstr_ieq
    test %eax, %eax
    jz be_col_badqual
1:  xor %r14d, %r14d
    mov TB_COLS(%r13), %r15
2:  cmp TB_NCOLS(%r13), %r14
    jae be_col_unknown
    mov COL_NAME(%r15), %rdi
    mov N_B(%r12), %rsi
    call pstr_ieq
    test %eax, %eax
    jnz 3f
    inc %r14
    add $COL_SIZE, %r15
    jmp 2b
3:  mov %r14, N_V1(%r12)
    mov COL_TYPE(%r15), %eax
    mov %eax, N_TYPE(%r12)
    cmpq $0, BS_INAGG(%rbx)
    jne be_done
    movq $1, BS_COLSEEN(%rbx)
    jmp be_done
be_col_unknown:
    mov N_B(%r12), %rdx
    add $8, %rdx
    mov $E_SEMANTIC_ERROR, %edi
    CSTR %rsi, "unknown column '%s'"
    call pq_raisef
be_col_badqual:
    mov N_A(%r12), %rdx
    add $8, %rdx
    mov $E_SEMANTIC_ERROR, %edi
    CSTR %rsi, "unknown table or alias '%s'"
    call pq_raisef
be_col_nonconst:
    RAISE E_SEMANTIC_ERROR, "LIMIT/OFFSET must be constant expressions"

/* ---------------------------------------------------------------- unary */
be_unary:
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    call bind_expr
    mov %rax, N_A(%r12)
    movzbl N_TYPE(%rax), %ecx
    cmpl $U_NOT, N_OP(%r12)
    jne 2f
    cmp $T_NULL, %ecx
    je 1f
    cmp $T_BOOL, %ecx
    jne bind_type_error
1:  movl $T_BOOL, N_TYPE(%r12)
    jmp be_done
2:  /* unary +/- : numeric */
    cmp $T_NULL, %ecx
    jne 3f
    movl $T_INT, N_TYPE(%r12)
    jmp be_done
3:  mov %ecx, %edi
    call is_numeric
    test %eax, %eax
    jz bind_type_error
    mov N_A(%r12), %rax
    mov N_TYPE(%rax), %eax
    mov %eax, N_TYPE(%r12)
    jmp be_done

/* ---------------------------------------------------------------- IS NULL */
be_isnull:
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    call bind_expr
    mov %rax, N_A(%r12)
    movl $T_BOOL, N_TYPE(%r12)
    jmp be_done

/* ---------------------------------------------------------------- CAST */
be_cast:
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    call bind_expr
    mov %rax, N_A(%r12)
    movzbl N_TYPE(%rax), %ecx       /* source kind */
    mov N_V1(%r12), %rdx
    movzbl %dl, %edx                /* target kind */
    lea cast_matrix(%rip), %rax
    movzbl (%rax, %rcx), %eax
    bt %edx, %eax
    jnc bind_type_error
    mov N_V1(%r12), %rax
    mov %eax, N_TYPE(%r12)
    jmp be_done

/* ---------------------------------------------------------------- binary */
be_binary:
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    call bind_expr
    mov %rax, N_A(%r12)
    mov %rbx, %rdi
    mov N_B(%r12), %rsi
    call bind_expr
    mov %rax, N_B(%r12)
    mov N_A(%r12), %rax
    mov N_TYPE(%rax), %r13d         /* left type */
    mov N_B(%r12), %rax
    mov N_TYPE(%rax), %r14d         /* right type */
    movzbl %r13b, %r8d              /* lk */
    movzbl %r14b, %r9d              /* rk */
    mov N_OP(%r12), %eax
    cmp $B_AND, %eax
    je bb_logic
    cmp $B_OR, %eax
    je bb_logic
    cmp $B_CONCAT, %eax
    je bb_concat
    cmp $B_EQ, %eax
    jb bb_arith
    /* ------------- comparison */
    movl $T_BOOL, N_TYPE(%r12)
    cmp $T_NULL, %r8d
    je be_done
    cmp $T_NULL, %r9d
    je be_done
    mov %r8d, %edi
    call is_numeric
    mov %eax, %r15d
    mov %r9d, %edi
    call is_numeric
    and %eax, %r15d
    movzbl %r13b, %r8d
    movzbl %r14b, %r9d
    test %r15d, %r15d
    jz bc_nonnum
    cmp %r8d, %r9d
    je be_done                      /* same numeric kind (DEC scales aligned at runtime) */
    cmp $T_FLOAT, %r8d
    je bc_cast_right_float
    cmp $T_FLOAT, %r9d
    je bc_cast_left_float
    /* INT vs DEC */
    cmp $T_INT, %r8d
    jne 1f
    mov %r14d, %esi                 /* left INT -> DEC(18, s_right) */
    and $0xff0000, %esi
    or $MKDEC(18, 0), %esi
    mov N_A(%r12), %rdi
    call wrap_cast
    mov %rax, N_A(%r12)
    jmp be_done
1:  mov %r13d, %esi                 /* right INT -> DEC(18, s_left) */
    and $0xff0000, %esi
    or $MKDEC(18, 0), %esi
    mov N_B(%r12), %rdi
    call wrap_cast
    mov %rax, N_B(%r12)
    jmp be_done
bc_cast_right_float:
    mov N_B(%r12), %rdi
    mov $T_FLOAT, %esi
    call wrap_cast
    mov %rax, N_B(%r12)
    jmp be_done
bc_cast_left_float:
    mov N_A(%r12), %rdi
    mov $T_FLOAT, %esi
    call wrap_cast
    mov %rax, N_A(%r12)
    jmp be_done
bc_nonnum:
    cmp %r8d, %r9d
    je be_done
    cmp $T_DATE, %r8d
    jne 2f
    cmp $T_TS, %r9d
    jne bind_type_error
    mov N_A(%r12), %rdi
    mov $T_TS, %esi
    call wrap_cast
    mov %rax, N_A(%r12)
    jmp be_done
2:  cmp $T_TS, %r8d
    jne bind_type_error
    cmp $T_DATE, %r9d
    jne bind_type_error
    mov N_B(%r12), %rdi
    mov $T_TS, %esi
    call wrap_cast
    mov %rax, N_B(%r12)
    jmp be_done

bb_logic:
    cmp $T_NULL, %r8d
    je 1f
    cmp $T_BOOL, %r8d
    jne bind_type_error
1:  cmp $T_NULL, %r9d
    je 2f
    cmp $T_BOOL, %r9d
    jne bind_type_error
2:  movl $T_BOOL, N_TYPE(%r12)
    jmp be_done

bb_concat:
    cmp $T_NULL, %r8d
    je 1f
    cmp $T_STR, %r8d
    jne bind_type_error
1:  cmp $T_NULL, %r9d
    je 2f
    cmp $T_STR, %r9d
    jne bind_type_error
2:  movl $T_STR, N_TYPE(%r12)
    jmp be_done

/* ------------- arithmetic + - * / % */
bb_arith:
    /* operands must be numeric or NULL */
    cmp $T_NULL, %r8d
    je 1f
    mov %r8d, %edi
    call is_numeric
    test %eax, %eax
    jz bind_type_error
1:  cmp $T_NULL, %r9d
    je 2f
    mov %r9d, %edi
    call is_numeric
    test %eax, %eax
    jz bind_type_error
2:  /* effective types: a NULL operand takes the other side's type */
    movzbl %r13b, %r8d
    movzbl %r14b, %r9d
    mov %r13d, 0(%rsp)              /* left effective type */
    mov %r14d, 4(%rsp)              /* right effective type */
    cmp $T_NULL, %r8d
    jne 3f
    mov %r14d, 0(%rsp)
3:  cmp $T_NULL, %r9d
    jne 4f
    mov %r13d, 4(%rsp)
4:  cmp $T_NULL, %r8d
    jne 5f
    cmp $T_NULL, %r9d
    jne 5f
    movl $T_INT, 0(%rsp)
    movl $T_INT, 4(%rsp)
5:  movzbl 0(%rsp), %r8d            /* lk (effective) */
    movzbl 4(%rsp), %r9d            /* rk (effective) */
    mov N_OP(%r12), %r10d
    cmp $T_INT, %r8d
    jne 6f
    cmp $T_INT, %r9d
    jne 6f
    movl $T_INT, N_TYPE(%r12)
    jmp be_done
6:  cmp $T_FLOAT, %r8d
    je ba_float
    cmp $T_FLOAT, %r9d
    je ba_float
    /* decimal arithmetic */
    cmp $B_MOD, %r10d
    je bind_type_error
    cmp $B_DIV, %r10d
    je ba_float
    /* scales: INT side adopts the other side's scale */
    mov 0(%rsp), %eax
    shr $16, %eax
    and $0xff, %eax
    mov %eax, 8(%rsp)               /* s1 */
    mov 4(%rsp), %eax
    shr $16, %eax
    and $0xff, %eax
    mov %eax, 12(%rsp)              /* s2 */
    cmp $T_INT, %r8d
    jne 7f
    mov 12(%rsp), %eax
    mov %eax, 8(%rsp)
    movzbl %r13b, %ecx
    cmp $T_NULL, %ecx
    je 7f
    mov 12(%rsp), %esi
    shl $16, %esi
    or $MKDEC(18, 0), %esi
    mov N_A(%r12), %rdi
    call wrap_cast
    mov %rax, N_A(%r12)
7:  cmp $T_INT, %r9d
    jne 8f
    mov 8(%rsp), %eax
    mov %eax, 12(%rsp)
    movzbl %r14b, %ecx
    cmp $T_NULL, %ecx
    je 8f
    mov 8(%rsp), %esi
    shl $16, %esi
    or $MKDEC(18, 0), %esi
    mov N_B(%r12), %rdi
    call wrap_cast
    mov %rax, N_B(%r12)
8:  mov 8(%rsp), %eax
    mov 12(%rsp), %ecx
    cmpl $B_MUL, N_OP(%r12)
    je 9f
    cmp %ecx, %eax                  /* + - : max scale */
    cmovb %ecx, %eax
    jmp 10f
9:  add %ecx, %eax                  /* * : s1 + s2 */
    cmp $18, %eax
    ja bind_type_error
10: shl $16, %eax
    or $MKDEC(18, 0), %eax
    mov %eax, N_TYPE(%r12)
    jmp be_done

ba_float:
    cmpl $B_MOD, N_OP(%r12)
    je bind_type_error
    movl $T_FLOAT, N_TYPE(%r12)
    movzbl %r13b, %ecx
    cmp $T_FLOAT, %ecx
    je 1f
    cmp $T_NULL, %ecx
    je 1f
    mov N_A(%r12), %rdi
    mov $T_FLOAT, %esi
    call wrap_cast
    mov %rax, N_A(%r12)
1:  movzbl %r14b, %ecx
    cmp $T_FLOAT, %ecx
    je be_done
    cmp $T_NULL, %ecx
    je be_done
    mov N_B(%r12), %rdi
    mov $T_FLOAT, %esi
    call wrap_cast
    mov %rax, N_B(%r12)
    jmp be_done

/* ---------------------------------------------------------------- functions */
be_func:
    mov N_B(%r12), %rdi
    lea agg_names(%rip), %rsi
    call name_index
    cmp $-1, %eax
    jne bf_agg
    mov N_B(%r12), %rdi
    add $8, %rdi
    CSTR %rsi, "PQ_SLEEP"
    call strcasecmp
    test %eax, %eax
    jnz bf_other
    cmpq $0, g_test_functions(%rip)
    je bf_unknown
    testl $(NF_STAR | NF_DISTINCT), N_FLAGS(%r12)
    jnz bf_arity
    cmpq $1, N_V1(%r12)
    jne bf_arity
    movl $F_PQ_SLEEP, N_OP(%r12)
    mov N_A(%r12), %r13
    mov %rbx, %rdi
    mov (%r13), %rsi
    call bind_expr
    mov %rax, (%r13)
    movzbl N_TYPE(%rax), %ecx
    cmp $T_INT, %ecx
    je 1f
    cmp $T_NULL, %ecx
    jne bind_type_error
1:  movl $T_INT, N_TYPE(%r12)
    jmp be_done
bf_other:
    mov N_B(%r12), %rdi
    lea phase2_funcs(%rip), %rsi
    call name_index
    cmp $-1, %eax
    je bf_unknown
    RAISE E_UNSUPPORTED, "function not supported by this engine"
bf_unknown:
    mov N_B(%r12), %rdx
    add $8, %rdx
    mov $E_SEMANTIC_ERROR, %edi
    CSTR %rsi, "unknown function '%s'"
    call pq_raisef
bf_arity:
    RAISE E_SEMANTIC_ERROR, "wrong number of arguments"

bf_agg:
    lea agg_ids(%rip), %rcx
    movzbl (%rcx, %rax), %r13d      /* AGG_* */
    cmpq $0, BS_ALLOWAGG(%rbx)
    je bf_agg_notallowed
    cmpq $0, BS_INAGG(%rbx)
    jne bf_agg_nested
    testl $NF_DISTINCT, N_FLAGS(%r12)
    jz 1f
    RAISE E_UNSUPPORTED, "DISTINCT aggregates are not supported by this engine"
1:  testl $NF_STAR, N_FLAGS(%r12)
    jz 2f
    cmp $AGG_COUNT, %r13d
    jne bf_arity_star
    movl $AGG_COUNT_STAR, N_OP(%r12)
    movq $0, N_A(%r12)
    movl $T_INT, N_TYPE(%r12)
    jmp bf_agg_register
2:  cmpq $1, N_V1(%r12)
    jne bf_arity
    mov %r13d, N_OP(%r12)
    incq BS_INAGG(%rbx)
    mov N_A(%r12), %rax
    mov %rbx, %rdi
    mov (%rax), %rsi
    call bind_expr
    decq BS_INAGG(%rbx)
    mov %rax, N_A(%r12)             /* A = the argument expression */
    mov N_TYPE(%rax), %r14d
    movzbl %r14b, %r15d             /* arg kind */
    cmp $AGG_COUNT, %r13d
    je 3f
    cmp $AGG_MIN, %r13d
    je 4f
    cmp $AGG_MAX, %r13d
    je 4f
    /* SUM / AVG: numeric */
    cmp $T_NULL, %r15d
    je 5f
    mov %r15d, %edi
    call is_numeric
    test %eax, %eax
    jz bind_type_error
5:  cmp $AGG_AVG, %r13d
    jne 6f
    movl $T_FLOAT, N_TYPE(%r12)
    jmp bf_agg_register
6:  cmp $T_DEC, %r15d
    jne 7f
    mov %r14d, %eax                 /* SUM(DEC(p,s)) -> DEC(18,s) */
    and $0xff0000, %eax
    or $MKDEC(18, 0), %eax
    mov %eax, N_TYPE(%r12)
    jmp bf_agg_register
7:  cmp $T_NULL, %r15d
    jne 8f
    mov $T_INT, %r14d
8:  mov %r14d, N_TYPE(%r12)
    jmp bf_agg_register
3:  movl $T_INT, N_TYPE(%r12)
    jmp bf_agg_register
4:  mov %r14d, N_TYPE(%r12)
bf_agg_register:
    movl $EK_AGG, N_KIND(%r12)
    mov BS_AGGS(%rbx), %rdi
    mov VEC_LEN(%rdi), %rax
    mov %rax, N_V2(%r12)
    mov %r12, %rsi
    call vec_push
    jmp be_done
bf_agg_notallowed:
    RAISE E_SEMANTIC_ERROR, "aggregate functions are not allowed here"
bf_agg_nested:
    RAISE E_SEMANTIC_ERROR, "aggregate calls cannot be nested"
bf_arity_star:
    RAISE E_SEMANTIC_ERROR, "only COUNT accepts *"
ENDF bind_expr

/* ================================================================ query */

/* add_out(vec rdi, expr rsi, name rdx, type ecx): appends an OutCol */
FUNC add_out
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %ecx, %r14d
    mov %rbx, %rdi
    mov %r12, %rsi
    call vec_push
    mov %rbx, %rdi
    mov %r13, %rsi
    call vec_push
    mov %rbx, %rdi
    mov %r14, %rsi
    call vec_push
    LEAVE
ENDF add_out

/* expand_star(B rdi, outs rsi): appends all table columns as bound column refs */
FUNC expand_star
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov BS_TABLE(%rbx), %r13
    test %r13, %r13
    jz 9f
    movq $1, BS_COLSEEN(%rbx)
    xor %r14d, %r14d
    mov TB_COLS(%r13), %r15
1:  cmp TB_NCOLS(%r13), %r14
    jae 8f
    mov $N_SIZE, %edi
    call tmp_zalloc
    movl $EK_COL, N_KIND(%rax)
    mov COL_NAME(%r15), %rcx
    mov %rcx, N_B(%rax)
    mov %r14, N_V1(%rax)
    mov COL_TYPE(%r15), %ecx
    mov %ecx, N_TYPE(%rax)
    mov %r12, %rdi
    mov %rax, %rsi
    mov COL_NAME(%r15), %rdx
    call add_out
    inc %r14
    add $COL_SIZE, %r15
    jmp 1b
8:  LEAVE
9:  RAISE E_SEMANTIC_ERROR, "SELECT * requires a FROM clause"
ENDF expand_star

/* const_int(B rdi, expr rsi, default rdx) -> rax value (validated constant INT64 >= 0) */
FUNC const_int
    ENTER 32
    mov %rdi, %rbx
    mov %rdx, %r13
    movq $1, BS_NOCOLS(%rbx)
    movq $0, BS_ALLOWAGG(%rbx)
    call bind_expr
    movq $0, BS_NOCOLS(%rbx)
    movzbl N_TYPE(%rax), %ecx
    cmp $T_NULL, %ecx
    je 2f
    cmp $T_INT, %ecx
    jne 3f
    /* evaluate with an empty context */
    mov %rax, %r12
    lea 0(%rsp), %rsi
    movq $0, EC_TABLE(%rsi)
    movq $0, EC_ROW(%rsi)
    movq $0, EC_AGGV(%rsi)
    mov %r12, %rdi
    call eval
    test %rdx, %rdx
    jnz 2f
    test %rax, %rax
    js 4f
    LEAVE
2:  mov %r13, %rax
    LEAVE
3:  RAISE E_TYPE_ERROR, "LIMIT/OFFSET must be INT64"
4:  RAISE E_INVALID_ARGUMENT, "LIMIT/OFFSET must not be negative"
ENDF const_int

/* same_expr(a rdi, b rsi) -> eax 1 if both are references to the same column */
FUNC same_expr
    xor %eax, %eax
    cmp %rdi, %rsi
    je 1f
    cmpl $EK_COL, N_KIND(%rdi)
    jne 2f
    cmpl $EK_COL, N_KIND(%rsi)
    jne 2f
    mov N_V1(%rdi), %rcx
    cmp N_V1(%rsi), %rcx
    jne 2f
1:  mov $1, %eax
2:  ret
ENDF same_expr

/* bind_select(stmt rdi) -> rax plan */
FUNC bind_select
    ENTER 64
    mov %rdi, %rbx                  /* stmt */
    cmpq $0, SS_GROUPBY(%rbx)
    jne bs_unsupported
    cmpq $0, SS_HAVING(%rbx)
    jne bs_unsupported
    cmpq $0, SS_DISTINCT(%rbx)
    jne bs_unsupported
    mov $QP_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r12                  /* plan */
    mov $BS_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r13                  /* binder state */
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, BS_AGGS(%r13)
    movq $1, BS_ALLOWAGG(%r13)

    /* FROM */
    mov SS_FROM(%rbx), %rdi
    test %rdi, %rdi
    jz 2f
    lea 8(%rdi), %rdi
    mov SS_FROM(%rbx), %rsi
    mov (%rsi), %rsi
    call cat_find
    test %rax, %rax
    jz bs_unknown_table
    mov %rax, BS_TABLE(%r13)
    mov %rax, QP_TABLE(%r12)
    mov SS_ALIAS(%rbx), %rax
    test %rax, %rax
    jnz 1f
    mov SS_FROM(%rbx), %rax
1:  mov %rax, BS_RANGE(%r13)
    mov %rax, QP_RANGE(%r12)

2:  /* WHERE (no aggregates; column refs do not count as ungrouped) */
    mov SS_WHERE(%rbx), %rsi
    test %rsi, %rsi
    jz 3f
    movq $0, BS_ALLOWAGG(%r13)
    mov %r13, %rdi
    call bind_expr
    mov %rax, QP_WHERE(%r12)
    movzbl N_TYPE(%rax), %ecx
    cmp $T_BOOL, %ecx
    je 21f
    cmp $T_NULL, %ecx
    jne bs_where_type
21: movq $1, BS_ALLOWAGG(%r13)
    movq $0, BS_COLSEEN(%r13)

3:  /* select list */
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, %r14                  /* outs vec (3 qwords per column) */
    xor %r15d, %r15d                /* item index */
4:  mov SS_ITEMS(%rbx), %rax
    cmp VEC_LEN(%rax), %r15
    jae 10f
    mov VEC_DATA(%rax), %rax
    mov (%rax, %r15, 8), %rax       /* SelectItem* */
    mov %rax, 0(%rsp)
    mov SI_KIND(%rax), %rcx
    cmp $1, %rcx
    je 5f
    cmp $2, %rcx
    je 6f
    /* expression item */
    mov %r13, %rdi
    mov SI_EXPR(%rax), %rsi
    call bind_expr
    mov %rax, 8(%rsp)               /* bound expr */
    mov 0(%rsp), %rcx
    mov SI_ALIAS(%rcx), %rdx
    test %rdx, %rdx
    jnz 8f
    cmpl $EK_COL, N_KIND(%rax)
    jne 7f
    mov BS_TABLE(%r13), %rcx        /* declared column name */
    mov TB_COLS(%rcx), %rcx
    mov N_V1(%rax), %rdx
    shl $5, %rdx
    mov COL_NAME(%rcx, %rdx), %rdx
    jmp 8f
7:  /* _colN */
    mov VEC_LEN(%r14), %rax
    xor %edx, %edx
    mov $3, %ecx
    div %rcx
    inc %rax
    mov %rax, %rcx
    lea 16(%rsp), %rdi
    mov $32, %esi
    CSTR %rdx, "_col%ld"
    xor %eax, %eax
    call snprintf
    lea 16(%rsp), %rdi
    mov %rax, %rsi
    call pstr_tmp
    mov %rax, %rdx
8:  mov 8(%rsp), %rsi
    mov N_TYPE(%rsi), %ecx
    mov %r14, %rdi
    call add_out
    jmp 9f
5:  mov %r13, %rdi                  /* * */
    mov %r14, %rsi
    call expand_star
    jmp 9f
6:  mov BS_TABLE(%r13), %rcx        /* q.* */
    test %rcx, %rcx
    jz bs_badqual
    mov SI_QUAL(%rax), %rdi
    mov BS_RANGE(%r13), %rsi
    call pstr_ieq
    test %eax, %eax
    jz bs_badqual
    mov %r13, %rdi
    mov %r14, %rsi
    call expand_star
9:  inc %r15
    jmp 4b
10: mov VEC_DATA(%r14), %rax
    mov %rax, QP_OUT(%r12)
    mov VEC_LEN(%r14), %rax
    xor %edx, %edx
    mov $3, %ecx
    div %rcx
    mov %rax, QP_NOUT(%r12)

    /* ORDER BY */
    mov SS_ORDER(%rbx), %rax
    test %rax, %rax
    jz 30f
    mov VEC_LEN(%rax), %rcx
    mov %rcx, QP_NKEYS(%r12)
    imul $SK_SIZE, %rcx, %rdi
    call tmp_zalloc
    mov %rax, QP_KEYS(%r12)
    xor %r15d, %r15d
11: cmp QP_NKEYS(%r12), %r15
    jae 30f
    mov SS_ORDER(%rbx), %rax
    mov VEC_DATA(%rax), %rax
    mov (%rax, %r15, 8), %rax       /* OrderItem* */
    mov %rax, 0(%rsp)
    imul $SK_SIZE, %r15, %r14
    add QP_KEYS(%r12), %r14         /* SortKey* */
    movq $-1, SK_OUT(%r14)
    mov OI_DESC(%rax), %rcx
    mov %rcx, SK_DESC(%r14)
    /* nulls first: default = ascending; explicit NULLS FIRST/LAST wins */
    xor %edx, %edx
    test %rcx, %rcx
    sete %dl
    mov OI_NULLS(%rax), %rcx
    cmp $1, %rcx
    jne 12f
    mov $1, %edx
12: cmp $2, %rcx
    jne 13f
    xor %edx, %edx
13: mov %rdx, SK_NFIRST(%r14)
    mov OI_EXPR(%rax), %rsi         /* expression */
    /* positional reference */
    cmpl $EK_LIT, N_KIND(%rsi)
    jne 15f
    cmpl $T_INT, N_TYPE(%rsi)
    jne 15f
    testl $(NF_NULL | NF_MINLIT), N_FLAGS(%rsi)
    jnz 15f
    mov N_V1(%rsi), %rax
    cmp $1, %rax
    jl bs_bad_ordinal
    cmp QP_NOUT(%r12), %rax
    jg bs_bad_ordinal
    dec %rax
    mov %rax, SK_OUT(%r14)
    jmp 19f
15: /* output name reference */
    cmpl $EK_COL, N_KIND(%rsi)
    jne 18f
    cmpq $0, N_A(%rsi)
    jne 18f
    mov %rsi, 8(%rsp)
    movq $-1, 16(%rsp)              /* first match */
    xor %ecx, %ecx
16: cmp QP_NOUT(%r12), %rcx
    jae 17f
    mov %rcx, 24(%rsp)
    imul $OC_SIZE, %rcx, %rax
    add QP_OUT(%r12), %rax
    mov OC_NAME(%rax), %rdi
    mov 8(%rsp), %rsi
    mov N_B(%rsi), %rsi
    call pstr_ieq
    test %eax, %eax
    jz 161f
    mov 24(%rsp), %rcx
    cmpq $-1, 16(%rsp)
    jne 162f
    mov %rcx, 16(%rsp)
    jmp 161f
162: /* second match: must be the same expression */
    imul $OC_SIZE, %rcx, %rax
    add QP_OUT(%r12), %rax
    mov OC_EXPR(%rax), %rdi
    mov 16(%rsp), %rcx
    imul $OC_SIZE, %rcx, %rax
    add QP_OUT(%r12), %rax
    mov OC_EXPR(%rax), %rsi
    call same_expr
    test %eax, %eax
    jz bs_ambiguous
161: mov 24(%rsp), %rcx
    inc %rcx
    jmp 16b
17: mov 16(%rsp), %rax
    cmp $-1, %rax
    je 171f
    mov %rax, SK_OUT(%r14)
    jmp 19f
171: mov 8(%rsp), %rsi
18: /* expression over input columns */
    mov %r13, %rdi
    call bind_expr
    mov %rax, SK_EXPR(%r14)
    mov N_TYPE(%rax), %eax
    mov %rax, SK_TYPE(%r14)
    inc %r15
    jmp 11b
19: mov SK_OUT(%r14), %rax
    imul $OC_SIZE, %rax, %rax
    add QP_OUT(%r12), %rax
    mov OC_TYPE(%rax), %rax
    mov %rax, SK_TYPE(%r14)
    inc %r15
    jmp 11b

30: /* aggregation */
    mov BS_AGGS(%r13), %rax
    mov VEC_LEN(%rax), %rcx
    mov %rcx, QP_NAGGS(%r12)
    mov VEC_DATA(%rax), %rdx
    mov %rdx, QP_AGGS(%r12)
    test %rcx, %rcx
    jz 31f
    movq $1, QP_AGG(%r12)
    cmpq $0, BS_COLSEEN(%r13)
    jne bs_ungrouped
31: /* LIMIT / OFFSET */
    movq $-1, QP_LIMIT(%r12)
    mov SS_LIMIT(%rbx), %rsi
    test %rsi, %rsi
    jz 32f
    mov %r13, %rdi
    mov $-1, %rdx
    call const_int
    mov %rax, QP_LIMIT(%r12)
32: mov SS_OFFSET(%rbx), %rsi
    test %rsi, %rsi
    jz 33f
    mov %r13, %rdi
    xor %edx, %edx
    call const_int
    mov %rax, QP_OFFSET(%r12)
33: mov %r12, %rax
    LEAVE

bs_unsupported:
    RAISE E_UNSUPPORTED, "GROUP BY, HAVING and DISTINCT are not supported by this engine"
bs_unknown_table:
    mov SS_FROM(%rbx), %rdx
    add $8, %rdx
    mov $E_SEMANTIC_ERROR, %edi
    CSTR %rsi, "unknown table '%s'"
    call pq_raisef
bs_where_type:
    RAISE E_TYPE_ERROR, "WHERE condition must be BOOLEAN"
bs_badqual:
    RAISE E_SEMANTIC_ERROR, "unknown table or alias in qualified *"
bs_bad_ordinal:
    RAISE E_SEMANTIC_ERROR, "ORDER BY position out of range"
bs_ambiguous:
    RAISE E_SEMANTIC_ERROR, "ambiguous ORDER BY reference"
bs_ungrouped:
    RAISE E_SEMANTIC_ERROR, "column must appear in an aggregate function (no GROUP BY)"
ENDF bind_select
