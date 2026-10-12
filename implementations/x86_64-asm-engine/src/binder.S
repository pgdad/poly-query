/*
 * binder.S - semantic analysis (binding & typing).
 *
 * Name resolution over nested scopes (one per SELECT; subqueries see their
 * enclosing scopes, derived tables and CTE bodies do not see the query that
 * contains them), CTE visibility, type checking with implicit numeric
 * promotions, aggregate and GROUP BY validation (structural equality),
 * output naming, ORDER BY resolution, constant LIMIT/OFFSET.  Produces one
 * bound query block (QP_*, RV_*) per SELECT, with the FROM clause as a
 * logical Scan / Join tree (QP_LFROM), and hands every block to the
 * planning pipeline (plan_block: logical plan, optimizer, physical plan).
 *
 *   bind_statement(SelectStmt*) -> rax plan*
 *   bind_expr(B, node) -> rax bound node      (used by functions.S)
 *   wrap_cast(node, type) -> rax cast node
 *   common_cmp_type(t1, t2) -> eax type to compare t1 with t2 (TYPE_ERROR if none)
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

/* binder state: one scope per SELECT */
#define BS_PARENT   0    /* enclosing scope or 0 */
#define BS_HIDE     8    /* 1 = the parent's range variables are not visible (derived table, CTE) */
#define BS_RVS      16   /* Vec* of RangeVar* */
#define BS_AGGS     24   /* Vec* of EK_AGG nodes */
#define BS_INAGG    32
#define BS_ALLOWAGG 40
#define BS_NOCOLS   48   /* constant context (LIMIT/OFFSET) */
#define BS_CTES     56   /* visible CTEs: list of {Cte*, next} */
#define BS_CORR     64   /* a column of an enclosing scope was referenced */
#define BS_NVIS     72   /* range variables visible to column references */
#define BS_SIZE     80

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

    .bss
    .p2align 3
bind_depth: .quad 0
    .text

#define MAX_BIND_DEPTH 400000

/* bind_expr(B rdi, node rsi) -> rax bound node (may be a replacement);
 * guards the recursion depth of very large expressions */
FUNC bind_expr
    sub $8, %rsp
    incq bind_depth(%rip)
    cmpq $MAX_BIND_DEPTH, bind_depth(%rip)
    ja 1f
    call bind_expr_node
    decq bind_depth(%rip)
    add $8, %rsp
    ret
1:  RAISE E_PARSE_ERROR, "expression too complex"
ENDF bind_expr

FUNC bind_expr_node
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
    cmp $EK_SUBQ, %eax
    je be_subq
    cmp $EK_EXISTS, %eax
    je be_exists
    cmp $EK_INSUBQ, %eax
    je be_insubq
    cmp $EK_OUTER, %eax
    je be_done
    cmp $EK_AGG, %eax
    je be_done
    cmp $EK_CASE, %eax              /* functions.S hook */
    jb 1f
    cmp $EK_LIKE, %eax
    ja 1f
    mov %rbx, %rdi
    mov %r12, %rsi
    call bind_special
    LEAVE
1:  RAISE E_INTERNAL_ERROR, "unknown expression node"

be_done:
    mov %r12, %rax
    LEAVE

be_lit:
    testl $NF_MINLIT, N_FLAGS(%r12)
    jz be_done
    RAISE E_NUMERIC_OVERFLOW, "integer literal out of range"

/* ---------------------------------------------------------------- column */
/* Search the scope chain; a match in an enclosing scope becomes EK_OUTER
 * (correlated reference) and marks every scope in between as correlated. */
be_col:
    cmpq $0, BS_NOCOLS(%rbx)
    jne be_col_nonconst
    mov %rbx, %r13                  /* scope */
    xor %r14d, %r14d                /* levels up */
1:  mov %r13, %rdi
    mov %r12, %rsi
    call resolve_in_scope
    cmp $-1, %rax
    jne 3f
2:  mov BS_HIDE(%r13), %rcx
    mov BS_PARENT(%r13), %r13
    test %r13, %r13
    jz be_col_unknown
    inc %r14
    test %rcx, %rcx
    jnz 2b
    jmp 1b
3:  mov %rax, N_V2(%r12)            /* range variable */
    mov %rdx, N_V1(%r12)            /* column */
    mov BS_RVS(%r13), %rcx
    mov VEC_DATA(%rcx), %rcx
    mov (%rcx, %rax, 8), %r15       /* RangeVar* */
    mov RV_USED(%r15), %rcx
    movb $1, (%rcx, %rdx)
    shl $4, %rdx
    add RV_COLS(%r15), %rdx
    mov RVC_TYPE(%rdx), %eax
    mov %eax, N_TYPE(%r12)
    test %r14, %r14
    jz be_done
    movl $EK_OUTER, N_KIND(%r12)
    mov %r14, N_V3(%r12)
    mov %rbx, %rcx
    mov %r14, %rdx
4:  movq $1, BS_CORR(%rcx)
    mov BS_PARENT(%rcx), %rcx
    dec %rdx
    jnz 4b
    jmp be_done
be_col_unknown:
    cmpq $0, N_A(%r12)
    jne be_col_badqual
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

/* ---------------------------------------------------------------- subqueries */
be_subq:
    mov %rbx, %rdi
    mov %r12, %rsi
    call bind_subplan
    cmpq $1, QP_NOUT(%rax)
    jne be_subq_cols
    mov QP_OUT(%rax), %rcx
    mov OC_TYPE(%rcx), %ecx
    mov %ecx, N_TYPE(%r12)
    jmp be_done
be_exists:
    mov %rbx, %rdi
    mov %r12, %rsi
    call bind_subplan
    movl $T_BOOL, N_TYPE(%r12)
    jmp be_done
be_insubq:
    mov %rbx, %rdi
    mov N_A(%r12), %rsi
    call bind_expr
    mov %rax, N_A(%r12)
    mov %rbx, %rdi
    mov %r12, %rsi
    call bind_subplan
    cmpq $1, QP_NOUT(%rax)
    jne be_subq_cols
    mov QP_OUT(%rax), %rcx
    mov OC_TYPE(%rcx), %esi
    mov N_A(%r12), %rax
    mov N_TYPE(%rax), %edi
    call common_cmp_type
    mov N_A(%r12), %rdi
    cmp N_TYPE(%rdi), %eax
    je 1f
    cmpb $T_NULL, N_TYPE(%rdi)
    je 1f
    mov %eax, %esi
    call wrap_cast
    mov %rax, N_A(%r12)
1:  movl $T_BOOL, N_TYPE(%r12)
    jmp be_done
be_subq_cols:
    RAISE E_SEMANTIC_ERROR, "subquery must return exactly one column"

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
    /* scales: an INT64 operand takes part as DECIMAL(18,0) */
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
    movl $0, 8(%rsp)
    movzbl %r13b, %ecx
    cmp $T_NULL, %ecx
    je 71f
    mov N_A(%r12), %rdi
    mov $MKDEC(18, 0), %esi
    call wrap_cast
    mov %rax, N_A(%r12)
    jmp 7f
71: mov 12(%rsp), %eax              /* NULL operand: mirror the other scale */
    mov %eax, 8(%rsp)
7:  cmp $T_INT, %r9d
    jne 8f
    movl $0, 12(%rsp)
    movzbl %r14b, %ecx
    cmp $T_NULL, %ecx
    je 72f
    mov N_B(%r12), %rdi
    mov $MKDEC(18, 0), %esi
    call wrap_cast
    mov %rax, N_B(%r12)
    jmp 8f
72: mov 8(%rsp), %eax
    mov %eax, 12(%rsp)
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
    mov %rbx, %rdi                  /* functions.S hook: scalar functions */
    mov %r12, %rsi
    call bind_scalar_func
    LEAVE
bf_arity:
    RAISE E_SEMANTIC_ERROR, "wrong number of arguments"

bf_agg:
    lea agg_ids(%rip), %rcx
    movzbl (%rcx, %rax), %r13d      /* AGG_* */
    cmpq $0, BS_ALLOWAGG(%rbx)
    je bf_agg_notallowed
    cmpq $0, BS_INAGG(%rbx)
    jne bf_agg_nested
    testl $NF_STAR, N_FLAGS(%r12)
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
ENDF bind_expr_node

/* ================================================================ comparison typing */

/* common_cmp_type(t1 edi, t2 esi) -> eax packed type both sides are promoted to
 * for a comparison (types.md §2, §5); TYPE_ERROR when not comparable */
FUNC common_cmp_type
    push %rbx
    push %r12
    push %r13
    mov %edi, %ebx
    mov %esi, %r12d
    movzbl %bl, %r8d
    movzbl %r12b, %r9d
    mov %r12d, %eax
    cmp $T_NULL, %r8d
    je 9f
    mov %ebx, %eax
    cmp $T_NULL, %r9d
    je 9f
    cmp %r12d, %ebx
    je 9f                           /* identical types */
    mov %r8d, %edi
    call is_numeric
    mov %eax, %r13d
    mov %r9d, %edi
    call is_numeric
    and %eax, %r13d
    movzbl %bl, %r8d
    movzbl %r12b, %r9d
    test %r13d, %r13d
    jz 5f
    mov $T_FLOAT, %eax
    cmp $T_FLOAT, %r8d
    je 9f
    cmp $T_FLOAT, %r9d
    je 9f
    mov $T_INT, %eax
    cmp %r8d, %r9d
    je 2f                           /* INT/INT or DEC/DEC */
1:  /* INT with DEC, or DEC with DEC: DECIMAL(18, max scale) */
    mov %ebx, %eax
    shr $16, %eax
    and $0xff, %eax
    mov %r12d, %ecx
    shr $16, %ecx
    and $0xff, %ecx
    cmp %ecx, %eax
    cmovb %ecx, %eax
    shl $16, %eax
    or $MKDEC(18, 0), %eax
    jmp 9f
2:  cmp $T_DEC, %r8d
    je 1b
    jmp 9f
5:  cmp %r8d, %r9d
    jne 6f
    mov %ebx, %eax
    jmp 9f
6:  mov $T_TS, %eax                 /* DATE with TIMESTAMP */
    cmp $T_DATE, %r8d
    jne 7f
    cmp $T_TS, %r9d
    je 9f
7:  cmp $T_TS, %r8d
    jne bind_type_error
    cmp $T_DATE, %r9d
    jne bind_type_error
9:  pop %r13
    pop %r12
    pop %rbx
    ret
ENDF common_cmp_type

/* ================================================================ tree utilities */

/* expr_equal(a rdi, b rsi) -> eax 1 if structurally equal (semantics.md §5) */
FUNC expr_equal
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov $1, %eax
    cmp %rbx, %r12
    je 9f
    xor %eax, %eax
    test %rbx, %rbx
    jz 9f
    test %r12, %r12
    jz 9f
    mov N_KIND(%rbx), %ecx
    cmp N_KIND(%r12), %ecx
    jne 9f
    mov N_OP(%rbx), %edx
    cmp N_OP(%r12), %edx
    jne 9f
    mov N_TYPE(%rbx), %edx
    cmp N_TYPE(%r12), %edx
    jne 9f
    cmp $EK_LIT, %ecx
    je 20f
    cmp $EK_COL, %ecx
    je 30f
    cmp $EK_OUTER, %ecx
    je 31f
    cmp $EK_SUBQ, %ecx
    je 9f                           /* subqueries: identity only */
    cmp $EK_EXISTS, %ecx
    je 9f
    cmp $EK_INSUBQ, %ecx
    je 9f
    cmp $EK_CAST, %ecx
    je 40f
    cmp $EK_AGG, %ecx
    je 41f
    cmp $EK_FUNC, %ecx
    je 42f
    cmp $EK_CASE, %ecx
    je 43f
    cmp $EK_INLIST, %ecx
    je 43f
    jmp 50f
20: /* literals */
    mov N_FLAGS(%rbx), %ecx
    xor N_FLAGS(%r12), %ecx
    test $NF_NULL, %ecx
    jnz 9f
    mov $1, %eax
    testl $NF_NULL, N_FLAGS(%rbx)
    jnz 9f
    movzbl N_TYPE(%rbx), %ecx
    cmp $T_STR, %ecx
    je 21f
    xor %eax, %eax
    mov N_V1(%rbx), %rcx
    cmp N_V1(%r12), %rcx
    sete %al
    jmp 9f
21: mov N_V1(%rbx), %rdi
    mov N_V1(%r12), %rsi
    call pstr_cmp
    test %eax, %eax
    sete %al
    movzbl %al, %eax
    jmp 9f
30: mov N_V1(%rbx), %rcx            /* same column of the same range variable */
    cmp N_V1(%r12), %rcx
    jne 9f
    mov N_V2(%rbx), %rcx
    cmp N_V2(%r12), %rcx
    jne 9f
    mov $1, %eax
    jmp 9f
31: mov N_V3(%rbx), %rcx
    cmp N_V3(%r12), %rcx
    jne 9f
    jmp 30b
40: mov N_V1(%rbx), %rcx            /* CAST target */
    cmp N_V1(%r12), %rcx
    jne 9f
    jmp 50f
41: mov N_FLAGS(%rbx), %ecx         /* aggregate: DISTINCT flag */
    xor N_FLAGS(%r12), %ecx
    test $NF_DISTINCT, %ecx
    jnz 9f
    jmp 50f
42: mov N_FLAGS(%rbx), %ecx
    xor N_FLAGS(%r12), %ecx
    test $(NF_DISTINCT | NF_STAR), %ecx
    jnz 9f
43: mov N_V1(%rbx), %rcx            /* argument / item / WHEN counts */
    cmp N_V1(%r12), %rcx
    jne 9f
50: /* children */
    mov %rbx, %rdi
    call expr_nchild
    mov %rax, %r13
    mov %r12, %rdi
    call expr_nchild
    cmp %rax, %r13
    jne 8f
    xor %r14d, %r14d
51: cmp %r13, %r14
    jae 7f
    mov %rbx, %rdi
    mov %r14, %rsi
    call expr_child_ptr
    mov (%rax), %r15
    mov %r12, %rdi
    mov %r14, %rsi
    call expr_child_ptr
    mov (%rax), %rsi
    mov %r15, %rdi
    call expr_equal
    test %eax, %eax
    jz 9f
    inc %r14
    jmp 51b
7:  mov $1, %eax
    jmp 9f
8:  xor %eax, %eax
9:  LEAVE
ENDF expr_equal

/* has_agg(expr rdi) -> eax 1 if an aggregate occurs (outside subqueries) */
FUNC has_agg
    ENTER 0
    mov %rdi, %rbx
    xor %eax, %eax
    test %rbx, %rbx
    jz 9f
    mov $1, %eax
    cmpl $EK_AGG, N_KIND(%rbx)
    je 9f
    mov %rbx, %rdi
    call expr_nchild
    mov %rax, %r13
    xor %r12d, %r12d
1:  xor %eax, %eax
    cmp %r13, %r12
    jae 9f
    mov %rbx, %rdi
    mov %r12, %rsi
    call expr_child_ptr
    mov (%rax), %rdi
    call has_agg
    test %eax, %eax
    jnz 9f
    inc %r12
    jmp 1b
9:  LEAVE
ENDF has_agg

/* check_grouped(expr rdi, plan rsi): SEMANTIC_ERROR if a column reference
 * remains outside aggregates after removing GROUP BY expressions */
FUNC check_grouped
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    test %rbx, %rbx
    jz 9f
    xor %r13d, %r13d
1:  cmp QP_NGROUP(%r12), %r13
    jae 2f
    mov QP_GROUP(%r12), %rax
    mov (%rax, %r13, 8), %rsi
    mov %rbx, %rdi
    call expr_equal
    test %eax, %eax
    jnz 9f
    inc %r13
    jmp 1b
2:  mov N_KIND(%rbx), %eax
    cmp $EK_COL, %eax
    je 8f
    cmp $EK_AGG, %eax
    je 9f
    mov %rbx, %rdi
    call expr_nchild
    mov %rax, %r14
    xor %r13d, %r13d
3:  cmp %r14, %r13
    jae 9f
    mov %rbx, %rdi
    mov %r13, %rsi
    call expr_child_ptr
    mov (%rax), %rdi
    mov %r12, %rsi
    call check_grouped
    inc %r13
    jmp 3b
8:  mov N_B(%rbx), %rdx
    add $8, %rdx
    mov $E_SEMANTIC_ERROR, %edi
    CSTR %rsi, "column '%s' must appear in GROUP BY or be used in an aggregate function"
    call pq_raisef
9:  LEAVE
ENDF check_grouped

/* ================================================================ scopes and range variables */

/* scope_rv(B rdi, i rsi) -> rax RangeVar* */
FUNC scope_rv
    mov BS_RVS(%rdi), %rax
    mov VEC_DATA(%rax), %rax
    mov (%rax, %rsi, 8), %rax
    ret
ENDF scope_rv

/* rv_find_col(rv rdi, name rsi) -> rax column index or -1; SEMANTIC_ERROR
 * when the name is ambiguous within the range variable */
FUNC rv_find_col
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov $-1, %r13
    xor %r14d, %r14d
1:  cmp RV_NCOLS(%rbx), %r14
    jae 8f
    mov %r14, %rax
    shl $4, %rax
    add RV_COLS(%rbx), %rax
    mov RVC_NAME(%rax), %rdi
    mov %r12, %rsi
    call pstr_ieq
    test %eax, %eax
    jz 2f
    cmp $-1, %r13
    jne bind_ambiguous
    mov %r14, %r13
2:  inc %r14
    jmp 1b
8:  mov %r13, %rax
    LEAVE
ENDF rv_find_col

bind_ambiguous:
    RAISE E_SEMANTIC_ERROR, "ambiguous column reference"

/* resolve_in_scope(B rdi, column node rsi) -> rax range variable index
 * (-1 = not found in this scope), rdx column index */
FUNC resolve_in_scope
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov $-1, %r13                   /* found range variable */
    mov $-1, %r14                   /* found column */
    xor %r15d, %r15d
    cmpq $0, N_A(%r12)
    je 5f
1:  cmp BS_NVIS(%rbx), %r15         /* qualified */
    jae 9f
    mov %rbx, %rdi
    mov %r15, %rsi
    call scope_rv
    mov %rax, 0(%rsp)
    mov RV_NAME(%rax), %rdi
    mov N_A(%r12), %rsi
    call pstr_ieq
    test %eax, %eax
    jnz 2f
    inc %r15
    jmp 1b
2:  mov 0(%rsp), %rdi
    mov N_B(%r12), %rsi
    call rv_find_col
    cmp $-1, %rax
    je 3f
    mov %r15, %r13
    mov %rax, %r14
    jmp 9f
3:  mov N_B(%r12), %rdx
    add $8, %rdx
    mov $E_SEMANTIC_ERROR, %edi
    CSTR %rsi, "unknown column '%s'"
    call pq_raisef
5:  cmp BS_NVIS(%rbx), %r15         /* unqualified: unique among visible range variables */
    jae 9f
    mov %rbx, %rdi
    mov %r15, %rsi
    call scope_rv
    mov %rax, %rdi
    mov N_B(%r12), %rsi
    call rv_find_col
    cmp $-1, %rax
    je 6f
    cmp $-1, %r13
    jne bind_ambiguous
    mov %r15, %r13
    mov %rax, %r14
6:  inc %r15
    jmp 5b
9:  mov %r13, %rax
    mov %r14, %rdx
    LEAVE
ENDF resolve_in_scope

/* new_scope(parent rdi, ctes rsi, hide rdx) -> rax B */
FUNC new_scope
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov $BS_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r14
    mov %rbx, BS_PARENT(%r14)
    mov %r12, BS_CTES(%r14)
    mov %r13, BS_HIDE(%r14)
    movq $1, BS_ALLOWAGG(%r14)
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, BS_RVS(%r14)
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, BS_AGGS(%r14)
    mov %r14, %rax
    LEAVE
ENDF new_scope

/* rv_new(ncols rdi) -> rax RangeVar with column and usage arrays */
FUNC rv_new
    ENTER 0
    mov %rdi, %rbx
    mov $RV_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r12
    mov %rbx, RV_NCOLS(%r12)
    mov %rbx, %rdi
    shl $4, %rdi
    add $16, %rdi
    call tmp_zalloc
    mov %rax, RV_COLS(%r12)
    lea 8(%rbx), %rdi
    call tmp_zalloc
    mov %rax, RV_USED(%r12)
    mov %r12, %rax
    LEAVE
ENDF rv_new

/* rv_from_table(Table* rdi) -> rax RangeVar */
FUNC rv_from_table
    ENTER 0
    mov %rdi, %rbx
    mov TB_NCOLS(%rbx), %rdi
    call rv_new
    mov %rax, %r12
    mov %rbx, RV_TABLE(%r12)
    xor %ecx, %ecx
1:  cmp TB_NCOLS(%rbx), %rcx
    jae 9f
    mov %rcx, %rdx
    shl $COL_SHIFT, %rdx
    add TB_COLS(%rbx), %rdx         /* Column* */
    mov %rcx, %rsi
    shl $4, %rsi
    add RV_COLS(%r12), %rsi
    mov COL_NAME(%rdx), %rax
    mov %rax, RVC_NAME(%rsi)
    mov COL_TYPE(%rdx), %rax
    mov %rax, RVC_TYPE(%rsi)
    inc %rcx
    jmp 1b
9:  mov %r12, %rax
    LEAVE
ENDF rv_from_table

/* rv_from_plan(plan rdi, names Vec* rsi or 0) -> rax RangeVar */
FUNC rv_from_plan
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r13
    mov QP_NOUT(%rbx), %rdi
    call rv_new
    mov %rax, %r12
    mov %rbx, RV_PLAN(%r12)
    xor %ecx, %ecx
1:  cmp QP_NOUT(%rbx), %rcx
    jae 9f
    imul $OC_SIZE, %rcx, %rdx
    add QP_OUT(%rbx), %rdx
    mov %rcx, %rsi
    shl $4, %rsi
    add RV_COLS(%r12), %rsi
    mov OC_NAME(%rdx), %rax
    test %r13, %r13
    jz 2f
    mov VEC_DATA(%r13), %rax
    mov (%rax, %rcx, 8), %rax
2:  mov %rax, RVC_NAME(%rsi)
    mov OC_TYPE(%rdx), %rax
    mov %rax, RVC_TYPE(%rsi)
    inc %rcx
    jmp 1b
9:  mov %r12, %rax
    LEAVE
ENDF rv_from_plan

/* add_rv(B rdi, rv rsi) -> rax index; duplicate range variable names are an error */
FUNC add_rv
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r13d, %r13d
1:  mov BS_RVS(%rbx), %rax
    cmp VEC_LEN(%rax), %r13
    jae 2f
    mov %rbx, %rdi
    mov %r13, %rsi
    call scope_rv
    mov RV_NAME(%rax), %rdi
    mov RV_NAME(%r12), %rsi
    call pstr_ieq
    test %eax, %eax
    jnz 8f
    inc %r13
    jmp 1b
2:  mov BS_RVS(%rbx), %rdi
    mov %r12, %rsi
    call vec_push
    mov %r13, %rax
    LEAVE
8:  mov RV_NAME(%r12), %rdx
    add $8, %rdx
    mov $E_SEMANTIC_ERROR, %edi
    CSTR %rsi, "duplicate range variable '%s' in FROM"
    call pq_raisef
ENDF add_rv

/* find_cte(list rdi, name rsi) -> rax Cte* or 0 (innermost first) */
FUNC find_cte
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
1:  test %rbx, %rbx
    jz 9f
    mov 0(%rbx), %rax
    mov CTE_NAME(%rax), %rdi
    mov %r12, %rsi
    call pstr_ieq
    test %eax, %eax
    jnz 8f
    mov 8(%rbx), %rbx
    jmp 1b
8:  mov 0(%rbx), %rax
    LEAVE
9:  xor %eax, %eax
    LEAVE
ENDF find_cte

/* bind_with(B rdi, ctes Vec* rsi): binds each CTE in order; later CTEs and
 * the main query see earlier ones */
FUNC bind_with
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r13d, %r13d
1:  cmp VEC_LEN(%r12), %r13
    jae 9f
    mov VEC_DATA(%r12), %rax
    mov (%rax, %r13, 8), %r14       /* Cte* */
    xor %r15d, %r15d
2:  cmp %r13, %r15                  /* duplicate names within this WITH */
    jae 3f
    mov VEC_DATA(%r12), %rax
    mov (%rax, %r15, 8), %rax
    mov CTE_NAME(%rax), %rdi
    mov CTE_NAME(%r14), %rsi
    call pstr_ieq
    test %eax, %eax
    jnz 8f
    inc %r15
    jmp 2b
3:  mov CTE_QUERY(%r14), %rdi
    mov %rbx, %rsi
    mov BS_CTES(%rbx), %rdx
    mov $1, %ecx
    call bind_query
    mov %rax, CTE_PLAN(%r14)
    mov CTE_COLS(%r14), %rcx
    test %rcx, %rcx
    jz 4f
    mov VEC_LEN(%rcx), %rcx
    cmp QP_NOUT(%rax), %rcx
    jne 7f
4:  mov $16, %edi
    call tmp_alloc
    mov %r14, 0(%rax)
    mov BS_CTES(%rbx), %rcx
    mov %rcx, 8(%rax)
    mov %rax, BS_CTES(%rbx)
    inc %r13
    jmp 1b
9:  LEAVE
7:  RAISE E_SEMANTIC_ERROR, "CTE column list does not match the query's column count"
8:  mov CTE_NAME(%r14), %rdx
    add $8, %rdx
    mov $E_SEMANTIC_ERROR, %edi
    CSTR %rsi, "duplicate CTE name '%s'"
    call pq_raisef
ENDF bind_with

/* bind_from(B rdi, FromItem* rsi) -> rax logical FROM tree (Scan /
 * SubqueryScan / Join nodes, lplan.S) */
FUNC bind_from
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov FI_KIND(%r12), %rax
    cmp $FK_JOIN, %rax
    je 5f
    cmp $FK_DERIVED, %rax
    je 3f
    /* base table or CTE */
    mov BS_CTES(%rbx), %rdi
    mov FI_NAME(%r12), %rsi
    call find_cte
    test %rax, %rax
    jz 1f
    mov CTE_COLS(%rax), %rsi
    mov CTE_PLAN(%rax), %rdi
    call rv_from_plan
    jmp 2f
1:  mov FI_NAME(%r12), %rsi
    lea 8(%rsi), %rdi
    mov (%rsi), %rsi
    call cat_find
    test %rax, %rax
    jz 8f
    mov %rax, %rdi
    call rv_from_table
2:  mov %rax, %r14
    mov FI_ALIAS(%r12), %rax
    test %rax, %rax
    jnz 21f
    mov FI_NAME(%r12), %rax
21: mov %rax, RV_NAME(%r14)
    jmp 4f
3:  /* derived table */
    mov FI_QUERY(%r12), %rdi
    mov %rbx, %rsi
    mov BS_CTES(%rbx), %rdx
    mov $1, %ecx
    call bind_query
    mov %rax, %rdi
    xor %esi, %esi
    call rv_from_plan
    mov %rax, %r14
    mov FI_ALIAS(%r12), %rax
    mov %rax, RV_NAME(%r14)
4:  mov %rbx, %rdi
    mov %r14, %rsi
    call add_rv
    mov %rax, %rdi
    mov %r14, %rsi
    call lp_from_rv
    LEAVE
5:  /* join */
    mov %rbx, %rdi
    mov FI_LEFT(%r12), %rsi
    call bind_from
    mov %rax, 0(%rsp)               /* left input */
    mov BS_RVS(%rbx), %rax
    mov VEC_LEN(%rax), %r13         /* right input's first range variable */
    mov %rbx, %rdi
    mov FI_RIGHT(%r12), %rsi
    call bind_from
    mov %rax, 8(%rsp)               /* right input */
    mov BS_RVS(%rbx), %rax
    mov VEC_LEN(%rax), %r14         /* end of the right input's */
    xor %r15d, %r15d                /* ON */
    mov FI_ON(%r12), %rsi
    test %rsi, %rsi
    jz 7f
    mov %r14, BS_NVIS(%rbx)         /* ON sees the range variables so far */
    movq $0, BS_ALLOWAGG(%rbx)
    mov %rbx, %rdi
    call bind_expr
    movq $1, BS_ALLOWAGG(%rbx)
    mov %rax, %r15
    movzbl N_TYPE(%rax), %ecx
    cmp $T_BOOL, %ecx
    je 7f
    cmp $T_NULL, %ecx
    jne 9f
7:  mov FI_JTYPE(%r12), %rdi
    mov 0(%rsp), %rsi
    mov 8(%rsp), %rdx
    mov %r15, %rcx
    mov %r13, %r8
    mov %r14, %r9
    call lp_join
    LEAVE
8:  mov FI_NAME(%r12), %rdx
    add $8, %rdx
    mov $E_SEMANTIC_ERROR, %edi
    CSTR %rsi, "unknown table '%s'"
    call pq_raisef
9:  RAISE E_TYPE_ERROR, "join condition must be BOOLEAN"
ENDF bind_from

/* ================================================================ select list */

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

/* expand_rv(B rdi, rv index rsi, outs rdx): appends all columns of a range variable */
FUNC expand_rv
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    call scope_rv
    mov %rax, %r14
    xor %r15d, %r15d
1:  cmp RV_NCOLS(%r14), %r15
    jae 9f
    mov RV_USED(%r14), %rax
    movb $1, (%rax, %r15)
    mov $N_SIZE, %edi
    call tmp_zalloc
    movl $EK_COL, N_KIND(%rax)
    mov %r15, N_V1(%rax)
    mov %r12, N_V2(%rax)
    mov %r15, %rcx
    shl $4, %rcx
    add RV_COLS(%r14), %rcx
    mov RVC_NAME(%rcx), %rdx
    mov %rdx, N_B(%rax)
    mov RVC_TYPE(%rcx), %rcx
    mov %ecx, N_TYPE(%rax)
    mov %r13, %rdi
    mov %rax, %rsi
    call add_out
    inc %r15
    jmp 1b
9:  LEAVE
ENDF expand_rv

/* col_name(B rdi, bound column node rsi) -> rax declared column name */
FUNC col_name
    mov N_V3(%rsi), %rcx
    cmpl $EK_OUTER, N_KIND(%rsi)
    je 1f
    xor %ecx, %ecx
1:  test %rcx, %rcx
    jz 2f
    mov BS_PARENT(%rdi), %rdi
    dec %rcx
    jmp 1b
2:  mov BS_RVS(%rdi), %rax
    mov VEC_DATA(%rax), %rax
    mov N_V2(%rsi), %rcx
    mov (%rax, %rcx, 8), %rax
    mov N_V1(%rsi), %rcx
    shl $4, %rcx
    add RV_COLS(%rax), %rcx
    mov RVC_NAME(%rcx), %rax
    ret
ENDF col_name

/* bind_select_list(B rdi, stmt rsi, plan rdx) -> rax Vec* of (alias, expr) pairs */
FUNC bind_select_list
    ENTER 64
    mov %rdi, %rbx
    mov %rsi, 32(%rsp)
    mov %rdx, %r12
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, %r13                  /* outs: 3 qwords per column */
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, 40(%rsp)              /* aliases */
    xor %r15d, %r15d
1:  mov 32(%rsp), %rax
    mov SS_ITEMS(%rax), %rax
    cmp VEC_LEN(%rax), %r15
    jae 20f
    mov VEC_DATA(%rax), %rax
    mov (%rax, %r15, 8), %r14       /* SelectItem* */
    mov SI_KIND(%r14), %rcx
    cmp $1, %rcx
    je 10f
    cmp $2, %rcx
    je 12f
    /* expression */
    mov %rbx, %rdi
    mov SI_EXPR(%r14), %rsi
    call bind_expr
    mov %rax, 8(%rsp)
    mov SI_ALIAS(%r14), %rdx
    test %rdx, %rdx
    jz 2f
    mov 40(%rsp), %rdi
    mov %rdx, %rsi
    call vec_push
    mov 40(%rsp), %rdi
    mov 8(%rsp), %rsi
    call vec_push
    mov SI_ALIAS(%r14), %rdx
    jmp 5f
2:  mov 8(%rsp), %rsi
    mov N_KIND(%rsi), %eax
    cmp $EK_COL, %eax
    je 3f
    cmp $EK_OUTER, %eax
    jne 4f
3:  mov %rbx, %rdi
    call col_name
    mov %rax, %rdx
    jmp 5f
4:  /* _colN */
    mov VEC_LEN(%r13), %rax
    xor %edx, %edx
    mov $3, %ecx
    div %rcx
    inc %rax
    mov %rax, %rcx
    lea 16(%rsp), %rdi
    mov $16, %esi
    CSTR %rdx, "_col%ld"
    xor %eax, %eax
    call snprintf
    lea 16(%rsp), %rdi
    mov %rax, %rsi
    call pstr_tmp
    mov %rax, %rdx
5:  mov 8(%rsp), %rsi
    mov N_TYPE(%rsi), %ecx
    mov %r13, %rdi
    call add_out
    jmp 19f
10: /* * : every range variable in FROM order */
    mov BS_RVS(%rbx), %rax
    cmpq $0, VEC_LEN(%rax)
    je 18f
    xor %r14d, %r14d
11: mov BS_RVS(%rbx), %rax
    cmp VEC_LEN(%rax), %r14
    jae 19f
    mov %rbx, %rdi
    mov %r14, %rsi
    mov %r13, %rdx
    call expand_rv
    inc %r14
    jmp 11b
12: /* q.* */
    xor %ecx, %ecx
    mov %rcx, 8(%rsp)
13: mov BS_RVS(%rbx), %rax
    mov 8(%rsp), %rcx
    cmp VEC_LEN(%rax), %rcx
    jae 17f
    mov %rbx, %rdi
    mov %rcx, %rsi
    call scope_rv
    mov RV_NAME(%rax), %rdi
    mov SI_QUAL(%r14), %rsi
    call pstr_ieq
    test %eax, %eax
    jnz 14f
    incq 8(%rsp)
    jmp 13b
14: mov %rbx, %rdi
    mov 8(%rsp), %rsi
    mov %r13, %rdx
    call expand_rv
19: inc %r15
    jmp 1b
20: mov VEC_DATA(%r13), %rax
    mov %rax, QP_OUT(%r12)
    mov VEC_LEN(%r13), %rax
    xor %edx, %edx
    mov $3, %ecx
    div %rcx
    mov %rax, QP_NOUT(%r12)
    mov 40(%rsp), %rax
    LEAVE
17: RAISE E_SEMANTIC_ERROR, "unknown table or alias in qualified *"
18: RAISE E_SEMANTIC_ERROR, "SELECT * requires a FROM clause"
ENDF bind_select_list

/* bind_group_by(B rdi, stmt rsi, plan rdx, aliases rcx) */
FUNC bind_group_by
    ENTER 32
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, 0(%rsp)
    mov SS_GROUPBY(%r12), %rax
    mov VEC_LEN(%rax), %rdi
    mov %rdi, QP_NGROUP(%r13)
    shl $3, %rdi
    call tmp_zalloc
    mov %rax, QP_GROUP(%r13)
    movq $0, BS_ALLOWAGG(%rbx)
    xor %r15d, %r15d
1:  mov SS_GROUPBY(%r12), %rax
    cmp VEC_LEN(%rax), %r15
    jae 9f
    mov VEC_DATA(%rax), %rax
    mov (%rax, %r15, 8), %r14       /* expr */
    cmpl $EK_LIT, N_KIND(%r14)
    jne 3f
    cmpl $T_INT, N_TYPE(%r14)
    jne 3f
    testl $(NF_NULL | NF_MINLIT), N_FLAGS(%r14)
    jnz 3f
    mov N_V1(%r14), %rax            /* ordinal: k-th select item */
    cmp $1, %rax
    jl 8f
    cmp QP_NOUT(%r13), %rax
    jg 8f
    dec %rax
    imul $OC_SIZE, %rax, %rax
    add QP_OUT(%r13), %rax
    mov OC_EXPR(%rax), %rax
    jmp 6f
3:  cmpl $EK_COL, N_KIND(%r14)
    jne 5f
    cmpq $0, N_A(%r14)
    jne 5f
    mov %rbx, %rdi                  /* input column first, then SELECT alias */
    mov %r14, %rsi
    call resolve_in_scope
    cmp $-1, %rax
    jne 5f
    mov 0(%rsp), %rcx
    xor %edx, %edx
4:  cmp VEC_LEN(%rcx), %rdx
    jae 5f
    mov %rdx, 8(%rsp)
    mov VEC_DATA(%rcx), %rax
    mov (%rax, %rdx, 8), %rdi
    mov N_B(%r14), %rsi
    call pstr_ieq
    mov 0(%rsp), %rcx
    mov 8(%rsp), %rdx
    test %eax, %eax
    jnz 41f
    add $2, %rdx
    jmp 4b
41: mov VEC_DATA(%rcx), %rax
    mov 8(%rax, %rdx, 8), %rax
    jmp 6f
5:  mov %rbx, %rdi
    mov %r14, %rsi
    call bind_expr
6:  mov QP_GROUP(%r13), %rcx
    mov %rax, (%rcx, %r15, 8)
    mov %rax, %rdi
    call has_agg
    test %eax, %eax
    jnz 7f
    inc %r15
    jmp 1b
9:  movq $1, BS_ALLOWAGG(%rbx)
    LEAVE
7:  RAISE E_SEMANTIC_ERROR, "aggregate functions are not allowed in GROUP BY"
8:  RAISE E_SEMANTIC_ERROR, "GROUP BY position out of range"
ENDF bind_group_by

/* find_out(plan rdi, expr rsi) -> rax index of an output column with a
 * structurally equal expression, or -1 */
FUNC find_out
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r13d, %r13d
1:  cmp QP_NOUT(%rbx), %r13
    jae 8f
    imul $OC_SIZE, %r13, %rax
    add QP_OUT(%rbx), %rax
    mov OC_EXPR(%rax), %rdi
    mov %r12, %rsi
    call expr_equal
    test %eax, %eax
    jnz 9f
    inc %r13
    jmp 1b
8:  mov $-1, %r13
9:  mov %r13, %rax
    LEAVE
ENDF find_out

/* bind_order_by(B rdi, stmt rsi, plan rdx) */
FUNC bind_order_by
    ENTER 48
    mov %rdi, %rbx
    mov %rsi, 32(%rsp)
    mov %rdx, %r12
    mov SS_ORDER(%rsi), %rax
    mov VEC_LEN(%rax), %rcx
    mov %rcx, QP_NKEYS(%r12)
    imul $SK_SIZE, %rcx, %rdi
    call tmp_zalloc
    mov %rax, QP_KEYS(%r12)
    xor %r15d, %r15d
11: cmp QP_NKEYS(%r12), %r15
    jae 30f
    mov 32(%rsp), %rax
    mov SS_ORDER(%rax), %rax
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
    jl bo_bad_ordinal
    cmp QP_NOUT(%r12), %rax
    jg bo_bad_ordinal
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
    call expr_equal
    test %eax, %eax
    jz bo_ambiguous
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
    cmpq $0, QP_NUNION(%r12)
    jne bo_compound
    mov %rbx, %rdi
    call bind_expr
    mov %rax, SK_EXPR(%r14)
    mov N_TYPE(%rax), %ecx
    mov %rcx, SK_TYPE(%r14)
    cmpq $0, QP_DISTINCT(%r12)
    je 181f
    mov %r12, %rdi                  /* DISTINCT: must be a select-list expression */
    mov %rax, %rsi
    call find_out
    cmp $-1, %rax
    je bo_distinct
    mov %rax, SK_OUT(%r14)
181: inc %r15
    jmp 11b
19: mov SK_OUT(%r14), %rax
    imul $OC_SIZE, %rax, %rax
    add QP_OUT(%r12), %rax
    mov OC_TYPE(%rax), %rax
    mov %rax, SK_TYPE(%r14)
    inc %r15
    jmp 11b
30: LEAVE
bo_bad_ordinal:
    RAISE E_SEMANTIC_ERROR, "ORDER BY position out of range"
bo_ambiguous:
    RAISE E_SEMANTIC_ERROR, "ambiguous ORDER BY reference"
bo_compound:
    RAISE E_SEMANTIC_ERROR, "ORDER BY of a UNION ALL must name an output column or position"
bo_distinct:
    RAISE E_SEMANTIC_ERROR, "ORDER BY expression must appear in the select list of a DISTINCT query"
ENDF bind_order_by

/* ================================================================ query */

/* const_int(B rdi, expr rsi, default rdx) -> rax value (validated constant INT64 >= 0) */
FUNC const_int
    ENTER 80
    mov %rdi, %rbx
    mov %rdx, %r13
    movq $1, BS_NOCOLS(%rbx)
    movq $0, BS_ALLOWAGG(%rbx)
    call bind_expr
    movq $0, BS_NOCOLS(%rbx)
    mov %rax, %r12
    mov %rax, %rdi
    call expr_is_const              /* literals and operators on them only */
    test %eax, %eax
    jz 5f
    mov %r12, %rax
    movzbl N_TYPE(%rax), %ecx
    cmp $T_NULL, %ecx
    je 2f
    cmp $T_INT, %ecx
    jne 3f
    mov %rax, %r12                  /* evaluate with an empty context */
    lea 0(%rsp), %rdi
    xor %esi, %esi
    mov $EC_SIZE, %edx
    call memset
    lea 0(%rsp), %rsi
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
5:  RAISE E_SEMANTIC_ERROR, "LIMIT/OFFSET must be constant expressions"
ENDF const_int

/* bind_subplan(B rdi, subquery node rsi) -> rax plan (stored in V2) */
FUNC bind_subplan
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov N_V1(%r12), %rdi
    mov %rbx, %rsi
    mov BS_CTES(%rbx), %rdx
    xor %ecx, %ecx
    call bind_query
    mov %rax, N_V2(%r12)
    cmpq $0, QP_CORR(%rax)
    je 1f
    orl $NF_CORR, N_FLAGS(%r12)
1:  LEAVE
ENDF bind_subplan

/* bind_statement(stmt rdi) -> rax plan of a top-level query */
FUNC bind_statement
    sub $8, %rsp
    movq $0, bind_depth(%rip)
    xor %esi, %esi
    xor %edx, %edx
    xor %ecx, %ecx
    call bind_query
    add $8, %rsp
    ret
ENDF bind_statement

/* bind_query(stmt rdi, parent scope rsi, ctes rdx, hide rcx) -> rax plan */
FUNC bind_query
    cmpq $0, SS_UNION(%rdi)
    jne bind_compound
    ENTER 32
    mov %rdi, %rbx                  /* stmt */
    mov %rsi, 0(%rsp)
    mov %rdx, 8(%rsp)
    mov %rcx, 16(%rsp)
    mov $QP_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r12                  /* plan */
    mov SS_DISTINCT(%rbx), %rax
    mov %rax, QP_DISTINCT(%r12)
    mov 0(%rsp), %rdi
    mov 8(%rsp), %rsi
    mov 16(%rsp), %rdx
    call new_scope
    mov %rax, %r13                  /* B */

    /* WITH */
    mov SS_WITH(%rbx), %rsi
    test %rsi, %rsi
    jz 1f
    mov %r13, %rdi
    call bind_with
1:  /* FROM */
    mov SS_FROM(%rbx), %rsi
    test %rsi, %rsi
    jz 2f
    mov %r13, %rdi
    call bind_from
    mov %rax, QP_LFROM(%r12)
2:  mov BS_RVS(%r13), %rax
    mov VEC_LEN(%rax), %rcx
    mov %rcx, BS_NVIS(%r13)
    mov %rcx, QP_NRV(%r12)
    mov VEC_DATA(%rax), %rcx
    mov %rcx, QP_RVS(%r12)

    /* WHERE */
    mov SS_WHERE(%rbx), %rsi
    test %rsi, %rsi
    jz 3f
    movq $0, BS_ALLOWAGG(%r13)
    mov %r13, %rdi
    call bind_expr
    movq $1, BS_ALLOWAGG(%r13)
    mov %rax, QP_WHERE(%r12)
    movzbl N_TYPE(%rax), %ecx
    cmp $T_BOOL, %ecx
    je 3f
    cmp $T_NULL, %ecx
    jne bq_where_type

3:  /* select list, GROUP BY, HAVING, ORDER BY */
    mov %r13, %rdi
    mov %rbx, %rsi
    mov %r12, %rdx
    call bind_select_list
    mov %rax, 24(%rsp)              /* aliases */
    cmpq $0, SS_GROUPBY(%rbx)
    je 4f
    mov %r13, %rdi
    mov %rbx, %rsi
    mov %r12, %rdx
    mov 24(%rsp), %rcx
    call bind_group_by
4:  mov SS_HAVING(%rbx), %rsi
    test %rsi, %rsi
    jz 5f
    mov %r13, %rdi
    call bind_expr
    mov %rax, QP_HAVING(%r12)
    movzbl N_TYPE(%rax), %ecx
    cmp $T_BOOL, %ecx
    je 5f
    cmp $T_NULL, %ecx
    jne bq_having_type
5:  cmpq $0, SS_ORDER(%rbx)
    je 6f
    mov %r13, %rdi
    mov %rbx, %rsi
    mov %r12, %rdx
    call bind_order_by

6:  /* aggregation */
    mov BS_AGGS(%r13), %rax
    mov VEC_LEN(%rax), %rcx
    mov %rcx, QP_NAGGS(%r12)
    mov VEC_DATA(%rax), %rdx
    mov %rdx, QP_AGGS(%r12)
    or QP_NGROUP(%r12), %rcx
    or QP_HAVING(%r12), %rcx
    jz 8f
    movq $1, QP_AGG(%r12)
    xor %r14d, %r14d                /* every output, HAVING and sort key must be grouped */
61: cmp QP_NOUT(%r12), %r14
    jae 62f
    imul $OC_SIZE, %r14, %rax
    add QP_OUT(%r12), %rax
    mov OC_EXPR(%rax), %rdi
    mov %r12, %rsi
    call check_grouped
    inc %r14
    jmp 61b
62: mov QP_HAVING(%r12), %rdi
    mov %r12, %rsi
    call check_grouped
    xor %r14d, %r14d
63: cmp QP_NKEYS(%r12), %r14
    jae 8f
    imul $SK_SIZE, %r14, %rax
    add QP_KEYS(%r12), %rax
    cmpq $-1, SK_OUT(%rax)
    jne 64f
    mov SK_EXPR(%rax), %rdi
    mov %r12, %rsi
    call check_grouped
64: inc %r14
    jmp 63b

8:  /* LIMIT / OFFSET */
    movq $-1, QP_LIMIT(%r12)
    mov SS_LIMIT(%rbx), %rsi
    test %rsi, %rsi
    jz 81f
    mov %r13, %rdi
    mov $-1, %rdx
    call const_int
    mov %rax, QP_LIMIT(%r12)
81: mov SS_OFFSET(%rbx), %rsi
    test %rsi, %rsi
    jz 82f
    mov %r13, %rdi
    xor %edx, %edx
    call const_int
    mov %rax, QP_OFFSET(%r12)
82: mov BS_CORR(%r13), %rax
    mov %rax, QP_CORR(%r12)
    mov %r12, %rdi                  /* logical plan, optimizer, physical */
    call plan_block                 /* plan (plan.S) */
    mov %r12, %rax
    LEAVE
bq_where_type:
    RAISE E_TYPE_ERROR, "WHERE condition must be BOOLEAN"
bq_having_type:
    RAISE E_TYPE_ERROR, "HAVING condition must be BOOLEAN"
ENDF bind_query

/* bind_compound(stmt rdi, parent scope rsi, ctes rdx, hide rcx) -> rax plan
 * of a UNION ALL compound (CR-1, see QP_NUNION in sql.inc).  Every branch is
 * bound like a query of its own in the compound's position (same enclosing
 * scope, visibility of the compound's WITH list); output column i is named
 * after the first branch and has the CASE result type (common_type) of
 * column i of all branches.  ORDER BY may only name output columns or
 * positions; LIMIT/OFFSET apply to the concatenation. */
FUNC bind_compound
    ENTER 48
    mov %rdi, %rbx                  /* stmt */
    mov %rsi, 0(%rsp)
    mov %rdx, 8(%rsp)
    mov %rcx, 16(%rsp)
    mov $QP_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r12                  /* plan */
    movq $-1, QP_LIMIT(%r12)
    mov 0(%rsp), %rdi
    mov 8(%rsp), %rsi
    mov 16(%rsp), %rdx
    call new_scope
    mov %rax, %r13                  /* B: WITH list, ORDER BY, LIMIT */
    mov SS_WITH(%rbx), %rsi
    test %rsi, %rsi
    jz 1f
    mov %r13, %rdi
    call bind_with
1:  /* ---- branches */
    mov SS_UNION(%rbx), %rax
    mov VEC_LEN(%rax), %rcx
    mov %rcx, QP_NUNION(%r12)
    lea (, %rcx, 8), %rdi
    call tmp_zalloc
    mov %rax, QP_UNION(%r12)
    xor %r14d, %r14d
2:  cmp QP_NUNION(%r12), %r14
    jae 3f
    mov SS_UNION(%rbx), %rax
    mov VEC_DATA(%rax), %rax
    mov (%rax, %r14, 8), %rdi
    mov 0(%rsp), %rsi
    mov BS_CTES(%r13), %rdx
    mov 16(%rsp), %rcx
    call bind_query
    mov QP_UNION(%r12), %rcx
    mov %rax, (%rcx, %r14, 8)
    mov QP_CORR(%rax), %rdx
    or %rdx, QP_CORR(%r12)
    mov QP_NOUT(%rax), %rdx
    mov (%rcx), %rcx                /* first branch */
    cmp QP_NOUT(%rcx), %rdx
    jne bc_ncols
    inc %r14
    jmp 2b
3:  /* ---- output columns */
    mov QP_UNION(%r12), %rax
    mov (%rax), %r15                /* first branch */
    mov QP_NOUT(%r15), %rcx
    mov %rcx, QP_NOUT(%r12)
    imul $OC_SIZE, %rcx, %rdi
    call tmp_zalloc
    mov %rax, QP_OUT(%r12)
    xor %r14d, %r14d                /* column */
4:  cmp QP_NOUT(%r12), %r14
    jae 6f
    imul $OC_SIZE, %r14, %rcx
    mov QP_OUT(%r15), %rsi
    add %rcx, %rsi                  /* the first branch's column */
    mov QP_OUT(%r12), %rdi
    add %rcx, %rdi
    mov %rdi, 24(%rsp)              /* the compound's column */
    mov OC_EXPR(%rsi), %rax
    mov %rax, OC_EXPR(%rdi)
    mov OC_NAME(%rsi), %rax
    mov %rax, OC_NAME(%rdi)
    mov OC_TYPE(%rsi), %rax
    mov %rax, OC_TYPE(%rdi)
    movq $1, 32(%rsp)               /* branch */
5:  mov 32(%rsp), %rcx
    cmp QP_NUNION(%r12), %rcx
    jae 51f
    mov QP_UNION(%r12), %rax
    mov (%rax, %rcx, 8), %rax
    mov QP_OUT(%rax), %rax
    imul $OC_SIZE, %r14, %rcx
    mov OC_TYPE(%rax, %rcx), %esi
    mov 24(%rsp), %rax
    mov OC_TYPE(%rax), %edi
    call common_type                /* TYPE_ERROR if incompatible */
    mov 24(%rsp), %rcx
    mov %rax, OC_TYPE(%rcx)
    incq 32(%rsp)
    jmp 5b
51: inc %r14
    jmp 4b
6:  /* ---- ORDER BY over the output columns */
    cmpq $0, SS_ORDER(%rbx)
    je 7f
    mov %r13, %rdi
    mov %rbx, %rsi
    mov %r12, %rdx
    call bind_order_by
7:  /* ---- LIMIT / OFFSET */
    mov SS_LIMIT(%rbx), %rsi
    test %rsi, %rsi
    jz 71f
    mov %r13, %rdi
    mov $-1, %rdx
    call const_int
    mov %rax, QP_LIMIT(%r12)
71: mov SS_OFFSET(%rbx), %rsi
    test %rsi, %rsi
    jz 72f
    mov %r13, %rdi
    xor %edx, %edx
    call const_int
    mov %rax, QP_OFFSET(%r12)
72: mov BS_CORR(%r13), %rax
    or %rax, QP_CORR(%r12)
    mov %r12, %rdi
    call plan_block
    mov %r12, %rax
    LEAVE
bc_ncols:
    RAISE E_SEMANTIC_ERROR, "UNION ALL branches must have the same number of columns"
ENDF bind_compound
