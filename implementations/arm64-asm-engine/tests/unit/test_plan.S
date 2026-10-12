// =============================================================================
// test_plan.S — unit tests for plan.S (logical/physical planning, EXPLAIN)
// and exec.S (joins, grouping, DISTINCT, subqueries).
//
// Each case runs SQL through parse_sql -> bind_query -> plan_statement and
// then, by mode, checks the EXPLAIN JSON (plan_explain) for a substring, the
// absence of a substring, the number of result rows (exec_plan), or an
// expected error code. Two hand-built tables are registered:
//
//   t: i INT64 [1, 2, NULL, 3]      s STRING ['a', 'b', 'c', 'd']
//   u: i INT64 [1, 1, 2, NULL]      v STRING ['x', 'y', 'z', 'w']
//
// Exit status 0 iff all cases pass.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

// Case record
#define TC_SQL    0
#define TC_ARG    8         // cstr (substring modes) or row count / error code
#define TC_MODE   16
#define TC_SIZE   24

#define M_HAS     0         // EXPLAIN JSON contains TC_ARG
#define M_HASNOT  1         // EXPLAIN JSON does not contain TC_ARG
#define M_ROWS    2         // result has TC_ARG rows
#define M_ERR     3         // raises error code TC_ARG

.macro TP sql, arg, mode
    .section .rodata
9990: .asciz "\sql"
9991: .asciz "\arg"
    .section .data.cases, "aw"
    .quad 9990b, 9991b, \mode
.endm
.macro TR sql, rows
    .section .rodata
9990: .asciz "\sql"
    .section .data.cases, "aw"
    .quad 9990b, \rows, M_ROWS
.endm
.macro TE sql, code
    .section .rodata
9990: .asciz "\sql"
    .section .data.cases, "aw"
    .quad 9990b, \code, M_ERR
.endm

.macro PSTR label, text
    .p2align 3
\label: .quad 9992f - 9993f
9993: .ascii "\text"
9992: .byte 0
.endm

// ------------------------------------------------------------- test tables ---
    .data
    .p2align 4
tbl_t:
    .quad s_t, 2, 4, cols_t
    .skip TBL_SIZE - TBL_ARENA
tbl_u:
    .quad s_u, 2, 4, cols_u
    .skip TBL_SIZE - TBL_ARENA
cols_t:
    .quad s_i;   .word T_INT, 0;   .quad t_i, t_inull
    .quad s_s;   .word T_STR, 0;   .quad t_s, nonull
cols_u:
    .quad s_i;   .word T_INT, 0;   .quad u_i, u_inull
    .quad s_v;   .word T_STR, 0;   .quad u_v, nonull
t_i:     .quad 1, 2, 0, 3
t_inull: .byte 0x04, 0, 0, 0    // null bitmaps
t_s:     .quad s_a, s_b, s_c, s_d
u_i:     .quad 1, 1, 2, 0
u_inull: .byte 0x08, 0, 0, 0
u_v:     .quad s_x, s_y, s_z, s_w
nonull:  .byte 0, 0, 0, 0
    PSTR s_t, "t"
    PSTR s_u, "u"
    PSTR s_i, "i"
    PSTR s_s, "s"
    PSTR s_v, "v"
    PSTR s_a, "a"
    PSTR s_b, "b"
    PSTR s_c, "c"
    PSTR s_d, "d"
    PSTR s_x, "x"
    PSTR s_y, "y"
    PSTR s_z, "z"
    PSTR s_w, "w"
    PSTR s_ti, "ti"
    PSTR s_ui, "ui"

// ------------------------------------------------------------------ cases ---
    .section .data.cases, "aw"
    .p2align 3
cases_start:
    // --- physical planning: join algorithm, pushdown, pruning
    TP  "SELECT t.s FROM t JOIN u ON t.i = u.i", "\"op\":\"HashJoin\",\"join_type\":\"INNER\"", M_HAS
    TP  "SELECT t.s FROM t JOIN u ON t.i < u.i", "\"op\":\"NestedLoopJoin\"", M_HAS
    TP  "SELECT t.s FROM t, u WHERE t.i = u.i", "\"op\":\"HashJoin\",\"join_type\":\"INNER\"", M_HAS
    TP  "SELECT t.s FROM t, u WHERE t.i = u.i", "\"op\":\"Filter\"", M_HASNOT
    TP  "SELECT t.s FROM t CROSS JOIN u", "\"join_type\":\"CROSS\"", M_HAS
    TP  "SELECT t.s FROM t LEFT JOIN u ON t.i = u.i", "\"op\":\"HashJoin\",\"join_type\":\"LEFT\"", M_HAS
    TP  "SELECT t.s FROM t LEFT JOIN u ON t.i = u.i WHERE u.v IS NULL", "\"op\":\"Filter\"", M_HAS
    TP  "SELECT t.s FROM t LEFT JOIN u ON t.i = u.i WHERE t.s = 'a'", "\"op\":\"Filter\"", M_HASNOT
    TP  "SELECT s FROM t WHERE i = 1", "\"columns\":[\"i\",\"s\"],\"filter\":true", M_HAS
    TP  "SELECT s FROM t WHERE i = 1", "\"op\":\"Filter\"", M_HASNOT
    TP  "SELECT s FROM t", "\"table\":\"t\",\"alias\":\"t\",\"columns\":[\"s\"]", M_HAS
    TP  "SELECT * FROM t", "\"columns\":[\"i\",\"s\"]", M_HAS
    TP  "SELECT COUNT(*) FROM t", "\"columns\":[]", M_HAS
    TP  "SELECT COUNT(*) FROM t GROUP BY s", "\"op\":\"Aggregate\"", M_HAS
    TP  "SELECT DISTINCT s FROM t ORDER BY s LIMIT 1", "{\"op\":\"Limit\",\"children\":[{\"op\":\"Sort\",\"children\":[{\"op\":\"Distinct\"", M_HAS
    TP  "SELECT x.s FROM (SELECT s FROM t) x", "\"op\":\"SubqueryScan\",\"alias\":\"x\"", M_HAS
    TP  "WITH c AS (SELECT i FROM u) SELECT * FROM c", "\"op\":\"SubqueryScan\",\"alias\":\"c\"", M_HAS
    TP  "SELECT 1", "\"op\":\"Values\"", M_HAS
    // --- execution: joins
    TR  "SELECT * FROM t JOIN u ON t.i = u.i", 3
    TR  "SELECT * FROM t LEFT JOIN u ON t.i = u.i", 5
    TR  "SELECT * FROM t LEFT JOIN u ON t.i = u.i AND u.v = 'z'", 4
    TR  "SELECT * FROM t LEFT JOIN u ON t.i = u.i WHERE u.v = 'z'", 1
    TR  "SELECT * FROM t CROSS JOIN u", 16
    TR  "SELECT * FROM t a JOIN t b ON a.i < b.i", 3
    TR  "SELECT * FROM t JOIN u ON t.i = u.i JOIN t t2 ON t2.i = u.i", 3
    // --- grouping / distinct
    TR  "SELECT s FROM t GROUP BY s", 4
    TR  "SELECT u.i, COUNT(*) FROM u GROUP BY u.i", 3
    TR  "SELECT DISTINCT u.i FROM u", 3
    TR  "SELECT COUNT(*) FROM t WHERE i > 100", 1
    TR  "SELECT i FROM t WHERE i > 100 GROUP BY i", 0
    TR  "SELECT i FROM u GROUP BY i HAVING COUNT(*) > 1", 1
    // --- subqueries
    TR  "SELECT i FROM t WHERE i IN (SELECT i FROM u)", 2
    TR  "SELECT i FROM t WHERE i NOT IN (SELECT i FROM u)", 0
    TR  "SELECT i FROM t WHERE i NOT IN (SELECT i FROM u WHERE i IS NOT NULL)", 1
    TR  "SELECT s FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.i = t.i)", 2
    TR  "SELECT s FROM t WHERE i = (SELECT MAX(i) FROM u)", 1
    TR  "SELECT (SELECT COUNT(*) FROM u WHERE u.i = t.i) FROM t", 4
    TR  "WITH c AS (SELECT i FROM u WHERE i IS NOT NULL) SELECT * FROM c a JOIN c b ON a.i = b.i", 5
    TE  "SELECT (SELECT i FROM u) FROM t", ERR_SUBQUERY_CARDINALITY
    TE  "SELECT i FROM t JOIN u ON t.i = u.i", ERR_SEMANTIC
    TE  "SELECT s FROM t GROUP BY i", ERR_SEMANTIC
    TE  "SELECT i, (SELECT COUNT(*) FROM u WHERE u.v = t.s) FROM t GROUP BY i", ERR_SEMANTIC
    TR  "SELECT i, (SELECT COUNT(*) FROM u WHERE u.i = t.i) FROM t GROUP BY i", 4
    TE  "SELECT * FROM t a JOIN (t b JOIN u ON u.i = a.i) ON a.i = b.i", ERR_SEMANTIC
    TR  "SELECT * FROM t a JOIN (t b JOIN u ON u.i = b.i) ON a.i = b.i", 3
    TP  "SELECT s FROM t WHERE i IN (SELECT i FROM u)", "\"table\":\"u\"", M_HAS
    TP  "SELECT (SELECT MAX(v) FROM u)", "\"op\":\"Values\",\"children\":[]},{\"op\":\"Aggregate\"", M_HAS
    // --- indexes (t.i HASH index "ti", u.i BTREE index "ui"), access paths
    TP  "SELECT s FROM t WHERE i = 2", "\"op\":\"IndexScan\",\"table\":\"t\",\"alias\":\"t\",\"columns\":[\"i\",\"s\"],\"filter\":true,\"index\":\"ti\",\"kind\":\"HASH\"", M_HAS
    TP  "SELECT s FROM t WHERE 2 = i AND s <> 'x'", "\"index\":\"ti\"", M_HAS
    TP  "SELECT s FROM t WHERE i > 1", "IndexScan", M_HASNOT
    TP  "SELECT v FROM u WHERE i > 5 AND i <= 7", "\"index\":\"ui\",\"kind\":\"BTREE\"", M_HAS
    TP  "SELECT v FROM u WHERE i = 1 OR i = 2", "IndexScan", M_HASNOT
    TP  "SELECT * FROM t JOIN u ON t.i = u.i WHERE u.v = 'x'", "\"alias\":\"t\",\"columns\":[\"i\",\"s\"],\"estimated_rows\":4", M_HAS
    TR  "SELECT s FROM t WHERE i = 2", 1
    TR  "SELECT s FROM t WHERE i = NULL", 0
    TR  "SELECT s FROM t WHERE i IN (1, 3, 3, NULL)", 2
    TR  "SELECT s FROM t WHERE i = 2.0", 1
    TR  "SELECT s FROM t WHERE i = 2.5", 0
    TR  "SELECT v FROM u WHERE i >= 1", 3
    TR  "SELECT v FROM u WHERE i > 1", 1
    TR  "SELECT v FROM u WHERE i BETWEEN 1 AND 1", 2
    TR  "SELECT v FROM u WHERE i < 1", 0
    TR  "SELECT v FROM u WHERE i <= -1 OR i IS NULL", 1
    TR  "SELECT * FROM t JOIN u ON t.i = u.i WHERE u.i = 1", 2
    // UNION ALL (CR-1)
    TP  "SELECT i FROM t UNION ALL SELECT i FROM u", "{\"op\":\"UnionAll\",\"children\":[{\"op\":\"Project\"", M_HAS
    TP  "SELECT i FROM t UNION ALL SELECT i FROM u ORDER BY 1 LIMIT 2", "{\"op\":\"Limit\",\"children\":[{\"op\":\"Sort\",\"children\":[{\"op\":\"UnionAll\"", M_HAS
    TP  "SELECT * FROM (SELECT i FROM t UNION ALL SELECT 5) x", "\"SubqueryScan\",\"alias\":\"x\",\"children\":[{\"op\":\"UnionAll\"", M_HAS
    TR  "SELECT i FROM t UNION ALL SELECT i FROM u", 8
    TR  "SELECT i FROM t UNION ALL SELECT i FROM u UNION ALL SELECT 1", 9
    TR  "SELECT i FROM t UNION ALL SELECT i FROM u ORDER BY i LIMIT 3 OFFSET 4", 3
    TR  "SELECT s FROM t WHERE i IN (SELECT i FROM u WHERE i > 1 UNION ALL SELECT 3)", 2
    TR  "SELECT DISTINCT i FROM (SELECT i FROM t UNION ALL SELECT i FROM u) x", 4
    TR  "SELECT 1 WHERE EXISTS (SELECT i FROM t WHERE i > 9 UNION ALL SELECT i FROM u WHERE i > 9)", 0
    TR  "SELECT s FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.i = t.i UNION ALL SELECT 1 WHERE t.s = 'd')", 3
    TE  "SELECT i, s FROM t UNION ALL SELECT i FROM u", ERR_SEMANTIC
    TE  "SELECT s FROM t UNION ALL SELECT i FROM u", ERR_TYPE
    TE  "SELECT i FROM t UNION ALL SELECT i FROM u ORDER BY i + 1", ERR_SEMANTIC
    TE  "SELECT i FROM t UNION ALL SELECT i FROM u ORDER BY v", ERR_SEMANTIC
    TE  "SELECT i FROM t UNION ALL SELECT 999999999999999999 UNION ALL SELECT 1.5", ERR_NUMERIC_OVERFLOW
cases_end:

    .section .rodata
fmt_fail:   .asciz "FAIL: %s\n   explain/result: %s (rows %lld, error %d)\n"
fmt_sum:    .asciz "test_plan: %d/%d passed\n"
    .text

// =============================================================================
// run_case(x0 case*) -> w0 1 pass / 0 fail
// setjmp(g_jmpbuf) catches errors raised below; only x19 (set before setjmp)
// is used after a longjmp.
//   x19 case, x20 root plan, x21 rows / scratch
// Stack: Buf at [sp] (BUF_SIZE), [sp+32] error code, [sp+40] row count
// =============================================================================
LFUNC run_case
    ENTER 3
    sub  sp, sp, #48
    mov  x19, x0
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    mov  x9, #-1
    stp  xzr, x9, [sp, #32]
    TLS_ADDR x0, g_jmpbuf
    bl   setjmp
    cbnz w0, .Lrc_error
    ldr  x20, [x19, #TC_SQL]
    mov  x0, x20
    bl   strlen
    mov  x1, x0
    mov  x0, x20
    bl   parse_sql
    ldr  x0, [x0, #ST_QUERY]
    bl   bind_query
    bl   plan_statement
    mov  x20, x0
    mov  x0, sp
    mov  x1, x20
    bl   plan_explain
    mov  x0, sp                         // NUL-terminate the JSON
    mov  w1, #0
    bl   buf_putc
    ldr  x9, [x19, #TC_MODE]
    cmp  x9, #M_HAS
    b.eq .Lrc_has
    cmp  x9, #M_HASNOT
    b.eq .Lrc_hasnot
    mov  x0, x20
    mov  x1, #0
    bl   exec_plan
    ldr  x21, [x0, #RS_NROWS]
    str  x21, [sp, #40]
    ldr  x9, [x19, #TC_MODE]
    cmp  x9, #M_ROWS
    b.ne .Lrc_fail                      // expected an error
    ldr  x9, [x19, #TC_ARG]
    cmp  x21, x9
    b.eq .Lrc_pass
    b    .Lrc_fail
.Lrc_has:
    ldr  x0, [sp, #BUF_PTR]
    ldr  x1, [x19, #TC_ARG]
    bl   strstr
    cbnz x0, .Lrc_pass
    b    .Lrc_fail
.Lrc_hasnot:
    ldr  x0, [sp, #BUF_PTR]
    ldr  x1, [x19, #TC_ARG]
    bl   strstr
    cbz  x0, .Lrc_pass
    b    .Lrc_fail
.Lrc_error:
    TLS_ADDR x9, g_err_code
    ldr  w9, [x9]
    str  x9, [sp, #32]
    ldr  x10, [x19, #TC_MODE]
    cmp  x10, #M_ERR
    b.ne .Lrc_fail
    ldr  x10, [x19, #TC_ARG]
    cmp  x9, x10
    b.eq .Lrc_pass
.Lrc_fail:
    ADR_L x0, fmt_fail
    ldr  x1, [x19, #TC_SQL]
    ldr  x2, [sp, #BUF_PTR]
    ADR_L x9, s_none
    cmp  x2, #0
    csel x2, x9, x2, eq
    ldr  x3, [sp, #40]
    ldr  x4, [sp, #32]
    bl   printf
    mov  w19, #0
    b    .Lrc_ret
.Lrc_pass:
    mov  w19, #1
.Lrc_ret:
    ldr  x0, [sp, #BUF_PTR]
    bl   free
    mov  w0, w19
    add  sp, sp, #48
    LEAVE 3
s_none: .asciz "-"
    .p2align 2
ENDF run_case

// =============================================================================
// main — runs every case; exit status 0 iff all pass.
//   x19 case cursor, x20 end, x21 failures, x22 total
// =============================================================================
FUNC main
    ENTER 2
    ADR_L x0, tbl_t
    bl   catalog_add
    ADR_L x0, tbl_u
    bl   catalog_add
    ADR_L x0, tbl_t                     // indexes: t(i) HASH, u(i) BTREE
    ADR_L x1, s_ti
    mov  x2, #0
    mov  w3, #IXK_HASH
    bl   index_create
    ADR_L x0, tbl_u
    ADR_L x1, s_ui
    mov  x2, #0
    mov  w3, #IXK_BTREE
    bl   index_create
    ADR_L x19, cases_start
    ADR_L x20, cases_end
    mov  x21, #0
    mov  x22, #0
1:  cmp  x19, x20
    b.hs 2f
    mov  x0, x19
    bl   run_case
    cmp  w0, #0
    cinc x21, x21, eq
    add  x22, x22, #1
    TLS_ADDR x0, g_arena
    bl   arena_free
    add  x19, x19, #TC_SIZE
    b    1b
2:  ADR_L x0, fmt_sum
    sub  x1, x22, x21
    mov  x2, x22
    bl   printf
    mov  x0, #0
    bl   fflush
    cmp  x21, #0
    cset w0, ne
    LEAVE 2
ENDF main

    NOTE_GNU_STACK
