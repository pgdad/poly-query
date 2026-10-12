/*
 * test_optimizer.S - unit tests for the logical plan (lplan.S) and each
 * optimizer rule on catalog tables t(a = 0..99, b = a % 10), u(a = 0..9).
 *
 * Each case binds a query with the optimizer off (so QP_LOGICAL is the
 * canonical, unoptimized logical plan), applies one rule - or none, or the
 * whole optimizer - and compares the printed logical plan (lp_print) with
 * the expectation:
 *   - builder: operator shapes of every clause, derived tables, UNION ALL
 *   - pushdown: into join inputs, not into the NULL-padded side of a LEFT
 *     JOIN, constant / correlated conjuncts stay, HAVING is not moved
 *   - prune_columns: scans produce only referenced columns, including
 *     columns referenced by correlated subqueries
 *   - fold_constants: folding, failing constants stay, AND/OR
 *     simplification (unsafe operands stay), TRUE filters disappear
 *   - optimize_logical: all rules in order; optimize = false applies none
 */
#include "pq.inc"
#include "sql.inc"

    .section .note.GNU-stack, "", @progbits

    .data
    .p2align 3
s_t:     .quad 1
         .asciz "t"
    .p2align 3
s_u:     .quad 1
         .asciz "u"
    .text

#include "test_lib.inc"

/* case table: SQL text, rule (0 = none), expected plan text */
    .section .rodata
.macro RCASE sql, rule, expect
    .pushsection .rodata.str1.1, "aMS", @progbits, 1
8001:
    .asciz "\sql"
8002:
    .asciz "\expect"
    .popsection
    .quad 8001b, \rule, 8002b
.endm

    .p2align 3
cases:
    /* ---- builder: the canonical logical plan */
    RCASE "SELECT b, COUNT(*) FROM t WHERE a > 5 GROUP BY b HAVING COUNT(*) > 1 ORDER BY b DESC LIMIT 3", 0, \
"Limit 3 OFFSET 0\n  Sort #0 DESC\n    Project t.b AS b, COUNT(*) AS _col2\n      Filter (COUNT(*) > 1)\n        Aggregate keys=[t.b] calls=[COUNT(*), COUNT(*)]\n          Filter (t.a > 5)\n            Scan t AS t [a, b]\n"
    RCASE "SELECT DISTINCT d.x FROM (SELECT a AS x FROM t) d ORDER BY 1", 0, \
"Sort #0\n  Distinct\n    Project d.x AS x\n      SubqueryScan d [x]\n        Project t.a AS x\n          Scan t AS t [a, b]\n"
    RCASE "SELECT 1 AS one WHERE 2 > 1", 0, \
"Project 1 AS one\n  Filter (2 > 1)\n    Values\n"
    RCASE "SELECT a FROM t UNION ALL SELECT a FROM u LIMIT 2", 0, \
"Limit 2 OFFSET 0\n  UnionAll\n    Project t.a AS a\n      Scan t AS t [a, b]\n    Project u.a AS a\n      Scan u AS u [a]\n"
    RCASE "SELECT CASE WHEN a BETWEEN 1 AND 2 THEN 'x' ELSE NULL END AS c FROM t WHERE b NOT IN (1, 2) AND CAST(a AS DOUBLE) > 1.5 AND 'q' LIKE 'q%' AND b IS NOT NULL AND a IN (SELECT a FROM u WHERE u.a <> t.b)", 0, \
"Project CASE WHEN (t.a BETWEEN 1 AND 2) THEN 'x' ELSE NULL END AS c\n  Filter (((((t.b NOT IN (1, 2)) AND (CAST(t.a AS FLOAT64) > CAST(1.5 AS FLOAT64))) AND ('q' LIKE 'q%')) AND (t.b IS NOT NULL)) AND (t.a IN (subquery)))\n    Scan t AS t [a, b]\n"
    RCASE "SELECT x.a FROM t x LEFT JOIN u y ON x.a = y.a CROSS JOIN u z", 0, \
"Project x.a AS a\n  Join CROSS\n    Join LEFT ON (x.a = y.a)\n      Scan t AS x [a, b]\n      Scan u AS y [a]\n    Scan u AS z [a]\n"

    /* ---- rule: pushdown */
    RCASE "SELECT t.a FROM t JOIN u ON t.a = u.a WHERE u.a = 1 AND t.b > 0 AND t.a + u.a > 3", rule_pushdown, \
"Project t.a AS a\n  Filter ((t.a + u.a) > 3)\n    Join INNER ON (t.a = u.a)\n      Filter (t.b > 0)\n        Scan t AS t [a, b]\n      Filter (u.a = 1)\n        Scan u AS u [a]\n"
    RCASE "SELECT t.a FROM t JOIN u ON t.a = u.a WHERE t.b = 2 AND t.a < 50 AND u.a > 1", rule_pushdown, \
"Project t.a AS a\n  Join INNER ON (t.a = u.a)\n    Filter ((t.b = 2) AND (t.a < 50))\n      Scan t AS t [a, b]\n    Filter (u.a > 1)\n      Scan u AS u [a]\n"
    RCASE "SELECT t.a FROM t LEFT JOIN u ON t.a = u.a WHERE u.a IS NULL AND t.b = 1", rule_pushdown, \
"Project t.a AS a\n  Filter (u.a IS NULL)\n    Join LEFT ON (t.a = u.a)\n      Filter (t.b = 1)\n        Scan t AS t [a, b]\n      Scan u AS u [a]\n"
    RCASE "SELECT a FROM t WHERE a > 5 AND 1 = 1 AND EXISTS (SELECT 1 FROM u WHERE u.a = t.b)", rule_pushdown, \
"Project t.a AS a\n  Filter ((1 = 1) AND EXISTS(subquery))\n    Filter (t.a > 5)\n      Scan t AS t [a, b]\n"
    RCASE "SELECT d.x FROM (SELECT a AS x FROM t) d WHERE d.x > 3", rule_pushdown, \
"Project d.x AS x\n  Filter (d.x > 3)\n    SubqueryScan d [x]\n      Project t.a AS x\n        Scan t AS t [a, b]\n"
    RCASE "SELECT b FROM t GROUP BY b HAVING b > 1", rule_pushdown, \
"Project t.b AS b\n  Filter (t.b > 1)\n    Aggregate keys=[t.b] calls=[]\n      Scan t AS t [a, b]\n"

    /* ---- rule: prune_columns */
    RCASE "SELECT t.a FROM t JOIN u ON t.a = u.a", rule_prune_columns, \
"Project t.a AS a\n  Join INNER ON (t.a = u.a)\n    Scan t AS t [a]\n    Scan u AS u [a]\n"
    RCASE "SELECT COUNT(*) FROM t", rule_prune_columns, \
"Project COUNT(*) AS _col1\n  Aggregate keys=[] calls=[COUNT(*)]\n    Scan t AS t []\n"
    RCASE "SELECT a FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.a = t.b)", rule_prune_columns, \
"Project t.a AS a\n  Filter EXISTS(subquery)\n    Scan t AS t [a, b]\n"
    RCASE "SELECT x FROM (SELECT a AS x, b AS y FROM t) d ORDER BY d.y", rule_prune_columns, \
"Sort d.y\n  Project d.x AS x\n    SubqueryScan d [x, y]\n      Project t.a AS x, t.b AS y\n        Scan t AS t [a, b]\n"
    RCASE "SELECT SUM(b) FROM t GROUP BY a % 2", rule_prune_columns, \
"Project SUM(t.b) AS _col1\n  Aggregate keys=[(t.a % 2)] calls=[SUM(t.b)]\n    Scan t AS t [a, b]\n"

    /* ---- rule: fold_constants */
    RCASE "SELECT a + (1 + 2) AS s FROM t WHERE b = 2 * 3", rule_fold_constants, \
"Project (t.a + 3) AS s\n  Filter (t.b = 6)\n    Scan t AS t [a, b]\n"
    RCASE "SELECT a FROM t WHERE a = 1 / 0", rule_fold_constants, \
"Project t.a AS a\n  Filter (t.a = (1 / 0))\n    Scan t AS t [a, b]\n"
    RCASE "SELECT a FROM t WHERE a > 5 OR 1 = 0", rule_fold_constants, \
"Project t.a AS a\n  Filter (t.a > 5)\n    Scan t AS t [a, b]\n"
    RCASE "SELECT a FROM t WHERE 1 = 1 AND TRUE", rule_fold_constants, \
"Project t.a AS a\n  Scan t AS t [a, b]\n"
    RCASE "SELECT a FROM t WHERE a / 2 > 1 AND 1 = 0", rule_fold_constants, \
"Project t.a AS a\n  Filter (((t.a / 2) > 1) AND FALSE)\n    Scan t AS t [a, b]\n"
    RCASE "SELECT a FROM t WHERE a > 1 AND 1 = 0", rule_fold_constants, \
"Project t.a AS a\n  Filter FALSE\n    Scan t AS t [a, b]\n"
    RCASE "SELECT UPPER('x') || 'y' AS s, CAST('7' AS INT64) AS n, b FROM t GROUP BY b HAVING SUM(a * (2 - 1)) > 0", rule_fold_constants, \
"Project 'Xy' AS s, 7 AS n, t.b AS b\n  Filter (SUM((t.a * 1)) > 0)\n    Aggregate keys=[t.b] calls=[SUM((t.a * 1))]\n      Scan t AS t [a, b]\n"
    RCASE "SELECT t.a FROM t JOIN u ON t.a = u.a AND 2 > 1 ORDER BY t.a + (0 * 5)", rule_fold_constants, \
"Sort (t.a + 0)\n  Project t.a AS a\n    Join INNER ON (t.a = u.a)\n      Scan t AS t [a, b]\n      Scan u AS u [a]\n"

    /* ---- the whole optimizer */
    RCASE "SELECT t.a FROM t JOIN u ON t.a = u.a WHERE t.b = 1 + 1 AND u.a > 0 AND 3 > 2", optimize_on, \
"Project t.a AS a\n  Join INNER ON (t.a = u.a)\n    Filter (t.b = 2)\n      Scan t AS t [a, b]\n    Filter (u.a > 0)\n      Scan u AS u [a]\n"
    RCASE "SELECT t.a FROM t JOIN u ON t.a = u.a WHERE t.b = 1 + 1 AND u.a > 0 AND 3 > 2", optimize_off, \
"Project t.a AS a\n  Filter (((t.b = (1 + 1)) AND (u.a > 0)) AND (3 > 2))\n    Join INNER ON (t.a = u.a)\n      Scan t AS t [a, b]\n      Scan u AS u [a]\n"
    .quad 0, 0, 0

    .section .rodata
fmt_got: .asciz "  expected:\n%s  got:\n%s"

    .bss
    .p2align 4
out:    .zero BUF_SIZE

    .text

/* optimize_on(lp rdi, plan rsi) -> rax: optimize_logical with optimize: true */
FUNC optimize_on
    sub $8, %rsp
    movq $1, g_opt_optimize(%rip)
    call optimize_logical
    movq $0, g_opt_optimize(%rip)
    add $8, %rsp
    ret
ENDF optimize_on

/* optimize_off(lp rdi, plan rsi) -> rax: optimize_logical with optimize:
 * false, which must return the plan untouched */
FUNC optimize_off
    ENTER 16
    mov %rdi, %rbx
    movq $0, g_opt_optimize(%rip)
    call optimize_logical
    cmp %rax, %rbx
    sete %dil
    movzbl %dil, %edi
    CSTR %rsi, "optimize = false returns the same plan"
    call check
    mov %rbx, %rax
    LEAVE
ENDF optimize_off

/* run_case(entry rdi): binds the SQL with the optimizer off, applies the
 * rule and compares the printed plan */
FUNC run_case
    ENTER 16
    mov %rdi, %rbx
    movq $0, g_opt_optimize(%rip)
    mov 0(%rbx), %rdi
    call plan_of
    mov %rax, %r12                  /* plan */
    mov QP_LOGICAL(%r12), %r13
    mov 8(%rbx), %rax
    test %rax, %rax
    jz 1f
    mov %r13, %rdi
    mov %r12, %rsi
    call *%rax
    mov %rax, %r13
1:  lea out(%rip), %rdi
    movq $0, BUF_LEN(%rdi)
    mov %r13, %rsi
    mov %r12, %rdx
    call lp_print
    lea out(%rip), %rdi
    xor %esi, %esi
    call buf_putc                   /* NUL terminator */
    mov out+BUF_DATA(%rip), %rdi
    mov 16(%rbx), %rsi
    call strcmp
    xor %edi, %edi
    test %eax, %eax
    sete %dil
    mov %edi, %r14d
    mov 0(%rbx), %rsi
    call check
    test %r14d, %r14d
    jnz 9f
    lea fmt_got(%rip), %rdi
    mov 16(%rbx), %rsi
    mov out+BUF_DATA(%rip), %rdx
    xor %eax, %eax
    call printf
9:  LEAVE
ENDF run_case

FUNC main
    ENTER 16
    call arena_new
    mov %rax, g_arena(%rip)
    lea s_t(%rip), %rdi
    mov $2, %esi
    mov $100, %edx
    call mk_int_table
    lea s_u(%rip), %rdi
    mov $1, %esi
    mov $10, %edx
    call mk_int_table
    lea out(%rip), %rdi
    call buf_init

    lea cases(%rip), %rbx
1:  cmpq $0, (%rbx)
    je 2f
    mov %rbx, %rdi
    call run_case
    add $24, %rbx
    jmp 1b

2:  /* the rule table: names and order */
    lea opt_rule_names(%rip), %rbx
    mov 0(%rbx), %rdi
    CSTR %rsi, "pushdown"
    call strcmp
    mov %eax, %r12d
    mov 8(%rbx), %rdi
    CSTR %rsi, "prune_columns"
    call strcmp
    or %eax, %r12d
    mov 16(%rbx), %rdi
    CSTR %rsi, "fold_constants"
    call strcmp
    or %eax, %r12d
    xor %edi, %edi
    test %r12d, %r12d
    sete %dil
    CSTR %rsi, "rules: pushdown, prune_columns, fold_constants in order"
    call check

    /* folded and simplified nodes keep their form as written */
    movq $1, g_opt_optimize(%rip)
    CSTR %rdi, "SELECT a FROM t WHERE b = 1 + 2 OR FALSE"
    call plan_of
    mov QP_FROM(%rax), %rax
    mov FP_FILTER(%rax), %rbx       /* b = 3 */
    xor %edi, %edi
    mov N_WRITTEN(%rbx), %rax       /* (b = (1 + 2)) OR FALSE */
    test %rax, %rax
    jz 3f
    cmpl $B_OR, N_OP(%rax)
    jne 3f
    mov N_B(%rbx), %rax             /* 3, written as 1 + 2 */
    cmpl $EK_LIT, N_KIND(%rax)
    jne 3f
    mov N_WRITTEN(%rax), %rax
    test %rax, %rax
    jz 3f
    cmpl $B_ADD, N_OP(%rax)
    sete %dil
3:  CSTR %rsi, "fold_constants keeps rewritten expressions as written"
    call check

    CSTR %rdi, "test_optimizer"
    call test_done
    LEAVE
ENDF main
