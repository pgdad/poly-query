/*
 * test_sql.S - unit tests for the SQL pipeline: lexer, parser, binder,
 * evaluator and executor on FROM-less queries.  Each case runs
 * sql_parse -> bind_statement -> exec_query and compares the serialized result
 * (or the raised error code) with the expectation.
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

/* case table: SQL text, expected output (or "!CODE" for an error) */
    .section .rodata
.macro CASE sql, expect
    .pushsection .rodata.str1.1, "aMS", @progbits, 1
8001:
    .asciz "\sql"
8002:
    .asciz "\expect"
    .popsection
    .quad 8001b, 8002b
.endm

    .p2align 3
cases:
    CASE "SELECT 1 + 2 * 3 AS x", "\"rows\":[[7]]"
    CASE "select (1 + 2) * 3", "\"name\":\"_col1\",\"type\":\"INT64\"}],\"rows\":[[9]]"
    CASE "SELECT 7 / 2, -7 / 2, 7 % 3, -7 % 3", "[[3,-3,1,-1]]"
    CASE "SELECT -9223372036854775808 AS m", "[[-9223372036854775808]]"
    CASE "SELECT 1.50 AS d", "\"type\":\"DECIMAL(3,2)\"}],\"rows\":[[\"1.50\"]]"
    CASE "SELECT 0.05, .5, 00012.5, 3.", "DECIMAL(2,2)"
    CASE "SELECT 1.25 * 2.5", "\"DECIMAL(18,3)\"}],\"rows\":[[\"3.125\"]]"
    CASE "SELECT 1.5 * 2", "\"DECIMAL(18,1)\"}],\"rows\":[[\"3.0\"]]"
    CASE "SELECT 2 - 0.75", "[[\"1.25\"]]"
    CASE "SELECT 0.1 + 0.2 = 0.3", "[[true]]"
    CASE "SELECT 1e3", "\"FLOAT64\"}],\"rows\":[[1000]]"
    CASE "SELECT 'it''s' AS s", "[[\"it's\"]]"
    CASE "SELECT NULL AS n", "\"STRING\"}],\"rows\":[[null]]"
    CASE "SELECT NULL AND FALSE, NULL OR TRUE, NOT NULL", "[[false,true,null]]"
    CASE "SELECT 1 IS NULL, NULL IS NOT NULL", "[[false,false]]"
    CASE "SELECT DATE '2024-02-29' < TIMESTAMP '2024-02-29 00:00:01'", "[[true]]"
    CASE "SELECT CAST('2024-03-01 10:00:00' AS TIMESTAMP)", "[[\"2024-03-01 10:00:00\"]]"
    CASE "SELECT CAST(-2.345 AS DECIMAL(5,2))", "[[\"-2.35\"]]"
    CASE "SELECT CAST(3.99 AS INT64), CAST(TRUE AS INT64)", "[[3,1]]"
    CASE "SELECT 'a' || 'b'", "[[\"ab\"]]"
    CASE "SELECT 1 WHERE 1 = 2", "\"rows\":[],\"row_count\":0"
    CASE "SELECT COUNT(*), SUM(1), AVG(2), MIN('x')", "[[1,1,2,\"x\"]]"
    CASE "SELECT 5 AS v ORDER BY v DESC LIMIT 1 OFFSET 0", "[[5]]"
    CASE "SELECT /* c */ 7 -- tail", "[[7]]"
    CASE "SELECT 1;", "[[1]]"
    CASE "SELECT 9223372036854775808", "!4"
    CASE "SELECT 9223372036854775807 + 1", "!4"
    CASE "SELECT 1 / 0", "!5"
    CASE "SELECT 1.5 % 2", "!3"
    CASE "SELECT 1 = '1'", "!3"
    CASE "SELECT DATE '2023-02-29'", "!6"
    CASE "SELECT CAST('abc' AS INT64)", "!6"
    CASE "SELECT CAST(1 AS WIDGET)", "!2"
    CASE "SELECT 1 = 1 = 1", "!1"
    CASE "SELEC 1", "!1"
    CASE "SELECT 'open", "!1"
    CASE "SELECT 1; SELECT 2", "!1"
    CASE "SELECT nope", "!2"
    CASE "SELECT *", "!2"
    CASE "SELECT 1 LIMIT -1", "!7"
    CASE "SELECT SUM(COUNT(*))", "!2"
    CASE "SELECT DISTINCT 1", "!11"
    CASE "SELECT x FROM t JOIN u ON 1 = 1", "!11"
    CASE "SELECT UPPER('a')", "!11"
    CASE "SELECT FOO(1)", "!2"
    .quad 0, 0

    .bss
    .p2align 4
out:    .zero BUF_SIZE
jb:     .zero 512
passed: .quad 0
failed: .quad 0

    .text

/* run_case(sql rdi, expect rsi) */
FUNC run_case
    ENTER 16
    mov %rdi, %rbx
    mov %rsi, %r12
    mov g_arena(%rip), %rdi
    call arena_reset
    lea out(%rip), %rdi
    movq $0, BUF_LEN(%rdi)
    lea jb(%rip), %rdi
    mov %rdi, g_jmpbuf(%rip)
    call _setjmp
    test %eax, %eax
    jnz 5f
    mov %rbx, %rdi
    call strlen
    mov %rbx, %rdi
    mov %rax, %rsi
    call sql_parse
    mov ST_QUERY(%rax), %rdi
    call bind_statement
    mov %rax, %rdi
    mov $-1, %rsi
    xor %edx, %edx
    lea out(%rip), %rcx
    call exec_query
    lea out(%rip), %rdi
    xor %esi, %esi
    call buf_putc                   /* NUL terminate */
    cmpb $'!', (%r12)
    je 8f                           /* expected an error */
    mov out+BUF_DATA(%rip), %rdi
    mov %r12, %rsi
    call strstr
    test %rax, %rax
    jz 8f
    incq passed(%rip)
    LEAVE
5:  /* error raised: compare the code */
    cmpb $'!', (%r12)
    jne 7f
    lea 1(%r12), %rdi
    call atoi
    cltq
    cmp g_err_code(%rip), %rax
    jne 7f
    incq passed(%rip)
    LEAVE
7:  lea fmt_err(%rip), %rdi
    mov %rbx, %rsi
    mov g_err_code(%rip), %rdx
    lea g_err_msg(%rip), %rcx
    mov %r12, %r8
    xor %eax, %eax
    call printf
    incq failed(%rip)
    LEAVE
8:  lea fmt_fail(%rip), %rdi
    mov %rbx, %rsi
    mov out+BUF_DATA(%rip), %rdx
    mov %r12, %rcx
    xor %eax, %eax
    call printf
    incq failed(%rip)
    LEAVE
ENDF run_case

    .section .rodata
fmt_err:  .asciz "FAIL: %s\n  raised %ld (%s), expected %s\n"
fmt_fail: .asciz "FAIL: %s\n  got %s\n  expected %s\n"
fmt_done: .asciz "test_sql: %ld passed, %ld failed\n"
    .text

FUNC main
    ENTER 0
    call arena_new
    mov %rax, g_arena(%rip)
    lea cases(%rip), %rbx
1:  mov (%rbx), %rdi
    test %rdi, %rdi
    jz 2f
    mov 8(%rbx), %rsi
    call run_case
    add $16, %rbx
    jmp 1b
2:  lea fmt_done(%rip), %rdi
    mov passed(%rip), %rsi
    mov failed(%rip), %rdx
    xor %eax, %eax
    call printf
    xor %eax, %eax
    cmpq $0, failed(%rip)
    setne %al
    LEAVE
ENDF main
