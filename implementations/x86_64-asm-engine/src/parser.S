/*
 * parser.S - recursive-descent SQL parser (grammar.md §2) building the AST
 * described in sql.inc.  Entry point:
 *
 *   sql_parse(ptr, len) -> rax SelectStmt*
 *
 * Syntax errors raise PARSE_ERROR; valid syntax of features this engine does
 * not implement yet (joins, subqueries, CASE, IN, ...) raises UNSUPPORTED.
 * All parse functions take the parser state (PS_*) in %rdi.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits
    .text

#define MAX_DEPTH 800

/* ================================================================ token helpers */

/* p_cur(P) -> rax token* */
FUNC p_cur
    mov PS_POS(%rdi), %rax
    shl $5, %rax
    add PS_TOKS(%rdi), %rax
    ret
ENDF p_cur

/* p_peek(P, k) -> rax token* at pos+k (clamped to the EOF token) */
FUNC p_peek
    mov PS_POS(%rdi), %rax
    add %rsi, %rax
    mov PS_NTOK(%rdi), %rcx
    dec %rcx
    cmp %rcx, %rax
    cmova %rcx, %rax
    shl $5, %rax
    add PS_TOKS(%rdi), %rax
    ret
ENDF p_peek

/* p_next(P): advance (never past EOF) */
FUNC p_next
    mov PS_POS(%rdi), %rax
    mov PS_NTOK(%rdi), %rcx
    dec %rcx
    cmp %rcx, %rax
    jae 1f
    incq PS_POS(%rdi)
1:  ret
ENDF p_next

/* p_is_kw(P, id) -> eax */
FUNC p_is_kw
    mov PS_POS(%rdi), %rax
    shl $5, %rax
    add PS_TOKS(%rdi), %rax
    xor %ecx, %ecx
    cmpl $TOK_KEYWORD, TK_KIND(%rax)
    jne 1f
    cmp %esi, TK_ID(%rax)
    jne 1f
    mov $1, %ecx
1:  mov %ecx, %eax
    ret
ENDF p_is_kw

/* p_is_op(P, id) -> eax */
FUNC p_is_op
    mov PS_POS(%rdi), %rax
    shl $5, %rax
    add PS_TOKS(%rdi), %rax
    xor %ecx, %ecx
    cmpl $TOK_OP, TK_KIND(%rax)
    jne 1f
    cmp %esi, TK_ID(%rax)
    jne 1f
    mov $1, %ecx
1:  mov %ecx, %eax
    ret
ENDF p_is_op

/* p_accept_kw(P, id) -> eax (advances on match) */
FUNC p_accept_kw
    push %rdi
    call p_is_kw
    pop %rdi
    test %eax, %eax
    jz 1f
    push %rax
    call p_next
    pop %rax
1:  ret
ENDF p_accept_kw

FUNC p_accept_op
    push %rdi
    call p_is_op
    pop %rdi
    test %eax, %eax
    jz 1f
    push %rax
    call p_next
    pop %rax
1:  ret
ENDF p_accept_op

/* p_error(P): raise PARSE_ERROR at the current token */
FUNC p_error
    sub $8, %rsp
    call p_cur
    mov TK_LINE(%rax), %edx
    mov TK_COL(%rax), %ecx
    mov $E_PARSE_ERROR, %edi
    CSTR %rsi, "syntax error at line %d, column %d"
    call pq_raisef
ENDF p_error

/* p_unsupported(P) */
FUNC p_unsupported
    sub $8, %rsp
    call p_cur
    mov TK_LINE(%rax), %edx
    mov TK_COL(%rax), %ecx
    mov $E_UNSUPPORTED, %edi
    CSTR %rsi, "unsupported SQL feature at line %d, column %d"
    call pq_raisef
ENDF p_unsupported

FUNC p_expect_kw
    push %rdi
    call p_accept_kw
    pop %rdi
    test %eax, %eax
    jz p_error
    ret
ENDF p_expect_kw

FUNC p_expect_op
    push %rdi
    call p_accept_op
    pop %rdi
    test %eax, %eax
    jz p_error
    ret
ENDF p_expect_op

/* p_is_ident(P) -> eax 1 if current token is IDENT or QIDENT */
FUNC p_is_ident
    mov PS_POS(%rdi), %rax
    shl $5, %rax
    add PS_TOKS(%rdi), %rax
    mov TK_KIND(%rax), %ecx
    xor %eax, %eax
    cmp $TOK_IDENT, %ecx
    je 1f
    cmp $TOK_QIDENT, %ecx
    jne 2f
1:  mov $1, %eax
2:  ret
ENDF p_is_ident

/* p_ident(P) -> rax pstr of the identifier; advances; PARSE_ERROR otherwise */
FUNC p_ident
    push %rbx
    mov %rdi, %rbx
    call p_cur
    mov TK_KIND(%rax), %ecx
    cmp $TOK_QIDENT, %ecx
    je 1f
    cmp $TOK_IDENT, %ecx
    jne 3f
    mov TK_PTR(%rax), %rdi
    mov TK_LEN(%rax), %rsi
    call pstr_tmp
    jmp 2f
1:  mov TK_PTR(%rax), %rax
    sub $8, %rax
2:  push %rax
    sub $8, %rsp
    mov %rbx, %rdi
    call p_next
    add $8, %rsp
    pop %rax
    pop %rbx
    ret
3:  mov %rbx, %rdi
    call p_error
ENDF p_ident

/* new_node(kind edi, token rsi) -> rax zeroed node with position */
FUNC new_node
    push %rbx
    push %r12
    sub $8, %rsp
    mov %edi, %ebx
    mov %rsi, %r12
    mov $N_SIZE, %edi
    call tmp_zalloc
    mov %ebx, N_KIND(%rax)
    test %r12, %r12
    jz 1f
    mov TK_LINE(%r12), %ecx
    mov %ecx, N_LINE(%rax)
    mov TK_COL(%r12), %ecx
    mov %ecx, N_COL(%rax)
1:  add $8, %rsp
    pop %r12
    pop %rbx
    ret
ENDF new_node

/* depth guard */
FUNC p_enter
    incq PS_DEPTH(%rdi)
    cmpq $MAX_DEPTH, PS_DEPTH(%rdi)
    ja 1f
    ret
1:  sub $8, %rsp
    RAISE E_PARSE_ERROR, "expression nested too deeply"
ENDF p_enter

/* ================================================================ statement */

/* sql_parse(ptr, len) -> SelectStmt* */
FUNC sql_parse
    ENTER 16
    call sql_lex
    mov %rax, %r12
    mov %rdx, %r13
    mov $PS_SIZE, %edi
    call tmp_zalloc
    mov %rax, %rbx
    mov %r12, PS_TOKS(%rbx)
    mov %r13, PS_NTOK(%rbx)
    /* statements of later phases */
    mov %rbx, %rdi
    call p_cur
    cmpl $TOK_KEYWORD, TK_KIND(%rax)
    jne 2f
    mov TK_ID(%rax), %ecx
    cmp $KW_WITH, %ecx
    je 1f
    cmp $KW_EXPLAIN, %ecx
    je 1f
    cmp $KW_CREATE, %ecx
    je 1f
    cmp $KW_DROP, %ecx
    je 1f
    cmp $KW_SELECT, %ecx
    jne 2f
    mov %rbx, %rdi
    call parse_select
    mov %rax, %r12
    mov %rbx, %rdi
    mov $OP_SEMI, %esi
    call p_accept_op
    mov %rbx, %rdi
    call p_cur
    cmpl $TOK_EOF, TK_KIND(%rax)
    je 3f
    mov %rbx, %rdi
    mov $KW_UNION, %esi
    call p_is_kw
    test %eax, %eax
    jnz 1f
2:  mov %rbx, %rdi
    call p_error
1:  mov %rbx, %rdi
    call p_unsupported
3:  mov %r12, %rax
    LEAVE
ENDF sql_parse

/* parse_select(P) -> SelectStmt* */
FUNC parse_select
    ENTER 16
    mov %rdi, %rbx
    mov $KW_SELECT, %esi
    call p_expect_kw
    mov $SS_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r12                  /* stmt */
    mov %rbx, %rdi
    mov $KW_DISTINCT, %esi
    call p_accept_kw
    mov %rax, SS_DISTINCT(%r12)
    test %eax, %eax
    jnz 1f
    mov %rbx, %rdi
    mov $KW_ALL, %esi
    call p_accept_kw
1:  mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, SS_ITEMS(%r12)
2:  mov %rbx, %rdi
    call parse_select_item
    mov SS_ITEMS(%r12), %rdi
    mov %rax, %rsi
    call vec_push
    mov %rbx, %rdi
    mov $OP_COMMA, %esi
    call p_accept_op
    test %eax, %eax
    jnz 2b

    /* FROM */
    mov %rbx, %rdi
    mov $KW_FROM, %esi
    call p_accept_kw
    test %eax, %eax
    jz 5f
    mov %rbx, %rdi
    mov $OP_LPAREN, %esi
    call p_is_op
    test %eax, %eax
    jnz ps_unsupported
    mov %rbx, %rdi
    call p_ident
    mov %rax, SS_FROM(%r12)
    mov %rbx, %rdi
    mov $KW_AS, %esi
    call p_accept_kw
    test %eax, %eax
    jnz 3f
    mov %rbx, %rdi
    call p_is_ident
    test %eax, %eax
    jz 4f
3:  mov %rbx, %rdi
    call p_ident
    mov %rax, SS_ALIAS(%r12)
4:  /* joins / derived tables are later-phase features */
    mov %rbx, %rdi
    call p_cur
    cmpl $TOK_OP, TK_KIND(%rax)
    jne 41f
    cmpl $OP_COMMA, TK_ID(%rax)
    je ps_unsupported
41: cmpl $TOK_KEYWORD, TK_KIND(%rax)
    jne 5f
    mov TK_ID(%rax), %ecx
    cmp $KW_JOIN, %ecx
    je ps_unsupported
    cmp $KW_INNER, %ecx
    je ps_unsupported
    cmp $KW_LEFT, %ecx
    je ps_unsupported
    cmp $KW_CROSS, %ecx
    je ps_unsupported
    cmp $KW_RIGHT, %ecx
    je ps_unsupported
    cmp $KW_FULL, %ecx
    je ps_unsupported

5:  /* WHERE */
    mov %rbx, %rdi
    mov $KW_WHERE, %esi
    call p_accept_kw
    test %eax, %eax
    jz 6f
    mov %rbx, %rdi
    call parse_expr
    mov %rax, SS_WHERE(%r12)
6:  /* GROUP BY */
    mov %rbx, %rdi
    mov $KW_GROUP, %esi
    call p_accept_kw
    test %eax, %eax
    jz 7f
    mov %rbx, %rdi
    mov $KW_BY, %esi
    call p_expect_kw
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, SS_GROUPBY(%r12)
61: mov %rbx, %rdi
    call parse_expr
    mov SS_GROUPBY(%r12), %rdi
    mov %rax, %rsi
    call vec_push
    mov %rbx, %rdi
    mov $OP_COMMA, %esi
    call p_accept_op
    test %eax, %eax
    jnz 61b
7:  /* HAVING */
    mov %rbx, %rdi
    mov $KW_HAVING, %esi
    call p_accept_kw
    test %eax, %eax
    jz 8f
    mov %rbx, %rdi
    call parse_expr
    mov %rax, SS_HAVING(%r12)
8:  /* ORDER BY */
    mov %rbx, %rdi
    mov $KW_ORDER, %esi
    call p_accept_kw
    test %eax, %eax
    jz 9f
    mov %rbx, %rdi
    mov $KW_BY, %esi
    call p_expect_kw
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, SS_ORDER(%r12)
81: mov %rbx, %rdi
    call parse_order_item
    mov SS_ORDER(%r12), %rdi
    mov %rax, %rsi
    call vec_push
    mov %rbx, %rdi
    mov $OP_COMMA, %esi
    call p_accept_op
    test %eax, %eax
    jnz 81b
9:  /* LIMIT / OFFSET in either order */
    mov %rbx, %rdi
    mov $KW_LIMIT, %esi
    call p_accept_kw
    test %eax, %eax
    jz 92f
    mov %rbx, %rdi
    call parse_expr
    mov %rax, SS_LIMIT(%r12)
    mov %rbx, %rdi
    mov $KW_OFFSET, %esi
    call p_accept_kw
    test %eax, %eax
    jz 99f
    mov %rbx, %rdi
    call parse_expr
    mov %rax, SS_OFFSET(%r12)
    jmp 99f
92: mov %rbx, %rdi
    mov $KW_OFFSET, %esi
    call p_accept_kw
    test %eax, %eax
    jz 99f
    mov %rbx, %rdi
    call parse_expr
    mov %rax, SS_OFFSET(%r12)
    mov %rbx, %rdi
    mov $KW_LIMIT, %esi
    call p_accept_kw
    test %eax, %eax
    jz 99f
    mov %rbx, %rdi
    call parse_expr
    mov %rax, SS_LIMIT(%r12)
99: mov %r12, %rax
    LEAVE
ps_unsupported:
    mov %rbx, %rdi
    call p_unsupported
ENDF parse_select

/* parse_select_item(P) -> SelectItem* */
FUNC parse_select_item
    ENTER 16
    mov %rdi, %rbx
    mov $SI_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r12
    mov %rbx, %rdi
    mov $OP_STAR, %esi
    call p_accept_op
    test %eax, %eax
    jz 1f
    movq $1, SI_KIND(%r12)
    jmp 9f
1:  /* q.* ? */
    mov %rbx, %rdi
    call p_is_ident
    test %eax, %eax
    jz 2f
    mov %rbx, %rdi
    mov $1, %esi
    call p_peek
    cmpl $TOK_OP, TK_KIND(%rax)
    jne 2f
    cmpl $OP_DOT, TK_ID(%rax)
    jne 2f
    mov %rbx, %rdi
    mov $2, %esi
    call p_peek
    cmpl $TOK_OP, TK_KIND(%rax)
    jne 2f
    cmpl $OP_STAR, TK_ID(%rax)
    jne 2f
    mov %rbx, %rdi
    call p_ident
    mov %rax, SI_QUAL(%r12)
    movq $2, SI_KIND(%r12)
    mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    call p_next
    jmp 9f
2:  mov %rbx, %rdi
    call parse_expr
    mov %rax, SI_EXPR(%r12)
    mov %rbx, %rdi
    mov $KW_AS, %esi
    call p_accept_kw
    test %eax, %eax
    jnz 3f
    mov %rbx, %rdi
    call p_is_ident
    test %eax, %eax
    jz 9f
3:  mov %rbx, %rdi
    call p_ident
    mov %rax, SI_ALIAS(%r12)
9:  mov %r12, %rax
    LEAVE
ENDF parse_select_item

/* parse_order_item(P) -> OrderItem* */
FUNC parse_order_item
    ENTER 16
    mov %rdi, %rbx
    mov $OI_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r12
    mov %rbx, %rdi
    call parse_expr
    mov %rax, OI_EXPR(%r12)
    mov %rbx, %rdi
    mov $KW_DESC, %esi
    call p_accept_kw
    test %eax, %eax
    jz 1f
    movq $1, OI_DESC(%r12)
    jmp 2f
1:  mov %rbx, %rdi
    mov $KW_ASC, %esi
    call p_accept_kw
2:  mov %rbx, %rdi
    mov $KW_NULLS, %esi
    call p_accept_kw
    test %eax, %eax
    jz 9f
    mov %rbx, %rdi
    mov $KW_FIRST, %esi
    call p_accept_kw
    test %eax, %eax
    jz 3f
    movq $1, OI_NULLS(%r12)
    jmp 9f
3:  mov %rbx, %rdi
    mov $KW_LAST, %esi
    call p_expect_kw
    movq $2, OI_NULLS(%r12)
9:  mov %r12, %rax
    LEAVE
ENDF parse_order_item

/* ================================================================ expressions */

/* mk_binary(op edi, left rsi, right rdx, token rcx) -> node */
FUNC mk_binary
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $8, %rsp
    mov %edi, %ebx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %rsi
    mov $EK_BINARY, %edi
    call new_node
    mov %ebx, N_OP(%rax)
    mov %r12, N_A(%rax)
    mov %r13, N_B(%rax)
    add $8, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    ret
ENDF mk_binary

/* parse_expr(P) -> node */
FUNC parse_expr
    ENTER 0
    mov %rdi, %rbx
    call p_enter
    mov %rbx, %rdi
    call parse_or
    decq PS_DEPTH(%rbx)
    LEAVE
ENDF parse_expr

FUNC parse_or
    ENTER 0
    mov %rdi, %rbx
    call parse_and
    mov %rax, %r12
1:  mov %rbx, %rdi
    call p_cur
    mov %rax, %r14
    mov %rbx, %rdi
    mov $KW_OR, %esi
    call p_accept_kw
    test %eax, %eax
    jz 2f
    mov %rbx, %rdi
    call parse_and
    mov $B_OR, %edi
    mov %r12, %rsi
    mov %rax, %rdx
    mov %r14, %rcx
    call mk_binary
    mov %rax, %r12
    jmp 1b
2:  mov %r12, %rax
    LEAVE
ENDF parse_or

FUNC parse_and
    ENTER 0
    mov %rdi, %rbx
    call parse_not
    mov %rax, %r12
1:  mov %rbx, %rdi
    call p_cur
    mov %rax, %r14
    mov %rbx, %rdi
    mov $KW_AND, %esi
    call p_accept_kw
    test %eax, %eax
    jz 2f
    mov %rbx, %rdi
    call parse_not
    mov $B_AND, %edi
    mov %r12, %rsi
    mov %rax, %rdx
    mov %r14, %rcx
    call mk_binary
    mov %rax, %r12
    jmp 1b
2:  mov %r12, %rax
    LEAVE
ENDF parse_and

FUNC parse_not
    ENTER 0
    mov %rdi, %rbx
    call p_cur
    mov %rax, %r14
    mov %rbx, %rdi
    mov $KW_NOT, %esi
    call p_accept_kw
    test %eax, %eax
    jz 1f
    mov %rbx, %rdi
    call p_enter
    mov %rbx, %rdi
    call parse_not
    decq PS_DEPTH(%rbx)
    mov %rax, %r12
    mov $EK_UNARY, %edi
    mov %r14, %rsi
    call new_node
    movl $U_NOT, N_OP(%rax)
    mov %r12, N_A(%rax)
    LEAVE
1:  mov %rbx, %rdi
    call parse_predicate
    LEAVE
ENDF parse_not

/* predicate = concat [ comp concat | IS [NOT] NULL | [NOT] BETWEEN/IN/LIKE ... ] */
FUNC parse_predicate
    ENTER 0
    mov %rdi, %rbx
    call parse_concat
    mov %rax, %r12
    mov %rbx, %rdi
    call p_cur
    mov %rax, %r14
    mov TK_KIND(%r14), %ecx
    cmp $TOK_OP, %ecx
    jne 3f
    mov TK_ID(%r14), %ecx
    cmp $OP_EQ, %ecx
    jb 9f
    cmp $OP_GE, %ecx
    ja 9f
    /* comparison: B_EQ.. map 1:1 from OP_EQ.. (OP_EQ=7=B_EQ) */
    mov %ecx, %r13d
    mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    call parse_concat
    mov %r13d, %edi
    mov %r12, %rsi
    mov %rax, %rdx
    mov %r14, %rcx
    call mk_binary
    LEAVE
3:  cmp $TOK_KEYWORD, %ecx
    jne 9f
    mov TK_ID(%r14), %ecx
    cmp $KW_IS, %ecx
    je 4f
    cmp $KW_BETWEEN, %ecx
    je 8f
    cmp $KW_IN, %ecx
    je 8f
    cmp $KW_LIKE, %ecx
    je 8f
    cmp $KW_NOT, %ecx
    jne 9f
    mov %rbx, %rdi
    mov $1, %esi
    call p_peek
    cmpl $TOK_KEYWORD, TK_KIND(%rax)
    jne 9f
    mov TK_ID(%rax), %ecx
    cmp $KW_BETWEEN, %ecx
    je 8f
    cmp $KW_IN, %ecx
    je 8f
    cmp $KW_LIKE, %ecx
    je 8f
    jmp 9f
4:  /* IS [NOT] NULL */
    mov %rbx, %rdi
    call p_next
    xor %r13d, %r13d
    mov %rbx, %rdi
    mov $KW_NOT, %esi
    call p_accept_kw
    mov %eax, %r13d
    mov %rbx, %rdi
    mov $KW_NULL, %esi
    call p_expect_kw
    mov $EK_ISNULL, %edi
    mov %r14, %rsi
    call new_node
    mov %r13d, N_OP(%rax)
    mov %r12, N_A(%rax)
    LEAVE
8:  mov %rbx, %rdi
    call p_unsupported
9:  mov %r12, %rax
    LEAVE
ENDF parse_predicate

FUNC parse_concat
    ENTER 0
    mov %rdi, %rbx
    call parse_additive
    mov %rax, %r12
1:  mov %rbx, %rdi
    call p_cur
    mov %rax, %r14
    mov %rbx, %rdi
    mov $OP_CONCAT, %esi
    call p_accept_op
    test %eax, %eax
    jz 2f
    mov %rbx, %rdi
    call parse_additive
    mov $B_CONCAT, %edi
    mov %r12, %rsi
    mov %rax, %rdx
    mov %r14, %rcx
    call mk_binary
    mov %rax, %r12
    jmp 1b
2:  mov %r12, %rax
    LEAVE
ENDF parse_concat

FUNC parse_additive
    ENTER 0
    mov %rdi, %rbx
    call parse_mult
    mov %rax, %r12
1:  mov %rbx, %rdi
    call p_cur
    mov %rax, %r14
    cmpl $TOK_OP, TK_KIND(%r14)
    jne 2f
    mov TK_ID(%r14), %ecx
    mov $B_ADD, %r13d
    cmp $OP_PLUS, %ecx
    je 3f
    mov $B_SUB, %r13d
    cmp $OP_MINUS, %ecx
    jne 2f
3:  mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    call parse_mult
    mov %r13d, %edi
    mov %r12, %rsi
    mov %rax, %rdx
    mov %r14, %rcx
    call mk_binary
    mov %rax, %r12
    jmp 1b
2:  mov %r12, %rax
    LEAVE
ENDF parse_additive

FUNC parse_mult
    ENTER 0
    mov %rdi, %rbx
    call parse_unary
    mov %rax, %r12
1:  mov %rbx, %rdi
    call p_cur
    mov %rax, %r14
    cmpl $TOK_OP, TK_KIND(%r14)
    jne 2f
    mov TK_ID(%r14), %ecx
    mov $B_MUL, %r13d
    cmp $OP_STAR, %ecx
    je 3f
    mov $B_DIV, %r13d
    cmp $OP_SLASH, %ecx
    je 3f
    mov $B_MOD, %r13d
    cmp $OP_PERCENT, %ecx
    jne 2f
3:  mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    call parse_unary
    mov %r13d, %edi
    mov %r12, %rsi
    mov %rax, %rdx
    mov %r14, %rcx
    call mk_binary
    mov %rax, %r12
    jmp 1b
2:  mov %r12, %rax
    LEAVE
ENDF parse_mult

FUNC parse_unary
    ENTER 0
    mov %rdi, %rbx
    call p_cur
    mov %rax, %r14
    cmpl $TOK_OP, TK_KIND(%r14)
    jne 5f
    mov TK_ID(%r14), %ecx
    mov $U_NEG, %r13d
    cmp $OP_MINUS, %ecx
    je 1f
    mov $U_POS, %r13d
    cmp $OP_PLUS, %ecx
    jne 5f
1:  mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    call p_enter
    mov %rbx, %rdi
    call parse_unary
    decq PS_DEPTH(%rbx)
    mov %rax, %r12
    /* fold -9223372036854775808 */
    cmp $U_NEG, %r13d
    jne 2f
    cmpl $EK_LIT, N_KIND(%r12)
    jne 2f
    testl $NF_MINLIT, N_FLAGS(%r12)
    jz 2f
    andl $~NF_MINLIT, N_FLAGS(%r12)
    mov %r12, %rax
    LEAVE
2:  mov $EK_UNARY, %edi
    mov %r14, %rsi
    call new_node
    mov %r13d, N_OP(%rax)
    mov %r12, N_A(%rax)
    LEAVE
5:  mov %rbx, %rdi
    call parse_primary
    LEAVE
ENDF parse_unary

/* parse_primary(P) -> node */
FUNC parse_primary
    ENTER 32
    mov %rdi, %rbx
    call p_cur
    mov %rax, %r14
    mov TK_KIND(%r14), %ecx
    cmp $TOK_NUMBER, %ecx
    je pp_number
    cmp $TOK_STRING, %ecx
    je pp_string
    cmp $TOK_IDENT, %ecx
    je pp_ident
    cmp $TOK_QIDENT, %ecx
    je pp_ident
    cmp $TOK_OP, %ecx
    je pp_op
    cmp $TOK_KEYWORD, %ecx
    jne pp_error
    mov TK_ID(%r14), %ecx
    cmp $KW_TRUE, %ecx
    je pp_true
    cmp $KW_FALSE, %ecx
    je pp_false
    cmp $KW_NULL, %ecx
    je pp_null
    cmp $KW_DATE, %ecx
    je pp_date
    cmp $KW_TIMESTAMP, %ecx
    je pp_timestamp
    cmp $KW_CAST, %ecx
    je pp_cast
    cmp $KW_CASE, %ecx
    je pp_unsupported
    cmp $KW_EXISTS, %ecx
    je pp_unsupported
pp_error:
    mov %rbx, %rdi
    call p_error
pp_unsupported:
    mov %rbx, %rdi
    call p_unsupported

pp_op:
    cmpl $OP_LPAREN, TK_ID(%r14)
    jne pp_error
    mov %rbx, %rdi
    mov $1, %esi
    call p_peek
    cmpl $TOK_KEYWORD, TK_KIND(%rax)
    jne 1f
    cmpl $KW_SELECT, TK_ID(%rax)
    je pp_unsupported
    cmpl $KW_WITH, TK_ID(%rax)
    je pp_unsupported
1:  mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    call parse_expr
    mov %rax, %r12
    orl $NF_PAREN, N_FLAGS(%r12)
    mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_expect_op
    mov %r12, %rax
    LEAVE

pp_true:
    mov $1, %r12d
    jmp 1f
pp_false:
    xor %r12d, %r12d
1:  mov $EK_LIT, %edi
    mov %r14, %rsi
    call new_node
    movl $T_BOOL, N_TYPE(%rax)
    mov %r12, N_V1(%rax)
    jmp pp_done_advance
pp_null:
    mov $EK_LIT, %edi
    mov %r14, %rsi
    call new_node
    movl $T_NULL, N_TYPE(%rax)
    movl $NF_NULL, N_FLAGS(%rax)
    jmp pp_done_advance
pp_string:
    mov $EK_LIT, %edi
    mov %r14, %rsi
    call new_node
    movl $T_STR, N_TYPE(%rax)
    mov TK_PTR(%r14), %rcx
    sub $8, %rcx
    mov %rcx, N_V1(%rax)
pp_done_advance:
    mov %rax, %r12
    mov %rbx, %rdi
    call p_next
    mov %r12, %rax
    LEAVE

pp_date:
    mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    call p_cur
    mov %rax, %r14
    cmpl $TOK_STRING, TK_KIND(%r14)
    jne pp_error
    mov TK_PTR(%r14), %rdi
    mov TK_LEN(%r14), %rsi
    call text_parse_date
    test %edx, %edx
    jnz pp_bad_date
    mov %rax, %r12
    mov $EK_LIT, %edi
    mov %r14, %rsi
    call new_node
    movl $T_DATE, N_TYPE(%rax)
    mov %r12, N_V1(%rax)
    jmp pp_done_advance
pp_bad_date:
    RAISE E_CONVERSION_ERROR, "invalid DATE literal"

pp_timestamp:
    mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    call p_cur
    mov %rax, %r14
    cmpl $TOK_STRING, TK_KIND(%r14)
    jne pp_error
    mov TK_PTR(%r14), %rdi
    mov TK_LEN(%r14), %rsi
    mov $1, %edx
    call text_parse_timestamp
    test %edx, %edx
    jnz pp_bad_ts
    mov %rax, %r12
    mov $EK_LIT, %edi
    mov %r14, %rsi
    call new_node
    movl $T_TS, N_TYPE(%rax)
    mov %r12, N_V1(%rax)
    jmp pp_done_advance
pp_bad_ts:
    RAISE E_CONVERSION_ERROR, "invalid TIMESTAMP literal"

pp_number:
    mov TK_ID(%r14), %ecx
    test $NUMF_EXP, %ecx
    jnz pp_float
    test $NUMF_DOT, %ecx
    jnz pp_decimal
    /* integer literal */
    mov TK_PTR(%r14), %rdi
    mov TK_LEN(%r14), %rsi
    call text_parse_int64
    mov %rax, %r12
    xor %r13d, %r13d
    test %edx, %edx
    jz 1f
    /* overflow: 9223372036854775808 is allowed under unary minus */
    mov TK_PTR(%r14), %rdi
    mov TK_LEN(%r14), %rsi
    CSTR %rdx, "9223372036854775808"
    call cstr_ieq
    test %eax, %eax
    jz pp_int_overflow
    mov $NF_MINLIT, %r13d
    mov $0x8000000000000000, %r12
1:  mov $EK_LIT, %edi
    mov %r14, %rsi
    call new_node
    movl $T_INT, N_TYPE(%rax)
    mov %r12, N_V1(%rax)
    mov %r13d, N_FLAGS(%rax)
    jmp pp_done_advance
pp_int_overflow:
    RAISE E_NUMERIC_OVERFLOW, "integer literal out of range"

pp_float:
    mov TK_PTR(%r14), %rdi
    mov TK_LEN(%r14), %rsi
    call text_parse_float
    test %eax, %eax
    jnz pp_float_overflow
    movq %xmm0, %r12
    mov $EK_LIT, %edi
    mov %r14, %rsi
    call new_node
    movl $T_FLOAT, N_TYPE(%rax)
    mov %r12, N_V1(%rax)
    jmp pp_done_advance
pp_float_overflow:
    RAISE E_NUMERIC_OVERFLOW, "numeric literal out of range"

pp_decimal:
    /* count significant integer digits (no leading zeros) and fraction digits */
    mov TK_PTR(%r14), %rdi
    mov TK_LEN(%r14), %rsi
    xor %ecx, %ecx                  /* index */
    xor %r8d, %r8d                  /* significant int digits */
    xor %r9d, %r9d                  /* fraction digits */
    xor %r10d, %r10d                /* seen nonzero */
1:  cmp %rsi, %rcx
    jae 4f
    movzbl (%rdi, %rcx), %eax
    inc %rcx
    cmp $'.', %al
    je 3f
    test %r10d, %r10d
    jnz 2f
    cmp $'0', %al
    je 1b
    mov $1, %r10d
2:  inc %r8d
    jmp 1b
3:  mov %rsi, %r9
    sub %rcx, %r9                   /* digits after the point */
4:  lea (%r8, %r9), %eax            /* p = max(int + s, 1) */
    test %eax, %eax
    jnz 5f
    mov $1, %eax
5:  cmp $18, %eax
    ja pp_float
    mov %eax, 0(%rsp)               /* p */
    mov %r9d, 4(%rsp)               /* s */
    mov $18, %edx
    mov %r9d, %ecx
    xor %r8d, %r8d
    call text_parse_decimal
    test %edx, %edx
    jnz pp_float
    mov %rax, %r12
    mov $EK_LIT, %edi
    mov %r14, %rsi
    call new_node
    mov 0(%rsp), %ecx
    shl $8, %ecx
    mov 4(%rsp), %edx
    shl $16, %edx
    or %edx, %ecx
    or $T_DEC, %ecx
    mov %ecx, N_TYPE(%rax)
    mov %r12, N_V1(%rax)
    jmp pp_done_advance

/* CAST ( expr AS type ) */
pp_cast:
    mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    mov $OP_LPAREN, %esi
    call p_expect_op
    mov %rbx, %rdi
    call parse_expr
    mov %rax, %r12
    mov %rbx, %rdi
    mov $KW_AS, %esi
    call p_expect_kw
    mov %rbx, %rdi
    call parse_type_name
    mov %rax, %r13
    mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_expect_op
    mov $EK_CAST, %edi
    mov %r14, %rsi
    call new_node
    mov %r12, N_A(%rax)
    mov %r13, N_V1(%rax)
    LEAVE

/* identifier: column reference or function call */
pp_ident:
    mov %rbx, %rdi
    mov $1, %esi
    call p_peek
    cmpl $TOK_OP, TK_KIND(%rax)
    jne pp_column
    cmpl $OP_LPAREN, TK_ID(%rax)
    je pp_func
pp_column:
    mov %rbx, %rdi
    call p_ident
    mov %rax, %r12                  /* first name */
    xor %r13d, %r13d                /* qualifier */
    mov %rbx, %rdi
    mov $OP_DOT, %esi
    call p_accept_op
    test %eax, %eax
    jz 1f
    mov %r12, %r13
    mov %rbx, %rdi
    call p_ident
    mov %rax, %r12
1:  mov $EK_COL, %edi
    mov %r14, %rsi
    call new_node
    mov %r13, N_A(%rax)
    mov %r12, N_B(%rax)
    LEAVE

pp_func:
    mov %rbx, %rdi
    call p_ident
    mov %rax, %r12                  /* name */
    mov %rbx, %rdi
    call p_next                     /* '(' */
    mov $EK_FUNC, %edi
    mov %r14, %rsi
    call new_node
    mov %rax, %r13
    mov %r12, N_B(%r13)
    mov %rbx, %rdi
    mov $OP_STAR, %esi
    call p_accept_op
    test %eax, %eax
    jz 1f
    orl $NF_STAR, N_FLAGS(%r13)
    jmp 8f
1:  mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_is_op
    test %eax, %eax
    jnz 8f
    mov %rbx, %rdi
    mov $KW_DISTINCT, %esi
    call p_accept_kw
    test %eax, %eax
    jz 2f
    orl $NF_DISTINCT, N_FLAGS(%r13)
2:  mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, 8(%rsp)
3:  mov %rbx, %rdi
    call parse_expr
    mov 8(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
    mov %rbx, %rdi
    mov $OP_COMMA, %esi
    call p_accept_op
    test %eax, %eax
    jnz 3b
    mov 8(%rsp), %rax
    mov VEC_DATA(%rax), %rcx
    mov %rcx, N_A(%r13)
    mov VEC_LEN(%rax), %rcx
    mov %rcx, N_V1(%r13)
8:  mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_expect_op
    mov %r13, %rax
    LEAVE
ENDF parse_primary

/* parse_type_name(P) -> rax packed type.  ident [ ( n [, n] ) ] */
FUNC parse_type_name
    ENTER 32
    mov %rdi, %rbx
    call p_cur
    mov %rax, %r14
    mov TK_KIND(%r14), %ecx
    cmp $TOK_IDENT, %ecx
    je 1f
    cmp $TOK_QIDENT, %ecx
    je 1f
    cmp $TOK_KEYWORD, %ecx
    jne pt_error
    mov TK_ID(%r14), %ecx
    cmp $KW_DATE, %ecx
    je 1f
    cmp $KW_TIMESTAMP, %ecx
    jne pt_error
1:  mov TK_PTR(%r14), %rdi
    mov TK_LEN(%r14), %rsi
    call type_lookup_name
    cmp $-1, %eax
    je pt_unknown
    mov %eax, %r12d                 /* kind */
    mov %edx, %r13d                 /* decimal? */
    mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    mov $OP_LPAREN, %esi
    call p_accept_op
    test %eax, %eax
    jnz 3f
    /* no parameters */
    mov %r12d, %eax
    test %r13d, %r13d
    jz 9f
    mov $MKDEC(18, 0), %eax
    jmp 9f
3:  /* parameters */
    mov %rbx, %rdi
    call pt_number
    mov %rax, 0(%rsp)               /* p */
    movq $0, 8(%rsp)                /* s */
    mov %rbx, %rdi
    mov $OP_COMMA, %esi
    call p_accept_op
    test %eax, %eax
    jz 4f
    mov %rbx, %rdi
    call pt_number
    mov %rax, 8(%rsp)
4:  mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_expect_op
    test %r13d, %r13d
    jnz 5f
    mov %r12d, %eax                 /* VARCHAR(n) etc: length ignored for STRING */
    cmp $T_STR, %eax
    je 9f
    jmp pt_badparams
5:  mov 0(%rsp), %rax
    mov 8(%rsp), %rcx
    cmp $1, %rax
    jl pt_badparams
    cmp $18, %rax
    jg pt_badparams
    cmp %rax, %rcx
    jg pt_badparams
    shl $8, %rax
    shl $16, %rcx
    or %rcx, %rax
    or $T_DEC, %rax
9:  LEAVE
pt_error:
    mov %rbx, %rdi
    call p_error
pt_unknown:
    RAISE E_SEMANTIC_ERROR, "unknown type name"
pt_badparams:
    RAISE E_SEMANTIC_ERROR, "invalid type parameters"
ENDF parse_type_name

/* pt_number(P) -> rax small non-negative integer from a NUMBER token */
FUNC pt_number
    push %rbx
    mov %rdi, %rbx
    call p_cur
    cmpl $TOK_NUMBER, TK_KIND(%rax)
    jne 1f
    cmpl $0, TK_ID(%rax)
    jne 1f
    mov TK_PTR(%rax), %rdi
    mov TK_LEN(%rax), %rsi
    call text_parse_int64
    test %edx, %edx
    jnz 2f
    push %rax
    sub $8, %rsp
    mov %rbx, %rdi
    call p_next
    add $8, %rsp
    pop %rax
    pop %rbx
    ret
1:  mov %rbx, %rdi
    call p_error
2:  RAISE E_SEMANTIC_ERROR, "invalid type parameters"
ENDF pt_number
