// =============================================================================
// test_optimizer.S — unit tests for the logical plan (logical.S) and every
// optimizer rule (optimize.S, rule_*.S).
//
// Each case runs SQL through parse_sql -> bind_query -> lp_build, applies up
// to two rules (or the whole optimizer, `optimize`) to the logical plan of
// the statement and compares the printed plan (lp_print: one line per
// operator, inputs indented by two spaces) with the expected text. Rules are applied on their own, so each case shows exactly what one
// rule does. Two hand-built tables are registered:
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
#define TC_OPT    8         // g_opt_optimize while the rules run
#define TC_R1     16        // first rule (LogicalNode* -> LogicalNode*) or 0
#define TC_R2     24        // second rule or 0
#define TC_EXP    32        // expected lp_print text
#define TC_SIZE   40

// A case: TO sql, rule1, rule2 (optimize on) or TOFF sql, rule1 (optimize
// off), then the expected plan, one PL line per operator, then TEND.
.macro TO sql, r1, r2, opt=1
    .section .rodata
9990: .asciz "\sql"
9991:
    .section .data.cases, "aw"
    .quad 9990b, \opt, \r1, \r2, 9991b
    .section .rodata
.endm
.macro TOFF sql, r1
    TO "\sql", \r1, 0, 0
.endm
.macro PL text
    .ascii "\text\n"
.endm
.macro TEND
    .byte 0
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

// ------------------------------------------------------------------ cases ---
    .section .data.cases, "aw"
    .p2align 3
cases_start:
    // --- logical plan construction (no rule)
    TO  "SELECT s FROM t WHERE i > 1", 0, 0
    PL  "Project out=[t.s]"
    PL  "  Filter (t.i > 1)"
    PL  "    Scan t AS t"
    TEND
    TO  "SELECT DISTINCT t.s FROM t JOIN u ON t.i = u.i ORDER BY t.s LIMIT 2 OFFSET 1", 0, 0
    PL  "Limit limit=2 offset=1"
    PL  "  Sort keys=1"
    PL  "    Distinct"
    PL  "      Project out=[t.s]"
    PL  "        Join INNER on (t.i = u.i)"
    PL  "          Scan t AS t"
    PL  "          Scan u AS u"
    TEND
    TO  "SELECT s, COUNT(*) AS n FROM t GROUP BY s HAVING COUNT(*) > 1", 0, 0
    PL  "Aggregate keys=[t.s] aggs=[COUNT(), COUNT()] having (COUNT() > 1) out=[key#0, COUNT()]"
    PL  "  Scan t AS t"
    TEND
    TO  "SELECT x.s FROM (SELECT s FROM t) x, u CROSS JOIN t AS t2", 0, 0
    PL  "Project out=[x.s]"
    PL  "  Join CROSS"
    PL  "    Join CROSS"
    PL  "      SubqueryScan x"
    PL  "      Scan u AS u"
    PL  "    Scan t AS t2"
    TEND
    TO  "SELECT i FROM t UNION ALL SELECT i FROM u WHERE v = 'x' ORDER BY i", 0, 0
    PL  "Sort keys=1"
    PL  "  UnionAll"
    PL  "    Project out=[t.i]"
    PL  "      Scan t AS t"
    PL  "    Project out=[u.i]"
    PL  "      Filter (u.v = \"x\")"
    PL  "        Scan u AS u"
    TEND
    TO  "SELECT 1 AS one", 0, 0
    PL  "Project out=[1]"
    PL  "  Values"
    TEND
    TO  "SELECT s FROM t WHERE i IN (SELECT i FROM u) AND EXISTS (SELECT 1 FROM u WHERE u.i = t.i)", 0, 0
    PL  "Project out=[t.s]"
    PL  "  Filter (IN_SUBQUERY(t.i) AND EXISTS())"
    PL  "    Scan t AS t"
    TEND
    // --- fold_constants
    TO  "SELECT i + (1 + 2) AS x FROM t WHERE i > 2 * 3", rule_fold_constants, 0
    PL  "Project out=[(t.i + 3)]"
    PL  "  Filter (t.i > 6)"
    PL  "    Scan t AS t"
    TEND
    TO  "SELECT 1 / 0 AS x, 2 + 2 AS y FROM t", rule_fold_constants, 0
    PL  "Project out=[(1 / 0), 4]"
    PL  "  Scan t AS t"
    TEND
    TO  "SELECT s FROM t WHERE s = UPPER('a') OR i = CAST('7' AS INT64)", rule_fold_constants, 0
    PL  "Project out=[t.s]"
    PL  "  Filter ((t.s = \"A\") OR (t.i = 7))"
    PL  "    Scan t AS t"
    TEND
    TO  "SELECT SUM(i * (2 - 1)) AS x FROM t GROUP BY s HAVING COUNT(*) > 1 + 1", rule_fold_constants, 0
    PL  "Aggregate keys=[t.s] aggs=[SUM((t.i * 1)), COUNT()] having (COUNT() > 2) out=[SUM((t.i * 1))]"
    PL  "  Scan t AS t"
    TEND
    TO  "SELECT t.s FROM t JOIN u ON t.i = u.i + (3 - 3)", rule_fold_constants, 0
    PL  "Project out=[t.s]"
    PL  "  Join INNER on (t.i = (u.i + 0))"
    PL  "    Scan t AS t"
    PL  "    Scan u AS u"
    TEND
    // --- simplify_predicates
    TO  "SELECT s FROM t WHERE i = 1 AND TRUE", rule_simplify_predicates, 0
    PL  "Project out=[t.s]"
    PL  "  Filter (t.i = 1)"
    PL  "    Scan t AS t"
    TEND
    TO  "SELECT s FROM t WHERE TRUE", rule_simplify_predicates, 0
    PL  "Project out=[t.s]"
    PL  "  Scan t AS t"
    TEND
    TO  "SELECT s FROM t WHERE FALSE OR NOT NOT i > 1", rule_simplify_predicates, 0
    PL  "Project out=[t.s]"
    PL  "  Filter (t.i > 1)"
    PL  "    Scan t AS t"
    TEND
    TO  "SELECT s FROM t WHERE TRUE OR i > 1", rule_simplify_predicates, 0
    PL  "Project out=[t.s]"
    PL  "  Scan t AS t"
    TEND
    TO  "SELECT s FROM t WHERE FALSE AND i > 1", rule_simplify_predicates, 0
    PL  "Project out=[t.s]"
    PL  "  Filter false"
    PL  "    Scan t AS t"
    TEND
    TO  "SELECT t.s FROM t JOIN u ON TRUE AND t.i = u.i", rule_simplify_predicates, 0
    PL  "Project out=[t.s]"
    PL  "  Join INNER on (t.i = u.i)"
    PL  "    Scan t AS t"
    PL  "    Scan u AS u"
    TEND
    TO  "SELECT s FROM t WHERE 1 = 1", rule_simplify_predicates, 0
    PL  "Project out=[t.s]"
    PL  "  Filter (1 = 1)"
    PL  "    Scan t AS t"
    TEND
    TO  "SELECT s FROM t WHERE 1 = 1", rule_fold_constants, rule_simplify_predicates
    PL  "Project out=[t.s]"
    PL  "  Scan t AS t"
    TEND
    // --- push_filters
    TO  "SELECT t.s FROM t, u WHERE t.i = u.i AND u.v = 'x' AND t.i > 1", rule_push_filters, 0
    PL  "Project out=[t.s]"
    PL  "  Join INNER on (t.i = u.i)"
    PL  "    Scan t AS t filter=(t.i > 1)"
    PL  "    Scan u AS u filter=(u.v = \"x\")"
    TEND
    TO  "SELECT t.s FROM t LEFT JOIN u ON t.i = u.i WHERE u.v IS NULL AND t.s = 'a'", rule_push_filters, 0
    PL  "Project out=[t.s]"
    PL  "  Filter ISNULL(u.v)"
    PL  "    Join LEFT on (t.i = u.i)"
    PL  "      Scan t AS t filter=(t.s = \"a\")"
    PL  "      Scan u AS u"
    TEND
    TO  "SELECT s FROM t WHERE i > 1 AND 1 = 2", rule_push_filters, 0
    PL  "Project out=[t.s]"
    PL  "  Filter (1 = 2)"
    PL  "    Scan t AS t filter=(t.i > 1)"
    TEND
    TO  "SELECT s FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.i = t.i)", rule_push_filters, 0
    PL  "Project out=[t.s]"
    PL  "  Scan t AS t filter=EXISTS()"
    TEND
    TO  "SELECT t.s FROM t, u, t AS t2 WHERE t.i = t2.i AND u.v = t2.s", rule_push_filters, 0
    PL  "Project out=[t.s]"
    PL  "  Join INNER on ((t.i = t2.i) AND (u.v = t2.s))"
    PL  "    Join CROSS"
    PL  "      Scan t AS t"
    PL  "      Scan u AS u"
    PL  "    Scan t AS t2"
    TEND
    TO  "SELECT x.s FROM (SELECT s FROM t) x WHERE x.s <> 'b'", rule_push_filters, 0
    PL  "Project out=[x.s]"
    PL  "  SubqueryScan x filter=(x.s <> \"b\")"
    TEND
    // --- push_join_conditions
    TO  "SELECT t.s FROM t JOIN u ON t.i = u.i AND u.v = 'x' AND t.s = 'a'", rule_push_join_conditions, 0
    PL  "Project out=[t.s]"
    PL  "  Join INNER on (t.i = u.i)"
    PL  "    Scan t AS t filter=(t.s = \"a\")"
    PL  "    Scan u AS u filter=(u.v = \"x\")"
    TEND
    TO  "SELECT t.s FROM t LEFT JOIN u ON t.i = u.i AND u.v = 'x' AND t.s = 'a'", rule_push_join_conditions, 0
    PL  "Project out=[t.s]"
    PL  "  Join LEFT on ((t.i = u.i) AND (t.s = \"a\"))"
    PL  "    Scan t AS t"
    PL  "    Scan u AS u filter=(u.v = \"x\")"
    TEND
    TO  "SELECT t.s FROM t JOIN u ON t.i = u.i JOIN t AS t2 ON t2.i = u.i AND u.v = 'y' AND t.s = t2.s", rule_push_join_conditions, 0
    PL  "Project out=[t.s]"
    PL  "  Join INNER on ((t2.i = u.i) AND (t.s = t2.s))"
    PL  "    Join INNER on (t.i = u.i)"
    PL  "      Scan t AS t"
    PL  "      Scan u AS u filter=(u.v = \"y\")"
    PL  "    Scan t AS t2"
    TEND
    TO  "SELECT t.s FROM t JOIN u ON 1 = 1", rule_push_join_conditions, 0
    PL  "Project out=[t.s]"
    PL  "  Join INNER on (1 = 1)"
    PL  "    Scan t AS t"
    PL  "    Scan u AS u"
    TEND
    // --- reorder_joins
    TO  "SELECT t.s FROM t, u, t AS t2 WHERE t.i = u.i AND u.i = t2.i AND t2.s = 'a'", rule_push_filters, rule_reorder_joins
    PL  "Project out=[t.s]"
    PL  "  Join INNER on (t.i = u.i)"
    PL  "    Join INNER on (u.i = t2.i)"
    PL  "      Scan t AS t2 filter=(t2.s = \"a\")"
    PL  "      Scan u AS u"
    PL  "    Scan t AS t"
    TEND
    TO  "SELECT t.s FROM t JOIN u ON t.i = u.i JOIN t AS t2 ON t2.i = u.i", rule_reorder_joins, 0
    PL  "Project out=[t.s]"
    PL  "  Join INNER on (t2.i = u.i)"
    PL  "    Join INNER on (t.i = u.i)"
    PL  "      Scan t AS t"
    PL  "      Scan u AS u"
    PL  "    Scan t AS t2"
    TEND
    TO  "SELECT t.s FROM t LEFT JOIN u ON t.i = u.i", rule_reorder_joins, 0
    PL  "Project out=[t.s]"
    PL  "  Join LEFT on (t.i = u.i)"
    PL  "    Scan t AS t"
    PL  "    Scan u AS u"
    TEND
    TO  "SELECT t.s FROM t JOIN u ON t.i = u.i", rule_reorder_joins, 0
    PL  "Project out=[t.s]"
    PL  "  Join INNER on (t.i = u.i)"
    PL  "    Scan t AS t"
    PL  "    Scan u AS u"
    TEND
    // --- prune_columns
    TO  "SELECT s FROM t WHERE i > 1", rule_prune_columns, 0
    PL  "Project out=[t.s]"
    PL  "  Filter (t.i > 1)"
    PL  "    Scan t AS t columns=[i,s]"
    TEND
    TO  "SELECT COUNT(*) AS n FROM t", rule_prune_columns, 0
    PL  "Aggregate keys=[] aggs=[COUNT()] out=[COUNT()]"
    PL  "  Scan t AS t columns=[]"
    TEND
    TO  "SELECT s FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.i = t.i)", rule_prune_columns, 0
    PL  "Project out=[t.s]"
    PL  "  Filter EXISTS()"
    PL  "    Scan t AS t columns=[i,s]"
    TEND
    TO  "SELECT t.s FROM t JOIN u ON t.i = u.i", rule_prune_columns, 0
    PL  "Project out=[t.s]"
    PL  "  Join INNER on (t.i = u.i)"
    PL  "    Scan t AS t columns=[i,s]"
    PL  "    Scan u AS u columns=[i]"
    TEND
    TO  "SELECT * FROM u", rule_prune_columns, 0
    PL  "Project out=[u.i, u.v]"
    PL  "  Scan u AS u columns=[i,v]"
    TEND
    TO  "SELECT i FROM t UNION ALL SELECT i FROM u WHERE v = 'x'", rule_prune_columns, 0
    PL  "UnionAll"
    PL  "  Project out=[t.i]"
    PL  "    Scan t AS t columns=[i]"
    PL  "  Project out=[u.i]"
    PL  "    Filter (u.v = \"x\")"
    PL  "      Scan u AS u columns=[i,v]"
    TEND
    // --- the optimizer: every rule in order; none with optimize = false
    TO  "SELECT t.s FROM t, u WHERE t.i = u.i AND u.v = 'x' AND 1 + 1 = 2", optimize, 0
    PL  "Project out=[t.s]"
    PL  "  Join INNER on (t.i = u.i)"
    PL  "    Scan t AS t columns=[i,s]"
    PL  "    Scan u AS u columns=[i,v] filter=(u.v = \"x\")"
    TEND
    TOFF "SELECT t.s FROM t, u WHERE t.i = u.i AND u.v = 'x' AND 1 + 1 = 2", optimize
    PL  "Project out=[t.s]"
    PL  "  Filter (((t.i = u.i) AND (u.v = \"x\")) AND ((1 + 1) = 2))"
    PL  "    Join CROSS"
    PL  "      Scan t AS t"
    PL  "      Scan u AS u"
    TEND
    .section .data.cases, "aw"
cases_end:

    .section .rodata
fmt_fail:   .asciz "FAIL: %s\n--- expected:\n%s--- got:\n%s"
fmt_err:    .asciz "FAIL: %s\n   error %d\n"
fmt_sum:    .asciz "test_optimizer: %d/%d passed\n"
    .text

// =============================================================================
// run_case(x0 case*) -> w0 1 pass / 0 fail
// setjmp(g_jmpbuf) catches errors raised below; only x19 (set before setjmp)
// is used after a longjmp.
//   x19 case, x20 plan
// Stack: Buf at [sp] (BUF_SIZE)
// =============================================================================
LFUNC run_case
    ENTER 2
    sub  sp, sp, #32
    mov  x19, x0
    stp  xzr, xzr, [sp]
    stp  xzr, xzr, [sp, #16]
    ldr  x9, [x19, #TC_OPT]
    TLS_ADDR x10, g_opt_optimize
    str  w9, [x10]
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
    bl   lp_build
    ldr  x9, [x19, #TC_R1]
    cbz  x9, 1f
    blr  x9
    ldr  x9, [x19, #TC_R2]
    cbz  x9, 1f
    blr  x9
1:  mov  x1, x0
    mov  x0, sp
    bl   lp_print
    mov  x0, sp                         // NUL-terminate the text
    mov  w1, #0
    bl   buf_putc
    ldr  x0, [sp, #BUF_PTR]
    ldr  x1, [x19, #TC_EXP]
    bl   strcmp
    cbz  w0, .Lrc_pass
    ADR_L x0, fmt_fail
    ldr  x1, [x19, #TC_SQL]
    ldr  x2, [x19, #TC_EXP]
    ldr  x3, [sp, #BUF_PTR]
    bl   printf
    b    .Lrc_fail
.Lrc_error:
    ADR_L x0, fmt_err
    ldr  x1, [x19, #TC_SQL]
    TLS_ADDR x9, g_err_code
    ldr  w2, [x9]
    bl   printf
.Lrc_fail:
    mov  w19, #0
    b    .Lrc_ret
.Lrc_pass:
    mov  w19, #1
.Lrc_ret:
    ldr  x0, [sp, #BUF_PTR]
    bl   free
    TLS_ADDR x10, g_opt_optimize
    mov  w9, #1
    str  w9, [x10]
    mov  w0, w19
    add  sp, sp, #32
    LEAVE 2
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
