/*
 * test_sql.S - unit tests for the SQL pipeline: lexer, parser, binder,
 * evaluator and executor on FROM-less queries.  Each case runs
 * sql_parse -> bind_select -> exec_query and compares the serialized result
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
    CASE "SELECT FOO(1)", "!2"
    /* scalar functions (functions.S) */
    CASE "SELECT UPPER('a'), LOWER('AbC'), UPPER('abc \303\234n\303\257')", "[[\"A\",\"abc\",\"ABC \303\234n\303\257\"]]"
    CASE "SELECT ABS(-5), ABS(-2.50), ABS(-1.5e0)", "\"DECIMAL(3,2)\"},{\"name\":\"_col3\",\"type\":\"FLOAT64\"}],\"rows\":[[5,\"2.50\",1.5]]"
    CASE "SELECT ABS(-9223372036854775808)", "!4"
    CASE "SELECT ROUND(2.5), ROUND(-2.345, 2), ROUND(1234.5678, -2), ROUND(-15, -1), ROUND(2.5, 5)", "[[\"3\",\"-2.35\",\"1200\",-20,\"2.5\"]]"
    CASE "SELECT ROUND(2.5, 5)", "\"DECIMAL(18,1)\""
    CASE "SELECT ROUND(5000000000000000000, -19)", "!4"
    CASE "SELECT ROUND(1.5, NULL), ROUND(1.26e0, 1)", "[[null,1.3]]"
    CASE "SELECT FLOOR(-2.7), CEIL(2.1), FLOOR(5), CEILING(-0.5e0)", "[[\"-3\",\"3\",5,0]]"
    CASE "SELECT SQRT(2.25), POWER(2, 10), MOD(-17, 5)", "[[1.5,1024,-2]]"
    CASE "SELECT SQRT(-1)", "!7"
    CASE "SELECT POWER(0, -1)", "!5"
    CASE "SELECT POWER(-8, 0.5)", "!7"
    CASE "SELECT POWER(10, 400)", "!4"
    CASE "SELECT LENGTH('h\303\251llo'), SUBSTR('h\303\251llo', 2, 2), SUBSTR('hello', 0, 2), SUBSTR('hello', 10)", "[[5,\"\303\251l\",\"h\",\"\"]]"
    CASE "SELECT SUBSTR('abc', 1, -1)", "!7"
    CASE "SELECT TRIM('  a b  '), LTRIM('  a '), RTRIM('  a '), REPLACE('banana', 'an', 'AN'), REPLACE('abc', '', 'x')", "[[\"a b\",\"a \",\"  a\",\"bANANa\",\"abc\"]]"
    CASE "SELECT CONCAT('a', NULL, 1, TRUE, 2.50, DATE '2024-01-02'), CONCAT(NULL)", "[[\"a1true2.502024-01-02\",\"\"]]"
    CASE "SELECT CONCAT('a', 1.5e0)", "!3"
    CASE "SELECT LENGTH(5)", "!3"
    CASE "SELECT LENGTH('a', 'b')", "!2"
    CASE "SELECT ABS(DISTINCT 1)", "!2"
    CASE "SELECT PQ_SLEEP(1)", "!2"
    CASE "SELECT COALESCE(NULL, 2, 3), COALESCE(NULL, NULL), COALESCE(1, 2.5), NULLIF(1, 1.0), NULLIF(1, 2)", "\"type\":\"DECIMAL(18,1)\"},{\"name\":\"_col4\",\"type\":\"INT64\"},{\"name\":\"_col5\",\"type\":\"INT64\"}],\"rows\":[[2,null,\"1.0\",null,1]]"
    CASE "SELECT COALESCE(1, 'a')", "!3"
    CASE "SELECT YEAR(DATE '2024-02-29'), MONTH(TIMESTAMP '1969-12-31 23:59:59.5'), DAY(DATE '2024-02-29'), HOUR(TIMESTAMP '1969-12-31 23:59:59.5'), SECOND(TIMESTAMP '2024-01-01 13:14:15.9')", "[[2024,12,29,23,15]]"
    CASE "SELECT DATE_TRUNC('Month', DATE '2024-02-29'), DATE_TRUNC('minute', TIMESTAMP '1969-12-31 23:59:59.5')", "[[\"2024-02-01 00:00:00\",\"1969-12-31 23:59:00\"]]"
    CASE "SELECT DATE_DIFF('day', TIMESTAMP '2024-01-01 23:59:59', TIMESTAMP '2024-01-02 00:00:01'), DATE_DIFF('day', DATE '2024-03-01', DATE '2024-01-01')", "[[1,-60]]"
    CASE "SELECT DATE_TRUNC('week', DATE '2024-01-01')", "!7"
    CASE "SELECT HOUR(DATE '2024-01-01')", "!3"
    /* CASE / BETWEEN / IN / LIKE */
    CASE "SELECT CASE WHEN FALSE THEN 1 WHEN NULL THEN 2 ELSE 3.5 END, CASE 1 WHEN NULL THEN 'n' WHEN 1.0 THEN 'one' END", "\"DECIMAL(18,1)\"},{\"name\":\"_col2\",\"type\":\"STRING\"}],\"rows\":[[\"3.5\",\"one\"]]"
    CASE "SELECT CASE WHEN TRUE THEN NULL ELSE 1 END, CASE WHEN FALSE THEN 1 END", "[[null,null]]"
    CASE "SELECT CASE WHEN 1 THEN 1 END", "!3"
    CASE "SELECT CASE WHEN TRUE THEN 1 ELSE 'x' END", "!3"
    CASE "SELECT CASE WHEN TRUE THEN 1", "!1"
    CASE "SELECT 1 IN (1, NULL), 2 IN (1, NULL), 2 NOT IN (1, NULL), NULL IN (1, 2), 1 IN (1.0, 2)", "[[true,null,null,null,true]]"
    CASE "SELECT 3 BETWEEN 5 AND 1, NULL BETWEEN 1 AND 2, 0 BETWEEN 1 AND NULL, 2 NOT BETWEEN 1 AND 3", "[[false,null,false,false]]"
    CASE "SELECT 1 IN ()", "!1"
    CASE "SELECT 1 IN ('a')", "!3"
    CASE "SELECT 'a%c' LIKE 'a%', 'abc' LIKE 'ABC', '\303\251a' LIKE '_a', 'mississippi' LIKE '%iss%ppi', 'ab' NOT LIKE '%b', NULL LIKE 'a'", "[[true,false,true,true,false,null]]"
    CASE "SELECT 1 LIKE '1'", "!3"
    CASE "SELECT 1 BETWEEN 0 AND 2 = TRUE", "!1"
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
    mov %rax, %rdi
    call bind_select
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
