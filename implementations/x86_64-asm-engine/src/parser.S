/*
 * parser.S - recursive-descent SQL parser (grammar.md §2) building the AST
 * described in sql.inc.  Entry point:
 *
 *   sql_parse(ptr, len) -> rax SelectStmt*
 *
 * Syntax errors raise PARSE_ERROR; valid syntax of features this engine does
 * not implement yet raises UNSUPPORTED.
 * All parse functions take the parser state (PS_*) in %rdi.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits
    .text

#define MAX_DEPTH 4000

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

/* p_error(P): raise PARSE_ERROR at the current token; a syntax error at one
 * of the keywords reserved for future use (UNION without ALL, RIGHT, FULL)
 * is UNSUPPORTED */
FUNC p_error
    sub $8, %rsp
    call p_cur
    cmpl $TOK_KEYWORD, TK_KIND(%rax)
    jne 1f
    mov TK_ID(%rax), %ecx
    cmp $KW_UNION, %ecx
    je 3f
    cmp $KW_RIGHT, %ecx
    je 2f
    cmp $KW_FULL, %ecx
    je 2f
1:  mov TK_LINE(%rax), %edx
    mov TK_COL(%rax), %ecx
    mov %rdx, g_err_line(%rip)
    mov %rcx, g_err_col(%rip)
    mov $E_PARSE_ERROR, %edi
    CSTR %rsi, "syntax error at line %d, column %d"
    call pq_raisef
2:  mov TK_LINE(%rax), %edx
    mov TK_COL(%rax), %ecx
    mov $E_UNSUPPORTED, %edi
    CSTR %rsi, "unsupported SQL feature at line %d, column %d"
    call pq_raisef
3:  /* UNION ALL is supported syntax: here it is misplaced (after ORDER BY /
     * LIMIT, after a parenthesised branch) */
    cmpl $TOK_KEYWORD, TK_KIND+TK_SIZE(%rax)
    jne 2b
    cmpl $KW_ALL, TK_ID+TK_SIZE(%rax)
    jne 2b
    jmp 1b
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

/* sql_parse(ptr, len) -> rax Stmt* (ST_*) */
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
    mov $ST_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r12                  /* stmt */
    mov %rbx, %rdi
    call p_cur
    cmpl $TOK_KEYWORD, TK_KIND(%rax)
    jne 9f
    mov TK_ID(%rax), %ecx
    cmp $KW_EXPLAIN, %ecx
    je 2f
    cmp $KW_CREATE, %ecx
    je 3f
    cmp $KW_DROP, %ecx
    je 4f
    cmp $KW_SELECT, %ecx
    je 1f
    cmp $KW_WITH, %ecx
    jne 9f
1:  movq $STMT_QUERY, ST_KIND(%r12)
    mov %rbx, %rdi
    call parse_query
    mov %rax, ST_QUERY(%r12)
    jmp 8f
2:  movq $STMT_EXPLAIN, ST_KIND(%r12)
    mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    call parse_query
    mov %rax, ST_QUERY(%r12)
    jmp 8f
3:  mov %rbx, %rdi
    mov %r12, %rsi
    call parse_create_index
    jmp 8f
4:  mov %rbx, %rdi
    mov %r12, %rsi
    call parse_drop_index
8:  /* optional single ';', then end of input */
    mov %rbx, %rdi
    mov $OP_SEMI, %esi
    call p_accept_op
    mov %rbx, %rdi
    call p_cur
    cmpl $TOK_EOF, TK_KIND(%rax)
    jne 9f
    mov %r12, %rax
    LEAVE
9:  mov %rbx, %rdi
    call p_error
ENDF sql_parse

/* parse_create_index(P, stmt):
 * CREATE INDEX [IF NOT EXISTS] name ON table ( column ) [USING HASH|BTREE] */
FUNC parse_create_index
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    movq $STMT_CREATE_INDEX, ST_KIND(%r12)
    call p_next
    mov %rbx, %rdi
    mov $KW_INDEX, %esi
    call p_expect_kw
    mov %rbx, %rdi
    mov $KW_IF, %esi
    call p_accept_kw
    test %eax, %eax
    jz 1f
    mov %rbx, %rdi
    mov $KW_NOT, %esi
    call p_expect_kw
    mov %rbx, %rdi
    mov $KW_EXISTS, %esi
    call p_expect_kw
    movq $1, ST_IFX(%r12)
1:  mov %rbx, %rdi
    call p_ident
    mov %rax, ST_NAME(%r12)
    mov %rbx, %rdi
    mov $KW_ON, %esi
    call p_expect_kw
    mov %rbx, %rdi
    call p_ident
    mov %rax, ST_TABLE(%r12)
    mov %rbx, %rdi
    mov $OP_LPAREN, %esi
    call p_expect_op
    mov %rbx, %rdi
    call p_ident
    mov %rax, ST_COLUMN(%r12)
    mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_expect_op
    mov %rbx, %rdi
    mov $KW_USING, %esi
    call p_accept_kw
    test %eax, %eax
    jz 9f
    mov %rbx, %rdi
    call p_cur
    mov %rax, %r13
    cmpl $TOK_IDENT, TK_KIND(%r13)
    jne 8f
    mov TK_PTR(%r13), %rdi
    mov TK_LEN(%r13), %rsi
    CSTR %rdx, "HASH"
    call cstr_ieq
    test %eax, %eax
    jz 2f
    movq $1, ST_USING(%r12)
    jmp 3f
2:  mov TK_PTR(%r13), %rdi
    mov TK_LEN(%r13), %rsi
    CSTR %rdx, "BTREE"
    call cstr_ieq
    test %eax, %eax
    jz 8f
    movq $2, ST_USING(%r12)
3:  mov %rbx, %rdi
    call p_next
9:  LEAVE
8:  mov %rbx, %rdi
    call p_error
ENDF parse_create_index

/* parse_drop_index(P, stmt): DROP INDEX [IF EXISTS] name */
FUNC parse_drop_index
    ENTER 0
    mov %rdi, %rbx
    mov %rsi, %r12
    movq $STMT_DROP_INDEX, ST_KIND(%r12)
    call p_next
    mov %rbx, %rdi
    mov $KW_INDEX, %esi
    call p_expect_kw
    mov %rbx, %rdi
    mov $KW_IF, %esi
    call p_accept_kw
    test %eax, %eax
    jz 1f
    mov %rbx, %rdi
    mov $KW_EXISTS, %esi
    call p_expect_kw
    movq $1, ST_IFX(%r12)
1:  mov %rbx, %rdi
    call p_ident
    mov %rax, ST_NAME(%r12)
    LEAVE
ENDF parse_drop_index

/* parse_query(P) -> SelectStmt*:
 *   [WITH cte {, cte}] select_core { UNION ALL select_core } [ORDER BY] [LIMIT]
 * A single select_core is returned as is; several become a compound
 * statement (SS_UNION = branches) carrying WITH / ORDER BY / LIMIT. */
FUNC parse_query
    ENTER 16
    mov %rdi, %rbx
    call p_enter
    xor %r13d, %r13d                /* WITH list */
    mov %rbx, %rdi
    mov $KW_WITH, %esi
    call p_accept_kw
    test %eax, %eax
    jz 5f
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, %r13
1:  /* cte = ident [ ( ident {, ident} ) ] AS ( query ) */
    mov $CTE_SIZE, %edi
    call tmp_zalloc
    mov %rax, %r12
    mov %r13, %rdi
    mov %r12, %rsi
    call vec_push
    mov %rbx, %rdi
    call p_ident
    mov %rax, CTE_NAME(%r12)
    mov %rbx, %rdi
    mov $OP_LPAREN, %esi
    call p_accept_op
    test %eax, %eax
    jz 3f
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, CTE_COLS(%r12)
2:  mov %rbx, %rdi
    call p_ident
    mov CTE_COLS(%r12), %rdi
    mov %rax, %rsi
    call vec_push
    mov %rbx, %rdi
    mov $OP_COMMA, %esi
    call p_accept_op
    test %eax, %eax
    jnz 2b
    mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_expect_op
3:  mov %rbx, %rdi
    mov $KW_AS, %esi
    call p_expect_kw
    mov %rbx, %rdi
    mov $OP_LPAREN, %esi
    call p_expect_op
    mov %rbx, %rdi
    call parse_query
    mov %rax, CTE_QUERY(%r12)
    mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_expect_op
    mov %rbx, %rdi
    mov $OP_COMMA, %esi
    call p_accept_op
    test %eax, %eax
    jnz 1b
5:  /* compound = select_core { UNION ALL select_core } (CR-1) */
    mov %rbx, %rdi
    call parse_select_core
    mov %rax, %r12                  /* the query itself or its first branch */
    mov %rbx, %rdi
    mov $KW_UNION, %esi
    call p_accept_kw
    test %eax, %eax
    jz 7f
    mov $SS_SIZE, %edi              /* compound statement */
    call tmp_zalloc
    mov %rax, %r14
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, SS_UNION(%r14)
    mov %rax, %rdi
    mov %r12, %rsi
    call vec_push
6:  mov %rbx, %rdi                  /* UNION [DISTINCT] stays reserved */
    mov $KW_ALL, %esi
    call p_accept_kw
    test %eax, %eax
    jz 8f
    mov %rbx, %rdi
    call parse_select_core
    mov SS_UNION(%r14), %rdi
    mov %rax, %rsi
    call vec_push
    mov %rbx, %rdi
    mov $KW_UNION, %esi
    call p_accept_kw
    test %eax, %eax
    jnz 6b
    mov %r14, %r12
7:  /* ORDER BY / LIMIT apply to the whole (compound) query */
    mov %rbx, %rdi
    mov %r12, %rsi
    call parse_order_limit
    mov %r13, SS_WITH(%r12)
    decq PS_DEPTH(%rbx)
    mov %r12, %rax
    LEAVE
8:  mov %rbx, %rdi
    call p_unsupported
ENDF parse_query

/* parse_select_core(P) -> SelectStmt*:
 * SELECT [DISTINCT|ALL] items [FROM] [WHERE] [GROUP BY] [HAVING] */
FUNC parse_select_core
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
    call parse_from_item
    mov %rax, SS_FROM(%r12)

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
8:  mov %r12, %rax
    LEAVE
ENDF parse_select_core

/* parse_order_limit(P, stmt): [ORDER BY items] [LIMIT/OFFSET] into stmt */
FUNC parse_order_limit
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    /* ORDER BY */
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
99: LEAVE
ENDF parse_order_limit

/* new_from(kind edi) -> rax zeroed FromItem */
FUNC new_from
    push %rbx
    mov %edi, %ebx
    mov $FI_SIZE, %edi
    call tmp_zalloc
    mov %rbx, FI_KIND(%rax)
    pop %rbx
    ret
ENDF new_from

/* parse_from_item(P) -> FromItem*:  table_ref { join_clause }  (left-associative) */
FUNC parse_from_item
    ENTER 16
    mov %rdi, %rbx
    call p_enter
    mov %rbx, %rdi
    call parse_table_ref
    mov %rax, %r12                  /* left */
1:  mov %rbx, %rdi
    call p_cur
    mov %rax, %r14
    mov TK_KIND(%r14), %ecx
    mov TK_ID(%r14), %edx
    cmp $TOK_OP, %ecx
    jne 2f
    cmp $OP_COMMA, %edx
    jne 9f
    mov $JT_CROSS, %r13d            /* ',' */
    mov %rbx, %rdi
    call p_next
    jmp 5f
2:  cmp $TOK_KEYWORD, %ecx
    jne 9f
    cmp $KW_CROSS, %edx
    jne 3f
    mov $JT_CROSS, %r13d
    jmp 4f
3:  mov $JT_INNER, %r13d
    cmp $KW_JOIN, %edx
    je 41f
    cmp $KW_INNER, %edx
    je 4f
    cmp $KW_RIGHT, %edx
    je 8f
    cmp $KW_FULL, %edx
    je 8f
    cmp $KW_LEFT, %edx
    jne 9f
    mov $JT_LEFT, %r13d
    mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    mov $KW_OUTER, %esi
    call p_accept_kw
    jmp 41f
4:  mov %rbx, %rdi                  /* CROSS / INNER */
    call p_next
41: mov %rbx, %rdi
    mov $KW_JOIN, %esi
    call p_expect_kw
5:  mov %rbx, %rdi
    call parse_table_ref
    mov %rax, %r15                  /* right */
    mov $FK_JOIN, %edi
    call new_from
    mov %r12, FI_LEFT(%rax)
    mov %r15, FI_RIGHT(%rax)
    mov %r13, FI_JTYPE(%rax)
    mov %rax, %r12
    cmp $JT_CROSS, %r13d
    je 1b
    mov %rbx, %rdi
    mov $KW_ON, %esi
    call p_expect_kw
    mov %rbx, %rdi
    call parse_expr
    mov %rax, FI_ON(%r12)
    jmp 1b
8:  mov %rbx, %rdi
    call p_unsupported
9:  decq PS_DEPTH(%rbx)
    mov %r12, %rax
    LEAVE
ENDF parse_from_item

/* parse_table_ref(P) -> FromItem*:
 *   ident [[AS] alias] | ( query ) [AS] alias | ( from_item ) */
FUNC parse_table_ref
    ENTER 16
    mov %rdi, %rbx
    mov $OP_LPAREN, %esi
    call p_is_op
    test %eax, %eax
    jz 5f
    mov %rbx, %rdi
    mov $1, %esi
    call p_peek
    cmpl $TOK_KEYWORD, TK_KIND(%rax)
    jne 3f
    mov TK_ID(%rax), %ecx
    cmp $KW_SELECT, %ecx
    je 1f
    cmp $KW_WITH, %ecx
    jne 3f
1:  /* derived table: alias required */
    mov %rbx, %rdi
    call p_next
    mov $FK_DERIVED, %edi
    call new_from
    mov %rax, %r12
    mov %rbx, %rdi
    call parse_query
    mov %rax, FI_QUERY(%r12)
    mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_expect_op
    mov %rbx, %rdi
    mov $KW_AS, %esi
    call p_accept_kw
    mov %rbx, %rdi
    call p_ident
    mov %rax, FI_ALIAS(%r12)
    jmp 9f
3:  /* parenthesised from_item */
    mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    call parse_from_item
    mov %rax, %r12
    mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_expect_op
    jmp 9f
5:  mov $FK_TABLE, %edi
    call new_from
    mov %rax, %r12
    mov %rbx, %rdi
    call p_ident
    mov %rax, FI_NAME(%r12)
    mov %rbx, %rdi
    mov $KW_AS, %esi
    call p_accept_kw
    test %eax, %eax
    jnz 6f
    mov %rbx, %rdi
    call p_is_ident
    test %eax, %eax
    jz 9f
6:  mov %rbx, %rdi
    call p_ident
    mov %rax, FI_ALIAS(%r12)
9:  mov %r12, %rax
    LEAVE
ENDF parse_table_ref

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
    jnz 4f
    mov %rbx, %rdi
    call p_is_ident
    test %eax, %eax
    jz 9f
3:  mov %rbx, %rdi
    call p_ident
    mov %rax, SI_ALIAS(%r12)
9:  mov %r12, %rax
    LEAVE
4:  /* after AS, the words reserved for future syntax FULL / RIGHT (never
     * valid there) name the column, e.g. `... AS full` (decimal38.pqt) */
    mov %rbx, %rdi
    call p_cur
    cmpl $TOK_KEYWORD, TK_KIND(%rax)
    jne 3b
    mov TK_ID(%rax), %ecx
    cmp $KW_FULL, %ecx
    je 5f
    cmp $KW_RIGHT, %ecx
    jne 3b
5:  mov TK_PTR(%rax), %rdi
    mov TK_LEN(%rax), %rsi
    call pstr_tmp
    mov %rax, SI_ALIAS(%r12)
    mov %rbx, %rdi
    call p_next
    jmp 9b
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

/* predicate = concat [ comp concat
 *                    | IS [NOT] NULL
 *                    | [NOT] BETWEEN concat AND concat
 *                    | [NOT] IN ( query | expr {, expr} )
 *                    | [NOT] LIKE concat ]
 * The predicate level is non-associative: after one suffix the caller sees
 * whatever follows (e.g. a second '='), which ends the expression and is then
 * rejected as a trailing token by the statement parser (PARSE_ERROR).
 *
 * registers: rbx P, r12 left operand, r13d NOT flag / operator, r14 operator token,
 *            r15 node under construction */
FUNC parse_predicate
    ENTER 16
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
    xor %r13d, %r13d                /* NOT flag */
    mov TK_ID(%r14), %ecx
    cmp $KW_IS, %ecx
    je 4f
    cmp $KW_NOT, %ecx
    jne 5f
    /* NOT BETWEEN / NOT IN / NOT LIKE; any other NOT ends the predicate */
    mov %rbx, %rdi
    mov $1, %esi
    call p_peek
    cmpl $TOK_KEYWORD, TK_KIND(%rax)
    jne 9f
    mov TK_ID(%rax), %ecx
    cmp $KW_BETWEEN, %ecx
    je 51f
    cmp $KW_IN, %ecx
    je 51f
    cmp $KW_LIKE, %ecx
    jne 9f
51: mov $1, %r13d
    mov %rbx, %rdi
    call p_next                     /* NOT */
5:  mov %rbx, %rdi
    call p_cur
    mov TK_ID(%rax), %ecx
    cmp $KW_BETWEEN, %ecx
    je pr_between
    cmp $KW_IN, %ecx
    je pr_in
    cmp $KW_LIKE, %ecx
    je pr_like
    jmp 9f
4:  /* IS [NOT] NULL */
    mov %rbx, %rdi
    call p_next
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
9:  mov %r12, %rax
    LEAVE

/* x [NOT] BETWEEN low AND high -> EK_BETWEEN (A x, B low, V1 high) */
pr_between:
    mov $EK_BETWEEN, %edi
    call pr_new
    mov %rbx, %rdi
    call p_next                     /* BETWEEN */
    mov %rbx, %rdi
    call parse_concat
    mov %rax, N_B(%r15)
    mov %rbx, %rdi
    mov $KW_AND, %esi
    call p_expect_kw
    mov %rbx, %rdi
    call parse_concat
    mov %rax, N_V1(%r15)
    mov %r15, %rax
    LEAVE

/* x [NOT] LIKE pattern -> EK_LIKE (A x, B pattern) */
pr_like:
    mov $EK_LIKE, %edi
    call pr_new
    mov %rbx, %rdi
    call p_next                     /* LIKE */
    mov %rbx, %rdi
    call parse_concat
    mov %rax, N_B(%r15)
    mov %r15, %rax
    LEAVE

/* x [NOT] IN ( query )        -> EK_INSUBQ (A x, V1 SelectStmt*)
 * x [NOT] IN ( e1 {, e} )     -> EK_INLIST (A x, B node*[V1]) */
pr_in:
    mov %rbx, %rdi
    call p_next                     /* IN */
    mov %rbx, %rdi
    mov $OP_LPAREN, %esi
    call p_expect_op
    mov %rbx, %rdi
    call p_starts_query
    test %eax, %eax
    jz 1f
    mov $EK_INSUBQ, %edi
    call pr_new
    mov %rbx, %rdi
    call parse_query
    mov %rax, N_V1(%r15)
    jmp 3f
1:  mov $EK_INLIST, %edi
    call pr_new
    mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_is_op
    test %eax, %eax
    jz 11f
    mov %rbx, %rdi                  /* IN () */
    call p_error
11: mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, 0(%rsp)
2:  mov %rbx, %rdi
    call parse_expr
    mov 0(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
    mov %rbx, %rdi
    mov $OP_COMMA, %esi
    call p_accept_op
    test %eax, %eax
    jnz 2b
    mov 0(%rsp), %rax
    mov VEC_DATA(%rax), %rcx
    mov %rcx, N_B(%r15)
    mov VEC_LEN(%rax), %rcx
    mov %rcx, N_V1(%r15)
3:  mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_expect_op
    mov %r15, %rax
    LEAVE

/* pr_new(kind edi): local helper of parse_predicate (runs on its frame):
 * r15 = new node at token r14 with A = r12 and N_OP = r13d (NOT flag) */
pr_new:
    sub $8, %rsp
    mov %r14, %rsi
    call new_node
    mov %rax, %r15
    mov %r12, N_A(%r15)
    mov %r13d, N_OP(%r15)
    add $8, %rsp
    ret
ENDF parse_predicate

/* p_starts_query(P) -> eax 1 if the current token is SELECT or WITH
 * (a '(' followed by such a token opens a subquery, grammar.md notes) */
FUNC p_starts_query
    mov PS_POS(%rdi), %rax
    shl $5, %rax
    add PS_TOKS(%rdi), %rax
    xor %ecx, %ecx
    cmpl $TOK_KEYWORD, TK_KIND(%rax)
    jne 1f
    mov TK_ID(%rax), %edx
    cmp $KW_SELECT, %edx
    sete %cl
    cmp $KW_WITH, %edx
    sete %dl
    or %dl, %cl
1:  mov %ecx, %eax
    ret
ENDF p_starts_query

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
    je pp_case
    cmp $KW_EXISTS, %ecx
    je pp_exists
pp_error:
    mov %rbx, %rdi
    call p_error

pp_op:
    cmpl $OP_LPAREN, TK_ID(%r14)
    jne pp_error
    mov %rbx, %rdi
    call p_next
    mov %rbx, %rdi
    call p_starts_query
    test %eax, %eax
    jnz pp_subquery
    mov %rbx, %rdi
    call parse_expr
    mov %rax, %r12
    orl $NF_PAREN, N_FLAGS(%r12)
    mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_expect_op
    mov %r12, %rax
    LEAVE

/* ( query ) -> EK_SUBQ (V1 SelectStmt*); the '(' has been consumed */
pp_subquery:
    mov $EK_SUBQ, %r13d
    jmp 1f
/* EXISTS ( query ) -> EK_EXISTS (V1 SelectStmt*) */
pp_exists:
    mov %rbx, %rdi
    call p_next                     /* EXISTS */
    mov %rbx, %rdi
    mov $OP_LPAREN, %esi
    call p_expect_op
    mov $EK_EXISTS, %r13d
1:  mov %rbx, %rdi
    call parse_query
    mov %rax, %r12
    mov %rbx, %rdi
    mov $OP_RPAREN, %esi
    call p_expect_op
    mov %r13d, %edi
    mov %r14, %rsi
    call new_node
    mov %r12, N_V1(%rax)
    LEAVE

/* CASE [operand] WHEN e THEN e {WHEN e THEN e} [ELSE e] END
 *   -> EK_CASE (A operand or 0, B node*[2*V1] = when1,then1,..., V2 ELSE or 0) */
pp_case:
    mov %rbx, %rdi
    call p_next                     /* CASE */
    xor %r12d, %r12d                /* operand */
    mov %rbx, %rdi
    mov $KW_WHEN, %esi
    call p_is_kw
    test %eax, %eax
    jnz 1f
    mov %rbx, %rdi
    call parse_expr
    mov %rax, %r12
1:  mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, 8(%rsp)               /* when/then pairs */
    mov %rbx, %rdi                  /* at least one WHEN */
    mov $KW_WHEN, %esi
    call p_expect_kw
2:  mov %rbx, %rdi
    call parse_expr
    mov 8(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
    mov %rbx, %rdi
    mov $KW_THEN, %esi
    call p_expect_kw
    mov %rbx, %rdi
    call parse_expr
    mov 8(%rsp), %rdi
    mov %rax, %rsi
    call vec_push
    mov %rbx, %rdi
    mov $KW_WHEN, %esi
    call p_accept_kw
    test %eax, %eax
    jnz 2b
    xor %r13d, %r13d                /* ELSE */
    mov %rbx, %rdi
    mov $KW_ELSE, %esi
    call p_accept_kw
    test %eax, %eax
    jz 3f
    mov %rbx, %rdi
    call parse_expr
    mov %rax, %r13
3:  mov %rbx, %rdi
    mov $KW_END, %esi
    call p_expect_kw
    mov $EK_CASE, %edi
    mov %r14, %rsi
    call new_node
    mov %r12, N_A(%rax)
    mov %r13, N_V2(%rax)
    mov 8(%rsp), %rcx
    mov VEC_DATA(%rcx), %rdx
    mov %rdx, N_B(%rax)
    mov VEC_LEN(%rcx), %rdx
    shr $1, %rdx
    mov %rdx, N_V1(%rax)
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
5:  cmp $38, %eax
    ja pp_float
    mov %eax, 0(%rsp)               /* p */
    mov %r9d, 4(%rsp)               /* s */
    cmp $18, %eax
    ja 6f
    mov $18, %edx
    mov %r9d, %ecx
    xor %r8d, %r8d
    call text_parse_decimal
    test %edx, %edx
    jnz pp_float
    mov %rax, %r12
    jmp 7f
6:  mov $38, %edx                   /* wide literal: boxed i128 */
    mov %r9d, %ecx
    xor %r8d, %r8d
    lea 16(%rsp), %r9
    call dec_parse
    test %eax, %eax
    jnz pp_float
    mov 16(%rsp), %rdi
    mov 24(%rsp), %rsi
    call dec_box
    mov %rax, %r12
7:  mov $EK_LIT, %edi
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
    cmp $38, %rax
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
