/*
 * rule_fold.S - optimizer rule "fold_constants": constant folding and
 * predicate simplification on the logical plan.
 *
 *   rule_fold_constants(lp rdi, plan rsi) -> rax plan root
 *
 * Every expression of the block (filters, join conditions, projections,
 * grouping keys, aggregate arguments, sort keys) is rewritten in place, so
 * every reference to a node sees the new form:
 *   - constant folding: a subtree without column, aggregate or outer
 *     references, subqueries or PQ_SLEEP is evaluated once and replaced by a
 *     literal of the same type.  If the evaluation raises an error the
 *     subtree is left alone, so the error still happens exactly when (and
 *     only if) the row engine evaluates it.
 *   - predicate simplification: TRUE AND x -> x, x AND TRUE -> x,
 *     FALSE OR x -> x, x OR FALSE -> x, TRUE OR x -> TRUE; FALSE AND x,
 *     x AND FALSE -> FALSE and x OR TRUE -> TRUE only when x cannot raise
 *     an error (the row engine may evaluate x first: OR evaluates its left
 *     operand first, and predicate pushdown reorders WHERE conjuncts).
 *   - a Filter whose predicate folds to TRUE disappears.
 * A rewritten node keeps a copy of itself as written (N_WRITTEN): the
 * physical planner analyses predicates as written (access paths, join keys),
 * so `optimize` never changes which rows are read or how inputs are joined.
 * Nested query blocks are folded when they are planned themselves.
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
    STACK_CHECK
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
    mov %rax, %r12                  /* value */
    mov %rdx, %r13
    mov %rbx, %rdi
    call keep_written
    movl $EK_LIT, N_KIND(%rbx)
    movl $0, N_OP(%rbx)
    mov %r12, N_V1(%rbx)
    xor %eax, %eax
    test %r13d, %r13d
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

/* copy_node(dst rdi, src rsi): dst becomes src (N_SIZE bytes) */
FUNC copy_node
    mov $N_SIZE/8, %ecx
    rep movsq
    ret
ENDF copy_node

/* keep_written(node rdi): records a copy of the node as written before it
 * is rewritten in place (the first rewrite of a node wins) */
FUNC keep_written
    ENTER 0
    mov %rdi, %rbx
    cmpq $0, N_WRITTEN(%rbx)
    jne 9f
    mov $N_SIZE, %edi
    call tmp_alloc
    mov %rax, %r12
    mov %rax, %rdi
    mov %rbx, %rsi
    call copy_node
    mov %r12, N_WRITTEN(%rbx)
9:  LEAVE
ENDF keep_written

/* replace_node(node rdi, by rsi): node becomes a copy of `by` (one of its
 * operands), keeping the node as written */
FUNC replace_node
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    mov N_WRITTEN(%rbx), %r13       /* already rewritten: keep that origin */
    test %r13, %r13
    jnz 1f
    mov $N_SIZE, %edi
    call tmp_alloc
    mov %rax, %r13
    mov %rax, %rdi
    mov %rbx, %rsi
    call copy_node
1:  mov %rbx, %rdi
    mov %r12, %rsi
    call copy_node
    mov %r13, N_WRITTEN(%rbx)
    LEAVE
ENDF replace_node

/* fold_expr(node rdi): bottom-up folding and simplification */
FUNC fold_expr
    STACK_CHECK
    call deadline_tick
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
    call replace_node
    jmp 9f
21: mov %rbx, %rdi                  /* -> left operand (a literal) */
    mov N_A(%rbx), %rsi
    call replace_node
    jmp 9f
22: mov %rbx, %rdi                  /* -> left operand */
    mov N_A(%rbx), %rsi
    call replace_node
    jmp 9f
23: mov %rbx, %rdi                  /* -> right operand (a literal) */
    mov N_B(%rbx), %rsi
    call replace_node
9:  LEAVE
ENDF fold_expr

/* fold_list(node*[] rdi, n rsi): folds every expression of an array */
FUNC fold_list
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r13d, %r13d
1:  cmp %r12, %r13
    jae 9f
    mov (%rbx, %r13, 8), %rdi
    call fold_expr
    inc %r13
    jmp 1b
9:  LEAVE
ENDF fold_list

/* fold_node(slot rdi): folds the expressions of the operator in *slot and
 * of its inputs; a Filter folding to TRUE is replaced by its input */
FUNC fold_node
    STACK_CHECK
    ENTER 0
    mov %rdi, %rbx
0:  mov (%rbx), %r12
    test %r12, %r12
    jz 9f
    mov LP_KIND(%r12), %rax
    cmp $LK_FILTER, %rax
    je 10f
    cmp $LK_JOIN, %rax
    je 20f
    cmp $LK_PROJECT, %rax
    je 30f
    cmp $LK_AGGREGATE, %rax
    je 40f
    cmp $LK_SORT, %rax
    je 50f
    jmp 80f
10: mov LP_A(%r12), %rdi            /* Filter */
    call fold_expr
    mov LP_A(%r12), %rdi
    mov $1, %esi
    call is_lit_bool
    test %eax, %eax
    jz 80f
    mov LP_IN(%r12), %rax           /* TRUE: drop the filter */
    mov %rax, (%rbx)
    jmp 0b
20: mov LP_B(%r12), %rdi            /* Join condition */
    call fold_expr
    jmp 80f
30: xor %r13d, %r13d                /* Project */
31: cmp LP_A(%r12), %r13
    jae 80f
    imul $OC_SIZE, %r13, %rax
    add LP_B(%r12), %rax
    mov OC_EXPR(%rax), %rdi
    call fold_expr
    inc %r13
    jmp 31b
40: mov LP_B(%r12), %rdi            /* Aggregate: keys, then arguments */
    mov LP_A(%r12), %rsi
    call fold_list
    xor %r13d, %r13d
41: cmp LP_C(%r12), %r13
    jae 80f
    mov LP_D(%r12), %rax
    mov (%rax, %r13, 8), %rax
    mov N_A(%rax), %rdi
    call fold_expr
    inc %r13
    jmp 41b
50: xor %r13d, %r13d                /* Sort: keys over the input */
51: cmp LP_A(%r12), %r13
    jae 80f
    imul $SK_SIZE, %r13, %rax
    add LP_B(%r12), %rax
    inc %r13
    cmpq $-1, SK_OUT(%rax)
    jne 51b
    mov SK_EXPR(%rax), %rdi
    call fold_expr
    jmp 51b
80: lea LP_IN(%r12), %rdi
    call fold_node
    lea LP_IN2(%r12), %rdi
    call fold_node
9:  LEAVE
ENDF fold_node

/* rule_fold_constants(lp rdi, plan rsi) -> rax plan root */
FUNC rule_fold_constants
    ENTER 16
    mov %rdi, 0(%rsp)
    lea 0(%rsp), %rdi
    call fold_node
    mov 0(%rsp), %rax
    LEAVE
ENDF rule_fold_constants
