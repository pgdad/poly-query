// =============================================================================
// test_exec5.S — unit tests for the Phase 5 executors: Volcano row mode
// (volcano.S), vectorized evaluation (vexec.S), hash aggregation (vagg.S),
// parallel tasks (parallel.S, ops.S), join algorithms (join.S) and the
// optimizer (optimize.S).
//
// Every case runs its SQL under six execution settings (mode x join x
// threads x optimize) with g_par_min_rows = 1, so even these 4-row tables are
// split into several parallel tasks. Each run must give the expected number
// of rows (or raise the expected error), and every run must produce the same
// order-independent checksum of the result cells as the first (row mode,
// nested loops, no optimization). Tables:
//
//   t: i INT64 [1, 2, NULL, 3]   s STRING ['a','b','c','d']
//      b BOOLEAN [TRUE, FALSE, NULL, NULL]
//   u: i INT64 [1, 1, 2, NULL]   v STRING ['x','y','z','w']
//      c BOOLEAN [NULL, TRUE, FALSE, TRUE]
//
// Exit status 0 iff all cases pass.
// =============================================================================
#include "pq.inc"
#include "frame.inc"

// Case record
#define TC_SQL    0
#define TC_ARG    8         // expected rows, or error code
#define TC_MODE   16
#define TC_SIZE   24
#define M_ROWS    0
#define M_ERR     1

#define NSET      6         // execution settings per case

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
    .quad s_t, 3, 4, cols_t
    .skip TBL_SIZE - TBL_ARENA
tbl_u:
    .quad s_u, 3, 4, cols_u
    .skip TBL_SIZE - TBL_ARENA
cols_t:
    .quad s_i;   .word T_INT, 0;   .quad t_i, t_inull
    .quad s_s;   .word T_STR, 0;   .quad t_s, nonull
    .quad s_b;   .word T_BOOL, 0;  .quad t_b, t_bnull
cols_u:
    .quad s_i;   .word T_INT, 0;   .quad u_i, u_inull
    .quad s_v;   .word T_STR, 0;   .quad u_v, nonull
    .quad s_c;   .word T_BOOL, 0;  .quad u_c, u_cnull
t_i:     .quad 1, 2, 0, 3
t_inull: .byte 0x04, 0, 0, 0
t_s:     .quad s_a, s_b2, s_c2, s_d
t_b:     .quad 1, 0, 0, 0
t_bnull: .byte 0x0c, 0, 0, 0
u_i:     .quad 1, 1, 2, 0
u_inull: .byte 0x08, 0, 0, 0
u_v:     .quad s_x, s_y, s_z, s_w
u_c:     .quad 0, 1, 0, 1
u_cnull: .byte 0x01, 0, 0, 0
nonull:  .byte 0, 0, 0, 0
    PSTR s_t, "t"
    PSTR s_u, "u"
    PSTR s_i, "i"
    PSTR s_s, "s"
    PSTR s_b, "b"
    PSTR s_v, "v"
    PSTR s_c, "c"
    PSTR s_a, "a"
    PSTR s_b2, "b"
    PSTR s_c2, "c"
    PSTR s_d, "d"
    PSTR s_x, "x"
    PSTR s_y, "y"
    PSTR s_z, "z"
    PSTR s_w, "w"

// execution settings: mode, join, threads, optimize
    .section .rodata
    .p2align 3
settings:
    .quad XM_ROW, XJ_NL,    1, 0
    .quad XM_ROW, XJ_HASH,  1, 1
    .quad XM_VEC, XJ_HASH,  4, 1
    .quad XM_VEC, XJ_MERGE, 3, 0
    .quad XM_VEC, XJ_NL,    2, 1
    .quad XM_VEC, XJ_AUTO,  8, 1

// ------------------------------------------------------------------ cases ---
    .section .data.cases, "aw"
    .p2align 3
cases_start:
    // joins (all algorithms), LEFT JOIN padding, residual conditions
    TR  "SELECT * FROM t JOIN u ON t.i = u.i", 3
    TR  "SELECT * FROM t LEFT JOIN u ON t.i = u.i", 5
    TR  "SELECT * FROM t LEFT JOIN u ON t.i = u.i AND u.v <> 'x'", 4
    TR  "SELECT * FROM t JOIN u ON t.i = u.i AND t.s < u.v", 3
    TR  "SELECT * FROM t a JOIN t b ON a.i < b.i", 3
    TR  "SELECT * FROM t JOIN u ON t.i = u.i JOIN t t2 ON t2.i = u.i", 3
    // three-valued logic in the vectorized evaluator
    TR  "SELECT t.b AND u.c, t.b OR u.c, NOT t.b FROM t CROSS JOIN u", 16
    TR  "SELECT * FROM t CROSS JOIN u WHERE (t.b AND u.c) IS NULL", 7
    TR  "SELECT * FROM t CROSS JOIN u WHERE (t.b OR u.c) IS NULL", 5
    TR  "SELECT * FROM t CROSS JOIN u WHERE t.b OR u.c", 10
    TR  "SELECT * FROM t WHERE NOT (i > 1 AND b)", 2
    // arithmetic, comparisons, strings, constants
    TR  "SELECT i + 1, i * 2, -i, i / 2, i % 2, i * 1.5 FROM t", 4
    TR  "SELECT s FROM t WHERE s > 'b' AND s <> 'd'", 1
    TR  "SELECT s FROM t WHERE i BETWEEN 2 AND 3 OR s = 'a'", 3
    TR  "SELECT 1 + 2 WHERE TRUE AND 1 = 1", 1
    TR  "SELECT i FROM t WHERE 1 = 0", 0
    TE  "SELECT i / 0 FROM t", ERR_DIVISION_BY_ZERO
    TE  "SELECT i FROM t WHERE i * 4611686018427387904 > 0", ERR_NUMERIC_OVERFLOW
    // grouping and aggregation (hash and sort based, partial merges)
    TR  "SELECT u.i, COUNT(*), COUNT(c), SUM(u.i), MIN(v), MAX(v) FROM u GROUP BY u.i", 3
    TR  "SELECT c, COUNT(*), AVG(i) FROM u GROUP BY c", 3
    TR  "SELECT COUNT(*), SUM(i), MIN(s), MAX(b) FROM t WHERE i > 100", 1
    TR  "SELECT COUNT(DISTINCT i), SUM(i) FROM u", 1
    TR  "SELECT v FROM u GROUP BY v HAVING COUNT(*) = 1", 4
    TR  "SELECT t.s, COUNT(u.v) FROM t LEFT JOIN u ON t.i = u.i GROUP BY t.s", 4
    TE  "SELECT SUM(i * 4611686018427387904) FROM u", ERR_NUMERIC_OVERFLOW
    // sorting, top-N, DISTINCT, subqueries
    TR  "SELECT i FROM t ORDER BY i DESC LIMIT 2", 2
    TR  "SELECT i FROM t ORDER BY i LIMIT 2 OFFSET 3", 1
    TR  "SELECT DISTINCT u.i FROM u", 3
    TR  "SELECT * FROM t WHERE i IN (SELECT i FROM u)", 2
    TR  "SELECT s, (SELECT COUNT(*) FROM u WHERE u.i = t.i) FROM t", 4
cases_end:

    .section .rodata
fmt_fail:   .asciz "FAIL: %s\n   setting %d: rows %lld, error %d, checksum %llx (expected %lld / first checksum %llx)\n"
fmt_sum:    .asciz "test_exec5: %d/%d passed\n"
    .text

// =============================================================================
// rs_checksum(x0 BoundQuery*, x1 ResultSet*) -> x0 order-independent hash
// of the visible cells (sum of per-row hashes)
//   x19 bq, x20 rs, x21 row, x22 column, x23 sum, x24 row hash
// =============================================================================
LFUNC rs_checksum
    ENTER 5
    mov  x19, x0
    mov  x20, x1
    mov  x23, #0
    mov  x21, #0
1:  ldr  x9, [x20, #RS_NROWS]
    cmp  x21, x9
    b.hs 5f
    mov  x24, #17
    mov  x22, #0
2:  ldr  x9, [x19, #BQ_NOUT]
    cmp  x22, x9
    b.hs 4f
    ldr  x9, [x20, #RS_ROWS]
    ldr  x9, [x9, x21, lsl #3]
    add  x9, x9, x22, lsl #4
    ldp  x0, x10, [x9]
    mov  x11, #0x5bd1
    cbnz x10, 3f                        // NULL
    ldr  x10, [x19, #BQ_OUT]
    mov  x11, #OC_SIZE
    madd x10, x22, x11, x10
    ldr  w1, [x10, #OC_TYPE]
    and  w12, w1, #T_KIND_MASK
    cbz  w12, 3f                        // null type
    bl   hash_cell
    mov  x11, x0
3:  eor  x24, x24, x11
    ldr  x9, =0x9e3779b97f4a7c15
    mul  x24, x24, x9
    add  x24, x24, x22
    add  x22, x22, #1
    b    2b
4:  add  x23, x23, x24
    add  x21, x21, #1
    b    1b
5:  mov  x0, x23
    LEAVE 5
ENDF rs_checksum

// =============================================================================
// run_once(x0 case*, x1 setting*) -> x0 rows (-1 on error), x1 error code,
// x2 checksum
// setjmp(g_jmpbuf) catches errors; only x19/x20 (set before) are used after
// a longjmp.
//   x19 case, x20 setting, x21 bq, x22 plan
// =============================================================================
LFUNC run_once
    ENTER 3
    mov  x19, x0
    mov  x20, x1
    ldr  x9, [x20]
    TLS_ADDR x10, g_opt_mode
    str  w9, [x10]
    ldr  x9, [x20, #8]
    TLS_ADDR x10, g_opt_join
    str  w9, [x10]
    ldr  x9, [x20, #16]
    TLS_ADDR x10, g_opt_threads
    str  x9, [x10]
    ldr  x9, [x20, #24]
    TLS_ADDR x10, g_opt_optimize
    str  w9, [x10]
    TLS_ADDR x0, g_jmpbuf
    bl   setjmp
    cbnz w0, 1f
    ldr  x21, [x19, #TC_SQL]
    mov  x0, x21
    bl   strlen
    mov  x1, x0
    mov  x0, x21
    bl   parse_sql
    ldr  x0, [x0, #ST_QUERY]
    bl   bind_query
    mov  x21, x0
    bl   plan_statement
    mov  x1, #0
    bl   exec_plan
    mov  x22, x0
    mov  x0, x21
    mov  x1, x22
    bl   rs_checksum
    mov  x2, x0
    ldr  x0, [x22, #RS_NROWS]
    mov  x1, #0
    LEAVE 3
1:  TLS_ADDR x9, g_err_code
    ldr  w1, [x9]
    mov  x0, #-1
    mov  x2, #0
    LEAVE 3
ENDF run_once

// =============================================================================
// run_case(x0 case*) -> w0 1 pass / 0 fail
//   x19 case, x20 setting index, x21 first checksum, x22 rows, x23 error,
//   x24 checksum
// =============================================================================
LFUNC run_case
    ENTER 5
    mov  x19, x0
    mov  x20, #0
1:  cmp  x20, #NSET
    b.hs 5f
    mov  x0, x19
    ADR_L x1, settings
    add  x1, x1, x20, lsl #5
    bl   run_once
    mov  x22, x0
    mov  x23, x1
    mov  x24, x2
    cbnz x20, 2f
    mov  x21, x24
2:  ldr  x9, [x19, #TC_MODE]
    cmp  x9, #M_ERR
    b.eq 3f
    ldr  x9, [x19, #TC_ARG]             // expected rows and checksum
    cmp  x22, x9
    b.ne 6f
    cmp  x24, x21
    b.ne 6f
    b    4f
3:  ldr  x9, [x19, #TC_ARG]             // expected error
    cmp  x23, x9
    b.ne 6f
4:  add  x20, x20, #1
    b    1b
5:  mov  w0, #1
    LEAVE 5
6:  ADR_L x0, fmt_fail
    ldr  x1, [x19, #TC_SQL]
    mov  x2, x20
    mov  x3, x22
    mov  x4, x23
    mov  x5, x24
    ldr  x6, [x19, #TC_ARG]
    mov  x7, x21
    bl   printf
    mov  w0, #0
    LEAVE 5
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
    mov  x9, #1                         // split even 4-row inputs
    ADR_L x10, g_par_min_rows
    str  x9, [x10]
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

    .ltorg
    NOTE_GNU_STACK
