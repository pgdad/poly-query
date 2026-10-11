/*
 * lexer.S - SQL tokenizer (grammar.md §1).
 *
 *   sql_lex(ptr, len) -> rax token array (TK_SIZE each, terminated by TOK_EOF),
 *                        rdx token count (including the EOF token)
 * Tokens are allocated in the request arena.  Lexical errors raise PARSE_ERROR.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

/* keyword table: length byte + upper-case text, in KW_* id order */
    .section .rodata
kw_table:
    .byte 3
    .ascii "ALL"
    .byte 3
    .ascii "AND"
    .byte 2
    .ascii "AS"
    .byte 3
    .ascii "ASC"
    .byte 7
    .ascii "BETWEEN"
    .byte 2
    .ascii "BY"
    .byte 4
    .ascii "CASE"
    .byte 4
    .ascii "CAST"
    .byte 6
    .ascii "CREATE"
    .byte 5
    .ascii "CROSS"
    .byte 4
    .ascii "DATE"
    .byte 4
    .ascii "DESC"
    .byte 8
    .ascii "DISTINCT"
    .byte 4
    .ascii "DROP"
    .byte 4
    .ascii "ELSE"
    .byte 3
    .ascii "END"
    .byte 6
    .ascii "EXISTS"
    .byte 7
    .ascii "EXPLAIN"
    .byte 5
    .ascii "FALSE"
    .byte 5
    .ascii "FIRST"
    .byte 4
    .ascii "FROM"
    .byte 4
    .ascii "FULL"
    .byte 5
    .ascii "GROUP"
    .byte 6
    .ascii "HAVING"
    .byte 2
    .ascii "IF"
    .byte 2
    .ascii "IN"
    .byte 5
    .ascii "INDEX"
    .byte 5
    .ascii "INNER"
    .byte 2
    .ascii "IS"
    .byte 4
    .ascii "JOIN"
    .byte 4
    .ascii "LAST"
    .byte 4
    .ascii "LEFT"
    .byte 4
    .ascii "LIKE"
    .byte 5
    .ascii "LIMIT"
    .byte 3
    .ascii "NOT"
    .byte 4
    .ascii "NULL"
    .byte 5
    .ascii "NULLS"
    .byte 6
    .ascii "OFFSET"
    .byte 2
    .ascii "ON"
    .byte 2
    .ascii "OR"
    .byte 5
    .ascii "ORDER"
    .byte 5
    .ascii "OUTER"
    .byte 5
    .ascii "RIGHT"
    .byte 6
    .ascii "SELECT"
    .byte 4
    .ascii "THEN"
    .byte 9
    .ascii "TIMESTAMP"
    .byte 4
    .ascii "TRUE"
    .byte 5
    .ascii "UNION"
    .byte 5
    .ascii "USING"
    .byte 4
    .ascii "WHEN"
    .byte 5
    .ascii "WHERE"
    .byte 4
    .ascii "WITH"
    .byte 0

    .text

/* kw_lookup(ptr, len) -> eax keyword id or 0 */
FUNC kw_lookup
    cmp $9, %rsi
    ja 9f
    lea kw_table(%rip), %r8
    mov $1, %eax                    /* current id */
1:  movzbl (%r8), %ecx
    test %ecx, %ecx
    jz 9f
    cmp %rsi, %rcx
    jne 4f
    xor %r9, %r9
2:  cmp %rcx, %r9
    jae 8f                          /* all matched */
    movzbl (%rdi, %r9), %edx
    lea -'a'(%rdx), %r10d
    cmp $25, %r10d
    ja 3f
    sub $32, %edx
3:  cmp 1(%r8, %r9), %dl
    jne 4f
    inc %r9
    jmp 2b
4:  lea 1(%r8, %rcx), %r8
    inc %eax
    jmp 1b
8:  ret
9:  xor %eax, %eax
    ret
ENDF kw_lookup

/*
 * register use in sql_lex:
 *   rbx = input ptr, r12 = len, r13 = pos, r14 = Vec* of tokens (4 qwords each)
 *   r15 = line start position (for column numbers); 0(%rsp) = line number
 */
FUNC sql_lex
    ENTER 48
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r13, %r13
    xor %r15, %r15
    movq $1, 0(%rsp)
    mov g_arena(%rip), %rdi
    call vec_new
    mov %rax, %r14

lex_loop:
    cmp %r12, %r13
    jae lex_eof
    movzbl (%rbx, %r13), %eax
    /* whitespace */
    cmp $'\n', %al
    jne 1f
    inc %r13
    incq 0(%rsp)
    mov %r13, %r15
    jmp lex_loop
1:  cmp $' ', %al
    je lex_skip1
    cmp $'\t', %al
    je lex_skip1
    cmp $'\r', %al
    je lex_skip1
    /* comments */
    cmp $'-', %al
    jne 2f
    lea 1(%r13), %rcx
    cmp %r12, %rcx
    jae 2f
    cmpb $'-', (%rbx, %rcx)
    jne 2f
3:  cmp %r12, %r13                  /* line comment: skip to newline */
    jae lex_loop
    cmpb $'\n', (%rbx, %r13)
    je lex_loop
    inc %r13
    jmp 3b
2:  cmp $'/', %al
    jne 5f
    lea 1(%r13), %rcx
    cmp %r12, %rcx
    jae 5f
    cmpb $'*', (%rbx, %rcx)
    jne 5f
    add $2, %r13
4:  lea 1(%r13), %rcx               /* block comment */
    cmp %r12, %rcx
    jae lex_err_comment
    cmpb $'\n', (%rbx, %r13)
    jne 6f
    incq 0(%rsp)
    lea 1(%r13), %r15
6:  cmpb $'*', (%rbx, %r13)
    jne 7f
    cmpb $'/', (%rbx, %rcx)
    jne 7f
    add $2, %r13
    jmp lex_loop
7:  inc %r13
    jmp 4b

5:  /* token start: record position */
    mov %r13, 8(%rsp)               /* start offset */
    /* identifiers / keywords */
    mov %eax, %ecx
    or $0x20, %ecx
    lea -'a'(%rcx), %edx
    cmp $25, %edx
    jbe lex_ident
    cmp $'_', %al
    je lex_ident
    lea -'0'(%rax), %edx
    cmp $9, %edx
    jbe lex_number
    cmp $'.', %al
    jne 8f
    lea 1(%r13), %rcx               /* '.' followed by digit => number */
    cmp %r12, %rcx
    jae lex_op
    movzbl (%rbx, %rcx), %edx
    sub $'0', %edx
    cmp $9, %edx
    jbe lex_number
    jmp lex_op
8:  cmp $'\'', %al
    je lex_string
    cmp $'"', %al
    je lex_qident
    jmp lex_op

lex_skip1:
    inc %r13
    jmp lex_loop

/* ---------------------------------------------------------- identifier/keyword */
lex_ident:
    inc %r13
1:  cmp %r12, %r13
    jae 2f
    movzbl (%rbx, %r13), %eax
    mov %eax, %ecx
    or $0x20, %ecx
    lea -'a'(%rcx), %edx
    cmp $25, %edx
    jbe 3f
    cmp $'_', %al
    je 3f
    lea -'0'(%rax), %edx
    cmp $9, %edx
    jbe 3f
    jmp 2f
3:  inc %r13
    jmp 1b
2:  mov 8(%rsp), %rdi
    add %rbx, %rdi
    mov %r13, %rsi
    sub 8(%rsp), %rsi
    call kw_lookup
    test %eax, %eax
    jz 4f
    mov $TOK_KEYWORD, %edi
    mov %eax, %esi
    jmp lex_emit_src
4:  mov $TOK_IDENT, %edi
    xor %esi, %esi
    jmp lex_emit_src

/* ---------------------------------------------------------- number */
lex_number:
    xor %r8d, %r8d                  /* flags */
1:  cmp %r12, %r13                  /* integer digits */
    jae 9f
    movzbl (%rbx, %r13), %eax
    sub $'0', %eax
    cmp $9, %eax
    ja 2f
    inc %r13
    jmp 1b
2:  cmpb $'.', (%rbx, %r13)
    jne 4f
    or $NUMF_DOT, %r8d
    inc %r13
3:  cmp %r12, %r13
    jae 9f
    movzbl (%rbx, %r13), %eax
    sub $'0', %eax
    cmp $9, %eax
    ja 4f
    inc %r13
    jmp 3b
4:  /* exponent: [eE][+-]?digits (only if digits follow) */
    movzbl (%rbx, %r13), %eax
    or $0x20, %eax
    cmp $'e', %eax
    jne 9f
    lea 1(%r13), %rcx
    cmp %r12, %rcx
    jae 9f
    movzbl (%rbx, %rcx), %eax
    cmp $'+', %al
    je 5f
    cmp $'-', %al
    jne 6f
5:  inc %rcx
    cmp %r12, %rcx
    jae 9f
    movzbl (%rbx, %rcx), %eax
6:  sub $'0', %eax
    cmp $9, %eax
    ja 9f
    or $NUMF_EXP, %r8d
    mov %rcx, %r13
7:  cmp %r12, %r13
    jae 9f
    movzbl (%rbx, %r13), %eax
    sub $'0', %eax
    cmp $9, %eax
    ja 9f
    inc %r13
    jmp 7b
9:  mov $TOK_NUMBER, %edi
    mov %r8d, %esi
    jmp lex_emit_src

/* ---------------------------------------------------------- 'string' / "ident" */
lex_string:
    mov $'\'', %ecx
    mov $TOK_STRING, %edx
    jmp lex_quoted
lex_qident:
    mov $'"', %ecx
    mov $TOK_QIDENT, %edx
lex_quoted:
    mov %ecx, 16(%rsp)              /* quote char */
    mov %edx, 20(%rsp)              /* token kind */
    /* decoded text is at most the remaining length */
    mov %r12, %rdi
    sub %r13, %rdi
    add $9, %rdi
    call tmp_alloc
    mov %rax, 24(%rsp)              /* pstr */
    lea 8(%rax), %rdi               /* write cursor */
    inc %r13
1:  cmp %r12, %r13
    jae lex_err_unterminated
    movzbl (%rbx, %r13), %eax
    cmp 16(%rsp), %eax
    jne 3f
    lea 1(%r13), %rcx               /* doubled quote? */
    cmp %r12, %rcx
    jae 4f
    cmpb %al, (%rbx, %rcx)
    jne 4f
    mov %al, (%rdi)
    inc %rdi
    add $2, %r13
    jmp 1b
3:  cmp $'\n', %al
    jne 5f
    incq 0(%rsp)
    lea 1(%r13), %r15
5:  mov %al, (%rdi)
    inc %rdi
    inc %r13
    jmp 1b
4:  inc %r13                        /* closing quote */
    movb $0, (%rdi)
    mov 24(%rsp), %rax
    lea 8(%rax), %rcx
    sub %rcx, %rdi
    mov %rdi, (%rax)                /* pstr length */
    /* emit with decoded text */
    mov 20(%rsp), %edi
    xor %esi, %esi
    lea 8(%rax), %rdx
    mov (%rax), %rcx
    jmp lex_emit

lex_err_unterminated:
    mov 0(%rsp), %rax               /* position for the error details */
    mov %rax, g_err_line(%rip)
    mov %r13, %rax
    sub %r15, %rax
    inc %rax
    mov %rax, g_err_col(%rip)
    RAISE E_PARSE_ERROR, "unterminated string literal or quoted identifier"
lex_err_comment:
    mov 0(%rsp), %rax               /* position for the error details */
    mov %rax, g_err_line(%rip)
    mov %r13, %rax
    sub %r15, %rax
    inc %rax
    mov %rax, g_err_col(%rip)
    RAISE E_PARSE_ERROR, "unterminated block comment"

/* ---------------------------------------------------------- operators */
lex_op:
    movzbl (%rbx, %r13), %eax
    lea 1(%r13), %rcx
    xor %edx, %edx                  /* next char or 0 */
    cmp %r12, %rcx
    jae 1f
    movzbl (%rbx, %rcx), %edx
1:  mov $1, %r9d                    /* token length */
    cmp $'+', %al
    mov $OP_PLUS, %esi
    je 8f
    cmp $'-', %al
    mov $OP_MINUS, %esi
    je 8f
    cmp $'*', %al
    mov $OP_STAR, %esi
    je 8f
    cmp $'/', %al
    mov $OP_SLASH, %esi
    je 8f
    cmp $'%', %al
    mov $OP_PERCENT, %esi
    je 8f
    cmp $'=', %al
    mov $OP_EQ, %esi
    je 8f
    cmp $'(', %al
    mov $OP_LPAREN, %esi
    je 8f
    cmp $')', %al
    mov $OP_RPAREN, %esi
    je 8f
    cmp $',', %al
    mov $OP_COMMA, %esi
    je 8f
    cmp $'.', %al
    mov $OP_DOT, %esi
    je 8f
    cmp $';', %al
    mov $OP_SEMI, %esi
    je 8f
    mov $2, %r9d
    cmp $'|', %al
    jne 2f
    cmp $'|', %dl
    mov $OP_CONCAT, %esi
    je 8f
    jmp lex_err_char
2:  cmp $'!', %al
    jne 3f
    cmp $'=', %dl
    mov $OP_NE, %esi
    je 8f
    jmp lex_err_char
3:  cmp $'<', %al
    jne 5f
    cmp $'=', %dl
    mov $OP_LE, %esi
    je 8f
    cmp $'>', %dl
    mov $OP_NE, %esi
    je 8f
    mov $1, %r9d
    mov $OP_LT, %esi
    jmp 8f
5:  cmp $'>', %al
    jne lex_err_char
    cmp $'=', %dl
    mov $OP_GE, %esi
    je 8f
    mov $1, %r9d
    mov $OP_GT, %esi
8:  add %r9, %r13
    mov $TOK_OP, %edi
    jmp lex_emit_src

lex_err_char:
    mov 0(%rsp), %rax               /* position for the error details */
    mov %rax, g_err_line(%rip)
    mov %r13, %rax
    sub %r15, %rax
    inc %rax
    mov %rax, g_err_col(%rip)
    RAISE E_PARSE_ERROR, "unexpected character in SQL text"

/* ---------------------------------------------------------- emit
 * lex_emit_src: kind edi, id esi; text = input[start .. r13)
 * lex_emit:     kind edi, id esi, text rdx, len rcx                     */
lex_emit_src:
    mov 8(%rsp), %rdx
    mov %r13, %rcx
    sub %rdx, %rcx
    add %rbx, %rdx
lex_emit:
    mov %rdx, 32(%rsp)
    mov %rcx, 40(%rsp)
    shl $32, %rsi
    or %rdi, %rsi
    mov %r14, %rdi
    call vec_push                   /* kind | id << 32 */
    mov %r14, %rdi
    mov 32(%rsp), %rsi
    call vec_push
    mov %r14, %rdi
    mov 40(%rsp), %rsi
    call vec_push
    /* line | col << 32 ; col = start - line_start + 1 */
    mov 8(%rsp), %rsi
    sub %r15, %rsi
    inc %rsi
    shl $32, %rsi
    or 0(%rsp), %rsi
    mov %r14, %rdi
    call vec_push
    jmp lex_loop

lex_eof:
    mov %r13, 8(%rsp)
    mov $TOK_EOF, %edi
    xor %esi, %esi
    mov %r14, %rdi
    mov $TOK_EOF, %esi
    call vec_push
    mov %r14, %rdi
    xor %esi, %esi
    call vec_push
    mov %r14, %rdi
    xor %esi, %esi
    call vec_push
    mov %r13, %rsi
    sub %r15, %rsi
    inc %rsi
    shl $32, %rsi
    or 0(%rsp), %rsi
    mov %r14, %rdi
    call vec_push
    mov VEC_DATA(%r14), %rax
    mov VEC_LEN(%r14), %rdx
    shr $2, %rdx
    LEAVE
ENDF sql_lex
