/*
 * optimizer.S - logical rewrites of a bound query block (option
 * `optimize`, default true; `optimize: false` is the unoptimized baseline).
 *
 *   optimize_block(plan rdi)   called by plan_block before pushdown
 *
 * Rewrites (in place, so every reference to a node sees the new form):
 *   - constant folding: a subtree without column, aggregate or outer
 *     references, subqueries or PQ_SLEEP is evaluated once and replaced by a
 *     literal of the same type.  If the evaluation raises an error the
 *     subtree is left alone, so the error still happens exactly when (and
 *     only if) the row engine evaluates it.  Folded casts and arithmetic on
 *     literals also let index selection and row-group skipping see plain
 *     constants (`a = 2 + 3` can use an index on a).
 *   - predicate simplification: TRUE AND x -> x, x AND TRUE -> x,
 *     FALSE OR x -> x, x OR FALSE -> x, TRUE OR x -> TRUE; FALSE AND x,
 *     x AND FALSE -> FALSE and x OR TRUE -> TRUE only when x cannot raise
 *     an error (the row engine may evaluate x first: OR evaluates its left
 *     operand first, and predicate pushdown reorders WHERE conjuncts).
 *     A WHERE / HAVING / pushed filter that folds to TRUE disappears.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .text

/* is_lit_bool(node rdi, value esi) -> eax 1 if node is the non-NULL
 * BOOLEAN literal `value` */
FUNC is_lit_bool
    xor %eax, %eax
    test %rdi, %rdi
    jz 9f
    cmpl $EK_LIT, N_KIND(%rdi)
    jne 9f
    testl $NF_NULL, N_FLAGS(%rdi)
    jnz 9f
    movzbl N_TYPE(%rdi), %ecx
    cmp $T_BOOL, %ecx
    jne 9f
    mov N_V1(%rdi), %rcx
    and $1, %ecx
    cmp %esi, %ecx
    sete %al
9:  ret
ENDF is_lit_bool

/* expr_safe(node rdi) -> eax 1 if evaluating the expression can never
 * raise an error: literals, columns, IS NULL, comparisons and boolean
 * connectives of such expressions */
FUNC expr_safe
    ENTER 0
    mov $1, %eax
    test %rdi, %rdi
    jz 9f
    mov %rdi, %rbx
    mov N_KIND(%rbx), %ecx
    cmp $EK_LIT, %ecx
    je 9f
    cmp $EK_COL, %ecx
    je 9f
    cmp $EK_OUTER, %ecx
    je 9f
    cmp $EK_ISNULL, %ecx
    je 1f
    xor %eax, %eax
    cmp $EK_UNARY, %ecx
    jne 2f
    cmpl $U_NOT, N_OP(%rbx)
    jne 9f
1:  mov N_A(%rbx), %rdi
    call expr_safe
    jmp 9f
2:  cmp $EK_BINARY, %ecx
    jne 9f
    mov N_OP(%rbx), %ecx
    cmp $B_EQ, %ecx
    jb 9f
    mov N_A(%rbx), %rdi
    call expr_safe
    test %eax, %eax
    jz 9f
    mov N_B(%rbx), %rdi
    call expr_safe
9:  LEAVE
ENDF expr_safe

/* try_fold(node rdi): replaces a constant subtree by its value, unless
 * evaluating it raises an error */
FUNC try_fold
    ENTER 288
    mov %rdi, %rbx
    mov g_jmpbuf(%rip), %rax
    mov %rax, 264(%rsp)             /* the request's handler */
    lea 0(%rsp), %rdi               /* jmp_buf at 0..199 */
    mov %rdi, g_jmpbuf(%rip)
    call _setjmp
    test %eax, %eax
    jnz 8f
    lea 200(%rsp), %rdi             /* zero EvalCtx: enough for constants */
    xor %eax, %eax
    mov $EC_SIZE/8, %ecx
    rep stosq
    mov %rbx, %rdi
    lea 200(%rsp), %rsi
    call eval
    mov 264(%rsp), %rcx
    mov %rcx, g_jmpbuf(%rip)
    movl $EK_LIT, N_KIND(%rbx)
    movl $0, N_OP(%rbx)
    mov %rax, N_V1(%rbx)
    xor %eax, %eax
    test %edx, %edx
    jz 1f
    mov $NF_NULL, %eax
1:  mov %eax, N_FLAGS(%rbx)
    movq $0, N_A(%rbx)
    movq $0, N_B(%rbx)
    LEAVE
8:  mov 264(%rsp), %rcx             /* error: keep the expression */
    mov %rcx, g_jmpbuf(%rip)
    LEAVE
ENDF try_fold

/* copy_node(dst rdi, src rsi): dst becomes src (64 bytes) */
FUNC copy_node
    mov $N_SIZE/8, %ecx
    rep movsq
    ret
ENDF copy_node

/* fold_expr(node rdi): bottom-up folding and simplification */
FUNC fold_expr
    ENTER 16
    test %rdi, %rdi
    jz 9f
    mov %rdi, %rbx
    mov N_KIND(%rbx), %eax
    cmp $EK_LIT, %eax
    je 9f
    cmp $EK_COL, %eax
    je 9f
    cmp $EK_OUTER, %eax
    je 9f
    cmp $EK_SUBQ, %eax              /* subquery blocks are optimized when planned */
    je 9f
    cmp $EK_EXISTS, %eax
    je 9f
    mov %rbx, %rdi                  /* children first */
    call expr_nchild
    mov %rax, %r12
    xor %r13d, %r13d
1:  cmp %r12, %r13
    jae 2f
    mov %rbx, %rdi
    mov %r13, %rsi
    call expr_child_ptr
    mov (%rax), %rdi
    call fold_expr
    inc %r13
    jmp 1b
2:  mov %rbx, %rdi
    call expr_batch_const
    test %eax, %eax
    jz 3f
    mov %rbx, %rdi
    call try_fold
    jmp 9f
3:  cmpl $EK_BINARY, N_KIND(%rbx)
    jne 9f
    mov N_OP(%rbx), %eax
    cmp $B_AND, %eax
    je 10f
    cmp $B_OR, %eax
    jne 9f
    /* ---- OR */
    mov N_A(%rbx), %rdi
    xor %esi, %esi
    call is_lit_bool
    test %eax, %eax
    jnz 20f                         /* FALSE OR x -> x */
    mov N_A(%rbx), %rdi
    mov $1, %esi
    call is_lit_bool
    test %eax, %eax
    jnz 21f                         /* TRUE OR x -> TRUE */
    mov N_B(%rbx), %rdi
    xor %esi, %esi
    call is_lit_bool
    test %eax, %eax
    jnz 22f                         /* x OR FALSE -> x */
    mov N_B(%rbx), %rdi
    mov $1, %esi
    call is_lit_bool
    test %eax, %eax
    jz 9f
    mov N_A(%rbx), %rdi             /* x OR TRUE -> TRUE if x is safe */
    call expr_safe
    test %eax, %eax
    jz 9f
    jmp 23f
10: /* ---- AND */
    mov N_A(%rbx), %rdi
    mov $1, %esi
    call is_lit_bool
    test %eax, %eax
    jnz 20f                         /* TRUE AND x -> x */
    mov N_A(%rbx), %rdi
    xor %esi, %esi
    call is_lit_bool
    test %eax, %eax
    jz 11f
    mov N_B(%rbx), %rdi             /* FALSE AND x -> FALSE if x is safe */
    call expr_safe                  /* (WHERE conjuncts are reordered by */
    test %eax, %eax                 /* pushdown, so x may run first) */
    jnz 21f
    jmp 9f
11:
    mov N_B(%rbx), %rdi
    mov $1, %esi
    call is_lit_bool
    test %eax, %eax
    jnz 22f                         /* x AND TRUE -> x */
    mov N_B(%rbx), %rdi
    xor %esi, %esi
    call is_lit_bool
    test %eax, %eax
    jz 9f
    mov N_A(%rbx), %rdi             /* x AND FALSE -> FALSE if x is safe */
    call expr_safe
    test %eax, %eax
    jz 9f
    jmp 23f
20: mov %rbx, %rdi                  /* -> right operand */
    mov N_B(%rbx), %rsi
    call copy_node
    jmp 9f
21: mov %rbx, %rdi                  /* -> left operand (a literal) */
    mov N_A(%rbx), %rsi
    call copy_node
    jmp 9f
22: mov %rbx, %rdi                  /* -> left operand */
    mov N_A(%rbx), %rsi
    call copy_node
    jmp 9f
23: mov %rbx, %rdi                  /* -> right operand (a literal) */
    mov N_B(%rbx), %rsi
    call copy_node
9:  LEAVE
ENDF fold_expr

/* fold_pred(slot rdi): folds the predicate in *slot; drops it if TRUE */
FUNC fold_pred
    push %rbx
    mov %rdi, %rbx
    mov (%rbx), %rdi
    call fold_expr
    mov (%rbx), %rdi
    mov $1, %esi
    call is_lit_bool
    test %eax, %eax
    jz 1f
    movq $0, (%rbx)
1:  pop %rbx
    ret
ENDF fold_pred

/* fold_fp(fp rdi): join conditions of the FROM tree */
FUNC fold_fp
    ENTER 0
    mov %rdi, %rbx
    cmpq $FK_JOIN, FP_KIND(%rbx)
    jne 9f
    mov FP_ON(%rbx), %rdi
    call fold_expr
    mov FP_LEFT(%rbx), %rdi
    call fold_fp
    mov FP_RIGHT(%rbx), %rdi
    call fold_fp
9:  LEAVE
ENDF fold_fp

/* optimize_block(plan rdi) */
FUNC optimize_block
    ENTER 0
    mov %rdi, %rbx
    lea QP_WHERE(%rbx), %rdi
    call fold_pred
    lea QP_HAVING(%rbx), %rdi
    call fold_pred
    xor %r12d, %r12d
1:  cmp QP_NOUT(%rbx), %r12
    jae 2f
    imul $OC_SIZE, %r12, %rax
    add QP_OUT(%rbx), %rax
    mov OC_EXPR(%rax), %rdi
    call fold_expr
    inc %r12
    jmp 1b
2:  xor %r12d, %r12d
3:  cmp QP_NKEYS(%rbx), %r12
    jae 4f
    imul $SK_SIZE, %r12, %rax
    add QP_KEYS(%rbx), %rax
    inc %r12
    cmpq $-1, SK_OUT(%rax)
    jne 3b
    mov SK_EXPR(%rax), %rdi
    call fold_expr
    jmp 3b
4:  xor %r12d, %r12d
5:  cmp QP_NGROUP(%rbx), %r12
    jae 6f
    mov QP_GROUP(%rbx), %rax
    mov (%rax, %r12, 8), %rdi
    call fold_expr
    inc %r12
    jmp 5b
6:  xor %r12d, %r12d
7:  cmp QP_NAGGS(%rbx), %r12
    jae 8f
    mov QP_AGGS(%rbx), %rax
    mov (%rax, %r12, 8), %rax
    mov N_A(%rax), %rdi
    call fold_expr
    inc %r12
    jmp 7b
8:  mov QP_FROM(%rbx), %rdi
    test %rdi, %rdi
    jz 9f
    call fold_fp
9:  LEAVE
ENDF optimize_block
